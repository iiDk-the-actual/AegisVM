--[[
    Parser.luau - Recursive-descent Luau parser

    Consumes the token list produced by Lexer and emits an AST.

    ── AST node shape ──────────────────────────────────────────────────
    Every node is a plain Lua table with at minimum:
        { kind : string, line : number, col : number }

    Statement node kinds
    ────────────────────
    Block              { stmts }
    LocalDeclaration   { names, attribs, typeAnnots, values }
    Assignment         { targets, values }
    CompoundAssignment { target, op, value }
    DoBlock            { body }
    WhileLoop          { cond, body }
    RepeatLoop         { body, cond }
    NumericFor         { var, start, limit, step, body }
    GenericFor         { vars, iters, body }
    IfStatement        { cond, thenBlock, elseIfs, elseBlock }
    FunctionDeclaration{ name, method, body }   -- name is an expr (field chain)
    LocalFunction      { name, body }
    ReturnStatement    { values }
    BreakStatement     { }
    ContinueStatement  { }
    LabelStatement     { name }
    GotoStatement      { name }
    TypeAlias          { name, generics, type }   -- parsed, ignored at runtime
    ExprStatement      { expr }                   -- a call used as a statement
    ClassDeclaration   { name, superName, fields, methods }
                       -- fields: list of {name, default?}
                       -- methods: list of {name, body}

    Expression node kinds
    ─────────────────────
    NumberLiteral      { value }
    StringLiteral      { value }
    BooleanLiteral     { value }
    NilLiteral         { }
    VarArg             { }
    Identifier         { name }
    TableConstructor   { fields }  -- fields: list of {kind,…}
                                   --   IndexedField  { key, value }
                                   --   NamedField    { name, value }
                                   --   ValueField    { value }
    FunctionExpr       { body }
    BinaryOp           { op, left, right }
    UnaryOp            { op, operand }
    IndexExpr          { table, key }
    FieldExpr          { table, field }
    MethodCall         { receiver, method, args }
    FunctionCall       { callee, args }
    TypeCast           { expr, type }             -- x :: T  (runtime: noop)
    InterpolatedString { parts }                  -- parts: {kind="text",value} | {kind="expr",expr}
    IfExpr             { cond, thenVal, elseIfs, elseVal }

    FunctionBody       { params, hasVarArg, retType, block }
    ── Operator precedence (lowest -> highest) ─────────────────────────
    1   or
    2   and
    3   < > <= >= == ~=
    4   |
    5   ~ (bitwise xor)
    6   &
    7   << >>
    8   ..            (right-associative)
    9   + -
    10  * / // %
    11  unary:  not  #  -  ~
    12  ^             (right-associative)
    13  postfix: call  index  field  method
]]

local Error = require(script.Parent.Error)
local Lexer = require(script.Parent.Lexer)

-- ─── Precedence table ────────────────────────────────────────────────

local BINARY_PREC = {
    ["or"]  = {1, 1}, ["and"] = {2, 2},
    ["<"]   = {3, 3}, [">"]   = {3, 3},
    ["<="]  = {3, 3}, [">="]  = {3, 3},
    ["=="]  = {3, 3}, ["~="]  = {3, 3},
    ["|"]   = {4, 4},
    ["~"]   = {5, 5},   -- binary bitwise xor (not unary!)
    ["&"]   = {6, 6},
    ["<<"]  = {7, 7}, [">>"]  = {7, 7},
    [".."]  = {8, 7},   -- right-associative: right prec < left prec
    ["+"]   = {9, 9},   ["-"]   = {9, 9},
    ["*"]   = {10, 10}, ["/"]   = {10, 10},
    ["//"]  = {10, 10}, ["%"]   = {10, 10},
    ["^"]   = {12, 11}, -- right-associative
}

-- True if the token type is a keyword string (used in type-parser below)
local KEYWORDS_SET = {
    ["and"]=1,["break"]=1,["continue"]=1,["do"]=1,["else"]=1,
    ["elseif"]=1,["end"]=1,["false"]=1,["for"]=1,["function"]=1,
    ["goto"]=1,["if"]=1,["in"]=1,["local"]=1,["nil"]=1,["not"]=1,
    ["or"]=1,["repeat"]=1,["return"]=1,["then"]=1,["true"]=1,
    ["until"]=1,["while"]=1,["type"]=1,["typeof"]=1,["export"]=1,
    ["class"]=1,["extends"]=1,
}

