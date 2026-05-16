--[[
    Error.luau - Error types and control-flow signals

    The engine distinguishes between two classes of "thrown" values:

    1. Real errors (LexerError, ParserError, RuntimeError)
       These are error objects with category, message, line, column,
       and an optional stack trace.  They halt execution and surface
       to the caller of the sandbox.

    2. Control-flow signals (break, continue, return, goto)
       These are NOT errors; they are the mechanism by which Lua
       control-flow statements propagate through the interpreter's
       call stack.  They are thrown with error() and caught with
       pcall() at the appropriate boundary (loop body, function body,
       block).  They carry payload data when needed (return values,
       goto target label).

    No getfenv / setfenv / loadstring are used here or anywhere else
    in the engine.
]]

local Error = {}
Error.__index = Error

-- ─── Categories ────────────────────────────────────────────────────

Error.Category = {
    LEXER    = "LexerError",
    PARSER   = "ParserError",
    RUNTIME  = "RuntimeError",

    -- Internal signal tags (never shown to end-user as errors)
    BREAK    = "__break__",
    CONTINUE = "__continue__",
    RETURN   = "__return__",
    GOTO     = "__goto__",
}

-- Unique sentinels so no user value can be confused with a signal
local BREAK_SIG    = { __signal = Error.Category.BREAK }
local CONTINUE_SIG = { __signal = Error.Category.CONTINUE }

-- ─── Real-error constructors ────────────────────────────────────────

function Error.new(category, message, line, column)
    local self = setmetatable({}, Error)
    self.isError   = true
    self.category  = category
    self.message   = message  or "unknown error"
    self.line      = line     or 0
    self.column    = column   or 0
    self.stackTrace = {}
    return self
end

function Error:__tostring()
    local loc = ""
    if self.line > 0 then
        loc = string.format(":%d", self.line)
        if self.column > 0 then
            loc = loc .. string.format(":%d", self.column)
        end
    end
    return string.format("[%s%s] %s", self.category, loc, self.message)
end

function Error.lexer(msg, line, col)
    return Error.new(Error.Category.LEXER,   msg, line, col)
end

function Error.parser(msg, line, col)
    return Error.new(Error.Category.PARSER,  msg, line, col)
end

function Error.runtime(msg, line, col)
    return Error.new(Error.Category.RUNTIME, msg, line, col)
end

-- Push a frame string onto this error's stack trace
function Error:pushFrame(frame)
    table.insert(self.stackTrace, frame)
end

-- ─── Control-flow signal constructors ──────────────────────────────

function Error.breakSignal()
    return BREAK_SIG
end

function Error.continueSignal()
    return CONTINUE_SIG
end

-- values must be a sequential table {v1, v2, ...}; n = count of values
function Error.returnSignal(values, n)
    return { __signal = Error.Category.RETURN, values = values, n = n or #values }
end

function Error.gotoSignal(label)
    return { __signal = Error.Category.GOTO, label = label }
end

-- ─── Signal inspection ──────────────────────────────────────────────

function Error.isSignal(v)
    return type(v) == "table" and v.__signal ~= nil
end

function Error.isBreak(v)    return v == BREAK_SIG    end
function Error.isContinue(v) return v == CONTINUE_SIG end

function Error.isReturn(v)
    return type(v) == "table" and v.__signal == Error.Category.RETURN
end

function Error.isGoto(v)
    return type(v) == "table" and v.__signal == Error.Category.GOTO
end

-- ─── Formatting ─────────────────────────────────────────────────────

function Error.format(e)
    if type(e) == "string" then return e end
    local mt = getmetatable(e)
    if mt == Error then return tostring(e) end
    if Error.isSignal(e) then
        return string.format("[Signal:%s]", e.__signal)
    end
    return tostring(e)
end

return Error
