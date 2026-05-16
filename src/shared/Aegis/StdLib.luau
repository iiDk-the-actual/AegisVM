--[[
    StdLib.luau - Safe sandboxed standard library

    Populates the interpreter's global scope with a whitelisted subset of
    Luau's built-in library.

    Security model
    ──────────────
    • Only explicitly listed functions are exposed.
    • Environment-manipulation functions (getfenv, setfenv) are NOT included.
    • loadstring, load, dofile, collectgarbage, and debug.* ARE included
      (permitted by Roblox Creator Store asset policy).
    • Roblox services, game, workspace, script, etc. are NOT included by
      default.  The caller may inject additional globals after calling
      StdLib.populate(scope).
    • table.* and string.* are provided in full (safe subset).
    • math.* is provided in full.
    • io / os / file are excluded (not applicable to Roblox sandboxes).
    • pcall / xpcall / error / assert are provided with wrapping so that
      interpreter control-flow signals are not swallowed.

    Adding host globals
    ───────────────────
    After calling StdLib.populate(scope), call:
        scope:defineGlobal("MyService", myServiceTable)
    to inject additional host-side values.
]]

local Constants     = require(script.Parent.Constants)
local Error         = require(script.Parent.Error)
local Lexer         = require(script.Parent.Lexer)
local Parser        = require(script.Parent.Parser)
local Scope         = require(script.Parent.Scope)
local InsertService = require(script.Parent.WebRbxmParser)

local StdLib = {}

-- ─── Utility ─────────────────────────────────────────────────────────

-- Wrap a native multi-return function so it is callable from the interpreter.
-- (Native functions are already callable; this is just for documentation.)
local function native(fn)
    return fn
end

-- ─── Core globals ────────────────────────────────────────────────────