-- ─── Parser class ────────────────────────────────────────────────────

local Parser = {}
Parser.__index = Parser

function Parser.new(tokens, sourceName)
    return setmetatable({
        tokens     = tokens,
        pos        = 1,
        sourceName = sourceName or "?",
    }, Parser)
end

-- ─── Token helpers ───────────────────────────────────────────────────

function Parser:cur()
    return self.tokens[self.pos]
end

function Parser:peek(offset)
    return self.tokens[self.pos + (offset or 0)]
end

function Parser:advance()
    local t = self.tokens[self.pos]
    if t.type ~= "EOF" then
        self.pos = self.pos + 1
    end
    return t
end

-- Return current token line/col
function Parser:loc()
    local t = self:cur()
    return t.line, t.col
end

-- Consume a token of exactly `ttype`; throw ParseError if mismatch.
function Parser:expect(ttype, hint)
    local t = self:cur()
    if t.type ~= ttype then
        self:error(string.format(
            "expected '%s'%s, got '%s'",
            ttype,
            hint and (" (" .. hint .. ")") or "",
            t.type
        ))
    end
    return self:advance()
end

-- Soft/contextual keywords that are valid as identifiers (variable names,
-- parameter names, field names). These are keywords only in specific
-- syntactic positions; everywhere else they act like plain identifiers.
-- Note: "typeof" is excluded - it has dedicated TypeOf AST node handling
-- in parsePrimaryExpr and must not be treated as a plain identifier there.
-- "continue" and "goto" are still parsed as statements when they appear at
-- statement-start; soft status only affects expectName and parsePrimaryExpr
-- (e.g. local continue = 5, function f(goto) end).
local SOFT_KEYWORDS = {
    ["type"]=true, ["export"]=true,
    ["class"]=true, ["extends"]=true,
    ["continue"]=true, ["goto"]=true,
}

-- Consume an identifier or a soft keyword used as a name.
-- Use this instead of expect("IDENTIFIER") wherever a variable/parameter
-- name is expected, so that code like  function f(type, export) end  works.
function Parser:expectName(hint)
    local t = self:cur()
    if t.type == "IDENTIFIER" or SOFT_KEYWORDS[t.type] then
        return self:advance()
    end
    self:error(string.format(
        "expected name%s, got '%s'",
        hint and (" (" .. hint .. ")") or "",
        t.type
    ))
end

-- Consume a token if its type matches; return the token or nil.
function Parser:consume(ttype)
    if self:cur().type == ttype then
        return self:advance()
    end
    return nil
end

-- Check current type without consuming
function Parser:check(ttype)
    return self:cur().type == ttype
end

-- Check any of a list of types
function Parser:checkAny(...)
    local t = self:cur().type
    for _, tt in ipairs({...}) do
        if t == tt then return true end
    end
    return false
end

function Parser:error(msg)
    local t = self:cur()
    error(Error.parser(msg, t.line, t.col), 0)
end

-- ─── Type annotation parser (result stored in AST, ignored at runtime) ──

-- Parse a Luau type expression; returns an opaque string (we just skip it).
function Parser:parseTypeExpr()
    -- We parse type expressions permissively and throw them away.
    -- The grammar fragment we need to survive:
    --   type  ::= name ('.' name)* ('<' typeList '>')?   |  '(' typeList ')' '->' type
    --           | '{' typeBody '}'  |  type '|' type  |  type '&' type
    --           | type '?'  |  'typeof' '(' expr ')'  |  '...' type
    -- We use a simple recursive parser that returns nothing useful.
    return self:parseTypeUnion()
end

function Parser:parseTypeUnion()
    local t = self:parseTypeIntersection()
    while self:check("|") do
        self:advance()
        self:parseTypeIntersection()
    end
    return t
end

function Parser:parseTypeIntersection()
    local t = self:parseTypeSimple()
    while self:check("&") do
        self:advance()
        self:parseTypeSimple()
    end
    return t
end

