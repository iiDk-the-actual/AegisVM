--[[
    LuaC.luau - Stack-based LuaC instruction interpreter for AegisVM

    Executes a text-based stack machine format that mirrors the Lua C API
    (lua_getglobal, lua_getfield, lua_setfield, lua_pcall, etc.).

    All global access goes through the AegisVM sandbox scope, so the same
    security constraints that apply to Aegis.run() apply here.

    ── Instruction set ───────────────────────────────────────────────────

    Stack operands:
        Positive indices are 1-based from the bottom of the stack.
        Negative indices are relative from the top: -1 = top, -2 = second.

    getglobal <name>
        Push the value of sandbox global <name>.

    getfield <idx> <name>
        Read field <name> from the value at stack position <idx>, push result.
        Does NOT remove the value at <idx>.

    setfield <idx> <name>
        Pop the top value and assign it as field <name> on the value at <idx>.
        The index is resolved before the pop.

    pushstring <str>
        Push the remainder of the line as a string literal.

    pushnumber <n>
        Push the numeric literal <n>.

    pushboolean <0|1|false|true>
        Push a boolean.

    pushnil
        Push nil.

    pushvalue <idx>
        Push a copy of the value at stack position <idx>.

    pcall <nargs> <nresults> <_>
        The function must be at stack position -(nargs+1) with the args above
        it. Pops the function and all nargs args, calls the function, and
        pushes exactly <nresults> return values (padded with nil as needed).
        Errors are silently discarded. The third field is unused (error
        handler index in Lua C API; always pass 0).

    emptystack
        Discard all values from the stack.

    settop <n>
        Truncate the stack to <n> entries. settop 0 is equivalent to
        emptystack.

    getservice <name>
        Shorthand for game:GetService(<name>). Pushes the service instance.

    loop <n>
        Begin a block that repeats <n> times. If <n> <= 0, skip to the
        matching loopend.

    loopend
        End of a loop block. Jump back to the start of the loop body if more
        iterations remain, otherwise fall through.

    wait <n>
        Yield for <n> seconds via task.wait. Useful inside loop bodies.

    ──────────────────────────────────────────────────────────────────────
]]

-- Sentinel stored on the stack instead of nil, because table slots cannot
-- hold nil without losing their position.
local NIL = {}

local function toStackVal(v)
    if v == nil then return NIL end
    return v
end

local function fromStackVal(v)
    if v == NIL then return nil end
    return v
end

-- Resolve a Lua-C-API-style stack index to a 1-based position.
local function resolveIdx(stack, idx)
    if idx < 0 then
        return #stack + idx + 1
    end
    return idx
end

-- Split source into non-empty, trimmed instruction lines.
local function parseLines(source)
    local lines = {}
    local i = 1
    local len = #source
    while i <= len do
        local j = source:find("\n", i, true)
        local raw
        if j then
            raw = source:sub(i, j - 1)
            i = j + 1
        else
            raw = source:sub(i)
            i = len + 1
        end
        -- strip CR and surrounding whitespace
        raw = raw:gsub("\r", ""):match("^%s*(.-)%s*$")
        if raw ~= "" then
            table.insert(lines, raw)
        end
    end
    return lines
end

-- Pre-scan to map each loop instruction index to its matching loopend index.
local function buildLoopMap(instructions)
    local loopEnds = {}
    local openStack = {}
    for i = 1, #instructions do
        local op = instructions[i]:match("^(%S+)")
        if op == "loop" then
            table.insert(openStack, i)
        elseif op == "loopend" and #openStack > 0 then
            loopEnds[table.remove(openStack)] = i
        end
    end
    return loopEnds
end

