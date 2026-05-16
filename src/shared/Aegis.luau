--[[
    Aegis.luau - AegisVM Luau-in-Luau execution engine (main entry point)

    ══════════════════════════════════════════════════════════════════
    A complete, standalone Luau source-code interpreter written
    entirely in Luau.  It tokenises, parses, and evaluates Luau source
    code without any of the forbidden reflection APIs:

        ✗  getfenv / setfenv
        ✗  loadstring / load
        ✗  debug library exploits
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

        local Aegis = require(ReplicatedStorage.Aegis)

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

    1.  Source text  →  Lexer.tokenize()
            The Lexer scans the raw UTF-8 source byte-by-byte.
            It emits a flat list of Token objects:
                { type, value, line, col }
            Long strings, escape sequences, and all Luau operators are
            handled.  Keywords are recognised as a post-processing step
            on identifiers.

    2.  Token list  →  Parser.parse()
            A recursive-descent parser with a Pratt sub-parser for
            expressions.  Each grammar rule is a method on the Parser
            object.  It returns a Block AST node containing a list of
            statement nodes, each of which may contain expression nodes
            as children.  Type annotations are parsed into placeholder
            nodes and discarded by the Runtime.

    3.  AST  →  Runtime:execBlock()
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

local Lexer   = require(script.Lexer)
local Parser  = require(script.Parser)
local Runtime = require(script.Runtime)
local Scope   = require(script.Scope)
local StdLib  = require(script.StdLib)
local Error   = require(script.Error)

-- ─── Sandbox object ──────────────────────────────────────────────────

--[[
    A Sandbox bundles the global scope and runtime together so you can
    run multiple code snippets in the same shared environment.
]]
local Sandbox = {}
Sandbox.__index = Sandbox

function Sandbox.new(options)
    options = options or {}
    local scope   = Scope.global("_G")
    local runtime = Runtime.new(scope)

    -- Optionally cap the call stack depth (default 200)
    if options.maxCallDepth then
        runtime.maxCallDepth = options.maxCallDepth
    end

    -- Inject safe standard library
    if options.noStdLib ~= true then
        StdLib.populate(scope, runtime)
    end

    -- Inject caller-supplied globals
    if options.globals then
        for k, v in pairs(options.globals) do
            scope:defineGlobal(k, v)
        end
    end

    return setmetatable({
        scope   = scope,
        runtime = runtime,
    }, Sandbox)
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

-- Execute a pre-compiled AST block in a sandbox.
-- Returns (true, v1, v2, …) on success or (false, errorMessage) on failure.
-- Top-level return values from the script are unpacked as extra return values.
local function execAST(sandbox, ast)
    local ok, result = Runtime.execBlock(sandbox.runtime, ast, sandbox.scope)
    if ok then
        if result == nil then
            return true
        end
        -- result is a MultiReturn table: { __multi=true, n=N, [1]=v1, … }
        return true, table.unpack(result, 1, result.n)
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
Aegis.Lexer   = Lexer
Aegis.Parser  = Parser
Aegis.Runtime = Runtime
Aegis.Scope   = Scope
Aegis.StdLib  = StdLib
Aegis.Error   = Error

-- Expose the Sandbox constructor directly.
Aegis.Sandbox = Sandbox

return Aegis