function Parser:parseTypeSimple()
    local t = self:cur()

    if t.type == "..." then
        self:advance()
        self:parseTypeSimple()
    elseif t.type == "typeof" then
        self:advance()
        -- typeof(expr) is the normal form; tolerate bare `typeof` (no parens)
        -- in type annotations so that malformed or unusual type defs don't crash.
        if self:check("(") then
            self:advance()
            self:parseExpr()   -- consume the expression
            self:expect(")")
        end
        -- If not followed by `(`, treat `typeof` as a bare type name and continue.
    elseif t.type == "(" then
        -- Tuple type or function type
        self:advance()
        if not self:check(")") then
            self:parseTypeExpr()
            while self:consume(",") do
                if self:check(")") then break end
                self:parseTypeExpr()
            end
        end
        self:expect(")")
        if self:consume("->") then
            -- Return type
            if self:check("(") then
                self:advance()
                if not self:check(")") then
                    self:parseTypeExpr()
                    while self:consume(",") do
                        if self:check(")") then break end
                        self:parseTypeExpr()
                    end
                end
                self:expect(")")
            else
                self:parseTypeExpr()
            end
        end
    elseif t.type == "{" then
        -- Table type
        self:advance()
        while not self:check("}") and not self:check("EOF") do
            if self:check("[") then
                -- [type]: type
                self:advance()
                self:parseTypeExpr()
                self:expect("]")
                self:expect(":")
                self:parseTypeExpr()
            elseif self:check("IDENTIFIER") then
                -- name: type  (named field)
                local p = self:peek(1)
                if p and p.type == ":" then
                    self:advance(); self:advance()  -- name :
                    self:parseTypeExpr()
                else
                    self:parseTypeExpr()
                end
            else
                self:parseTypeExpr()
            end
            if not self:consume(",") and not self:consume(";") then break end
        end
        self:expect("}")
    elseif t.type == "IDENTIFIER" or t.type == "nil" or t.type == "true" or t.type == "false" or t.type == "string" then
        self:advance()
        -- Dotted name: Foo.Bar
        while self:check(".") and self:peek(1) and self:peek(1).type == "IDENTIFIER" do
            self:advance(); self:advance()
        end
        -- Generic parameters: Foo<T, U>
        if self:check("<") then
            local saved = self.pos
            self:advance()
            local ok = pcall(function()
                self:parseTypeExpr()
                while self:consume(",") do
                    self:parseTypeExpr()
                end
                self:expect(">")
            end)
            if not ok then
                self.pos = saved   -- rewind; the < was a comparison operator
            end
        end
    else
        -- Unrecognised - just skip one token to avoid infinite loop
        if not self:check("EOF") then self:advance() end
    end

    -- Optional: type?
    while self:check("?") do
        self:advance()
    end
end

-- ─── Statement parsing ───────────────────────────────────────────────

