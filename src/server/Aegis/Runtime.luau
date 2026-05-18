--[[
    Runtime.luau - AST interpreter / evaluator

    Walks the AST produced by Parser and executes each node.

    Key design decisions
    ────────────────────

    Multiple return values
    ~~~~~~~~~~~~~~~~~~~~~~
    In Lua/Luau a function call may return many values.  Inside the
    interpreter this is modelled as a "MultiReturn" table:
        { __multi = true, n = count, [1] = v1, [2] = v2, … }
    eval()      always returns a single value (the first result).
    evalMulti() returns that table (or a single-element wrapper).
    When building expression lists (return, call args, assignment RHS)
    the LAST expression is expanded via evalMulti; all prior ones use eval.

    Closures
    ~~~~~~~~
    A closure value is a plain table:
        { __fn = true, params, hasVarArg, block, closure (Scope) }
    When the function is called, a new child scope of `closure` is created.
    Because Scope.variables is a regular Lua table, all mutations by nested
    functions are naturally visible to sibling closures-no upvalue boxing needed.

    Control flow
    ~~~~~~~~~~~~
    break / continue / return / goto are propagated via Lua's error()
    mechanism using the signal tables from Error.luau.  Each loop body
    and function body wraps its execution in pcall() and inspects the
    thrown value.

    Metatables
    ~~~~~~~~~~
    Tables created by the guest script may have metatables.  The runtime
    checks for __index, __newindex, __add, __sub, __mul, __div, __mod,
    __pow, __unm, __idiv, __concat, __len, __eq, __lt, __le, __call,
    __tostring, __band, __bor, __bxor, __bnot, __shl, __shr.

    No forbidden APIs
    ~~~~~~~~~~~~~~~~~
    getfenv / setfenv / loadstring / load internals are never used.
    All evaluation is manual AST traversal.
]]

local Error      = require(script.Parent.Error)
local Scope      = require(script.Parent.Scope)
local Constants  = require(script.Parent.Constants)
local TextFilter = require(script.Parent.TextFilter)

-- ─── Helpers ─────────────────────────────────────────────────────────

local function multiRet(...)
    local t = table.pack(...)
    t.__multi = true
    return t
end

-- rawget-based tag checks: use rawget so that tables with __index metamethods
-- (such as the game proxy) never trigger Roblox property lookups when AegisVM
-- inspects its own internal type tags (__multi, __fn).
local function isMulti(v)
    return type(v) == "table" and rawget(v, "__multi") == true
end

local function isClosure(v)
    return type(v) == "table" and rawget(v, "__fn") == true
end

local function singleOf(v)
    if isMulti(v) then
        return v[1]
    end
    return v
end

-- Unwrap a potential MultiReturn into a plain array of values
local function unpackMulti(v)
    if isMulti(v) then
        local out = {}
        for i = 1, v.n do out[i] = v[i] end
        return out, v.n
    end
    return { v }, 1
end

-- Build a flat argument list from an expression list (last item expanded)
-- count must be passed explicitly: results[i]=nil is a no-op in Lua, so
-- #results is unreliable when any non-last expression evaluates to nil.
local function flattenExprList(results, count)
    local out = {}
    local n   = 0
    for i = 1, count do
        local v = results[i]
        if i < count then
            n = n + 1
            out[n] = singleOf(v)
        else
            -- Last expression expands multiple returns.
            if isMulti(v) then
                for j = 1, v.n do
                    n = n + 1
                    out[n] = v[j]
                end
            else
                n = n + 1
                out[n] = v
            end
        end
    end
    out.n = n  -- reliable count; use this instead of # on the returned table
    return out
end

-- Luau truthiness: nil and false are falsy, everything else is truthy
local function isTruthy(v)
    return v ~= nil and v ~= false
end

