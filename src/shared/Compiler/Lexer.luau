--[[
    Lexer.luau — Luau source tokenizer

    Converts raw source text into a sequential list of Token objects.

    Token shape:
        {
            type   : string  -- see TT constants below
            value  : any     -- literal value for NUMBER/STRING; raw text otherwise
            line   : number
            col    : number
        }

    Design notes
    ─────────────
    • Operates on byte positions (pos is 1-based byte index into source string).
    • Line numbers start at 1; column numbers start at 1 (byte offset on line).
    • Long strings / long comments support arbitrary bracket levels [==[…]==].
    • All Luau operators, compound-assignment operators, and type-annotation
      punctuation (-> :: ?) are tokenised.
    • Keywords are initially scanned as identifiers and then looked up in the
      KEYWORDS table; the token type is set to the keyword string (e.g. "if",
      "function").  This keeps the parser logic clean.
    • Numbers are parsed to their numeric value during lexing.
    • String escape sequences are fully resolved during lexing.
    • No regex: every character is examined one at a time.
]]

local Error = require(script.Parent.Error)

-- ─── Token type constants ────────────────────────────────────────────

local TT = {
    -- Literals (type carries the Luau datatype name)
    NUMBER     = "NUMBER",
    STRING     = "STRING",

    -- Identifier (not a keyword)
    IDENTIFIER = "IDENTIFIER",

    -- Keywords — the token type IS the keyword text
    -- (listed here only for documentation / autocomplete)
    --  "and" "break" "continue" "do" "else" "elseif" "end"
    --  "false" "for" "function" "goto" "if" "in" "local"
    --  "nil" "not" "or" "repeat" "return" "then" "true"
    --  "until" "while" "type" "typeof" "export"

    -- Operators & punctuation — token type IS the symbol string
    -- Single-char: + - * % ^ # & | ~ < > = ( ) [ ] { } , ; : . ? @
    -- Multi-char:  // .. ... == ~= <= >= << >> -> :: += -= *= /= //= %= ^= ..= &= |= <<= >>=

    EOF = "EOF",
}

-- Keyword set (identifier text → token type string)
local KEYWORDS = {
    ["and"]      = "and",
    ["break"]    = "break",
    ["continue"] = "continue",
    ["do"]       = "do",
    ["else"]     = "else",
    ["elseif"]   = "elseif",
    ["end"]      = "end",
    ["false"]    = "false",
    ["for"]      = "for",
    ["function"] = "function",
    ["goto"]     = "goto",
    ["if"]       = "if",
    ["in"]       = "in",
    ["local"]    = "local",
    ["nil"]      = "nil",
    ["not"]      = "not",
    ["or"]       = "or",
    ["repeat"]   = "repeat",
    ["return"]   = "return",
    ["then"]     = "then",
    ["true"]     = "true",
    ["until"]    = "until",
    ["while"]    = "while",
    ["type"]     = "type",
    ["typeof"]   = "typeof",
    ["export"]   = "export",
}

-- ─── Lexer class ─────────────────────────────────────────────────────

local Lexer = {}
Lexer.__index = Lexer

function Lexer.new(source, sourceName)
    return setmetatable({
        source     = source,
        sourceName = sourceName or "?",
        pos        = 1,
        line       = 1,
        lineStart  = 1,   -- byte position of start of current line
        tokens     = {},
    }, Lexer)
end

-- ─── Low-level character helpers ─────────────────────────────────────

-- Current character (string of length 1, or nil at EOF)
function Lexer:cur()
    return string.sub(self.source, self.pos, self.pos)
end

-- Character at pos+offset (0-based offset from current)
function Lexer:peek(offset)
    local p = self.pos + (offset or 0)
    return string.sub(self.source, p, p)
end

-- Advance one character, updating line/column tracking.
-- Returns the character that was consumed.
function Lexer:advance()
    local c = string.sub(self.source, self.pos, self.pos)
    self.pos = self.pos + 1
    if c == "\n" then
        self.line = self.line + 1
        self.lineStart = self.pos
    end
    return c
end

-- If the current char equals `expected`, consume it and return true.
function Lexer:match(expected)
    if string.sub(self.source, self.pos, self.pos) == expected then
        self:advance()
        return true
    end
    return false
end

-- Are we at or past the end of the source?
function Lexer:atEnd()
    return self.pos > #self.source
end

-- Current column number (1-based)
function Lexer:col()
    return self.pos - self.lineStart + 1
end

-- Throw a LexerError
function Lexer:error(msg)
    error(Error.lexer(msg, self.line, self:col()), 0)
end

-- Add a token to the list
function Lexer:emit(tokenType, value, line, col)
    table.insert(self.tokens, {
        type  = tokenType,
        value = value,
        line  = line,
        col   = col,
    })
