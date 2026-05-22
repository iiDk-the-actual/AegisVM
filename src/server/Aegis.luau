--[[
    Aegis.luau - AegisVM Luau-in-Luau execution engine (main entry point)

    ══════════════════════════════════════════════════════════════════
    A complete, standalone Luau source-code interpreter written
    entirely in Luau.  It tokenises, parses, and evaluates Luau source
    code without any of the forbidden reflection APIs:

        ✗  getfenv / setfenv
        ✗  loadstring / load
        ✗  Roblox internals / bytecode injection
        ✗  external executors / unsafe sandbox escapes

    Everything is manual: the Lexer builds tokens, the Parser builds an
    AST, and the Runtime walks that AST node-by-node.

    ══════════════════════════════════════════════════════════════════
    Architecture
    ════════════

    ┌──────────────────────────────────────────┐
    │  Aegis.luau  (this file - public API)    │
    │                                          │
    │  ┌──────────┐  tokens   ┌────────────┐   │
    │  │  Lexer   │──────────▶│   Parser   │   │
    │  └──────────┘           └────────────┘   │
    │                              │  AST      │
    │  ┌──────────┐               ▼            │
    │  │  Scope   │◀────── ┌─────────────┐     │
    │  └──────────┘        │   Runtime   │     │
    │                      └─────────────┘     │
    │  ┌──────────┐               ▲            │
    │  │  StdLib  │───────────────┘            │
    │  └──────────┘                            │
    │  ┌──────────┐                            │
    │  │  Error   │  (used by all modules)     │
    │  └──────────┘                            │
    └──────────────────────────────────────────┘

    Modules (children of this ModuleScript in Roblox):
        Aegis.Lexer    - Tokeniser
        Aegis.Parser   - Recursive-descent + Pratt expression parser
        Aegis.Runtime  - AST evaluator / interpreter
        Aegis.Scope    - Lexical scope chain
        Aegis.StdLib   - Sandboxed standard library
        Aegis.Error    - Error types and control-flow signals

    ══════════════════════════════════════════════════════════════════
    Quick-start
    ═══════════

        local Aegis = require(game:GetService("ServerScriptService").Aegis)

        -- Run code in a fresh sandbox
        local ok, err = Aegis.run([[
            local x = 10
            local function fact(n)
                if n <= 1 then return 1 end
                return n * fact(n - 1)
            end
            print(fact(x))   -- -> 3628800
        \]\])
        if not ok then warn(err) end

        -- Shared sandbox across multiple calls
        local sandbox = Aegis.newSandbox()
        Aegis.runIn(sandbox, "x = 42")
        Aegis.runIn(sandbox, "print(x)")   -- -> 42

        -- Inject host values into the sandbox
        sandbox.scope:defineGlobal("myService", myServiceTable)

    ══════════════════════════════════════════════════════════════════
    Interpreter flow
    ════════════════

    1.  Source text  ->  Lexer.tokenize()
            The Lexer scans the raw UTF-8 source byte-by-byte.
            It emits a flat list of Token objects:
                { type, value, line, col }
            Long strings, escape sequences, and all Luau operators are
            handled.  Keywords are recognised as a post-processing step
            on identifiers.

    2.  Token list  ->  Parser.parse()
            A recursive-descent parser with a Pratt sub-parser for
            expressions.  Each grammar rule is a method on the Parser
            object.  It returns a Block AST node containing a list of
            statement nodes, each of which may contain expression nodes
            as children.  Type annotations are parsed into placeholder
            nodes and discarded by the Runtime.

    3.  AST  ->  Runtime:execBlock()
            The Runtime walks the AST.  eval() handles expressions;
            execStat() handles statements.  All Lua/Luau control-flow
            (break, continue, return, goto) is propagated via Lua's
            own error()/pcall() mechanism using sentinel signal tables.
            Function calls (including closures) create fresh child scopes
            of the function's defining scope, giving correct lexical
            scoping and upvalue semantics.

    Closure handling
    ────────────────
    A closure value is stored as:
        { __fn=true, params, hasVarArg, block, closure=<Scope> }
    When the function is called the Runtime creates a new child Scope
    from `closure` (the scope in which the function was *defined*, not
    the one from which it is *called*).  Because Scope.variables is a
    plain Lua table, mutations through any nested function are
    automatically visible to sibling closures-identical semantics to
    Lua's native upvalues.

    Environment / scope model
    ──────────────────────────
    • Scope.new(parent) creates a scope node in the chain.
    • scope:declareLocal(name, value) - binds a new local in THIS scope.
    • scope:get(name)                 - walks the chain outward.
    • scope:assign(name, value)       - updates an existing binding or
                                        creates a global if not found.
    • The global scope is the root node (parent = nil).
    • StdLib.populate(scope, runtime) fills the global scope with safe
      built-ins before execution begins.

    ══════════════════════════════════════════════════════════════════
]]