-- Try a binary or unary operation at the raw Lua level so that Roblox
-- userdata types (Vector3, CFrame, etc.) can handle their own locked native
-- metamethods, which are invisible to getmetatable/rawget.
-- Returns ok, result.
local function tryNativeBinop(op, l, r)
    if op == "+"  then return pcall(function() return l +  r end)
    elseif op == "-"  then return pcall(function() return l -  r end)
    elseif op == "*"  then return pcall(function() return l *  r end)
    elseif op == "/"  then return pcall(function() return l /  r end)
    elseif op == "//" then return pcall(function() return l // r end)
    elseif op == "%"  then return pcall(function() return l %  r end)
    elseif op == "^"  then return pcall(function() return l ^  r end)
    elseif op == ".." then return pcall(function() return l .. r end)
    elseif op == "<"  then return pcall(function() return l <  r end)
    elseif op == "<=" then return pcall(function() return l <= r end)
    elseif op == ">"  then return pcall(function() return l >  r end)
    elseif op == ">=" then return pcall(function() return l >= r end)
    end
    return false, nil
end

-- Extract a human-readable name from a function declaration name expression.
-- Returns a string like "foo", "obj.foo", or "obj:method", or nil.
local function nameExprToString(nameExpr)
    if nameExpr.kind == "Identifier" then
        return nameExpr.name
    elseif nameExpr.kind == "FieldExpr" then
        local parent = nameExprToString(nameExpr.table)
        if parent then return parent .. "." .. nameExpr.field end
        return nameExpr.field
    elseif nameExpr.kind == "MethodName" then
        local parent = nameExprToString(nameExpr.table)
        if parent then return parent .. ":" .. nameExpr.method end
        return nameExpr.method
    end
    return nil
end

-- ─── Metatable helpers ────────────────────────────────────────────────

local function getMetamethod(tbl, event)
    if type(tbl) ~= "table" then return nil end
    local mt = getmetatable(tbl)
    if mt == nil then return nil end
    return rawget(mt, event)
end

-- Attempt to call a metamethod; returns nil if not found.
local function callMeta(runtime, tbl, event, ...)
    local mm = getMetamethod(tbl, event)
    if mm == nil then return nil, false end
    local res = runtime:callFunction(mm, { tbl, ... })
    return res, true
end

-- ─── Runtime class ───────────────────────────────────────────────────

local Runtime = {}
Runtime.__index = Runtime

function Runtime.new(globalScope)
    local self = setmetatable({}, Runtime)
    self.globalScope  = globalScope or Scope.global("global")
    self.callDepth    = 0
    self.maxCallDepth = 200
    self.sourceName   = "?"     -- current chunk name; set by Aegis before each execBlock
    self.callStacks   = {}      -- per-coroutine call stacks: [coroutine] = {frame, ...}
    self._currentLine = 0       -- last statement line seen by execStat
    return self
end

-- ─── eval: evaluate one expression node, return first value ──────────

function Runtime:eval(node, scope)
    local result = self:evalMulti(node, scope)
    return singleOf(result)
end

-- ─── evalMulti: evaluate expression, return MultiReturn (or plain value)

function Runtime:evalMulti(node, scope)
    local kind = node.kind

    -- ── Literals ──────────────────────────────────────────────────
    if kind == "NumberLiteral"  then return node.value end
    if kind == "StringLiteral"  then return node.value end
    if kind == "BooleanLiteral" then return node.value end
    if kind == "NilLiteral"     then return nil end
    if kind == "TypeCast"       then return self:evalMulti(node.expr, scope) end

    -- ── Interpolated string: `Hello {name}!` ─────────────────────
    if kind == "InterpolatedString" then
        local sandboxTostr = self.globalScope:get("tostring")
        local parts = {}
        for _, part in ipairs(node.parts) do
            if part.kind == "text" then
                parts[#parts + 1] = part.value
            else
                local val = self:eval(part.expr, scope)
                local s
                if type(sandboxTostr) == "function" then
                    s = sandboxTostr(val)
                elseif isClosure(sandboxTostr) then
                    s = self:callFunction(sandboxTostr, { val })
                else
                    s = tostring(val)
                end
                parts[#parts + 1] = tostring(s)
            end
        end
        return table.concat(parts)
    end

    -- ── if-then-else expression: if cond then a else b ────────────
    if kind == "IfExpr" then
        if isTruthy(self:eval(node.cond, scope)) then
            return self:evalMulti(node.thenVal, scope)
        end
        for _, ei in ipairs(node.elseIfs) do
            if isTruthy(self:eval(ei.cond, scope)) then
                return self:evalMulti(ei.value, scope)
            end
        end
        return self:evalMulti(node.elseVal, scope)
    end

    -- ── Vararg ────────────────────────────────────────────────────
    if kind == "VarArg" then
        local va = scope:get("...")
        if va == nil then return multiRet() end
        local out = multiRet(table.unpack(va.values, 1, va.n))
        out.n = va.n
        return out
    end

    -- ── Identifier ────────────────────────────────────────────────
    if kind == "Identifier" then
        return scope:get(node.name)
    end

    -- ── Paren: forces single value ─────────────────────────────────
    if kind == "Paren" then
        return self:eval(node.expr, scope)
    end

    -- ── TypeOf ────────────────────────────────────────────────────
    if kind == "TypeOf" then
        local v = self:eval(node.expr, scope)
        return type(v)
    end

    -- ── Table constructor ──────────────────────────────────────────
    if kind == "TableConstructor" then
        return self:evalTableConstructor(node, scope)
    end

    -- ── Function expression (closure) ─────────────────────────────
    if kind == "FunctionExpr" then
        return self:makeClosure(node.body, scope)
    end

    -- ── Unary operators ───────────────────────────────────────────
    if kind == "UnaryOp" then
        return self:evalUnary(node, scope)
    end

    -- ── Binary operators ──────────────────────────────────────────
    if kind == "BinaryOp" then
        return self:evalBinary(node, scope)
    end

    -- ── Field access:  tbl.field ──────────────────────────────────
    if kind == "FieldExpr" then
        local tbl = self:eval(node.table, scope)
        return self:tableGet(tbl, node.field, node.line)
    end

    -- ── Index access:  tbl[key] ───────────────────────────────────
    if kind == "IndexExpr" then
        local tbl = self:eval(node.table, scope)
        local key = self:eval(node.key,   scope)
        return self:tableGet(tbl, key, node.line)
    end

    -- ── Function call ─────────────────────────────────────────────
    if kind == "FunctionCall" then
        local fn   = self:eval(node.callee, scope)
        local args = self:evalArgList(node.args, scope)
        return self:callFunctionMulti(fn, args, node.line)
    end

    -- ── Method call:  obj:method(args) ────────────────────────────
    if kind == "MethodCall" then
        local obj  = self:eval(node.receiver, scope)
        local fn   = self:tableGet(obj, node.method, node.line)
        local args = self:evalArgList(node.args, scope)
        table.insert(args, 1, obj)   -- prepend self
        args.n = args.n + 1          -- keep .n in sync with the inserted element
        return self:callFunctionMulti(fn, args, node.line)
    end

    self:runtimeError(
        string.format("unknown expression node kind '%s'", kind),
        node.line
    )
end

-- ─── Table get with __index metamethod support ────────────────────────

function Runtime:tableGet(tbl, key, line, depth)
    depth = depth or 0
    if depth > 200 then
        self:runtimeError(
            "attempt to index: __index chain too long (possible circular reference)",
            line
        )
    end

    local t = type(tbl)

    -- ── Plain Lua table ───────────────────────────────────────────────
    if t == "table" then
        local raw = rawget(tbl, key)
        if raw ~= nil then return raw end

        local mt = getmetatable(tbl)
        if mt == nil then return nil end

        local index = rawget(mt, "__index")
        if index == nil then return nil end

        if type(index) == "function" or isClosure(index) then
            return singleOf(self:callFunction(index, { tbl, key }))
        elseif type(index) == "table" then
            return self:tableGet(index, key, line, depth + 1)
        end
        return nil

    -- ── Roblox Instance / userdata / vector ──────────────────────────────
    -- All Roblox instances are userdata; Vector3/similar are "vector" in newer
    -- Roblox builds. Let Roblox's own __index handle property and method
    -- look-ups; pcall absorbs invalid access.
    --
    -- .Source intercept: Roblox restricts script source access at runtime.
    -- NewScript stores the source as a "Source" attribute; read that instead.
    -- If the instance has no such attribute, error as Roblox normally would.
    elseif t == "userdata" or t == "vector" then
        if key == "Source" then
            local attrOk, attrVal = pcall(function() return tbl:GetAttribute("Source") end)
            if attrOk and attrVal ~= nil then
                return attrVal
            end
            self:runtimeError("Source is not a valid member of " .. tostring(tbl.ClassName or tbl), line)
        end
        -- Text filtering: return the archived raw text so the script sees what
        -- it assigned, not the filtered value the instance property holds.
        if Constants.FILTER_TEXT
            and (key == "Text" or key == "PlaceholderText")
        then
            local raw = TextFilter.getRaw(tbl, key)
            if raw ~= nil then return raw end
        end
        local ok, val = pcall(function() return tbl[key] end)
        return ok and val or nil

    -- ── String ───────────────────────────────────────────────────────
    -- Forward to the sandboxed "string" library so methods like
    -- ("hello"):upper() resolve correctly without touching the locked
    -- host string metatable.
    elseif t == "string" then
        local strlib = self.globalScope:get("string")
        if type(strlib) == "table" then
            return rawget(strlib, key)
        end
        return nil

    else
        self:runtimeError(
            string.format("attempt to index a %s value", t),
            line
        )
    end
end

-- ─── Table set with __newindex metamethod support ─────────────────────

function Runtime:tableSet(tbl, key, value, line)
    local t = type(tbl)

    -- ── Roblox Instance / userdata / vector ──────────────────────────────
    -- Assign to properties directly; Roblox raises its own errors for
    -- read-only or nonexistent members.
    --
    -- .Source intercept: if the instance has a "Source" attribute (set by
    -- NewScript), write to that instead. Otherwise error as Roblox would.
    if t == "userdata" or t == "vector" then
        if key == "Source" then
            local attrOk, attrVal = pcall(function() return tbl:GetAttribute("Source") end)
            if attrOk and attrVal ~= nil then
                local setOk, setErr = pcall(function() tbl:SetAttribute("Source", value) end)
                if not setOk then
                    self:runtimeError(tostring(setErr), line)
                end
                return
            end
            self:runtimeError("Source is not a valid member of " .. tostring(tbl.ClassName or tbl), line)
        end
        -- Text filtering: route .Text / .PlaceholderText through TextService
        -- when FILTER_TEXT is enabled. TextFilter.apply handles both the
        -- raw write and the async/sync filtered update; we return early so
        -- the normal pcall assignment below is skipped.
        if Constants.FILTER_TEXT
            and type(value) == "string"
            and (key == "Text" or key == "PlaceholderText")
        then
            TextFilter.apply(tbl, key, value)
            return
        end
        local ok, err = pcall(function() tbl[key] = value end)
        if not ok then
            self:runtimeError(tostring(err), line)
        end
        return
    end

    if t ~= "table" then
        self:runtimeError(
            string.format("attempt to index a %s value", t),
            line
        )
    end

    -- If key already exists raw, just set it
    if rawget(tbl, key) ~= nil then
        rawset(tbl, key, value)
        return
    end

    local mt      = getmetatable(tbl)
    local newindex = mt and rawget(mt, "__newindex")

    if newindex == nil then
        rawset(tbl, key, value)
    elseif type(newindex) == "function" or isClosure(newindex) then
        self:callFunction(newindex, { tbl, key, value })
    elseif type(newindex) == "table" then
        self:tableSet(newindex, key, value, line)
    else
        rawset(tbl, key, value)
    end
end

-- ─── Argument list evaluator ─────────────────────────────────────────

function Runtime:evalArgList(argNodes, scope)
    local count   = #argNodes
    local results = {}
    for i = 1, count do
        results[i] = self:evalMulti(argNodes[i], scope)
    end
    return flattenExprList(results, count)
end

-- ─── Closure factory ─────────────────────────────────────────────────

function Runtime:makeClosure(bodyNode, scope, name)
    return {
        __fn      = true,
        params    = bodyNode.params,
        hasVarArg = bodyNode.hasVarArg,
        block     = bodyNode.block,
        closure   = scope,            -- captured lexical scope
        sourceName = self.sourceName, -- chunk where this closure was defined
        name      = name,             -- display name for stack traces (may be nil)
    }
end

-- ─── Function calling ─────────────────────────────────────────────────

-- Call a function (closure or native Lua function) with the given args list.
-- Returns a MultiReturn table.
function Runtime:callFunctionMulti(fn, args, line)
    if fn == nil then
        self:runtimeError("attempt to call a nil value", line)
    end

    -- Native Lua/Luau function (from StdLib or a Roblox API)
    if type(fn) == "function" then
        -- Any interpreter closure passed as an argument (e.g. to Signal:Connect,
        -- table.sort, pcall, etc.) must be wrapped in a real Lua function.
        -- Otherwise Roblox rejects the table with "Passed value is not a function".
        local argN       = args.n or #args
        local wrappedArgs = args
        for i = 1, argN do
            if isClosure(args[i]) then
                -- Lazy-copy args only on first closure found
                if wrappedArgs == args then
                    wrappedArgs = { n = argN }
                    for j = 1, argN do wrappedArgs[j] = args[j] end
                end
                local closure = args[i]
                local runtime = self
                wrappedArgs[i] = function(...)
                    local callArgs = table.pack(...)
                    local rets = table.pack(pcall(function()
                        local r = runtime:callFunctionMulti(closure, callArgs)
                        return table.unpack(r, 1, r.n)
                    end))
                    if not rets[1] then
                        local err = rets[2]
                        -- Control-flow signals (break/continue/return/goto) must
                        -- not escape a native callback boundary; swallow silently.
                        if Error.isSignal(err) then return end
                        -- Real errors are re-thrown so that guest pcall/xpcall
                        -- can catch them. For fire-and-forget callbacks (e.g.
                        -- Signal:Connect) Roblox will surface the error itself.
                        -- tostring() is required: if err is an Error table object
                        -- Roblox cannot print non-string errors and shows the
                        -- generic "Error occurred, no output from Luau." instead.
                        error(tostring(err), 0)
                    end
                    return table.unpack(rets, 2, rets.n)
                end
            end
        end
        local rawResults = table.pack(pcall(fn, table.unpack(wrappedArgs, 1, wrappedArgs.n or argN)))
        if not rawResults[1] then
            local err = rawResults[2]
            -- Re-raise control-flow signals thrown by wrapped closure callbacks
            if Error.isSignal(err) then error(err, 0) end
            self:runtimeError(tostring(err), line)
        end
        local results = {}
        results.__multi = true
        results.n = rawResults.n - 1
        for i = 2, rawResults.n do results[i - 1] = rawResults[i] end
        return results
    end

    -- Interpreter closure
    if isClosure(fn) then
        self.callDepth = self.callDepth + 1
        if self.callDepth > self.maxCallDepth then
            self.callDepth = self.callDepth - 1
            self:runtimeError("stack overflow", line)
        end

        local callScope = fn.closure:child("function")

        -- Bind parameters
        for i, paramName in ipairs(fn.params) do
            callScope:declareLocal(paramName, args[i])
        end

        -- Bind vararg
        if fn.hasVarArg then
            local vaValues = {}
            local vaCount  = 0
            for i = #fn.params + 1, args.n or #args do
                vaCount = vaCount + 1
                vaValues[vaCount] = args[i]
            end
            callScope:declareLocal("...", { values = vaValues, n = vaCount })
        end

        -- Push a call stack frame into this coroutine's own stack so that
        -- runtimeError can build a correct trace. Using coroutine.running()
        -- as the key keeps frames from different coroutines from interleaving
        -- in the shared table and creating holes that break #-length queries.
        local co = coroutine.running() or "main"
        local coStack = self.callStacks[co]
        if not coStack then
            coStack = {}
            self.callStacks[co] = coStack
        end
        local frameIdx = #coStack + 1
        coStack[frameIdx] = { chunkName = fn.sourceName or "?", line = line or 0, fnName = fn.name }

        -- Execute body; catch return signals
        local ok, sig = pcall(function()
            self:execBlock(fn.block, callScope)
        end)

        -- Always pop the frame before returning or re-raising.
        coStack[frameIdx] = nil
        self.callDepth = self.callDepth - 1

        if ok then
            return multiRet()   -- no explicit return -> returns nothing
        end

        if Error.isReturn(sig) then
            local r = multiRet(table.unpack(sig.values, 1, sig.n))
            r.n = sig.n
            return r
        end

        -- Propagate real errors and other signals upward
        error(sig, 0)
    end

    -- __call metamethod (tables only; getMetamethod uses rawget)
    local callMM = getMetamethod(fn, "__call")
    if callMM then
        local newArgs = { fn, table.unpack(args, 1, args.n or #args) }
        return self:callFunctionMulti(callMM, newArgs, line)
    end

    -- Roblox userdata/vector that is itself callable (rare, but handle gracefully)
    if type(fn) == "userdata" or type(fn) == "vector" then
        local results = table.pack(pcall(fn, table.unpack(args, 1, args.n or #args)))
        if results[1] then
            -- results[1] = true (ok), rest are return values
            local out = {}
            for i = 2, results.n do out[i - 1] = results[i] end
            local r = multiRet(table.unpack(out, 1, results.n - 1))
            r.n = results.n - 1
            return r
        else
            self:runtimeError(tostring(results[2]), line)
        end
    end

    self:runtimeError(
        string.format("attempt to call a %s value", type(fn)),
        line
    )
end

-- Convenience wrapper that returns only the first value
function Runtime:callFunction(fn, args, line)
    return singleOf(self:callFunctionMulti(fn, args, line))
end

-- ─── Unary operator evaluation ────────────────────────────────────────

function Runtime:evalUnary(node, scope)
    local op = node.op
    local v  = self:eval(node.operand, scope)

    if op == "-" then
        if type(v) == "number" then return -v end
        local r, ok = callMeta(self, v, "__unm")
        if ok then return singleOf(r) end
        if type(v) == "userdata" or type(v) == "vector" then
            local nok, nres = pcall(function() return -v end)
            if nok then return nres end
        end
        self:runtimeError("attempt to perform arithmetic on a " .. type(v), node.line)

    elseif op == "#" then
        if type(v) == "string" then return #v end
        if type(v) == "table"  then
            local mm = getMetamethod(v, "__len")
            if mm then return singleOf(self:callFunction(mm, { v })) end
            return #v
        end
        self:runtimeError("attempt to get length of a " .. type(v), node.line)

    elseif op == "not" then
        return not isTruthy(v)

    elseif op == "~" then
        if type(v) == "number" then return bit32.bnot(math.floor(v)) end
        local r, ok = callMeta(self, v, "__bnot")
        if ok then return singleOf(r) end
        self:runtimeError("attempt to perform bitwise op on a " .. type(v), node.line)
    end
end

-- ─── Binary operator evaluation ───────────────────────────────────────

-- Arithmetic metamethod names
local ARITH_MM = {
    ["+"]  = "__add", ["-"]  = "__sub", ["*"]  = "__mul",
    ["/"]  = "__div", ["//"] = "__idiv", ["%"] = "__mod",
    ["^"]  = "__pow", ["&"]  = "__band", ["|"] = "__bor",
    ["~"]  = "__bxor", ["<<"] = "__shl", [">>"] = "__shr",
}

function Runtime:evalBinary(node, scope)
    local op = node.op

    -- Short-circuit logical operators
    if op == "and" then
        local l = self:eval(node.left, scope)
        if not isTruthy(l) then return l end
        return self:eval(node.right, scope)
    end

    if op == "or" then
        local l = self:eval(node.left, scope)
        if isTruthy(l) then return l end
        return self:eval(node.right, scope)
    end

    local l = self:eval(node.left,  scope)
    local r = self:eval(node.right, scope)

    -- Arithmetic
    local mmName = ARITH_MM[op]
    if mmName then
        if type(l) == "number" and type(r) == "number" then
            if op == "+"  then return l + r
            elseif op == "-"  then return l - r
            elseif op == "*"  then return l * r
            elseif op == "/"  then return l / r
            elseif op == "//" then return l // r
            elseif op == "%"  then return l % r
            elseif op == "^"  then return l ^ r
            elseif op == "&"  then return bit32.band(math.floor(l), math.floor(r))
            elseif op == "|"  then return bit32.bor (math.floor(l), math.floor(r))
            elseif op == "~"  then return bit32.bxor(math.floor(l), math.floor(r))
            elseif op == "<<" then return bit32.lshift(math.floor(l), math.floor(r))
            elseif op == ">>" then return bit32.rshift(math.floor(l), math.floor(r))
            end
        end
        -- Try numeric coercion for string operands (only for +/-/*/…, not bitwise)
        if mmName == "__add" or mmName == "__sub" or mmName == "__mul"
            or mmName == "__div" or mmName == "__idiv" or mmName == "__mod"
            or mmName == "__pow" then
            local nl = type(l) == "string" and tonumber(l) or nil
            local nr = type(r) == "string" and tonumber(r) or nil
            if nl ~= nil and (type(r) == "number" or nr ~= nil) then
                l = nl; r = nr or r
                if type(l) == "number" and type(r) == "number" then
                    if op == "+"  then return l + r
                    elseif op == "-"  then return l - r
                    elseif op == "*"  then return l * r
                    elseif op == "/"  then return l / r
                    elseif op == "//" then return l // r
                    elseif op == "%"  then return l % r
                    elseif op == "^"  then return l ^ r
                    end
                end
            end
        end
        -- Metamethod fallback
        local res, ok = callMeta(self, l, mmName, r)
        if not ok then res, ok = callMeta(self, r, mmName, l) end
        if ok then return singleOf(res) end
        -- Roblox userdata (Vector3, CFrame, etc.) use locked native metamethods
        -- invisible to getmetatable; fall back to raw Lua operators via pcall.
        if type(l) == "userdata" or type(r) == "userdata" or type(l) == "vector" or type(r) == "vector" then
            local nok, nres = tryNativeBinop(op, l, r)
            if nok then return nres end
        end
        self:runtimeError(
            string.format("attempt to perform arithmetic on a %s value", type(l)),
            node.line
        )
    end

    -- Concatenation
    if op == ".." then
        if (type(l) == "string" or type(l) == "number") and
           (type(r) == "string" or type(r) == "number") then
            return tostring(l) .. tostring(r)
        end
        local res, ok = callMeta(self, l, "__concat", r)
        if not ok then res, ok = callMeta(self, r, "__concat", l) end
        if ok then return singleOf(res) end
        if type(l) == "userdata" or type(r) == "userdata" or type(l) == "vector" or type(r) == "vector" then
            local nok, nres = tryNativeBinop("..", l, r)
            if nok then return nres end
        end
        self:runtimeError(
            "attempt to concatenate a " .. type(l) .. " value",
            node.line
        )
    end

    -- Comparison
    if op == "==" then
        if type(l) ~= type(r) then return false end
        if type(l) == "table" then
            local res, ok = callMeta(self, l, "__eq", r)
            if ok then return isTruthy(singleOf(res)) end
        end
        return l == r
    end

    if op == "~=" then
        if type(l) ~= type(r) then return true end
        if type(l) == "table" then
            local res, ok = callMeta(self, l, "__eq", r)
            if ok then return not isTruthy(singleOf(res)) end
        end
        return l ~= r
    end

    if op == "<" then
        if type(l) == "number" and type(r) == "number" then return l < r end
        if type(l) == "string" and type(r) == "string" then return l < r end
        local res, ok = callMeta(self, l, "__lt", r)
        if ok then return isTruthy(singleOf(res)) end
        if type(l) == "userdata" or type(r) == "userdata" or type(l) == "vector" or type(r) == "vector" then
            local nok, nres = tryNativeBinop("<", l, r)
            if nok then return nres end
        end
        self:runtimeError("attempt to compare two " .. type(l) .. " values", node.line)
    end

    if op == ">" then
        if type(l) == "number" and type(r) == "number" then return l > r end
        if type(l) == "string" and type(r) == "string" then return l > r end
        -- Luau: a > b equivalent to b < a
        local res, ok = callMeta(self, r, "__lt", l)
        if ok then return isTruthy(singleOf(res)) end
        if type(l) == "userdata" or type(r) == "userdata" or type(l) == "vector" or type(r) == "vector" then
            local nok, nres = tryNativeBinop(">", l, r)
            if nok then return nres end
        end
        self:runtimeError("attempt to compare two " .. type(l) .. " values", node.line)
    end

    if op == "<=" then
        if type(l) == "number" and type(r) == "number" then return l <= r end
        if type(l) == "string" and type(r) == "string" then return l <= r end
        local res, ok = callMeta(self, l, "__le", r)
        if ok then return isTruthy(singleOf(res)) end
        -- Fallback: a <= b equivalent to not (b < a)
        res, ok = callMeta(self, r, "__lt", l)
        if ok then return not isTruthy(singleOf(res)) end
        if type(l) == "userdata" or type(r) == "userdata" or type(l) == "vector" or type(r) == "vector" then
            local nok, nres = tryNativeBinop("<=", l, r)
            if nok then return nres end
        end
        self:runtimeError("attempt to compare two " .. type(l) .. " values", node.line)
    end

    if op == ">=" then
        if type(l) == "number" and type(r) == "number" then return l >= r end
        if type(l) == "string" and type(r) == "string" then return l >= r end
        local res, ok = callMeta(self, r, "__le", l)
        if ok then return isTruthy(singleOf(res)) end
        res, ok = callMeta(self, l, "__lt", r)
        if ok then return not isTruthy(singleOf(res)) end
        if type(l) == "userdata" or type(r) == "userdata" or type(l) == "vector" or type(r) == "vector" then
            local nok, nres = tryNativeBinop(">=", l, r)
            if nok then return nres end
        end
        self:runtimeError("attempt to compare two " .. type(l) .. " values", node.line)
    end

    self:runtimeError("unknown binary operator: " .. op, node.line)
end

-- ─── Table constructor evaluation ────────────────────────────────────

function Runtime:evalTableConstructor(node, scope)
    local tbl      = {}
    local arrayIdx = 1

    for i, field in ipairs(node.fields) do
        if field.kind == "NamedField" then
            local v = self:eval(field.value, scope)
            tbl[field.name] = v

        elseif field.kind == "IndexedField" then
            local k = self:eval(field.key,   scope)
            local v = self:eval(field.value, scope)
            tbl[k] = v

        elseif field.kind == "ValueField" then
            -- Last field: expand multi-return
            if i == #node.fields then
                local vals, n = unpackMulti(self:evalMulti(field.value, scope))
                for j = 1, n do
                    tbl[arrayIdx] = vals[j]
                    arrayIdx = arrayIdx + 1
                end
            else
                local v = self:eval(field.value, scope)
                tbl[arrayIdx] = v
                arrayIdx = arrayIdx + 1
            end
        end
    end

    return tbl
end

-- ─── Statement execution ──────────────────────────────────────────────

function Runtime:execStat(node, scope)
    if node.line then self._currentLine = node.line end
    local kind = node.kind

    -- ── Expression statement (must be a call) ────────────────────
    if kind == "ExprStatement" then
        self:evalMulti(node.expr, scope)
        return

    -- ── Local declaration ─────────────────────────────────────────
    elseif kind == "LocalDeclaration" then
        local count   = #node.values
        local results = {}
        for i = 1, count do
            results[i] = self:evalMulti(node.values[i], scope)
        end
        local flat = flattenExprList(results, count)
        for i, name in ipairs(node.names) do
            local attr    = node.attribs[i]
            local isConst = attr == "const"
            local isClose = attr == "close"
            scope:declareLocal(name, flat[i], isConst, isClose)
        end
        return

    -- ── Assignment ────────────────────────────────────────────────
    elseif kind == "Assignment" then
        local count   = #node.values
        local results = {}
        for i = 1, count do
            results[i] = self:evalMulti(node.values[i], scope)
        end
        local flat = flattenExprList(results, count)

        for i, target in ipairs(node.targets) do
            local val = flat[i]
            self:assignTarget(target, val, scope)
        end
        return

    -- ── Compound assignment  target op= value ─────────────────────
    elseif kind == "CompoundAssignment" then
        -- Strip trailing = to get the base operator: += -> +, ..= -> ..
        local op    = string.sub(node.op, 1, -2)
        local left  = self:eval(node.target, scope)
        local right = self:eval(node.value,  scope)
        local result = self:evalBinaryValues(op, left, right, node.line)
        self:assignTarget(node.target, result, scope)
        return

    -- ── Do block ─────────────────────────────────────────────────
    elseif kind == "DoBlock" then
        local inner = scope:child("do")
        self:execBlock(node.body, inner)
        return

    -- ── While loop ────────────────────────────────────────────────
    elseif kind == "WhileLoop" then
        while isTruthy(self:eval(node.cond, scope)) do
            local inner = scope:child("while")
            local ok, sig = pcall(function()
                self:execBlock(node.body, inner)
            end)
            if not ok then
                if Error.isBreak(sig) then break end
                if not Error.isContinue(sig) then error(sig, 0) end
                -- continue: fall through to next iteration
            end
        end
        return

    -- ── Repeat...until ───────────────────────────────────────────
    elseif kind == "RepeatLoop" then
        repeat
            local inner = scope:child("repeat")
            local broken = false
            local ok, sig = pcall(function()
                self:execBlock(node.body, inner)
            end)
            if not ok then
                if Error.isBreak(sig)    then broken = true
                elseif Error.isContinue(sig) then -- continue just re-checks cond
                else error(sig, 0) end
            end
            if broken then break end
            -- Note: cond is evaluated in inner scope (can see loop locals)
        until isTruthy(self:eval(node.cond, inner))
        return

    -- ── Numeric for ───────────────────────────────────────────────
    elseif kind == "NumericFor" then
        local startV = self:eval(node.start, scope)
        local limitV = self:eval(node.limit, scope)
        local stepV  = node.step and self:eval(node.step, scope) or 1

        if type(startV) ~= "number" then
            self:runtimeError("'for' initial value must be a number", node.line)
        end
        if type(limitV) ~= "number" then
            self:runtimeError("'for' limit must be a number", node.line)
        end
        if type(stepV) ~= "number" or stepV == 0 then
            self:runtimeError("'for' step must be a non-zero number", node.line)
        end

        local i = startV
        while (stepV > 0 and i <= limitV) or (stepV < 0 and i >= limitV) do
            local inner = scope:child("numfor")
            inner:declareLocal(node.var, i)

            local ok, sig = pcall(function()
                self:execBlock(node.body, inner)
            end)
            if not ok then
                if Error.isBreak(sig) then break end
                if not Error.isContinue(sig) then error(sig, 0) end
                -- continue: fall through to i increment below
            end

            i = i + stepV   -- reached on normal completion or continue
        end
        return

    -- ── Generic for ───────────────────────────────────────────────
    elseif kind == "GenericFor" then
        -- Evaluate iterator expressions
        local count   = #node.iters
        local results = {}
        for i = 1, count do
            results[i] = self:evalMulti(node.iters[i], scope)
        end
        local flat = flattenExprList(results, count)

        -- Luau __iter metamethod: if a single table is passed as the
        -- iterator and it has __iter in its metatable, call __iter(table)
        -- to obtain (iterFn, state, control).
        if #node.iters == 1 then
            local first = flat[1]
            if type(first) == "table" and not isClosure(first) then
                local mt = getmetatable(first)
                if mt then
                    local iterMM = rawget(mt, "__iter")
                    if iterMM then
                        local mr = self:callFunctionMulti(iterMM, { first }, node.line)
                        local newFlat = {}
                        for i = 1, mr.n do newFlat[i] = mr[i] end
                        flat = newFlat
                    end
                end
            end
        end

        local iterFn  = flat[1]   -- iterator function
        local state   = flat[2]   -- state
        local control = flat[3]   -- initial control variable

        while true do
            local retVals = self:callFunctionMulti(iterFn, { state, control }, node.line)
            local vals, n = unpackMulti(retVals)

            -- Stop if first returned value is nil
            if vals[1] == nil then break end
            control = vals[1]

            local inner = scope:child("genfor")
            for i, varName in ipairs(node.vars) do
                inner:declareLocal(varName, vals[i])
            end

            local ok, sig = pcall(function()
                self:execBlock(node.body, inner)
            end)
            if not ok then
                if Error.isBreak(sig) then break end
                if not Error.isContinue(sig) then error(sig, 0) end
                -- continue: fall through to next iteration
            end
        end
        return

    -- ── If statement ──────────────────────────────────────────────
    elseif kind == "IfStatement" then
        if isTruthy(self:eval(node.cond, scope)) then
            local inner = scope:child("if-then")
            self:execBlock(node.thenBlock, inner)
        else
            local taken = false
            for _, ei in ipairs(node.elseIfs) do
                if isTruthy(self:eval(ei.cond, scope)) then
                    local inner = scope:child("elseif")
                    self:execBlock(ei.body, inner)
                    taken = true
                    break
                end
            end
            if not taken and node.elseBlock then
                local inner = scope:child("else")
                self:execBlock(node.elseBlock, inner)
            end
        end
        return

    -- ── Function declaration (statement form) ─────────────────────
    elseif kind == "FunctionDeclaration" then
        local closure = self:makeClosure(node.body, scope, nameExprToString(node.name))
        self:assignNameExpr(node.name, closure, scope, node.isMethod)
        return

    -- ── Local function declaration ────────────────────────────────
    elseif kind == "LocalFunction" then
        -- The function name is visible inside itself (recursive)
        scope:declareLocal(node.name, nil)
        local closure = self:makeClosure(node.body, scope, node.name)
        scope:declareLocal(node.name, closure)
        return

    -- ── Return ────────────────────────────────────────────────────
    elseif kind == "ReturnStatement" then
        local count   = #node.values
        local results = {}
        for i = 1, count do
            results[i] = self:evalMulti(node.values[i], scope)
        end
        local flat = flattenExprList(results, count)
        error(Error.returnSignal(flat, flat.n), 0)

    -- ── Break / Continue ──────────────────────────────────────────
    elseif kind == "BreakStatement" then
        error(Error.breakSignal(), 0)

    elseif kind == "ContinueStatement" then
        error(Error.continueSignal(), 0)

    -- ── Goto / Label ──────────────────────────────────────────────
    elseif kind == "GotoStatement" then
        error(Error.gotoSignal(node.name), 0)

    elseif kind == "LabelStatement" then
        -- Labels are handled during block execution (see execBlock)
        return

    -- ── Class declaration ─────────────────────────────────────────
    -- class Foo [extends Bar]
    --   field = default     -> classTable.field = default
    --   function method(...) -> classTable.method = closure
    -- end
    -- Declares `Foo` as a local in the current scope.
    -- Sets classTable.__index = classTable so that instances created with
    -- setmetatable({}, Foo) automatically inherit class methods.
    elseif kind == "ClassDeclaration" then
        local classTable = {}
        classTable.__index = classTable

        -- Declare the class name before executing the body so that methods
        -- can reference the class (e.g. inside Animal.new, `Animal` resolves).
        scope:declareLocal(node.name, classTable)

        -- Inheritance: setmetatable(classTable, {__index = ParentClass})
        -- This lets classTable.parentMethod resolve via the parent's table.
        if node.superName then
            local parent = scope:get(node.superName)
            if type(parent) == "table" then
                setmetatable(classTable, { __index = parent })
            else
                self:runtimeError(
                    "class '" .. node.name .. "' extends unknown class '"
                        .. node.superName .. "'",
                    node.line
                )
            end
        end

        -- Field defaults: stored on the class table so instances inherit them
        -- via __index unless the instance overrides them.
        for _, field in ipairs(node.fields) do
            if field.default ~= nil then
                classTable[field.name] = self:eval(field.default, scope)
            end
        end

        -- Methods: each becomes a closure bound to the class table.
        for _, method in ipairs(node.methods) do
            classTable[method.name] = self:makeClosure(method.body, scope, method.name)
        end

        return

    -- ── Type alias (no-op at runtime) ────────────────────────────
    elseif kind == "TypeAlias" then
        return

    else
        self:runtimeError(
            string.format("unknown statement kind '%s'", kind),
            node.line
        )
    end
end

-- ─── Block execution (with goto support) ─────────────────────────────

-- Run __close handlers for all to-be-closed variables in `scope`.
-- closeErr is the error object if the block exited via a runtime error,
-- or nil for normal exit and control-flow signals (break/continue/return/goto).
-- Handlers are called in reverse declaration order; errors inside them are
-- swallowed so that close errors do not mask the original signal.
function Runtime:runCloseHandlers(scope, closeErr)
    local list = scope.closeList
    for j = #list, 1, -1 do
        local name = list[j]
        local val  = scope.variables[name]
        if type(val) == "table" then
            local mt = getmetatable(val)
            if mt then
                local closeMM = rawget(mt, "__close")
                if closeMM ~= nil then
                    pcall(function()
                        self:callFunction(closeMM, { val, closeErr })
                    end)
                end
            end
        end
    end
end

function Runtime:execBlock(block, scope)
    local stmts = block.stmts
    local i     = 1

    -- Outer pcall captures any signal that escapes the statement loop so
    -- that to-be-closed variables can be finalized before re-raising.
    local blockOk, blockSig = pcall(function()
        while i <= #stmts do
            local stat = stmts[i]

            local ok, sig = pcall(function()
                self:execStat(stat, scope)
            end)

            if not ok then
                -- Goto: scan forward / backward for label in this block
                if Error.isGoto(sig) then
                    local label = sig.label
                    local found = false
                    for j, s in ipairs(stmts) do
                        if s.kind == "LabelStatement" and s.name == label then
                            i = j + 1
                            found = true
                            break
                        end
                    end
                    if not found then
                        error(sig, 0)   -- propagate to outer block
                    end
                    -- continue loop from new i
                else
                    error(sig, 0)   -- re-raise all other signals / errors
                end
            else
                i = i + 1
            end
        end
    end)

    -- Run to-be-closed variable handlers (LIFO) if any were declared in
    -- this scope. Most blocks have none, so the check is cheap.
    if #scope.closeList > 0 then
        local closeErr = nil
        if not blockOk then
            -- Control-flow signals are not errors; only real RuntimeErrors get
            -- passed to __close as the second argument.
            local isSignal = Error.isBreak(blockSig)    or Error.isContinue(blockSig)
                          or Error.isReturn(blockSig)   or Error.isGoto(blockSig)
            if not isSignal then
                closeErr = blockSig
            end
        end
        self:runCloseHandlers(scope, closeErr)
    end

    if not blockOk then
        error(blockSig, 0)
    end
end

-- ─── Assignment helpers ───────────────────────────────────────────────

-- Assign a value to a target expression node.
function Runtime:assignTarget(target, value, scope)
    local kind = target.kind

    if kind == "Identifier" then
        -- Walk scope chain; if not found, create global
        scope:assign(target.name, value)

    elseif kind == "FieldExpr" then
        local tbl = self:eval(target.table, scope)
        self:tableSet(tbl, target.field, value, target.line)

    elseif kind == "IndexExpr" then
        local tbl = self:eval(target.table, scope)
        local key = self:eval(target.key,   scope)
        self:tableSet(tbl, key, value, target.line)

    else
        self:runtimeError(
            "invalid assignment target",
            target.line
        )
    end
end

-- For function declarations: assign to a dotted name expression.
-- node.name can be  Identifier | FieldExpr | MethodName
function Runtime:assignNameExpr(nameExpr, value, scope, isMethod)
    local kind = nameExpr.kind

    if kind == "Identifier" then
        scope:assign(nameExpr.name, value)

    elseif kind == "FieldExpr" then
        local tbl = self:eval(nameExpr.table, scope)
        self:tableSet(tbl, nameExpr.field, value, nameExpr.line)

    elseif kind == "MethodName" then
        local tbl = self:eval(nameExpr.table, scope)
        self:tableSet(tbl, nameExpr.method, value, nameExpr.line)

    else
        self:runtimeError("unsupported function name form", nameExpr.line)
    end
end

-- ─── Binary arithmetic on raw values (for compound assignment) ────────
-- Mirrors evalBinary's metamethod dispatch so that compound assignment
-- (+=, -=, ..=, etc.) correctly invokes __add, __sub, __concat, etc.
-- on interpreter-defined metatables. (#9)

function Runtime:evalBinaryValues(op, l, r, line)
    local mmName = ARITH_MM[op]
    if mmName then
        if type(l) == "number" and type(r) == "number" then
            if op == "+"  then return l + r
            elseif op == "-"  then return l - r
            elseif op == "*"  then return l * r
            elseif op == "/"  then return l / r
            elseif op == "//" then return l // r
            elseif op == "%"  then return l % r
            elseif op == "^"  then return l ^ r
            elseif op == "&"  then return bit32.band(math.floor(l), math.floor(r))
            elseif op == "|"  then return bit32.bor (math.floor(l), math.floor(r))
            elseif op == "~"  then return bit32.bxor(math.floor(l), math.floor(r))
            elseif op == "<<" then return bit32.lshift(math.floor(l), math.floor(r))
            elseif op == ">>" then return bit32.rshift(math.floor(l), math.floor(r))
            end
        end
        -- String coercion for arithmetic operators (not bitwise)
        if mmName == "__add" or mmName == "__sub" or mmName == "__mul"
            or mmName == "__div" or mmName == "__idiv" or mmName == "__mod"
            or mmName == "__pow" then
            local nl = type(l) == "string" and tonumber(l) or nil
            local nr = type(r) == "string" and tonumber(r) or nil
            if nl ~= nil and (type(r) == "number" or nr ~= nil) then
                local ll, rr = nl, nr or r
                if type(ll) == "number" and type(rr) == "number" then
                    if op == "+"  then return ll + rr
                    elseif op == "-"  then return ll - rr
                    elseif op == "*"  then return ll * rr
                    elseif op == "/"  then return ll / rr
                    elseif op == "//" then return ll // rr
                    elseif op == "%"  then return ll % rr
                    elseif op == "^"  then return ll ^ rr
                    end
                end
            end
        end
        local res, ok = callMeta(self, l, mmName, r)
        if not ok then res, ok = callMeta(self, r, mmName, l) end
        if ok then return singleOf(res) end
        if type(l) == "userdata" or type(r) == "userdata" or type(l) == "vector" or type(r) == "vector" then
            local nok, nres = tryNativeBinop(op, l, r)
            if nok then return nres end
        end
        self:runtimeError(
            string.format("attempt to perform arithmetic on a %s value", type(l)),
            line
        )
    end

    if op == ".." then
        if (type(l) == "string" or type(l) == "number") and
           (type(r) == "string" or type(r) == "number") then
            return tostring(l) .. tostring(r)
        end
        local res, ok = callMeta(self, l, "__concat", r)
        if not ok then res, ok = callMeta(self, r, "__concat", l) end
        if ok then return singleOf(res) end
        if type(l) == "userdata" or type(r) == "userdata" or type(l) == "vector" or type(r) == "vector" then
            local nok, nres = tryNativeBinop("..", l, r)
            if nok then return nres end
        end
        self:runtimeError("attempt to concatenate a " .. type(l) .. " value", line)
    end

    self:runtimeError("unknown compound operator: " .. op, line)
end

-- ─── Error helper ─────────────────────────────────────────────────────

function Runtime:runtimeError(msg, line)
    local err = Error.runtime(msg, line)
    local co = coroutine.running() or "main"
    local stack = self.callStacks[co] or {}
    local N = #stack
    if N == 0 then
        -- Error in main chunk
        if line and line > 0 then
            err:pushFrame(string.format("    Line %d - in main chunk", line))
        end
    else
        -- Innermost frame: where the error actually happened
        local innerName = stack[N].fnName
        if line and line > 0 then
            if innerName then
                err:pushFrame(string.format("    Line %d - in function '%s'", line, innerName))
            else
                err:pushFrame(string.format("    Line %d - in function '?'", line))
            end
        end
        -- Intermediate frames (innermost call site down to second frame)
        for i = N, 2, -1 do
            local callerName = stack[i - 1].fnName
            if callerName then
                err:pushFrame(string.format("    Line %d - in function '%s'", stack[i].line, callerName))
            else
                err:pushFrame(string.format("    Line %d - in function '?'", stack[i].line))
            end
        end
        -- Outermost: main chunk called into the first function
        if stack[1].line > 0 then
            err:pushFrame(string.format("    Line %d - in main chunk", stack[1].line))
        end
    end
    error(err, 0)
end

-- ─── Public interface ─────────────────────────────────────────────────

local RuntimeModule = {}

function RuntimeModule.new(globalScope)
    return Runtime.new(globalScope)
end

-- Execute a pre-parsed AST block in a given scope.
-- Returns ok (bool), result_or_error.
function RuntimeModule.execBlock(runtime, block, scope)
    local ok, err = pcall(function()
        runtime:execBlock(block, scope)
    end)
    if ok then
        return true, nil
    end
    if Error.isReturn(err) then
        return true, err.values
    end
    return false, err
end

return RuntimeModule
