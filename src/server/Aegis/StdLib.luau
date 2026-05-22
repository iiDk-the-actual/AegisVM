--[[
    StdLib.luau - Safe sandboxed standard library

    Populates the interpreter's global scope with a whitelisted subset of
    Luau's built-in library.

    Security model
    ──────────────
    • Only explicitly listed functions are exposed.
    • getfenv / setfenv are included as sandbox-safe proxies: they operate on
      the AegisVM scope chain and never expose the host Lua environment.
    • io / file are excluded (not applicable to Roblox sandboxes).
      os is included in part: time, clock, date, difftime.
    • loadstring, load, dofile, collectgarbage, and debug.* ARE included
      (permitted by Roblox Creator Store asset policy).
    • Roblox services, game, workspace, script, etc. are NOT included by
      default.  The caller may inject additional globals after calling
      StdLib.populate(scope).
    • table.* and string.* are provided in full (safe subset).
    • math.* is provided in full.
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
local TextFilter    = require(script.Parent.TextFilter)
local InsertService = require(script.Parent.Libraries.WebRbxmParser)
local ClientComm    = require(script.Parent.Libraries.ClientComm)

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
        if Constants.VERBOSITY <= Constants.VERBOSITY_SUPPRESS then return end
        local parts = {}
        for i = 1, select("#", ...) do
            parts[i] = tostring(select(i, ...))
        end
        local text = table.concat(parts, "\t")
        if Constants.FILTER_TEXT and Constants.FILTER_OUTPUT then
            if Constants.FILTER_ASYNC then
                task.spawn(function()
                    print(TextFilter.filterString(text, 0))
                end)
            else
                print(TextFilter.filterString(text, 0))
            end
        else
            print(text)
        end
    end))

    -- warn
    scope:defineGlobal("warn", native(function(...)
        if Constants.VERBOSITY <= Constants.VERBOSITY_SUPPRESS then return end
        local parts = {}
        for i = 1, select("#", ...) do
            parts[i] = tostring(select(i, ...))
        end
        local text = table.concat(parts, "\t")
        if Constants.FILTER_TEXT and Constants.FILTER_OUTPUT then
            if Constants.FILTER_ASYNC then
                task.spawn(function()
                    warn(TextFilter.filterString(text, 0))
                end)
            else
                warn(TextFilter.filterString(text, 0))
            end
        else
            warn(text)
        end
    end))

    -- tostring
    scope:defineGlobal("tostring", native(function(v)
        if type(v) == "table" then
            -- Metatable __tostring takes priority over everything, including
            -- closures - so that guest code can give closures custom names.
            local mm = getmetatable(v)
            if mm then
                local ts = rawget(mm, "__tostring")
                if ts then
                    if type(ts) == "function" then
                        return tostring(ts(v))
                    end
                    -- Interpreter closure __tostring
                    if type(ts) == "table" and rawget(ts, "__fn") then
                        local result = runtime:callFunction(ts, { v })
                        return tostring(result)
                    end
                end
                local name = rawget(mm, "__name")
                if name then return string.format("%s: %p", name, v) end
            end
            -- Interpreter closures are plain tables with no metatable;
            -- present them as "function: <addr>" rather than "table: <addr>".
            if rawget(v, "__fn") then
                return (tostring(v):gsub("^table: ", "function: "))
            end
        end
        return tostring(v)
    end))

    -- tonumber
    scope:defineGlobal("tonumber", native(function(v, base)
        return tonumber(v, base)
    end))

    -- type (#6: closures are tables internally; report them as "function")
    scope:defineGlobal("type", native(function(v)
        if type(v) == "table" and rawget(v, "__fn") then return "function" end
        return type(v)
    end))

    -- require
    -- ModuleScript instances are executed through the AegisVM pipeline so that
    -- guest code, metatables, and closures all work correctly. Results are cached
    -- by instance identity (matching Roblox's single-evaluation guarantee).
    --
    -- When REQUIRE_FETCH_NUMERIC is enabled:
    --   require(number)  - fetches via InsertService:LoadAsset, finds MainModule,
    --                      then falls back through this function recursively.
    --   require(string)  - http(s):// URLs fetched via InsertService:GetObjects.
    -- A verbosity-dependent message is printed before any network fetch.
    local moduleCache = {}  -- [instance] = cached return value

    local function requireFetchLog(label)
        if Constants.VERBOSITY <= Constants.VERBOSITY_SUPPRESS then return end
        local co = coroutine.running() or "main"
        local stack = runtime.callStacks[co] or {}
        local msg = "Requiring asset " .. label .. "."
        if Constants.VERBOSITY >= Constants.VERBOSITY_STANDARD and #stack > 0 then
            local parts = { msg, "Callstack:" }
            for i = #stack, 1, -1 do
                local frame = stack[i]
                local entry = frame.chunkName .. ", line " .. frame.line
                if frame.fnName then
                    entry = entry .. " - " .. frame.fnName
                end
                parts[#parts + 1] = entry
            end
            warn(table.concat(parts, "\n"))
        else
            warn(msg)
        end
    end

    -- Check if v is a Roblox ModuleScript instance.
    -- Uses .ClassName (a plain property) instead of :IsA() to avoid method-call
    -- security restrictions in some Roblox contexts.
    local function isModuleScript(v)
        if type(v) ~= "userdata" then return false end
        local ok, cls = pcall(function() return v.ClassName end)
        return ok and cls == "ModuleScript"
    end

    -- Run a ModuleScript's source through the AegisVM pipeline and cache the result.
    -- Falls back to native require when .Source is empty or unreadable (live games
    -- restrict source access; Studio allows it).
    local function requireModule(instance)
        if moduleCache[instance] ~= nil then
            return moduleCache[instance]
        end
        local nameOk, fullName = pcall(function() return instance:GetFullName() end)
        local chunkName = nameOk and fullName or "ModuleScript"
        -- Prefer the "Source" attribute set by NewScript (works in live games).
        -- Fall back to the native .Source property (Studio only).
        local source
        local attrOk, attrVal = pcall(function() return instance:GetAttribute("Source") end)
        if attrOk and type(attrVal) == "string" and attrVal ~= "" then
            source = attrVal
        else
            local srcOk, srcVal = pcall(function() return instance.Source end)
            if srcOk and type(srcVal) == "string" and srcVal ~= "" then
                source = srcVal
            end
        end
        if not source then
            error("require: cannot read Source of '" .. chunkName .. "' (not a NewScript module and source is restricted)", 0)
        end
        -- Tokenise
        local tokens
        local tokOk, tokErr = pcall(function()
            tokens = Lexer.tokenize(source, chunkName)
        end)
        if not tokOk then
            error("require: " .. Error.format(tokErr), 0)
        end
        -- Parse
        local ast
        local parseOk, parseErr = pcall(function()
            ast = Parser.parse(tokens, chunkName)
        end)
        if not parseOk then
            error("require: " .. Error.format(parseErr), 0)
        end
        -- Execute in a child of the sandbox global scope.
        -- Shadow `script` with the module instance being required, matching
        -- Roblox's native behaviour where each ModuleScript sees itself as `script`.
        local chunkScope = Scope.new(scope)
        chunkScope:declareLocal("script", instance)
        local execOk, sig = pcall(function()
            runtime:execBlock(ast, chunkScope)
        end)
        local result
        if execOk then
            error("require: module '" .. chunkName .. "' did not return a value", 0)
        elseif Error.isReturn(sig) then
            if sig.n == 0 then
                error("require: module '" .. chunkName .. "' did not return a value", 0)
            end
            result = sig.values[1]
        else
            error(sig, 0)
        end
        -- If the module returned an interpreter closure, wrap it in a real
        -- Lua function so that native callers (e.g. require(mod)(args) from
        -- the command bar or ModuleScriptTemplate) can call it directly.
        -- This mirrors the argument-wrapping done in callFunctionMulti.
        if type(result) == "table" and rawget(result, "__fn") then
            local closure = result
            local rt = runtime
            result = function(...)
                local callArgs = table.pack(...)
                local rets = table.pack(pcall(function()
                    local r = rt:callFunctionMulti(closure, callArgs)
                    return table.unpack(r, 1, r.n)
                end))
                if not rets[1] then
                    local err = rets[2]
                    if Error.isSignal(err) then return end
                    error(tostring(err), 0)
                end
                return table.unpack(rets, 2, rets.n)
            end
        end
        moduleCache[instance] = result
        return result
    end

    scope:defineGlobal("require", native(function(v)
        -- ModuleScript instance: run through AegisVM pipeline
        if isModuleScript(v) then
            return requireModule(v)
        end
        if Constants.REQUIRE_FETCH_NUMERIC then
            if type(v) == "number" then
                requireFetchLog(tostring(v))
                local objects = InsertService:LoadAsset(v)
                for _, obj in ipairs(objects) do
                    if obj.Name == "MainModule" then
                        -- recurse so the ModuleScript path runs it through AegisVM
                        return requireModule(obj)
                    end
                end
                error("require: no MainModule found in asset " .. tostring(v), 2)
            elseif type(v) == "string"
                and (v:sub(1, 7) == "http://" or v:sub(1, 8) == "https://") then
                requireFetchLog(v)
                local objects = InsertService:GetObjects(v)
                for _, obj in ipairs(objects) do
                    if obj.Name == "MainModule" then
                        return requireModule(obj)
                    end
                end
                error("require: no MainModule found at " .. v, 2)
            end
        end
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

    -- assert (#11: non-string error objects must be passed through unchanged)
    scope:defineGlobal("assert", native(function(v, msg, ...)
        if v == nil or v == false then
            if type(msg) == "string" then
                error(Error.runtime(msg), 0)
            elseif msg ~= nil then
                error(msg, 0)
            else
                error(Error.runtime("assertion failed!"), 0)
            end
        end
        return v, msg, ...
    end))

    -- Helper: call fn (native or closure) and return packed results.
    -- Signals that escape the call are re-thrown upward.
    local function callGuest(fn, args)
        if type(fn) == "function" then
            return table.pack(fn(table.unpack(args, 1, #args)))
        elseif type(fn) == "table" and rawget(fn, "__fn") then
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
        -- Only format interpreter RuntimeError objects; pass everything else
        -- through as-is so guest code receives the original thrown value. (#10)
        local errVal = (type(sig) == "table" and getmetatable(sig) == Error)
            and Error.format(sig) or sig
        return false, errVal
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
        -- Same pass-through rule as pcall (#10)
        local msg = (type(sig) == "table" and getmetatable(sig) == Error)
            and Error.format(sig) or sig
        local handlerOk, handlerResult = pcall(function()
            if type(handler) == "function" then
                return handler(msg)
            elseif type(handler) == "table" and rawget(handler, "__fn") then
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

    -- ipairs - supports __ipairs metamethod for consistency with __pairs
    scope:defineGlobal("ipairs", native(function(tbl)
        local mt = getmetatable(tbl)
        if mt then
            local mm = rawget(mt, "__ipairs")
            if mm ~= nil then return mm(tbl) end
        end
        -- Standard sequential integer-key iteration
        local i = 0
        return function(t, _)
            i = i + 1
            local v = t[i]
            if v ~= nil then
                return i, v
            end
        end, tbl, 0
    end))

    -- pairs - supports __pairs metamethod on any value (tables, userdata, etc.)
    scope:defineGlobal("pairs", native(function(tbl)
        local mt = getmetatable(tbl)
        if mt then
            local mm = rawget(mt, "__pairs")
            if mm then return mm(tbl) end
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

    -- typeof (#6: same closure fix as type)
    scope:defineGlobal("typeof", native(function(v)
        if type(v) == "table" and rawget(v, "__fn") then return "function" end
        return typeof and typeof(v) or type(v)
    end))

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
        elseif type(chunk) == "function" or (type(chunk) == "table" and rawget(chunk, "__fn")) then
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

    -- getfenv(fn_or_level): sandbox-safe proxy.
    -- For interpreter closures and numeric stack levels, returns the _G proxy
    -- (all AegisVM code shares one global environment). Returns nil for native
    -- functions so the host Lua environment is never reachable from guest code.
    scope:defineGlobal("getfenv", native(function(fnOrLevel)
        if fnOrLevel == nil or type(fnOrLevel) == "number" then
            return scope:get("_G")
        end
        if type(fnOrLevel) == "table" and rawget(fnOrLevel, "__fn") then
            return scope:get("_G")
        end
        return nil
    end))

    -- setfenv(fn_or_level, env): sandbox-safe proxy.
    -- Merges all key/value pairs from env into the sandbox global scope, which
    -- is the AegisVM equivalent of replacing a function's environment table.
    -- Returns fn for interpreter closures or nil otherwise.
    scope:defineGlobal("setfenv", native(function(fnOrLevel, env)
        if type(env) ~= "table" then return nil end
        local isLevel   = type(fnOrLevel) == "number"
        local isClosure = type(fnOrLevel) == "table" and rawget(fnOrLevel, "__fn")
        if fnOrLevel == nil or isLevel or isClosure then
            local globalScope = scope:getGlobalScope()
            for k, v in pairs(env) do
                globalScope:declareLocal(k, v)
            end
            if isClosure then return fnOrLevel end
            return nil
        end
        return nil
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
        upper    = string.upper,
        -- pack/unpack/packsize: binary serialization (#12)
        pack     = string.pack,
        unpack   = string.unpack,
        packsize = string.packsize,
        -- split: use plain find so multi-char separators work correctly (#13)
        split = function(s, sep)
            sep = sep or " "
            local result = {}
            local i = 1
            while true do
                local s2, e = string.find(s, sep, i, true)
                if not s2 then
                    result[#result + 1] = string.sub(s, i)
                    break
                end
                result[#result + 1] = string.sub(s, i, s2 - 1)
                i = e + 1
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

local function buildTable(scope, runtime)
    -- Call fn (native or interpreter closure) and return the first result.
    local function callComp(fn, a, b)
        if type(fn) == "table" and rawget(fn, "__fn") then
            local mr = runtime:callFunctionMulti(fn, {a, b})
            local r = mr[1]
            return r ~= nil and r ~= false
        end
        return fn(a, b)
    end

    local lib = {
        insert  = table.insert,
        remove  = table.remove,
        concat  = table.concat,
        -- sort: wrap interpreter closure comparators
        sort    = function(t, comp)
            if comp == nil then
                table.sort(t)
            elseif type(comp) == "table" and rawget(comp, "__fn") then
                table.sort(t, function(a, b) return callComp(comp, a, b) end)
            else
                table.sort(t, comp)
            end
        end,
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
        -- Luau table.freeze / table.isfrozen (read-only tables)
        freeze   = table.freeze   or function(t) return t end,
        isfrozen = table.isfrozen or function(_) return false end,
        getn   = function(t) return #t end,  -- Lua 5.1 compat
        maxn   = function(t)
            local max = 0
            for k in pairs(t) do
                if type(k) == "number" and k > max then max = k end
            end
            return max
        end,
        -- Lua 5.1 compat: table.foreach / table.foreachi
        -- Iterate t calling f(key, value); stop early if f returns non-nil.
        foreach = function(t, f)
            for k, v in pairs(t) do
                local r
                if type(f) == "table" and rawget(f, "__fn") then
                    local mr = runtime:callFunctionMulti(f, {k, v})
                    r = mr[1]
                else
                    r = f(k, v)
                end
                if r ~= nil then return r end
            end
        end,
        foreachi = function(t, f)
            for i, v in ipairs(t) do
                local r
                if type(f) == "table" and rawget(f, "__fn") then
                    local mr = runtime:callFunctionMulti(f, {i, v})
                    r = mr[1]
                else
                    r = f(i, v)
                end
                if r ~= nil then return r end
            end
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
        tointeger  = math.tointeger,
        type       = math.type,
        maxinteger = math.maxinteger,
        mininteger = math.mininteger,
        -- Roblox Luau: Perlin noise
        noise = math.noise,
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

local function buildCoroutine(scope, runtime)
    -- coroutine.create/wrap require a real Lua function.  Wrap interpreter
    -- closures so the Lua coroutine machinery accepts them.  Yields issued
    -- from within the closure correctly propagate through the native layer.
    local function wrapFn(fn)
        if type(fn) == "table" and rawget(fn, "__fn") then
            return function(...)
                local args = table.pack(...)
                local ok, res = pcall(runtime.callFunctionMulti, runtime, fn, args)
                if not ok then
                    -- Control-flow signals must not escape the coroutine boundary.
                    if Error.isSignal(res) then return end
                    -- Format RuntimeErrors into strings so coroutine.resume
                    -- returns a readable message rather than a raw error object.
                    error(Error.format(res), 0)
                end
                local out = {}
                for i = 1, res.n do out[i] = res[i] end
                return table.unpack(out, 1, res.n)
            end
        end
        return fn
    end
    scope:defineGlobal("coroutine", {
        create      = function(fn) return coroutine.create(wrapFn(fn)) end,
        resume      = coroutine.resume,
        yield       = coroutine.yield,
        status      = coroutine.status,
        wrap        = function(fn) return coroutine.wrap(wrapFn(fn)) end,
        running     = coroutine.running,
        isyieldable = coroutine.isyieldable,
        close       = coroutine.close,
    })
end

-- ─── task library (Roblox) ───────────────────────────────────────────

local function buildTask(scope, runtime)
    if not task then return end
    -- task.spawn/defer/delay require real Lua functions.  Wrap interpreter
    -- closures so the Roblox scheduler accepts them.
    local function wrapFn(fn)
        if type(fn) == "table" and rawget(fn, "__fn") then
            return function(...)
                local args = table.pack(...)
                local ok, res = pcall(runtime.callFunctionMulti, runtime, fn, args)
                if not ok then
                    if Error.isSignal(res) then return end
                    error(Error.format(res), 0)
                end
            end
        end
        return fn
    end
    scope:defineGlobal("task", {
        spawn  = function(fn, ...) return task.spawn(wrapFn(fn), ...) end,
        defer  = function(fn, ...) return task.defer(wrapFn(fn), ...) end,
        delay  = function(t, fn, ...) return task.delay(t, wrapFn(fn), ...) end,
        wait   = task.wait,
        cancel = task.cancel,
    })
end

-- ─── buffer library (Roblox) ─────────────────────────────────────────

local function buildBuffer(scope)
    if not buffer then return end
    scope:defineGlobal("buffer", {
        create      = buffer.create,
        fromstring  = buffer.fromstring,
        tostring    = buffer.tostring,
        len         = buffer.len,
        copy        = buffer.copy,
        fill        = buffer.fill,
        readi8      = buffer.readi8,
        readu8      = buffer.readu8,
        readi16     = buffer.readi16,
        readu16     = buffer.readu16,
        readi32     = buffer.readi32,
        readu32     = buffer.readu32,
        readf32     = buffer.readf32,
        readf64     = buffer.readf64,
        writei8     = buffer.writei8,
        writeu8     = buffer.writeu8,
        writei16    = buffer.writei16,
        writeu16    = buffer.writeu16,
        writei32    = buffer.writei32,
        writeu32    = buffer.writeu32,
        writef32    = buffer.writef32,
        writef64    = buffer.writef64,
        readstring  = buffer.readstring,
        writestring = buffer.writestring,
    })
end

-- ─── debug library ───────────────────────────────────────────────────

local function buildDebug(scope, runtime)
    local lib = {}

    -- traceback(msg?, level?) - AegisVM-aware guest call stack trace.
    -- Returns a multi-line string in Luau format. Falls back to a minimal
    -- message when the interpreter call stack is empty (top-level script).
    lib.traceback = function(msgOrThread, level)
        local msg = type(msgOrThread) == "string" and msgOrThread or nil
        level = type(level) == "number" and math.max(1, level) or 1

        local stack = runtime.callStack
        -- Count filled slots (slots are cleared to nil on pop, so compact)
        local frameCount = #stack

        local lines = { "Stack Begin" }
        local skip = level - 1
        local skipped = 0
        -- Frames are oldest at index 1; newest (innermost) at frameCount.
        -- Luau lists innermost first, so iterate in reverse.
        for i = frameCount, 1, -1 do
            local frame = stack[i]
            if frame then
                if skipped < skip then
                    skipped = skipped + 1
                else
                    lines[#lines + 1] = "  Script '"
                        .. tostring(frame.chunkName)
                        .. "', Line "
                        .. tostring(frame.line)
                end
            end
        end
        lines[#lines + 1] = "Stack End"

        local traceStr = table.concat(lines, "\n")
        if msg then
            return msg .. "\n" .. traceStr
        end
        return traceStr
    end

    if debug then

        -- info(level|thread|func, options) - Roblox variant of getinfo
        if debug.info then
            lib.info = debug.info
        end

        -- getinfo - standard Lua getinfo; may not exist in all Roblox builds
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

        -- Roblox-specific profiling markers
        if debug.profilebegin then lib.profilebegin = debug.profilebegin end
        if debug.profileend   then lib.profileend   = debug.profileend   end

        -- Roblox memory category helpers (Studio / server only)
        if debug.resetmemorycategory then
            lib.resetmemorycategory = debug.resetmemorycategory
        end
        if debug.setmemorycategory then
            lib.setmemorycategory = debug.setmemorycategory
        end
    end

    -- The following are intentionally absent:
    --   getlocal / setlocal  - walk the host Lua call stack; level 1 inside the
    --                          sandbox exposes the Runtime's own locals.
    --   getupvalue / setupvalue - operate on host function upvalue chains, not
    --                          AegisVM closure captures.
    --   sethook              - hooks the host Lua VM's instruction dispatch,
    --                          not the AegisVM interpreter layer.

    -- getfenv / setfenv are proxied to sandbox-safe Aegis equivalents rather
    -- than forwarded to the host, which would violate the getfenv/setfenv ban.

    -- debug.getfenv(fn): for interpreter closures returns the sandbox _G proxy
    -- (the closure's global environment in AegisVM terms). Returns nil for
    -- native functions so host environments are never exposed.
    lib.getfenv = function(fn)
        if type(fn) == "table" and rawget(fn, "__fn") then
            return scope:get("_G")
        end
        return nil
    end

    -- debug.setfenv(fn, env): for interpreter closures injects all key/value
    -- pairs from env into the sandbox global scope - the AegisVM equivalent of
    -- replacing a function's global environment. Returns fn on success, nil if
    -- fn is not an interpreter closure or env is not a table.
    lib.setfenv = function(fn, env)
        if type(fn) == "table" and rawget(fn, "__fn") and type(env) == "table" then
            local globalScope = scope:getGlobalScope()
            for k, v in pairs(env) do
                globalScope:declareLocal(k, v)
            end
            return fn
        end
        return nil
    end

    scope:defineGlobal("debug", lib)
end

-- ─── _G (the guest global table) ────────────────────────────────────

local function buildGlobalTable(scope)
    -- _G must proxy the global scope so reads/writes through _G are
    -- equivalent to reading/writing globals directly. (#7)
    local globalScope = scope:getGlobalScope()
    local G = setmetatable({}, {
        __index = function(_, k)
            return globalScope:get(k)
        end,
        __newindex = function(_, k, v)
            globalScope:assign(k, v)
        end,
    })
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

local function buildRoblox(scope, runtime)
    -- ── Core game objects ────────────────────────────────────────────
    -- `game` is a proxy over the real DataModel that intercepts a handful of
    -- legacy / convenience methods while passing everything else through.
    -- `workspace` is the one true lowercase service alias Roblox always exposes.
    local realGame = game

    -- Per-sandbox CLIENT_COMMUNICATION override.
    -- If the guest environment defines CLIENT_COMMUNICATION as a global (e.g.
    -- via options.globals or sandbox.scope:defineGlobal), that value takes
    -- precedence over the module-level constant for this sandbox only.
    local function isClientComm()
        local override = scope:get("CLIENT_COMMUNICATION")
        if override ~= nil then return override == true end
        return Constants.CLIENT_COMMUNICATION
    end

    -- ── CLIENT_COMMUNICATION setup ───────────────────────────────────
    -- When enabled, client-only APIs (LocalPlayer, RenderStepped, GetMouse,
    -- UserInputService, CoreGui) are emulated via a LocalScript injected into
    -- the owner player's PlayerGui and two RemoteEvents for mouse/input data.

    -- Proxy cache: real Player -> wrapped player table (identity-stable)
    local playerProxyCache = {}

    -- Wrap a real Player so GetMouse() is intercepted; all other members
    -- fall through to the real object.
    local function wrapPlayer(player)
        if not player then return nil end
        if playerProxyCache[player] then return playerProxyCache[player] end
        local proxy = setmetatable({}, {
            __index = function(_, k)
                if k == "GetMouse" then
                    return function(_self)
                        return ClientComm.getMouse(player)
                    end
                end
                if k == "GetCamera" then
                    return function(_self)
                        return ClientComm.getCamera(player)
                    end
                end
                local v = player[k]
                if type(v) == "function" then
                    return function(_, ...) return v(player, ...) end
                end
                return v
            end,
            __newindex = function(_, k, v) player[k] = v end,
            __eq = function(a, b)
                return rawequal(a, player) or rawequal(b, player)
            end,
            __tostring = function() return tostring(player) end,
        })
        playerProxyCache[player] = proxy
        return proxy
    end

    -- Lazy owner resolution. Resolved once and cached; nil is also cached
    -- (logged once with callstack unless VERBOSITY is SUPPRESS).
    local ownerResolved = false
    local cachedOwner   = nil  -- real Player
    local ownerProxy    = nil  -- wrapPlayer(cachedOwner)

    local function resolveOwner()
        if ownerResolved then return end
        ownerResolved = true

        -- 1. "owner" global (must be a Player)
        local ownerGlobal = scope:get("owner")
        if ownerGlobal ~= nil then
            local ok, cls = pcall(function() return ownerGlobal.ClassName end)
            if ok and cls == "Player" then
                cachedOwner = ownerGlobal
                ownerProxy  = wrapPlayer(cachedOwner)
                ClientComm.setup(cachedOwner)
                return
            end
        end

        -- 2. Walk "script" parents looking for a Player
        local scriptInst = scope:get("script")
        if scriptInst ~= nil then
            local cur = scriptInst
            while cur ~= nil do
                local ok, cls = pcall(function() return cur.ClassName end)
                if ok and cls == "Player" then
                    cachedOwner = cur
                    ownerProxy  = wrapPlayer(cachedOwner)
                    ClientComm.setup(cachedOwner)
                    return
                end
                local pok, parent = pcall(function() return cur.Parent end)
                if not pok then break end
                cur = parent
            end

            -- 3. Walk "script" parents looking for a Model whose name matches a player
            cur = scriptInst
            while cur ~= nil do
                local ok, cls = pcall(function() return cur.ClassName end)
                if ok and cls == "Model" then
                    local nok, name = pcall(function() return cur.Name end)
                    if nok then
                        local p = game:GetService("Players"):FindFirstChild(name)
                        if p ~= nil then
                            local pok2, pcls = pcall(function() return p.ClassName end)
                            if pok2 and pcls == "Player" then
                                cachedOwner = p
                                ownerProxy  = wrapPlayer(cachedOwner)
                                ClientComm.setup(cachedOwner)
                                return
                            end
                        end
                    end
                end
                local pok2, parent = pcall(function() return cur.Parent end)
                if not pok2 then break end
                cur = parent
            end
        end

        -- 4. Not found - warn with callstack
        if Constants.VERBOSITY > Constants.VERBOSITY_SUPPRESS then
            local co    = coroutine.running() or "main"
            local stack = runtime.callStacks[co] or {}
            local parts = { "Could not find owner.", "Callstack:" }
            for i = #stack, 1, -1 do
                local frame = stack[i]
                local entry = frame.chunkName .. ", line " .. frame.line
                if frame.fnName then entry = entry .. " - " .. frame.fnName end
                parts[#parts + 1] = entry
            end
            warn(table.concat(parts, "\n"))
        end
    end

    local function getOwnerProxy()
        resolveOwner()
        return ownerProxy
    end

    local function getOwnerReal()
        resolveOwner()
        return cachedOwner
    end

    -- RunService proxy: maps RenderStepped -> Stepped for server execution,
    -- and overrides IsStudio() when Constants.STUDIO_OVERRIDE is non-nil.
    local realRunService    = realGame:GetService("RunService")
    local runServiceProxy   = setmetatable({}, {
        __index = function(_, k)
            if k == "RenderStepped" then return realRunService.Stepped end
            if k == "IsStudio" and Constants.STUDIO_OVERRIDE ~= nil then
                local ov = Constants.STUDIO_OVERRIDE
                return function() return ov end
            end
            local v = realRunService[k]
            if type(v) == "function" then
                return function(_, ...) return v(realRunService, ...) end
            end
            return v
        end,
        __newindex = function(_, k, v) realRunService[k] = v end,
        __tostring = function() return tostring(realRunService) end,
    })

    -- Players proxy: LocalPlayer -> resolved owner.
    local realPlayers   = realGame:GetService("Players")
    local playersProxy  = setmetatable({}, {
        __index = function(_, k)
            if k == "LocalPlayer" or k == "localPlayer" then
                return getOwnerProxy()
            end
            local v = realPlayers[k]
            if type(v) == "function" then
                return function(_, ...) return v(realPlayers, ...) end
            end
            return v
        end,
        __newindex = function(_, k, v) realPlayers[k] = v end,
        __tostring = function() return tostring(realPlayers) end,
    })

    -- Helper: return the emulated UserInputService for the owner.
    local function getUIS()
        local owner = getOwnerReal()
        if not owner then return nil end
        return ClientComm.getUserInputService(owner)
    end

    -- CoreGui emulation proxy - built once per sandbox and cached.
    --
    -- Always returned for game:GetService("CoreGui") regardless of whether
    -- CLIENT_COMMUNICATION is enabled, so guest scripts never receive the real
    -- CoreGui (which would fail on most API calls from a server Script).
    --
    -- When CLIENT_COMMUNICATION is on and an owner is resolved, the proxy
    -- forwards notification and SetCore/ToggleCoreGui calls to the client
    -- via ClientComm RemoteEvents. Otherwise those calls are silent no-ops.
    local cachedCoreGuiProxy = nil

    local function buildCoreGuiProxy()
        -- Fire a notification to the owner's client (if resolved and comms active).
        local function fireNotif(title, text, icon, duration)
            if not isClientComm() then return end
            local owner = getOwnerReal()
            if owner then
                ClientComm.sendNotification(owner, title, text, icon, duration)
            end
        end

        -- Forward a SetCore / ToggleCoreGui action to the owner's client.
        local function fireCoreAction(action, a1, a2)
            if not isClientComm() then return end
            local owner = getOwnerReal()
            if owner then
                ClientComm.sendCoreGuiAction(owner, action, a1, a2)
            end
        end

        -- Stub BindableEvent-like proxy for RobloxGui children that scripts may
        -- index but not meaningfully use. Provides .Fire() no-op and .Event signal.
        local function makeStubSignal(name)
            local be = Instance.new("BindableEvent")
            return setmetatable({}, {
                __index = function(_, k)
                    if k == "Fire"      then return function() end
                    elseif k == "Event" then return be.Event
                    elseif k == "Name"  then return name
                    elseif k == "ClassName" then return "BindableEvent"
                    end
                    return nil
                end,
            })
        end

        -- SendNotification proxy.
        -- :Fire(title, text, icon, duration) sends a toast notification to the
        -- client and also fires the backing BindableEvent for server-side listeners.
        -- .Event is a real RBXScriptSignal so :Connect() works on the server too.
        local snBE = Instance.new("BindableEvent")
        local sendNotifProxy = setmetatable({}, {
            __index = function(_, k)
                if k == "Fire" then
                    return function(_, title, text, icon, duration)
                        if Constants.FILTER_TEXT then
                            local userId = (getOwnerReal() and getOwnerReal().UserId) or 0
                            local rawTitle = tostring(title or "")
                            local rawText  = tostring(text  or "")
                            if Constants.FILTER_ASYNC then
                                snBE:Fire(title, text, icon, duration)
                                task.spawn(function()
                                    local ft = TextFilter.filterString(rawTitle, userId)
                                    local fb = TextFilter.filterString(rawText,  userId)
                                    fireNotif(ft, fb, icon, duration)
                                end)
                            else
                                local ft = TextFilter.filterString(rawTitle, userId)
                                local fb = TextFilter.filterString(rawText,  userId)
                                snBE:Fire(ft, fb, icon, duration)
                                fireNotif(ft, fb, icon, duration)
                            end
                        else
                            snBE:Fire(title, text, icon, duration)
                            fireNotif(title, text, icon, duration)
                        end
                    end
                elseif k == "Event"     then return snBE.Event
                elseif k == "Name"      then return "SendNotification"
                elseif k == "ClassName" then return "BindableEvent"
                end
                return nil
            end,
        })

        -- RobloxGui proxy: emulates the ScreenGui normally found inside CoreGui.
        -- Provides SendNotification and stubs for other commonly-accessed children.
        local robloxGuiChildren = {
            SendNotification    = sendNotifProxy,
            SettingsShowSignal  = makeStubSignal("SettingsShowSignal"),
            PlayerNameDisplayed = makeStubSignal("PlayerNameDisplayed"),
        }

        local robloxGuiProxy = setmetatable({}, {
            __index = function(_, k)
                if robloxGuiChildren[k] then return robloxGuiChildren[k] end
                if k == "Name"      then return "RobloxGui"
                elseif k == "ClassName" then return "ScreenGui"
                elseif k == "Enabled"   then return false
                elseif k == "WaitForChild" then
                    return function(_, name, _timeout)
                        return robloxGuiChildren[name]
                    end
                elseif k == "FindFirstChild" then
                    return function(_, name) return robloxGuiChildren[name] end
                elseif k == "GetChildren" then
                    return function(_)
                        local out = {}
                        for _, v in pairs(robloxGuiChildren) do
                            out[#out + 1] = v
                        end
                        return out
                    end
                end
                return nil
            end,
            __tostring = function() return "RobloxGui" end,
        })

        -- State storage for SetCore / GetCore / ToggleCoreGui / GetCoreGuiEnabled
        local setCoreValues  = {}          -- [string] = value
        local coreGuiEnabled = {}          -- [tostring(coreGuiEnum)] = bool

        local knownChildren = { RobloxGui = robloxGuiProxy }

        local coreGuiProxy = setmetatable({}, {
            __index = function(_, k)
                -- Instance navigation
                if k == "WaitForChild" or k == "FindFirstChild" then
                    return function(_, name, _timeout)
                        return knownChildren[name]
                    end
                elseif k == "GetChildren" then
                    return function(_)
                        local out = {}
                        for _, v in pairs(knownChildren) do out[#out + 1] = v end
                        return out
                    end
                elseif k == "IsA" then
                    return function(_, cls)
                        return cls == "CoreGui" or cls == "Instance"
                    end
                elseif k == "GetFullName" then
                    return function(_) return "CoreGui" end
                -- CoreGui API
                elseif k == "SetCore" then
                    return function(_, coreGuiType, value)
                        if type(coreGuiType) ~= "string" then return end
                        setCoreValues[coreGuiType] = value
                        if coreGuiType == "SendNotification" and type(value) == "table" then
                            -- Alternative notification form: SetCore("SendNotification", {...})
                            local title    = value.Title    or value[1] or ""
                            local text     = value.Text     or value[2] or ""
                            local icon     = value.Icon     or value[3] or ""
                            local duration = value.Duration or value[4] or 5
                            fireNotif(title, text, icon, duration)
                        else
                            fireCoreAction("SetCore", coreGuiType, value)
                        end
                    end
                elseif k == "GetCore" then
                    return function(_, coreGuiType)
                        return setCoreValues[coreGuiType]
                    end
                elseif k == "GetCoreGuiEnabled" then
                    return function(_, coreGuiType)
                        local key = tostring(coreGuiType)
                        if coreGuiEnabled[key] ~= nil then return coreGuiEnabled[key] end
                        return true
                    end
                elseif k == "ToggleCoreGui" then
                    return function(_, coreGuiType, enabled)
                        local key = tostring(coreGuiType)
                        coreGuiEnabled[key] = enabled
                        fireCoreAction("ToggleCoreGui", coreGuiType, enabled)
                    end
                elseif k == "SetCoreGuiEnabled" then
                    -- Some scripts call this on CoreGui directly instead of StarterGui
                    return function(_, coreGuiType, enabled)
                        local key = tostring(coreGuiType)
                        coreGuiEnabled[key] = enabled
                        fireCoreAction("ToggleCoreGui", coreGuiType, enabled)
                    end
                -- Direct child access by property name (e.g. CoreGui.RobloxGui)
                elseif knownChildren[k] then
                    return knownChildren[k]
                -- Identity fields
                elseif k == "Name"      then return "CoreGui"
                elseif k == "ClassName" then return "CoreGui"
                end
                return nil
            end,
            __newindex = function() end,
            __tostring = function() return "CoreGui" end,
        })

        return coreGuiProxy
    end

    -- Return the cached CoreGui proxy, building it the first time it is needed.
    local function getCoreGui()
        if not cachedCoreGuiProxy then
            cachedCoreGuiProxy = buildCoreGuiProxy()
        end
        return cachedCoreGuiProxy
    end

    -- ── Game proxy ───────────────────────────────────────────────────
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
                -- Pass the resolved owner so WebRbxmParser can inject it into
                -- sub-script sandboxes when REPLICATE_SCRIPTS is enabled.
                return function(_, url)
                    return InsertService:GetObjects(url, getOwnerReal())
                end
            elseif key == "GetService" then
                return function(_, serviceName)
                    -- CoreGui is always proxied: the real CoreGui is not safely
                    -- accessible from a server Script and guest scripts should
                    -- never receive it directly.
                    if serviceName == "CoreGui" then
                        return getCoreGui()
                    end
                    if serviceName == "RunService" and (isClientComm() or Constants.STUDIO_OVERRIDE ~= nil) then
                        return runServiceProxy
                    end
                    if isClientComm() then
                        if serviceName == "Players" then
                            return playersProxy
                        elseif serviceName == "UserInputService" then
                            return getUIS() or realGame:GetService("UserInputService")
                        end
                    end
                    return realGame:GetService(serviceName)
                end
            end

            -- ── Property shortcuts ───────────────────────────────────────
            -- CoreGui is always proxied (no CLIENT_COMMUNICATION guard needed).
            if key == "CoreGui" then
                return getCoreGui()
            end
            if isClientComm() then
                if key == "Players" then
                    return playersProxy
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
                    -- rawequal avoids triggering the proxy's __eq metamethod.
                    if rawequal(selfArg, gameProxy) then selfArg = realGame end
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
            -- rawequal avoids re-triggering __eq recursively when other IS gameProxy.
            return rawequal(other, realGame) or rawequal(other, gameProxy)
        end,
    })
    scope:defineGlobal("game",      gameProxy)

    -- Workspace proxy: intercepts CurrentCamera to return the owner's emulated
    -- camera when CLIENT_COMMUNICATION is active. All other accesses pass through.
    local realWorkspace = workspace
    local workspaceProxy
    workspaceProxy = setmetatable({}, {
        __index = function(_, k)
            if k == "CurrentCamera" and isClientComm() then
                local owner = getOwnerReal()
                if owner then return ClientComm.getCamera(owner) end
            end
            local v = realWorkspace[k]
            if type(v) == "function" then
                return function(selfArg, ...)
                    if rawequal(selfArg, workspaceProxy) then selfArg = realWorkspace end
                    return v(selfArg, ...)
                end
            end
            return v
        end,
        __newindex = function(_, k, v) realWorkspace[k] = v end,
        __tostring = function() return tostring(realWorkspace) end,
    })
    scope:defineGlobal("workspace", workspaceProxy)
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

    -- Deprecated global schedulers (still common in the wild).
    -- spawn and delay receive a callback, so wrap interpreter closures.
    local function wrapFn(fn)
        if type(fn) == "table" and rawget(fn, "__fn") then
            return function(...)
                local args = { ... }
                runtime:callFunctionMulti(fn, args)
            end
        end
        return fn
    end
    scope:defineGlobal("wait", wait)
    scope:defineGlobal("spawn", function(fn, ...) return spawn(wrapFn(fn), ...) end)
    scope:defineGlobal("delay", function(t, fn) return delay(t, wrapFn(fn)) end)

    -- ── Roblox helpers ───────────────────────────────────────────────
    scope:defineGlobal("typeof",        typeof)
    scope:defineGlobal("printidentity", printidentity)

    -- Plugin context (only non-nil when running inside a Studio plugin)
    local plug = hostGlobal("plugin")
    if plug then scope:defineGlobal("plugin", plug) end

    -- newproxy(createMetatable?) - creates an empty userdata value.
    -- Roblox-specific; safe to forward directly.
    local np = hostGlobal("newproxy")
    if np then scope:defineGlobal("newproxy", np) end
end

-- ─── Populate ────────────────────────────────────────────────────────

function StdLib.populate(scope, runtime)
    buildCore(scope, runtime)
    buildString(scope)
    buildTable(scope, runtime)
    buildMath(scope)
    buildBit32(scope)
    buildUtf8(scope)
    buildCoroutine(scope, runtime)
    buildTask(scope, runtime)
    buildBuffer(scope)
    buildDebug(scope, runtime)
    buildRoblox(scope, runtime)
    buildGlobalTable(scope)
end

return StdLib