local Constants  = require(script.Constants)
local Lexer      = require(script.Lexer)
local Parser     = require(script.Parser)
local Runtime    = require(script.Runtime)
local Scope      = require(script.Scope)
local StdLib     = require(script.StdLib)
local Error      = require(script.Error)
local Libraries  = require(script.Libraries)
local LuaC       = require(script.LuaC)

-- ─── Sandbox object ──────────────────────────────────────────────────

--[[
    A Sandbox bundles the global scope and runtime together so you can
    run multiple code snippets in the same shared environment.
]]
local Sandbox = {}
Sandbox.__index = Sandbox

function Sandbox.new(options)
    options = options or {}

    -- Two-layer global scope:
    --   stdlibScope  (protected = true)  - populated by StdLib; never mutated
    --                                       by guest code after populate.
    --   scope        (user-globals layer) - exposed as sandbox.scope; holds
    --                                       host-injected and runIn-shared vars.
    -- A third per-chunk scope is created inside execAST for each run, so that
    -- guest assignments to stdlib names (math, print, script, …) are isolated
    -- to that script and do not leak into other scripts or the stdlib layer.
    local stdlibScope     = Scope.global("stdlib")
    stdlibScope.protected = true
    local scope           = Scope.new(stdlibScope, "globals")
    local runtime         = Runtime.new(scope)

    -- Optionally cap the call stack depth (default 200)
    if options.maxCallDepth then
        runtime.maxCallDepth = options.maxCallDepth
    end

    -- Inject safe standard library.
    -- Pass scope (sandbox_scope) so StdLib closures capture a scope that can
    -- see the full chain (sandbox_scope -> stdlibScope).  StdLib writes via
    -- scope:defineGlobal which calls getGlobalScope(), landing in stdlibScope
    -- (the protected root) regardless of which scope is passed here.
    if options.noStdLib ~= true then
        StdLib.populate(scope, runtime)
    end

    -- Inject caller-supplied globals into the user-globals layer.
    if options.globals then
        for k, v in pairs(options.globals) do
            scope:defineGlobal(k, v)
        end
    end

    local sandbox = setmetatable({
        scope   = scope,
        runtime = runtime,
    }, Sandbox)

    -- Inject a "luac" cursor global when the constant is enabled.
    -- Skipped if the caller already provided their own "luac" via options.globals.
    if Constants.LUAC_GLOBAL and scope:get("luac") == nil then
        scope:defineGlobal("luac", LuaC.cursor(sandbox))
    end

    return sandbox
end

-- ─── Compilation ─────────────────────────────────────────────────────

-- Compile source code into an AST block.
-- Returns (ast, nil) on success, (nil, errorMessage) on failure.
local function compile(source, sourceName)
    sourceName = sourceName or "chunk"

    -- Tokenise
    local tokens
    local ok, err = pcall(function()
        tokens = Lexer.tokenize(source, sourceName)
    end)
    if not ok then
        return nil, Error.format(err)
    end

    -- Parse
    local ast
    ok, err = pcall(function()
        ast = Parser.parse(tokens, sourceName)
    end)
    if not ok then
        return nil, Error.format(err)
    end

    return ast, nil
end

-- ─── Execution ────────────────────────────────────────────────────────