local function execute(instructions, sandbox)
    local loopEnds = buildLoopMap(instructions)
    local stack    = {}
    local loopStk  = {}  -- stack of { startPc, remaining }
    local pc       = 1

    -- push / pop helpers
    local function push(v) table.insert(stack, toStackVal(v)) end
    local function pop()   return fromStackVal(table.remove(stack)) end
    local function peek(idx)
        local pos = resolveIdx(stack, idx)
        return fromStackVal(stack[pos])
    end

    local function getGlobal(name)
        return sandbox.scope:get(name)
    end

    while pc <= #instructions do
        local line     = instructions[pc]
        local op, rest = line:match("^(%S+)%s*(.*)")
        local jumped   = false

        if op == "getglobal" then
            push(getGlobal(rest))

        elseif op == "getfield" then
            local idxStr, name = rest:match("^(-?%d+)%s+(.+)")
            if idxStr then
                local tbl = peek(tonumber(idxStr))
                local val = nil
                if tbl ~= nil then
                    pcall(function() val = tbl[name] end)
                end
                push(val)
            end

        elseif op == "setfield" then
            local idxStr, name = rest:match("^(-?%d+)%s+(.+)")
            if idxStr then
                -- Resolve the table reference BEFORE popping the value so that
                -- the index is computed against the full stack.
                local pos = resolveIdx(stack, tonumber(idxStr))
                local tbl = fromStackVal(stack[pos])
                local val = pop()
                if tbl ~= nil then
                    pcall(function() tbl[name] = val end)
                end
            end

        elseif op == "pushstring" then
            push(rest)

        elseif op == "pushnumber" then
            push(tonumber(rest))

        elseif op == "pushboolean" then
            local n = tonumber(rest)
            if n ~= nil then
                push(n ~= 0)
            else
                push(rest == "true")
            end

        elseif op == "pushnil" then
            push(nil)

        elseif op == "pushvalue" then
            local idx = tonumber(rest)
            if idx then push(peek(idx)) end

        elseif op == "pcall" then
            local nargs_s, nresults_s = rest:match("^(%d+)%s+(%d+)")
            local nargs    = tonumber(nargs_s)    or 0
            local nresults = tonumber(nresults_s) or 0

            local funcPos = #stack - nargs
            if funcPos >= 1 then
                local fn   = fromStackVal(stack[funcPos])
                local args = table.create(nargs)
                for i = 1, nargs do
                    args[i] = fromStackVal(stack[funcPos + i])
                end

                -- remove function + args
                for i = #stack, funcPos, -1 do
                    table.remove(stack, i)
                end

                if fn ~= nil then
                    if nresults == 0 then
                        pcall(fn, table.unpack(args, 1, nargs))
                    else
                        local rets = table.pack(pcall(fn, table.unpack(args, 1, nargs)))
                        if rets[1] then
                            local nret = rets.n - 1
                            for i = 1, nresults do
                                local v = if i <= nret then rets[i + 1] else nil
                                push(v)
                            end
                        end
                    end
                end
            end

        elseif op == "emptystack" then
            stack = {}

        elseif op == "settop" then
            local n = tonumber(rest) or 0
            if n <= 0 then
                stack = {}
            else
                while #stack > n do
                    table.remove(stack)
                end
            end

        elseif op == "getservice" then
            local gameObj = getGlobal("game")
            local svc     = nil
            if gameObj ~= nil then
                pcall(function() svc = gameObj:GetService(rest) end)
            end
            push(svc)

        elseif op == "loop" then
            local n = tonumber(rest) or 0
            if n <= 0 then
                local endPc = loopEnds[pc]
                pc     = endPc and (endPc + 1) or (pc + 1)
                jumped = true
            else
                table.insert(loopStk, { startPc = pc, remaining = n - 1 })
            end

        elseif op == "loopend" then
            if #loopStk > 0 then
                local frame = loopStk[#loopStk]
                if frame.remaining > 0 then
                    frame.remaining -= 1
                    pc     = frame.startPc + 1
                    jumped = true
                else
                    table.remove(loopStk)
                end
            end

        elseif op == "wait" then
            local n = tonumber(rest) or 0
            task.wait(n)

        end

        if not jumped then
            pc += 1
        end
    end
end

-- ── Public API ────────────────────────────────────────────────────────

local LuaC = {}

-- Execute a LuaC script in a FRESH sandbox.
-- Returns (true) on success or (false, errorMessage) on error.
function LuaC.run(source, sourceName, options)
    local Aegis        = require(script.Parent)
    local sandbox      = Aegis.newSandbox(options)
    local instructions = parseLines(source)
    local ok, err      = pcall(execute, instructions, sandbox)
    if not ok then
        return false, tostring(err)
    end
    return true
end

-- Execute a LuaC script in an EXISTING sandbox.
-- Returns (true) on success or (false, errorMessage) on error.
function LuaC.runIn(sandbox, source, sourceName)
    local instructions = parseLines(source)
    local ok, err      = pcall(execute, instructions, sandbox)
    if not ok then
        return false, tostring(err)
    end
    return true
end

return LuaC