-- Parse a block until one of the stop tokens is encountered.
function Parser:parseBlock(...)
    local stopSet = {}
    for _, s in ipairs({...}) do stopSet[s] = true end
    stopSet["EOF"] = true

    local stmts = {}
    local line, col = self:loc()

    while not stopSet[self:cur().type] do
        -- Optional semicolons
        while self:consume(";") do end
        if stopSet[self:cur().type] then break end

        local s = self:parseStatement()
        if s then
            stmts[#stmts + 1] = s
        end

        -- A return statement must be the last in a block
        if s and s.kind == "ReturnStatement" then
            self:consume(";")
            break
        end
    end

    return { kind = "Block", stmts = stmts, line = line, col = col }
end

function Parser:parseStatement()
    local t = self:cur()
    local line, col = t.line, t.col

    -- ── Local declaration ──────────────────────────────────────────
    if t.type == "local" then
        self:advance()

        -- local function
        if self:check("function") then
            self:advance()
            local nameToken = self:expectName("function name")
            local body = self:parseFunctionBody()
            return { kind = "LocalFunction", name = nameToken.value,
                     body = body, line = line, col = col }
        end

        -- local var list (with optional type annotations and attributes)
        local names, attribs, typeAnnots = {}, {}, {}
        repeat
            local nm = self:expectName("variable name")
            names[#names + 1] = nm.value

            -- Luau attribute <close> <const>
            local attr = nil
            if self:check("<") then
                self:advance()
                attr = self:expect("IDENTIFIER", "attribute name").value
                self:expect(">")
            end
            attribs[#attribs + 1] = attr

            -- Type annotation : Type
            local annot = nil
            if self:check(":") then
                self:advance()
                annot = true   -- we parse but discard
                self:parseTypeExpr()
            end
            typeAnnots[#typeAnnots + 1] = annot
        until not self:consume(",")

        local values = {}
        if self:consume("=") then
            values = self:parseExprList()
        end

        return { kind = "LocalDeclaration", names = names, attribs = attribs,
                 typeAnnots = typeAnnots, values = values,
                 line = line, col = col }

    -- ── Function declaration ───────────────────────────────────────
    elseif t.type == "function" then
        self:advance()

        -- Name: can be  a  |  a.b.c  |  a.b.c:d
        local nameBase = self:expectName("function name")
        local nameExpr = { kind = "Identifier", name = nameBase.value,
                           line = nameBase.line, col = nameBase.col }
        local isMethod = false

        while self:check(".") do
            self:advance()
            local field = self:expectName("field name")
            nameExpr = { kind = "FieldExpr", table = nameExpr,
                         field = field.value,
                         line = field.line, col = field.col }
        end

        if self:consume(":") then
            local method = self:expectName("method name")
            nameExpr = { kind = "MethodName", table = nameExpr,
                         method = method.value,
                         line = method.line, col = method.col }
            isMethod = true
        end

        local body = self:parseFunctionBody(isMethod)
        return { kind = "FunctionDeclaration", name = nameExpr,
                 isMethod = isMethod, body = body,
                 line = line, col = col }

    -- ── Type alias (Luau) ──────────────────────────────────────────
    elseif t.type == "type" then
        -- Could be  type Foo = ...  or identifier named "type"
        local next = self:peek(1)
        if next and next.type == "IDENTIFIER" then
            self:advance()   -- consume "type"
            local aliasName = self:advance().value
            -- Generic parameters
            if self:check("<") then
                self:advance()
                if not self:check(">") then
                    self:expect("IDENTIFIER")
                    while self:consume(",") do
                        if self:check(">") then break end
                        self:expect("IDENTIFIER")
                    end
                end
                self:expect(">")
            end
            self:expect("=")
            self:parseTypeExpr()
            return { kind = "TypeAlias", name = aliasName,
                     line = line, col = col }
        end
        -- else fall through to expression statement

    -- ── Class declaration (Luau) ──────────────────────────────────
    elseif t.type == "class" then
        self:advance()
        local className = self:expect("IDENTIFIER", "class name").value

        local superName = nil
        if self:check("extends") then
            self:advance()
            superName = self:expect("IDENTIFIER", "parent class name").value
        end

        local fields  = {}
        local methods = {}

        -- Parse the class body: field declarations and method declarations.
        while not self:check("end") and not self:check("EOF") do
            while self:consume(";") do end
            if self:check("end") then break end

            local bt = self:cur()

            if bt.type == "function" then
                -- Method: function [ClassName.]name(params)...end
                --       or function [ClassName:]name(params)...end
                self:advance()
                local firstName = self:expectName("method name").value
                local methodName = firstName
                local isMethod   = false

                if self:check(".") then
                    self:advance()
                    methodName = self:expectName("method name").value
                elseif self:check(":") then
                    self:advance()
                    methodName = self:expectName("method name").value
                    isMethod   = true
                end

                local body = self:parseFunctionBody(isMethod)
                methods[#methods + 1] = { name = methodName, body = body }

            elseif bt.type == "type" then
                -- Type alias inside class body - parse and discard
                local nextTok = self:peek(1)
                if nextTok and nextTok.type == "IDENTIFIER" then
                    self:advance()  -- "type"
                    self:advance()  -- alias name
                    if self:check("<") then
                        self:advance()
                        if not self:check(">") then
                            self:expect("IDENTIFIER")
                            while self:consume(",") do
                                if self:check(">") then break end
                                self:expect("IDENTIFIER")
                            end
                        end
                        self:expect(">")
                    end
                    self:expect("=")
                    self:parseTypeExpr()
                else
                    break
                end

            elseif bt.type == "IDENTIFIER" then
                -- Field: name [: Type] [= expr]
                local fieldName = self:advance().value
                if self:check(":") then
                    self:advance()
                    self:parseTypeExpr()
                end
                local default = nil
                if self:consume("=") then
                    default = self:parseExpr()
                end
                fields[#fields + 1] = { name = fieldName, default = default }

            else
                -- Unexpected token - stop class body parsing
                break
            end
        end

        self:expect("end")
        return { kind = "ClassDeclaration", name = className,
                 superName = superName, fields = fields, methods = methods,
                 line = line, col = col }

    -- ── Export type (Luau) ────────────────────────────────────────
    elseif t.type == "export" then
        local next = self:peek(1)
        if next and next.type == "type" then
            self:advance()   -- export
            self:advance()   -- type
            local aliasName = self:advance().value
            if self:check("<") then
                self:advance()
                if not self:check(">") then
                    self:expect("IDENTIFIER")
                    while self:consume(",") do
                        if self:check(">") then break end
                        self:expect("IDENTIFIER")
                    end
                end
                self:expect(">")
            end
            self:expect("=")
            self:parseTypeExpr()
            return { kind = "TypeAlias", name = aliasName, exported = true,
                     line = line, col = col }
        end

    -- ── Control flow ───────────────────────────────────────────────
    elseif t.type == "return" then
        self:advance()
        local values = {}
        -- return values if next token isn't a block-ender
        local ender = self:cur().type
        if ender ~= "end" and ender ~= "else" and ender ~= "elseif"
            and ender ~= "until" and ender ~= "EOF" and ender ~= ";" then
            values = self:parseExprList()
        end
        return { kind = "ReturnStatement", values = values,
                 line = line, col = col }

    elseif t.type == "break" then
        self:advance()
        return { kind = "BreakStatement", line = line, col = col }

    elseif t.type == "continue" then
        -- If followed by = or , the script is using "continue" as a variable
        -- name (allowed because it is a soft keyword), not as a statement.
        local next = self:peek(1)
        if next and (next.type == "=" or next.type == ",") then
            -- fall through to the expression/assignment path below
        else
            self:advance()
            return { kind = "ContinueStatement", line = line, col = col }
        end

    -- ── goto / label ───────────────────────────────────────────────
    elseif t.type == "goto" then
        -- If followed by = or , the script is using "goto" as a variable name.
        local next = self:peek(1)
        if next and (next.type == "=" or next.type == ",") then
            -- fall through to the expression/assignment path below
        else
            self:advance()
            local name = self:expect("IDENTIFIER", "label name").value
            return { kind = "GotoStatement", name = name, line = line, col = col }
        end

    elseif t.type == "::" then
        self:advance()
        local name = self:expect("IDENTIFIER", "label name").value
        self:expect("::")
        return { kind = "LabelStatement", name = name, line = line, col = col }

    -- ── do...end ──────────────────────────────────────────────────
    elseif t.type == "do" then
        self:advance()
        local body = self:parseBlock("end")
        self:expect("end")
        return { kind = "DoBlock", body = body, line = line, col = col }

    -- ── while ─────────────────────────────────────────────────────
    elseif t.type == "while" then
        self:advance()
        local cond = self:parseExpr()
        self:expect("do")
        local body = self:parseBlock("end")
        self:expect("end")
        return { kind = "WhileLoop", cond = cond, body = body,
                 line = line, col = col }

    -- ── repeat...until ────────────────────────────────────────────
    elseif t.type == "repeat" then
        self:advance()
        local body = self:parseBlock("until")
        self:expect("until")
        local cond = self:parseExpr()
        return { kind = "RepeatLoop", body = body, cond = cond,
                 line = line, col = col }

    -- ── if ────────────────────────────────────────────────────────
    elseif t.type == "if" then
        self:advance()
        local cond = self:parseExpr()
        self:expect("then")
        local thenBlock = self:parseBlock("else", "elseif", "end")

        local elseIfs = {}
        local elseBlock = nil

        while self:check("elseif") do
            local eiLine, eiCol = self:loc()
            self:advance()
            local eiCond = self:parseExpr()
            self:expect("then")
            local eiBody = self:parseBlock("else", "elseif", "end")
            elseIfs[#elseIfs + 1] = { cond = eiCond, body = eiBody,
                                       line = eiLine, col = eiCol }
        end

        if self:consume("else") then
            elseBlock = self:parseBlock("end")
        end
        self:expect("end")

        return { kind = "IfStatement", cond = cond,
                 thenBlock = thenBlock, elseIfs = elseIfs,
                 elseBlock = elseBlock, line = line, col = col }

    -- ── for ───────────────────────────────────────────────────────
    elseif t.type == "for" then
        self:advance()
        local firstName = self:expectName().value

        -- Numeric: for i = start, limit [, step] do
        if self:consume("=") then
            local start = self:parseExpr()
            self:expect(",")
            local limit = self:parseExpr()
            local step  = self:consume(",") and self:parseExpr() or nil
            self:expect("do")
            local body = self:parseBlock("end")
            self:expect("end")
            return { kind = "NumericFor",
                     var = firstName, start = start, limit = limit, step = step,
                     body = body, line = line, col = col }

        -- Generic: for a, b, … in iters do
        else
            local vars = { firstName }

            -- Type annotation on first var (Luau)
            if self:check(":") then
                self:advance(); self:parseTypeExpr()
            end

            while self:consume(",") do
                vars[#vars + 1] = self:expectName().value
                if self:check(":") then
                    self:advance(); self:parseTypeExpr()
                end
            end
            self:expect("in")
            local iters = self:parseExprList()
            self:expect("do")
            local body = self:parseBlock("end")
            self:expect("end")
            return { kind = "GenericFor", vars = vars, iters = iters,
                     body = body, line = line, col = col }
        end
    end

    -- ── Expression statement (assignment, compound-assign, call) ──
    do
        local expr = self:parseSuffixExpr()

        -- Compound assignment:  target op= value
        local compOps = {
            ["+="] = true, ["-="] = true, ["*="] = true, ["/="] = true,
            ["//="] = true, ["%="] = true, ["^="] = true, ["..="] = true,
            ["&="] = true, ["|="] = true, ["<<="] = true, [">>="] = true,
        }
        if compOps[self:cur().type] then
            local op = self:advance().type
            local value = self:parseExpr()
            return { kind = "CompoundAssignment",
                     target = expr, op = op, value = value,
                     line = line, col = col }
        end

        -- Multi-target assignment:  a, b, c = …
        if self:check(",") or self:check("=") then
            local targets = { expr }
            while self:consume(",") do
                targets[#targets + 1] = self:parseSuffixExpr()
            end
            self:expect("=")
            local values = self:parseExprList()
            return { kind = "Assignment", targets = targets, values = values,
                     line = line, col = col }
        end

        -- Must be a function / method call (valid expression statement)
        if expr.kind ~= "FunctionCall" and expr.kind ~= "MethodCall" then
            self:error("syntax error near '" .. self:cur().type .. "'")
        end
        return { kind = "ExprStatement", expr = expr, line = line, col = col }
    end
end

-- ─── Function body ───────────────────────────────────────────────────

-- Parses  (params) [: returnType]  block  end
-- isMethod = true ⟹ implicitly prepend "self" to param list
function Parser:parseFunctionBody(isMethod)
    local line, col = self:loc()
    -- Skip generic type parameters <T, U, ...> if present.
    -- Roblox Luau allows  function foo<T, U>(...)  and even
    -- constraint syntax like  <T and U>  that would confuse parseTypeExpr.
    -- We scan by angle-bracket depth so any tokens inside are tolerated.
    if self:check("<") then
        local saved = self.pos
        local ok = pcall(function()
            self:advance()  -- consume <
            local depth = 1
            while depth > 0 and not self:check("EOF") do
                local tt = self:cur().type
                if tt == "<" then
                    depth = depth + 1
                    self:advance()
                elseif tt == ">" then
                    depth = depth - 1
                    if depth > 0 then self:advance() end
                else
                    self:advance()
                end
            end
            self:expect(">")  -- consume the closing >
        end)
        if not ok then
            self.pos = saved  -- rewind; the < was a comparison, not a generic
        end
    end
    self:expect("(")

    local params = {}
    local hasVarArg = false

    if isMethod then
        params[#params + 1] = "self"
    end

    if not self:check(")") then
        repeat
            if self:check("...") then
                self:advance()
                hasVarArg = true
                break
            end
            local paramName = self:expectName("parameter name").value
            params[#params + 1] = paramName
            -- Optional type annotation
            if self:check(":") then
                self:advance(); self:parseTypeExpr()
            end
        until not self:consume(",")
    end

    self:expect(")")

    -- Optional return type annotation  : Type
    local retType = nil
    if self:check(":") then
        -- Disambiguate:  (params): RetType  vs a label ::
        local saved = self.pos
        self:advance()
        if not self:check(":") then   -- not ::
            self:parseTypeExpr()
            retType = true
        else
            self.pos = saved           -- rewind; colon is part of ::
        end
    end

    local block = self:parseBlock("end")
    self:expect("end")

    return { kind = "FunctionBody",
             params = params, hasVarArg = hasVarArg,
             retType = retType, block = block,
             line = line, col = col }
end

-- ─── Expression list ────────────────────────────────────────────────

function Parser:parseExprList()
    local list = { self:parseExpr() }
    while self:consume(",") do
        list[#list + 1] = self:parseExpr()
    end
    return list
end

-- ─── Expression parsing (Pratt / precedence climbing) ───────────────

-- Primary entry: parse a full expression with binary operators.
-- minPrec is the minimum left-binding power (default 0).
function Parser:parseExpr(minPrec)
    minPrec = minPrec or 0

    -- Parse left-hand side (unary + primary)
    local left = self:parseUnaryExpr()

    -- Expand binary operators
    while true do
        local op = self:cur().type
        local prec = BINARY_PREC[op]
        if not prec or prec[1] <= minPrec then break end

        local line, col = self:loc()
        self:advance()

        local right = self:parseExpr(prec[2])   -- right prec handles associativity
        left = { kind = "BinaryOp", op = op, left = left, right = right,
                 line = line, col = col }
    end

    -- Type cast  expr :: Type  (Luau)
    if self:check("::") then
        local line, col = self:loc()
        self:advance()
        self:parseTypeExpr()
        left = { kind = "TypeCast", expr = left, line = line, col = col }
    end

    return left
end

-- Unary operators: not  #  -  ~
function Parser:parseUnaryExpr()
    local t = self:cur()
    local line, col = t.line, t.col
    if t.type == "not" or t.type == "#" or t.type == "-" or t.type == "~" then
        local op = self:advance().type
        -- Unary has prec 11; ^ is 12 so unary binds tighter than binary ^ on right
        local operand = self:parseExpr(11)
        return { kind = "UnaryOp", op = op, operand = operand,
                 line = line, col = col }
    end
    return self:parseSuffixExpr()
end

-- Suffix expressions: primary + chains of  .field  [key]  (args)  :method(args)
function Parser:parseSuffixExpr()
    local expr = self:parsePrimaryExpr()

    while true do
        local t = self:cur()
        local line, col = t.line, t.col

        if t.type == "." then
            self:advance()
            local field = self:expectName("field name")
            expr = { kind = "FieldExpr", table = expr, field = field.value,
                     line = field.line, col = field.col }

        elseif t.type == "[" then
            self:advance()
            local key = self:parseExpr()
            self:expect("]")
            expr = { kind = "IndexExpr", table = expr, key = key,
                     line = line, col = col }

        elseif t.type == ":" then
            self:advance()
            local method = self:expectName("method name")
            local args   = self:parseCallArgs(line, col)
            expr = { kind = "MethodCall", receiver = expr,
                     method = method.value, args = args,
                     line = line, col = col }

        elseif t.type == "(" or t.type == "{"
               or t.type == "STRING" then
            local args = self:parseCallArgs(line, col)
            expr = { kind = "FunctionCall", callee = expr, args = args,
                     line = line, col = col }

        else
            break
        end
    end

    return expr
end

-- Call argument list:  (exprList)  |  stringLiteral  |  tableConstructor
function Parser:parseCallArgs(line, col)
    local t = self:cur()
    if t.type == "(" then
        self:advance()
        local args = {}
        if not self:check(")") then
            args = self:parseExprList()
        end
        self:expect(")")
        return args

    elseif t.type == "STRING" then
        local s = self:advance()
        return { { kind = "StringLiteral", value = s.value,
                   line = s.line, col = s.col } }

    elseif t.type == "{" then
        return { self:parseTableConstructor() }

    else
        self:error("expected function arguments")
    end
end

-- ─── Primary expressions ─────────────────────────────────────────────

function Parser:parsePrimaryExpr()
    local t = self:cur()
    local line, col = t.line, t.col

    -- Number literal
    if t.type == "NUMBER" then
        self:advance()
        return { kind = "NumberLiteral", value = t.value, line = line, col = col }

    -- String literal
    elseif t.type == "STRING" then
        self:advance()
        return { kind = "StringLiteral", value = t.value, line = line, col = col }

    -- Boolean: true / false
    elseif t.type == "true" then
        self:advance()
        return { kind = "BooleanLiteral", value = true, line = line, col = col }

    elseif t.type == "false" then
        self:advance()
        return { kind = "BooleanLiteral", value = false, line = line, col = col }

    -- nil
    elseif t.type == "nil" then
        self:advance()
        return { kind = "NilLiteral", line = line, col = col }

    -- Vararg
    elseif t.type == "..." then
        self:advance()
        return { kind = "VarArg", line = line, col = col }

    -- Anonymous function
    elseif t.type == "function" then
        self:advance()
        local body = self:parseFunctionBody(false)
        return { kind = "FunctionExpr", body = body, line = line, col = col }

    -- Table constructor
    elseif t.type == "{" then
        return self:parseTableConstructor()

    -- Parenthesised expression - wrapping with () adjusts to single value
    elseif t.type == "(" then
        self:advance()
        local inner = self:parseExpr()
        self:expect(")")
        -- Wrapping in Paren adjusts multiple returns to 1
        return { kind = "Paren", expr = inner, line = line, col = col }

    -- Identifier (or a soft keyword used as a variable reference)
    elseif t.type == "IDENTIFIER" or SOFT_KEYWORDS[t.type] then
        self:advance()
        return { kind = "Identifier", name = t.value, line = line, col = col }

    -- typeof(expr) as a primary expression (Luau)
    elseif t.type == "typeof" then
        self:advance()
        self:expect("(")
        local inner = self:parseExpr()
        self:expect(")")
        return { kind = "TypeOf", expr = inner, line = line, col = col }

    -- Interpolated string: `Hello {name}!`
    elseif t.type == "ISTRING" then
        self:advance()
        local parts = {}
        for _, part in ipairs(t.value) do
            if part.kind == "text" then
                parts[#parts + 1] = { kind = "text", value = part.value }
            else
                -- Re-tokenise and parse the embedded expression source
                local ok, tokens = pcall(Lexer.tokenize, part.source, self.sourceName)
                if not ok then
                    self:error("interpolated string expression error: "
                        .. tostring(tokens))
                end
                local subParser  = Parser.new(tokens, self.sourceName)
                local exprNode   = subParser:parseExpr()
                parts[#parts + 1] = { kind = "expr", expr = exprNode }
            end
        end
        return { kind = "InterpolatedString", parts = parts,
                 line = line, col = col }

    -- if-then-else expression (Luau): if cond then a [elseif cond then b]* else c
    elseif t.type == "if" then
        self:advance()
        local cond    = self:parseExpr()
        self:expect("then")
        local thenVal = self:parseExpr()

        local elseIfs = {}
        while self:check("elseif") do
            self:advance()
            local eiCond = self:parseExpr()
            self:expect("then")
            local eiVal  = self:parseExpr()
            elseIfs[#elseIfs + 1] = { cond = eiCond, value = eiVal }
        end

        self:expect("else")
        local elseVal = self:parseExpr()

        return { kind = "IfExpr", cond = cond, thenVal = thenVal,
                 elseIfs = elseIfs, elseVal = elseVal,
                 line = line, col = col }

    else
        self:error(string.format(
            "unexpected token '%s' in expression",
            t.value or t.type
        ))
    end
end

-- ─── Table constructor ───────────────────────────────────────────────

function Parser:parseTableConstructor()
    local line, col = self:loc()
    self:expect("{")
    local fields = {}

    while not self:check("}") and not self:check("EOF") do
        local fLine, fCol = self:loc()

        -- [expr] = value
        if self:check("[") then
            self:advance()
            local key = self:parseExpr()
            self:expect("]")
            self:expect("=")
            local value = self:parseExpr()
            fields[#fields + 1] = { kind = "IndexedField",
                                     key = key, value = value,
                                     line = fLine, col = fCol }

        -- name = value  (name may be a soft keyword like "type")
        elseif (self:check("IDENTIFIER") or SOFT_KEYWORDS[self:cur().type])
               and self:peek(1).type == "=" then
            local name = self:advance().value
            self:advance()   -- =
            local value = self:parseExpr()
            fields[#fields + 1] = { kind = "NamedField",
                                     name = name, value = value,
                                     line = fLine, col = fCol }

        -- positional value
        else
            local value = self:parseExpr()
            fields[#fields + 1] = { kind = "ValueField",
                                     value = value,
                                     line = fLine, col = fCol }
        end

        -- Field separator: , or ;
        if not self:consume(",") and not self:consume(";") then
            break
        end
    end

    self:expect("}")
    return { kind = "TableConstructor", fields = fields, line = line, col = col }
end

-- ─── Public interface ────────────────────────────────────────────────

local ParserModule = {}

function ParserModule.parse(tokens, sourceName)
    local parser = Parser.new(tokens, sourceName)
    local block  = parser:parseBlock("EOF")
    block.sourceName = sourceName or "?"
    return block
end

function ParserModule.parseExpr(tokens, sourceName)
    local parser = Parser.new(tokens, sourceName)
    return parser:parseExpr()
end

return ParserModule
