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
        matching loopend. Not meaningful in cursor mode.

    loopend
        End of a loop block. Jump back to the start of the loop body if more
        iterations remain, otherwise fall through. Not meaningful in cursor mode.

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

-- ── Shared instruction dispatcher ────────────────────────────────────────
--
-- Executes one instruction against the given mutable stack.
--
-- stack   : the mutable stack array (modified in place - never reassigned)
-- op/rest : parsed opcode and operand string
-- runtime : sandbox.runtime  (for tableGet / tableSet)
-- sandbox : the sandbox object (for scope:get)
-- pcCtx   : { pc, loopEnds, loopStk } present in execute(), nil in cursor()
--           When nil, loop/loopend are treated as no-ops.
--
-- Returns true if pcCtx.pc was changed (a loop jump occurred).

local function dispatchOp(op, rest, stack, runtime, sandbox, pcCtx)
    local function push(v) table.insert(stack, toStackVal(v)) end
    local function pop()   return fromStackVal(table.remove(stack)) end
    local function peek(idx)
        return fromStackVal(stack[resolveIdx(stack, idx)])
    end

    if op == "getglobal" then
        push(sandbox.scope:get(rest))

    elseif op == "getfield" then
        local idxStr, name = rest:match("^(-?%d+)%s+(.+)")
        if idxStr then
            local tbl = peek(tonumber(idxStr))
            local val = nil
            if tbl ~= nil then
                pcall(function() val = runtime:tableGet(tbl, name, nil) end)
            end
            push(val)
        end

    elseif op == "setfield" then
        local idxStr, name = rest:match("^(-?%d+)%s+(.+)")
        if idxStr then
            -- Resolve the table reference BEFORE popping the value.
            local pos = resolveIdx(stack, tonumber(idxStr))
            local tbl = fromStackVal(stack[pos])
            local val = pop()
            if tbl ~= nil then
                pcall(function() runtime:tableSet(tbl, name, val, nil) end)
            end
        end

    elseif op == "pushstring" then
        push(rest)

    elseif op == "pushnumber" then
        push(tonumber(rest))

    elseif op == "pushboolean" then
        local n = tonumber(rest)
        push(if n ~= nil then n ~= 0 else rest == "true")

    elseif op == "pushnil" then
        push(nil)

    elseif op == "pushvalue" then
        local idx = tonumber(rest)
        if idx then push(peek(idx)) end

    elseif op == "pcall" then
        local nargs_s, nresults_s = rest:match("^(%d+)%s+(%d+)")
        local nargs    = tonumber(nargs_s)    or 0
        local nresults = tonumber(nresults_s) or 0
        local funcPos  = #stack - nargs
        if funcPos >= 1 then
            local fn   = fromStackVal(stack[funcPos])
            local args = table.create(nargs)
            for i = 1, nargs do
                args[i] = fromStackVal(stack[funcPos + i])
            end
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
                            push(if i <= nret then rets[i + 1] else nil)
                        end
                    end
                end
            end
        end

    elseif op == "emptystack" then
        -- table.clear modifies the existing table in place so that cursor
        -- closures holding a reference to the same stack see the cleared state.
        table.clear(stack)

    elseif op == "settop" then
        local n = tonumber(rest) or 0
        if n <= 0 then
            table.clear(stack)
        else
            while #stack > n do
                table.remove(stack)
            end
        end

    elseif op == "getservice" then
        local gameObj = sandbox.scope:get("game")
        local svc     = nil
        if gameObj ~= nil then
            pcall(function() svc = gameObj:GetService(rest) end)
        end
        push(svc)

    elseif op == "wait" then
        task.wait(tonumber(rest) or 0)

    elseif op == "loop" and pcCtx then
        local n = tonumber(rest) or 0
        if n <= 0 then
            local endPc = pcCtx.loopEnds[pcCtx.pc]
            pcCtx.pc = endPc and (endPc + 1) or (pcCtx.pc + 1)
            return true
        else
            table.insert(pcCtx.loopStk, { startPc = pcCtx.pc, remaining = n - 1 })
        end

    elseif op == "loopend" and pcCtx then
        if #pcCtx.loopStk > 0 then
            local frame = pcCtx.loopStk[#pcCtx.loopStk]
            if frame.remaining > 0 then
                frame.remaining -= 1
                pcCtx.pc = frame.startPc + 1
                return true
            else
                table.remove(pcCtx.loopStk)
            end
        end

    end

    return false
end

-- ── Batch execution (run / runIn) ────────────────────────────────────────

local function execute(instructions, sandbox)
    local runtime = sandbox.runtime
    local stack   = {}
    local pcCtx   = {
        pc       = 1,
        loopEnds = buildLoopMap(instructions),
        loopStk  = {},
    }

    while pcCtx.pc <= #instructions do
        local line     = instructions[pcCtx.pc]
        local op, rest = line:match("^(%S+)%s*(.*)")
        local jumped   = dispatchOp(op, rest, stack, runtime, sandbox, pcCtx)
        if not jumped then
            pcCtx.pc += 1
        end
    end
end

-- ── Public API ────────────────────────────────────────────────────────────

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

-- Returns a single-instruction executor bound to a persistent stack.
-- The returned function accepts one instruction string per call and
-- executes it immediately; the stack survives across calls.
--
-- Usage:
--   local luac = Aegis.LuaC.cursor(sandbox)
--   luac'getglobal game'
--   luac'getfield -1 Workspace'
--   luac'getglobal Instance'
--   luac'getfield -1 new'
--   luac'pushstring Part'
--   luac'pushvalue -4'
--   luac'pcall 2 1 0'
--   luac'emptystack'
--
-- loop / loopend are not meaningful in cursor mode and are silently ignored.
-- Inject the returned function as a sandbox global to use it from guest code:
--   sandbox.scope:defineGlobal("luac", Aegis.LuaC.cursor(sandbox))
function LuaC.cursor(sandbox)
    local runtime = sandbox.runtime
    local stack   = {}

    return function(instruction)
        local line = tostring(instruction or ""):gsub("\r", ""):match("^%s*(.-)%s*$")
        if line == "" then return end
        local op, rest = line:match("^(%S+)%s*(.*)")
        if op then
            pcall(dispatchOp, op, rest, stack, runtime, sandbox, nil)
        end
    end
end

return LuaC