local function buildCore(scope, runtime)
    -- print
    scope:defineGlobal("print", native(function(...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[i] = tostring(select(i, ...))
        end
        print(table.concat(parts, "\t"))
    end))

    -- warn
    scope:defineGlobal("warn", native(function(...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[i] = tostring(select(i, ...))
        end
        warn(table.concat(parts, "\t"))
    end))

    -- tostring
    scope:defineGlobal("tostring", native(function(v)
        if type(v) == "table" then
            local mm = getmetatable(v)
            if mm then
                local ts = rawget(mm, "__tostring")
                if ts then
                    if type(ts) == "function" then
                        return tostring(ts(v))
                    end
                    -- Interpreter closure __tostring
                    if type(ts) == "table" and ts.__fn then
                        local result = runtime:callFunction(ts, { v })
                        return tostring(result)
                    end
                end
                local name = rawget(mm, "__name")
                if name then return string.format("%s: %p", name, v) end
            end
        end
        return tostring(v)
    end))

    -- tonumber
    scope:defineGlobal("tonumber", native(function(v, base)
        return tonumber(v, base)
    end))

    -- type
    scope:defineGlobal("type", native(function(v)
        return type(v)
    end))

    -- require
    scope:defineGlobal("require", native(function(v)
        return require(v)
    end))

    -- error - wraps message in a RuntimeError unless it's already a signal
    scope:defineGlobal("error", native(function(msg, level)
        if Error.isSignal(msg) then
            error(msg, 0)  -- pass-through control flow signals
        end
        -- Convert to RuntimeError so interpreter catches it correctly
        if type(msg) == "string" then
            error(Error.runtime(msg), 0)
        end
        error(msg, 0)
    end))

    -- assert
    scope:defineGlobal("assert", native(function(v, msg, ...)
        if v == nil or v == false then
            error(Error.runtime(
                type(msg) == "string" and msg or "assertion failed!"
            ), 0)
        end
        return v, msg, ...
    end))

    -- Helper: call fn (native or closure) and return packed results.
    -- Signals that escape the call are re-thrown upward.
    local function callGuest(fn, args)
        if type(fn) == "function" then
            return table.pack(fn(table.unpack(args, 1, #args)))
        elseif type(fn) == "table" and fn.__fn then
            local mr = runtime:callFunctionMulti(fn, args)
            local out = {}
            for i = 1, mr.n do out[i] = mr[i] end
            out.n = mr.n
            return out
        else
            error(Error.runtime("attempt to call a " .. type(fn) .. " value"), 0)
        end
    end

    -- pcall - must not swallow interpreter control-flow signals
    scope:defineGlobal("pcall", native(function(fn, ...)
        local args  = { ... }
        local rets  = table.pack(pcall(function()
            local r = callGuest(fn, args)
            return table.unpack(r, 1, r.n)
        end))
        -- rets[1] = ok/fail boolean; rest = return values or error object
        local ok = rets[1]
        if ok then
            return table.unpack(rets, 1, rets.n)  -- true, v1, v2, …
        end
        local sig = rets[2]
        -- Re-raise control-flow signals - guest pcall must NOT swallow them
        if Error.isBreak(sig) or Error.isContinue(sig)
            or Error.isReturn(sig) or Error.isGoto(sig) then
            error(sig, 0)
        end
        return false, Error.format(sig)
    end))

    -- xpcall
    scope:defineGlobal("xpcall", native(function(fn, handler, ...)
        local args  = { ... }
        local rets  = table.pack(pcall(function()
            local r = callGuest(fn, args)
            return table.unpack(r, 1, r.n)
        end))
        local ok  = rets[1]
        if ok then
            return table.unpack(rets, 1, rets.n)
        end
        local sig = rets[2]
        if Error.isBreak(sig) or Error.isContinue(sig)
            or Error.isReturn(sig) or Error.isGoto(sig) then
            error(sig, 0)
        end
        local msg = Error.format(sig)
        local handlerOk, handlerResult = pcall(function()
            if type(handler) == "function" then
                return handler(msg)
            elseif type(handler) == "table" and handler.__fn then
                return runtime:callFunction(handler, { msg })
            end
        end)
        if handlerOk then
            return false, handlerResult
        end
        return false, msg
    end))

    -- select
    scope:defineGlobal("select", native(function(index, ...)
        if index == "#" then
            return select("#", ...)
        end
        return select(index, ...)
    end))

    -- ipairs
    scope:defineGlobal("ipairs", native(ipairs))

    -- pairs - supports __pairs metamethod
    scope:defineGlobal("pairs", native(function(tbl)
        if type(tbl) == "table" then
            local mt = getmetatable(tbl)
            if mt then
                local mm = rawget(mt, "__pairs")
                if mm then return mm(tbl) end
            end
        end
        return next, tbl, nil
    end))

    -- next
    scope:defineGlobal("next", native(next))

    -- rawget / rawset / rawequal / rawlen
    scope:defineGlobal("rawget",    native(rawget))
    scope:defineGlobal("rawset",    native(rawset))
    scope:defineGlobal("rawequal",  native(rawequal))
    scope:defineGlobal("rawlen",    native(rawlen))

    -- unpack (Lua 5.1 compat; Luau uses table.unpack)
    scope:defineGlobal("unpack",    native(table.unpack))

    -- setmetatable / getmetatable
    scope:defineGlobal("setmetatable", native(setmetatable))
    scope:defineGlobal("getmetatable", native(getmetatable))

    -- typeof (Luau-specific; identical to type for plain values)
    scope:defineGlobal("typeof", native(function(v) return typeof and typeof(v) or type(v) end))

    -- _VERSION / _AEGIS_VERSION
    scope:defineGlobal("_VERSION",       "Luau")
    scope:defineGlobal("_AEGIS_VERSION", Constants.VERSION)

    -- loadstring - re-runs the interpreter on new source code.
    -- Returns a callable function on success, or (nil, errorMessage) on failure.
    -- The returned function executes in the sandbox's global scope when called.
    scope:defineGlobal("loadstring", native(function(source, chunkName)
        chunkName = chunkName or Constants.DEFAULT_CHUNK_NAME
        -- Tokenise
        local tokens
        local tokOk, tokErr = pcall(function()
            tokens = Lexer.tokenize(source, chunkName)
        end)
        if not tokOk then
            return nil, Error.format(tokErr)
        end
        -- Parse
        local ast
        local parseOk, parseErr = pcall(function()
            ast = Parser.parse(tokens, chunkName)
        end)
        if not parseOk then
            return nil, Error.format(parseErr)
        end
        -- Return a chunk function; each call gets its own child scope for locals
        return function(...)
            local callArgs = { ... }
            local callN = select("#", ...)
            local chunkScope = Scope.new(scope)
            -- Expose varargs as a local in the chunk scope (standard Lua behaviour)
            chunkScope:declareLocal("arg", callArgs)
            chunkScope:declareLocal("...", { values = callArgs, n = callN })
            local execOk, sig = pcall(function()
                runtime:execBlock(ast, chunkScope)
            end)
            if execOk then
                return  -- chunk returned nothing
            end
            if Error.isReturn(sig) then
                return table.unpack(sig.values, 1, sig.values.n)
            end
            error(sig, 0)   -- propagate runtime errors / other signals
        end
    end))

    -- load(chunk [, chunkname [, mode [, env]]])
    -- Generalized version of loadstring.  chunk may be a string or a
    -- callable that returns successive string pieces (nil/"" to finish).
    -- mode and env are accepted for API compatibility but ignored:
    -- AegisVM only processes text chunks and runs in the sandbox scope.
    scope:defineGlobal("load", native(function(chunk, chunkName, mode, env)
        chunkName = chunkName or "=(" .. Constants.INTERPRETER_NAME .. ")"
        local source
        if type(chunk) == "string" then
            source = chunk
        elseif type(chunk) == "function" or (type(chunk) == "table" and chunk.__fn) then
            local pieces = {}
            while true do
                local piece
                local ok, err = pcall(function()
                    if type(chunk) == "function" then
                        piece = chunk()
                    else
                        piece = runtime:callFunction(chunk, {})
                    end
                end)
                if not ok then return nil, Error.format(err) end
                if piece == nil or piece == "" then break end
                if type(piece) ~= "string" then
                    return nil, "reader function must return a string"
                end
                pieces[#pieces + 1] = piece
            end
            source = table.concat(pieces)
        else
            return nil, "bad argument #1 to 'load' (string or function expected, got "
                .. type(chunk) .. ")"
        end
        -- Tokenise
        local tokens
        local tokOk, tokErr = pcall(function()
            tokens = Lexer.tokenize(source, chunkName)
        end)
        if not tokOk then return nil, Error.format(tokErr) end
        -- Parse
        local ast
        local parseOk, parseErr = pcall(function()
            ast = Parser.parse(tokens, chunkName)
        end)
        if not parseOk then return nil, Error.format(parseErr) end
        -- Return the chunk function
        return function(...)
            local callArgs = { ... }
            local callN = select("#", ...)
            local chunkScope = Scope.new(scope)
            chunkScope:declareLocal("arg", callArgs)
            chunkScope:declareLocal("...", { values = callArgs, n = callN })
            local execOk, sig = pcall(function()
                runtime:execBlock(ast, chunkScope)
            end)
            if execOk then return end
            if Error.isReturn(sig) then
                return table.unpack(sig.values, 1, sig.values.n)
            end
            error(sig, 0)
        end
    end))

    -- dofile(filename)
    -- Standard Lua: load and execute a file from disk.  Roblox has no
    -- filesystem, so this always raises an error.
    scope:defineGlobal("dofile", native(function(filename)
        error(Error.runtime("dofile is not supported: no filesystem access in Roblox"), 0)
    end))

    -- collectgarbage(opt [, arg])
    -- Delegates to the host collectgarbage where the option is safe to
    -- forward.  Returns 0/true for options the host does not expose.
    scope:defineGlobal("collectgarbage", native(function(opt, arg)
        opt = opt or "collect"
        if opt == "count" then
            if collectgarbage then
                local ok, kb, frac = pcall(collectgarbage, "count")
                if ok then return kb, frac or 0 end
            end
            return 0, 0
        elseif opt == "collect" or opt == "step" then
            if collectgarbage then pcall(collectgarbage, opt, arg) end
            return 0
        elseif opt == "stop" or opt == "restart"
            or opt == "incremental" or opt == "generational" then
            if collectgarbage then pcall(collectgarbage, opt, arg) end
            return 0
        elseif opt == "setpause" or opt == "setstepmul" then
            if collectgarbage then
                local ok, prev = pcall(collectgarbage, opt, arg)
                if ok then return prev end
            end
            return 0
        elseif opt == "isrunning" then
            if collectgarbage then
                local ok, v = pcall(collectgarbage, "isrunning")
                if ok then return v end
            end
            return true
        end
        return 0
    end))
end

-- ─── string library ──────────────────────────────────────────────────

local function buildString(scope)
    local lib = {
        byte    = string.byte,
        char    = string.char,
        find    = string.find,
        format  = string.format,
        gmatch  = string.gmatch,
        gsub    = string.gsub,
        len     = string.len,
        lower   = string.lower,
        match   = string.match,
        rep     = string.rep,
        reverse = string.reverse,
        sub     = string.sub,
        upper   = string.upper,
        split   = function(s, sep)
            local result = {}
            local pattern = "([^" .. (sep or "%s") .. "]*)"
            for chunk in string.gmatch(s, pattern) do
                result[#result + 1] = chunk
            end
            return result
        end,
    }
    scope:defineGlobal("string", lib)
    -- Note: Roblox locks the string metatable, so we cannot set __index on it.
    -- String method calls like ("hello"):upper() are handled in Runtime:tableGet,
    -- which falls back to the "string" global when indexing a string value.
end

-- ─── table library ───────────────────────────────────────────────────

local function buildTable(scope)
    local lib = {
        insert  = table.insert,
        remove  = table.remove,
        concat  = table.concat,
        sort    = table.sort,
        unpack  = table.unpack,
        pack    = table.pack,
        move    = table.move,
        find    = table.find,   -- Luau extension
        create  = table.create, -- Luau extension
        clear   = table.clear,  -- Luau extension
        clone   = function(t)   -- shallow clone
            local out = {}
            for k, v in pairs(t) do out[k] = v end
            return out
        end,
        getn   = function(t) return #t end,  -- Lua 5.1 compat
        maxn   = function(t)
            local max = 0
            for k in pairs(t) do
                if type(k) == "number" and k > max then max = k end
            end
            return max
        end,
    }
    scope:defineGlobal("table", lib)
end

-- ─── math library ────────────────────────────────────────────────────

local function buildMath(scope)
    local lib = {
        abs   = math.abs,   acos  = math.acos,  asin  = math.asin,
        atan  = math.atan,  ceil  = math.ceil,   cos   = math.cos,
        cosh  = math.cosh,  deg   = math.deg,    exp   = math.exp,
        floor = math.floor, fmod  = math.fmod,   huge  = math.huge,
        log   = math.log,   max   = math.max,    min   = math.min,
        modf  = math.modf,  pi    = math.pi,     pow   = function(a,b) return a^b end,
        rad   = math.rad,   random = math.random, randomseed = math.randomseed,
        sin   = math.sin,   sinh  = math.sinh,   sqrt  = math.sqrt,
        tan   = math.tan,   tanh  = math.tanh,
        -- Luau extras
        sign  = math.sign or function(n) return n > 0 and 1 or (n < 0 and -1 or 0) end,
        clamp = math.clamp or function(n, lo, hi) return math.max(lo, math.min(hi, n)) end,
        round = math.round or function(n) return math.floor(n + 0.5) end,
        tointeger = math.tointeger,
        type      = math.type,
        maxinteger = math.maxinteger,
        mininteger = math.mininteger,
    }
    scope:defineGlobal("math", lib)
end

-- ─── bit32 library ───────────────────────────────────────────────────

local function buildBit32(scope)
    if not bit32 then return end
    scope:defineGlobal("bit32", {
        arshift  = bit32.arshift,
        band     = bit32.band,
        bnot     = bit32.bnot,
        bor      = bit32.bor,
        btest    = bit32.btest,
        bxor     = bit32.bxor,
        extract  = bit32.extract,
        lrotate  = bit32.lrotate,
        lshift   = bit32.lshift,
        replace  = bit32.replace,
        rrotate  = bit32.rrotate,
        rshift   = bit32.rshift,
    })
end

-- ─── utf8 library ────────────────────────────────────────────────────

local function buildUtf8(scope)
    if not utf8 then return end
    scope:defineGlobal("utf8", {
        char      = utf8.char,
        charpattern = utf8.charpattern,
        codepoint = utf8.codepoint,
        codes     = utf8.codes,
        len       = utf8.len,
        offset    = utf8.offset,
        nfcnormalize  = utf8.nfcnormalize,
        nfdnormalize  = utf8.nfdnormalize,
        graphemes = utf8.graphemes,
    })
end

-- ─── coroutine library ───────────────────────────────────────────────

local function buildCoroutine(scope)
    scope:defineGlobal("coroutine", {
        create  = coroutine.create,
        resume  = coroutine.resume,
        yield   = coroutine.yield,
        status  = coroutine.status,
        wrap    = coroutine.wrap,
        running = coroutine.running,
        isyieldable = coroutine.isyieldable,
        close   = coroutine.close,
    })
end

-- ─── task library (Roblox) ───────────────────────────────────────────

local function buildTask(scope)
    if not task then return end
    scope:defineGlobal("task", {
        spawn   = task.spawn,
        defer   = task.defer,
        delay   = task.delay,
        wait    = task.wait,
        cancel  = task.cancel,
    })
end

-- ─── debug library ───────────────────────────────────────────────────

local function buildDebug(scope)
    local lib = {}

    if debug then
        -- traceback(msg?, level?) - human-readable stack trace string
        if debug.traceback then
            lib.traceback = debug.traceback
        end

        -- info(level|thread|func, options) - Roblox variant of getinfo
        -- Returns a string formatted according to the options character string.
        if debug.info then
            lib.info = debug.info
        end

        -- getinfo - standard Lua getinfo; may not exist in all Roblox builds,
        -- but expose it when present.
        if debug.getinfo then
            lib.getinfo = debug.getinfo
        end

        -- getmetatable / setmetatable bypass the __metatable protection field
        if debug.getmetatable then
            lib.getmetatable = debug.getmetatable
        end
        if debug.setmetatable then
            lib.setmetatable = debug.setmetatable
        end

        -- upvalue access
        if debug.getupvalue  then lib.getupvalue  = debug.getupvalue  end
        if debug.setupvalue  then lib.setupvalue  = debug.setupvalue  end

        -- local variable access (level-based; subject to Roblox availability)
        if debug.getlocal    then lib.getlocal    = debug.getlocal    end
        if debug.setlocal    then lib.setlocal    = debug.setlocal    end

        -- hook API (may be restricted or absent in Roblox)
        if debug.sethook     then lib.sethook     = debug.sethook     end
        if debug.getfenv     then lib.getfenv     = debug.getfenv     end
        if debug.setfenv     then lib.setfenv     = debug.setfenv     end

        -- Roblox-specific profiling markers
        if debug.profilebegin then lib.profilebegin = debug.profilebegin end
        if debug.profileend   then lib.profileend   = debug.profileend   end

        -- Roblox resettelemetry / dumpcounters (Studio only, safe to include)
        if debug.resetmemorycategory   then
            lib.resetmemorycategory   = debug.resetmemorycategory
        end
        if debug.setmemorycategory     then
            lib.setmemorycategory     = debug.setmemorycategory
        end
    end

    scope:defineGlobal("debug", lib)
end

-- ─── _G (the guest global table) ────────────────────────────────────

local function buildGlobalTable(scope)
    local G = {}
    scope:defineGlobal("_G", G)
end

-- ─── Roblox globals ──────────────────────────────────────────────────

-- Safely read a host global that may or may not exist in this context.
local function hostGlobal(name)
    -- In Roblox Luau, globals not present in the environment return nil.
    -- We use a pcall so that any access error (e.g. restricted API) is silent.
    local ok, v = pcall(function()
        return _G[name]
    end)
    return ok and v or nil
end

local function buildRoblox(scope)
    -- ── Core game objects ────────────────────────────────────────────
    -- `game` is a proxy over the real DataModel that intercepts a handful of
    -- legacy / convenience methods while passing everything else through.
    -- `workspace` is the one true lowercase service alias Roblox always exposes.
    local realGame = game
    local gameProxy
    gameProxy = setmetatable({}, {
        __index = function(_, key)
            -- ── Intercepted methods ──────────────────────────────────────
            if key == "HttpGet" or key == "HttpGetAsync" then
                -- game:HttpGet(url [, noCache])  ->  HttpService:GetAsync(url [, noCache])
                return function(_, url, noCache)
                    local hs = realGame:GetService("HttpService")
                    return hs:GetAsync(url, noCache)
                end
            elseif key == "GetObjects" then
                -- game:GetObjects(url)  ->  WebRbxmParser module
                return function(_, url)
                    return InsertService:GetObjects(url)
                end
            end
            -- ── Pass-through ─────────────────────────────────────────────
            -- Properties return directly; methods are bound to realGame so
            -- that Roblox receives the correct 'self' (an Instance, not a table).
            local val = realGame[key]
            if type(val) == "function" then
                return function(selfArg, ...)
                    -- When called as gameProxy:method(...) selfArg is gameProxy;
                    -- transparently substitute realGame so Roblox accepts it.
                    if selfArg == gameProxy then selfArg = realGame end
                    return val(selfArg, ...)
                end
            end
            return val
        end,
        __newindex = function(_, key, value)
            realGame[key] = value
        end,
        __tostring = function()
            return tostring(realGame)
        end,
        __eq = function(_, other)
            return other == realGame or other == gameProxy
        end,
    })
    scope:defineGlobal("game",      gameProxy)
    scope:defineGlobal("workspace", workspace)
    scope:defineGlobal("Enum",      Enum)
    scope:defineGlobal("Instance",  Instance)
    scope:defineGlobal("shared",    shared)
    -- `script` is intentionally nil by default so guest code cannot accidentally
    -- reference the host ModuleScript.  Callers may inject it:
    --   sandbox.scope:defineGlobal("script", myScriptInstance)
    scope:defineGlobal("script", nil)

    -- ── Value-type constructors ───────────────────────────────────────
    scope:defineGlobal("Vector3",                 Vector3)
    scope:defineGlobal("Vector2",                 Vector2)
    scope:defineGlobal("Vector3int16",            hostGlobal("Vector3int16"))
    scope:defineGlobal("Vector2int16",            hostGlobal("Vector2int16"))
    scope:defineGlobal("CFrame",                  CFrame)
    scope:defineGlobal("Color3",                  Color3)
    scope:defineGlobal("BrickColor",              BrickColor)
    scope:defineGlobal("UDim",                    UDim)
    scope:defineGlobal("UDim2",                   UDim2)
    scope:defineGlobal("Ray",                     Ray)
    scope:defineGlobal("Region3",                 Region3)
    scope:defineGlobal("Region3int16",            hostGlobal("Region3int16"))
    scope:defineGlobal("NumberRange",             NumberRange)
    scope:defineGlobal("NumberSequence",          NumberSequence)
    scope:defineGlobal("NumberSequenceKeypoint",  NumberSequenceKeypoint)
    scope:defineGlobal("ColorSequence",           ColorSequence)
    scope:defineGlobal("ColorSequenceKeypoint",   ColorSequenceKeypoint)
    scope:defineGlobal("TweenInfo",               TweenInfo)
    scope:defineGlobal("Rect",                    Rect)
    scope:defineGlobal("PhysicalProperties",      PhysicalProperties)
    scope:defineGlobal("Axes",                    hostGlobal("Axes"))
    scope:defineGlobal("Faces",                   hostGlobal("Faces"))
    scope:defineGlobal("Font",                    hostGlobal("Font"))
    scope:defineGlobal("RaycastParams",           RaycastParams)
    scope:defineGlobal("OverlapParams",           hostGlobal("OverlapParams"))
    scope:defineGlobal("Random",                  Random)

    -- ── Time / scheduling ────────────────────────────────────────────
    scope:defineGlobal("tick",        tick)
    scope:defineGlobal("time",        time)
    scope:defineGlobal("elapsedTime", elapsedTime)
    scope:defineGlobal("os", {
        time     = os.time,
        clock    = os.clock,
        date     = os.date,
        difftime = os.difftime,
    })

    -- Deprecated global schedulers (still very common in the wild)
    scope:defineGlobal("wait",  wait)
    scope:defineGlobal("spawn", spawn)
    scope:defineGlobal("delay", delay)

    -- ── Roblox helpers ───────────────────────────────────────────────
    scope:defineGlobal("typeof",        typeof)
    scope:defineGlobal("printidentity", printidentity)

    -- Plugin context (only non-nil when running inside a Studio plugin)
    local plug = hostGlobal("plugin")
    if plug then scope:defineGlobal("plugin", plug) end
end

-- ─── Populate ────────────────────────────────────────────────────────

function StdLib.populate(scope, runtime)
    buildCore(scope, runtime)
    buildString(scope)
    buildTable(scope)
    buildMath(scope)
    buildBit32(scope)
    buildUtf8(scope)
    buildCoroutine(scope)
    buildTask(scope)
    buildDebug(scope)
    buildRoblox(scope)
    buildGlobalTable(scope)
end

return StdLib