-- Wrap a single value: if it is an AegisVM interpreter closure (a table with
-- __fn=true), return a native Lua function that dispatches through the runtime
-- so callers outside the interpreter can invoke it directly.  If it is a plain
-- table, recursively wrap any closure values stored inside it (handles the
-- common pattern of a module returning { fn1 = ..., fn2 = ... }).
-- visited is used internally to avoid infinite loops on circular tables.
local function wrapIfClosure(rt, value, visited)
    if type(value) ~= "table" then
        return value
    end
    if rawget(value, "__fn") then
        local closure = value
        return function(...)
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
    -- Plain table - walk its values and wrap any closures in place.
    visited = visited or {}
    if visited[value] then return value end
    visited[value] = true
    for k, v in pairs(value) do
        if type(v) == "table" then
            local w = wrapIfClosure(rt, v, visited)
            if w ~= v then
                rawset(value, k, w)
            end
        end
    end
    return value
end

-- Execute a pre-compiled AST block in a sandbox.
-- Returns (true, v1, v2, …) on success or (false, errorMessage) on failure.
-- Top-level return values from the script are unpacked as extra return values.
-- Any AegisVM closure values in the return list are wrapped in native functions
-- so callers outside the interpreter (e.g. ModuleScriptTemplate) can call them.
local function execAST(sandbox, ast)
    -- Inform the runtime which chunk is running so call-stack frames carry
    -- the correct source name in debug.traceback output.
    sandbox.runtime.sourceName = ast.sourceName or "chunk"

    -- Create a per-chunk scope so that assignments to stdlib globals
    -- (math, print, script, …) are shadowed here rather than mutating the
    -- shared stdlib or user-globals scope.  Scope:assign redirects writes to
    -- protected (stdlib) names into the nearest isChunkScope ancestor.
    local chunkScope            = sandbox.scope:child("chunk")
    chunkScope.isChunkScope     = true

    local ok, result = Runtime.execBlock(sandbox.runtime, ast, chunkScope)
    if ok then
        if result == nil then
            return true
        end
        -- result is a MultiReturn table: { __multi=true, n=N, [1]=v1, … }
        -- Wrap any interpreter closures before handing values to native callers.
        local rt = sandbox.runtime
        local n = result.n
        local wrapped = table.create(n)
        for i = 1, n do
            wrapped[i] = wrapIfClosure(rt, result[i])
        end
        return true, table.unpack(wrapped, 1, n)
    end
    return false, Error.format(result)
end

-- ─── Public API ───────────────────────────────────────────────────────

local Aegis = {}

-- Create a new shared sandbox environment.
-- options:
--   maxCallDepth : number  (default 200)
--   noStdLib     : bool    (skip StdLib.populate)
--   globals      : table   (extra globals to inject)
function Aegis.newSandbox(options)
    return Sandbox.new(options)
end

-- Compile + run source code in a FRESH sandbox each time.
-- Returns (true, returnValues) or (false, errorMessage).
function Aegis.run(source, sourceName, options)
    local ast, compileErr = compile(source, sourceName)
    if not ast then
        return false, compileErr
    end

    local sandbox = Sandbox.new(options)
    return execAST(sandbox, ast)
end

-- Compile + run source code in an EXISTING shared sandbox.
-- Returns (true, returnValues) or (false, errorMessage).
function Aegis.runIn(sandbox, source, sourceName)
    local ast, compileErr = compile(source, sourceName)
    if not ast then
        return false, compileErr
    end
    return execAST(sandbox, ast)
end

-- Only compile (tokenise + parse), returning the AST or nil+error.
-- Useful for pre-compilation or syntax checking.
function Aegis.compile(source, sourceName)
    return compile(source, sourceName)
end

-- Execute a pre-compiled AST in an existing sandbox.
function Aegis.execAST(sandbox, ast)
    return execAST(sandbox, ast)
end

-- Expose sub-module references for advanced use.
Aegis.Lexer      = Lexer
Aegis.Parser     = Parser
Aegis.Runtime    = Runtime
Aegis.Scope      = Scope
Aegis.StdLib     = StdLib
Aegis.Error      = Error
Aegis.Libraries  = Libraries
Aegis.LuaC       = LuaC

-- Expose the Sandbox constructor directly.
Aegis.Sandbox = Sandbox

return Aegis