end

-- ─── Whitespace / comments ───────────────────────────────────────────

function Lexer:skipWhitespaceAndComments()
    while not self:atEnd() do
        local c = self:cur()

        -- Whitespace
        if c == " " or c == "\t" or c == "\r" or c == "\n" then
            self:advance()

        -- Comments: start with --
        elseif c == "-" and self:peek(1) == "-" then
            self:advance(); self:advance()  -- consume --

            -- Long comment?  Try [=*[ opener.
            local isLongComment = false
            if self:cur() == "[" then
                local level = self:checkLongBracketLevel()
                if level ~= nil then
                    self:consumeLongBracketOpen(level)
                    self:readLongBracketBody(level)   -- discard content
                    isLongComment = true
                end
            end

            -- Short comment: consume until EOL (skip if long comment already handled)
            if not isLongComment then
                while not self:atEnd() and self:cur() ~= "\n" do
                    self:advance()
                end
            end
        else
            break
        end
    end
end

-- ─── Long bracket helpers ────────────────────────────────────────────

-- Check if, starting at current position, we have a long-bracket open [=*[
-- Returns the level (number of = signs), or nil if not a long bracket.
-- Does NOT advance position.
function Lexer:checkLongBracketLevel()
    if self:cur() ~= "[" then return nil end
    local i = 1
    while self:peek(i) == "=" do
        i = i + 1
    end
    if self:peek(i) == "[" then
        return i - 1   -- level = number of = signs
    end
    return nil
end

-- Consume the opening [=*[ (caller already checked it's valid).
function Lexer:consumeLongBracketOpen(level)
    self:advance()                        -- [
    for _ = 1, level do self:advance() end  -- = * level
    self:advance()                        -- [
end

-- Read the body of a long bracket until the matching ]=*] close.
-- Returns the body content as a string.
-- The first newline immediately after the opening bracket is skipped
-- (Lua / Luau reference behaviour).
function Lexer:readLongBracketBody(level)
    local close = "]" .. string.rep("=", level) .. "]"
    local startLine = self.line

    -- Skip leading newline
    if self:cur() == "\n" then
        self:advance()
    elseif self:cur() == "\r" then
        self:advance()
        if self:cur() == "\n" then self:advance() end
    end

    local contentStart = self.pos
    local closePos, closeEnd = string.find(self.source, close, contentStart, true)

    if not closePos then
        self:error(string.format("unfinished long string (started at line %d)", startLine))
    end

    local body = string.sub(self.source, contentStart, closePos - 1)

    -- Advance position past the body and closing bracket,
    -- updating line counter for newlines in the body.
    for i = contentStart, closeEnd do
        if string.sub(self.source, i, i) == "\n" then
            self.line = self.line + 1
            self.lineStart = i + 1
        end
    end
    self.pos = closeEnd + 1

    return body
end

-- ─── String literals ─────────────────────────────────────────────────

-- String escape sequences → resolved character
local ESCAPE_MAP = {
    a  = "\a", b  = "\b", f  = "\f", n  = "\n",
    r  = "\r", t  = "\t", v  = "\v",
    ["\\"] = "\\", ["'"] = "'", ['"'] = '"',
    ["\n"] = "\n", ["\r"] = "\n",
}

function Lexer:readQuotedString(quote)
    local buf = {}
    while not self:atEnd() do
        local c = self:advance()
        if c == quote then
            return table.concat(buf)
        elseif c == "\\" then
            -- Escape sequence
            local e = self:advance()
            if ESCAPE_MAP[e] then
                buf[#buf + 1] = ESCAPE_MAP[e]
            elseif e == "x" then
                -- Hex escape \xNN
                local h1 = self:advance()
                local h2 = self:advance()
                local n  = tonumber(h1 .. h2, 16)
                if not n then self:error("invalid hex escape") end
                buf[#buf + 1] = string.char(n)
            elseif e == "u" then
                -- Unicode escape \u{NNNN}
                if not self:match("{") then self:error("missing '{' in \\u escape") end
                local hex = {}
                while self:cur() ~= "}" and not self:atEnd() do
                    hex[#hex + 1] = self:advance()
                end
                if not self:match("}") then self:error("missing '}' in \\u escape") end
                local codepoint = tonumber(table.concat(hex), 16)
                if not codepoint then self:error("invalid unicode escape") end
                -- Encode as UTF-8
                buf[#buf + 1] = utf8 and utf8.char(codepoint) or string.char(codepoint % 256)
            elseif e == "z" then
                -- \z skips following whitespace
                while not self:atEnd() and string.match(self:cur(), "%s") do
                    self:advance()
                end
            elseif string.match(e, "%d") then
                -- Decimal escape \NNN (up to 3 digits)
                local digits = { e }
                for _ = 1, 2 do
                    if string.match(self:cur(), "%d") then
                        digits[#digits + 1] = self:advance()
                    end
                end
                local n = tonumber(table.concat(digits))
                if not n or n > 255 then self:error("decimal escape too large") end
                buf[#buf + 1] = string.char(n)
            else
                self:error(string.format("invalid escape sequence '\\%s'", e))
            end
        elseif c == "\n" or c == "\r" then
            self:error("unfinished string near end of line")
        else
            buf[#buf + 1] = c
        end
    end
    self:error("unfinished string near <eof>")
end

-- ─── Number literals ──────────────────────────────────────────────────

function Lexer:readNumber(line, col)
    local start = self.pos
    local isHex = false

    -- Hex: 0x or 0X
    if self:cur() == "0" and (self:peek(1) == "x" or self:peek(1) == "X") then
        isHex = true
        self:advance(); self:advance()  -- 0x
        -- Hex digits (with optional _ separator in Luau)
        local hasDigit = false
        while not self:atEnd() do
            local c = self:cur()
            if string.match(c, "[0-9a-fA-F]") or c == "_" then
                hasDigit = true
                self:advance()
            else
                break
            end
        end
        if not hasDigit then self:error("malformed hexadecimal number") end
        -- Hex float exponent (p or P)
        if self:cur() == "p" or self:cur() == "P" then
            self:advance()
            if self:cur() == "+" or self:cur() == "-" then self:advance() end
            if not string.match(self:cur(), "%d") then self:error("malformed number exponent") end
            while string.match(self:cur(), "[%d_]") do self:advance() end
        end
    -- Binary: 0b or 0B (Luau extension)
    elseif self:cur() == "0" and (self:peek(1) == "b" or self:peek(1) == "B") then
        self:advance(); self:advance()
        local hasDigit = false
        while self:cur() == "0" or self:cur() == "1" or self:cur() == "_" do
            if self:cur() ~= "_" then hasDigit = true end
            self:advance()
        end
        if not hasDigit then self:error("malformed binary number") end
    else
        -- Decimal integer / float
        while not self:atEnd() and string.match(self:cur(), "[%d_]") do
            self:advance()
        end
        -- Decimal point
        if self:cur() == "." and string.match(self:peek(1), "%d") then
            self:advance()
            while not self:atEnd() and string.match(self:cur(), "[%d_]") do
                self:advance()
            end
        end
        -- Exponent e or E
        if self:cur() == "e" or self:cur() == "E" then
            self:advance()
            if self:cur() == "+" or self:cur() == "-" then self:advance() end
            if not string.match(self:cur(), "%d") then self:error("malformed number exponent") end
            while string.match(self:cur(), "[%d_]") do self:advance() end
        end
    end

    -- Extract raw text, strip _ separators, then convert
    local raw = string.sub(self.source, start, self.pos - 1)
    raw = string.gsub(raw, "_", "")  -- strip digit separators

    local n
    if isHex then
        n = tonumber(raw)          -- tonumber handles 0x prefix
    elseif string.sub(raw, 1, 2) == "0b" or string.sub(raw, 1, 2) == "0B" then
        n = tonumber(string.sub(raw, 3), 2)
    else
        n = tonumber(raw)
    end

    if n == nil then
        self:error(string.format("malformed number '%s'", raw))
    end

    self:emit(TT.NUMBER, n, line, col)
end

-- ─── Main tokenise loop ───────────────────────────────────────────────

function Lexer:tokenize()
    while true do
        self:skipWhitespaceAndComments()

        if self:atEnd() then
            self:emit(TT.EOF, nil, self.line, self:col())
            break
        end

        local line = self.line
        local col  = self:col()
        local c    = self:cur()

        -- ── Identifier / keyword ───────────────────────────────────
        if c == "_" or string.match(c, "[%a]") then
            local start = self.pos
            while not self:atEnd() and string.match(self:cur(), "[%w_]") do
                self:advance()
            end
            local text = string.sub(self.source, start, self.pos - 1)
            local kw   = KEYWORDS[text]
            self:emit(kw or TT.IDENTIFIER, text, line, col)

        -- ── Number ────────────────────────────────────────────────
        elseif string.match(c, "%d") then
            self:readNumber(line, col)

        -- ── String: single or double quote ────────────────────────
        elseif c == '"' or c == "'" then
            self:advance()  -- consume opening quote
            local s = self:readQuotedString(c)
            self:emit(TT.STRING, s, line, col)

        -- ── String: long bracket [=*[ ─────────────────────────────
        elseif c == "[" then
            local level = self:checkLongBracketLevel()
            if level ~= nil then
                self:consumeLongBracketOpen(level)
                local s = self:readLongBracketBody(level)
                self:emit(TT.STRING, s, line, col)
            else
                self:advance()
                self:emit("[", nil, line, col)
            end

        -- ── Operators / punctuation ────────────────────────────────
        elseif c == "+" then
            self:advance()
            if self:match("=") then self:emit("+=",  nil, line, col)
            else                     self:emit("+",   nil, line, col) end

        elseif c == "-" then
            self:advance()
            if self:match(">") then  self:emit("->",  nil, line, col)
            elseif self:match("=") then self:emit("-=", nil, line, col)
            else                     self:emit("-",   nil, line, col) end

        elseif c == "*" then
            self:advance()
            if self:match("=") then self:emit("*=",  nil, line, col)
            else                     self:emit("*",   nil, line, col) end

        elseif c == "/" then
            self:advance()
            if self:cur() == "/" then
                self:advance()
                if self:match("=") then self:emit("//=", nil, line, col)
                else                    self:emit("//",  nil, line, col) end
            elseif self:match("=") then self:emit("/=",  nil, line, col)
            else                        self:emit("/",   nil, line, col) end

        elseif c == "%" then
            self:advance()
            if self:match("=") then self:emit("%=",  nil, line, col)
            else                     self:emit("%",   nil, line, col) end

        elseif c == "^" then
            self:advance()
            if self:match("=") then self:emit("^=",  nil, line, col)
            else                     self:emit("^",   nil, line, col) end

        elseif c == "#" then
            self:advance()
            self:emit("#", nil, line, col)

        elseif c == "&" then
            self:advance()
            if self:match("=") then      self:emit("&=",  nil, line, col)
            else                         self:emit("&",   nil, line, col) end

        elseif c == "|" then
            self:advance()
            if self:match("=") then      self:emit("|=",  nil, line, col)
            else                         self:emit("|",   nil, line, col) end

        elseif c == "~" then
            self:advance()
            if self:match("=") then      self:emit("~=",  nil, line, col)
            else                         self:emit("~",   nil, line, col) end

        elseif c == "<" then
            self:advance()
            if self:cur() == "<" then
                self:advance()
                if self:match("=") then  self:emit("<<=", nil, line, col)
                else                     self:emit("<<",  nil, line, col) end
            elseif self:match("=") then  self:emit("<=",  nil, line, col)
            else                         self:emit("<",   nil, line, col) end

        elseif c == ">" then
            self:advance()
            if self:cur() == ">" then
                self:advance()
                if self:match("=") then  self:emit(">>=", nil, line, col)
                else                     self:emit(">>",  nil, line, col) end
            elseif self:match("=") then  self:emit(">=",  nil, line, col)
            else                         self:emit(">",   nil, line, col) end

        elseif c == "=" then
            self:advance()
            if self:match("=") then self:emit("==", nil, line, col)
            else                     self:emit("=",  nil, line, col) end

        elseif c == "(" then self:advance(); self:emit("(", nil, line, col)
        elseif c == ")" then self:advance(); self:emit(")", nil, line, col)
        elseif c == "]" then self:advance(); self:emit("]", nil, line, col)
        elseif c == "{" then self:advance(); self:emit("{", nil, line, col)
        elseif c == "}" then self:advance(); self:emit("}", nil, line, col)
        elseif c == "," then self:advance(); self:emit(",", nil, line, col)
        elseif c == ";" then self:advance(); self:emit(";", nil, line, col)
        elseif c == "?" then self:advance(); self:emit("?", nil, line, col)
        elseif c == "@" then self:advance(); self:emit("@", nil, line, col)

        elseif c == ":" then
            self:advance()
            if self:match(":") then self:emit("::", nil, line, col)
            else                     self:emit(":",  nil, line, col) end

        elseif c == "." then
            self:advance()
            if self:cur() == "." then
                self:advance()
                if self:cur() == "." then
                    self:advance()
                    self:emit("...", nil, line, col)
                elseif self:match("=") then
                    self:emit("..=", nil, line, col)
                else
                    self:emit("..", nil, line, col)
                end
            elseif string.match(self:cur(), "%d") then
                -- Number starting with .  (e.g. .5)
                -- Back up one and re-read as number
                self.pos = self.pos - 1
                self:readNumber(line, col)
            else
                self:emit(".", nil, line, col)
            end

        else
            self:error(string.format("unexpected character '%s'", c))
        end
    end

    return self.tokens
end

-- ─── Public interface ────────────────────────────────────────────────

local LexerModule = {}

-- Tokenise `source` and return the token list.
-- Throws a LexerError (via error()) on invalid input.
function LexerModule.tokenize(source, sourceName)
    local lex = Lexer.new(source, sourceName)
    return lex:tokenize()
end

-- Expose token-type constants so the parser can reference them.
LexerModule.TT = TT

return LexerModule
