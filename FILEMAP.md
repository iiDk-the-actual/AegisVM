# FILEMAP.md

Quick reference for every source file. One-line purpose + key symbols.

---

## `src/shared/Aegis.luau`
Public API entry point. Creates sandboxes, drives the compile/exec pipeline.

| Symbol | What it does |
|---|---|
| `Sandbox.new(options)` | Creates a global scope + runtime, calls StdLib.populate |
| `compile(source, sourceName)` | Tokenise -> parse, returns AST or nil+error |
| `execAST(sandbox, ast)` | Runs a pre-compiled AST, unpacks MultiReturn into varargs |
| `Aegis.run` | Fresh sandbox per call |
| `Aegis.runIn` | Existing shared sandbox |
| `Aegis.newSandbox` | Returns a Sandbox object |

---

## `src/shared/Aegis/Lexer.luau`
Tokeniser. Scans source byte-by-byte into a flat token list.

| Symbol | What it does |
|---|---|
| `Lexer.tokenize(source, name)` | Entry point; returns `{type, value, line, col}[]` |
| `Lexer:scanToken()` | Dispatches on current byte to the right scan path |
| `Lexer:scanString(quote)` | Handles `'...'` and `"..."` with escape sequences |
| `Lexer:scanLongString(level)` | Handles `[=[...]=]`-style long strings/comments |
| `Lexer:scanNumber()` | Handles decimal, hex, binary, scientific notation |
| `KEYWORDS` table | Maps identifier text -> keyword token type |

---

## `src/shared/Aegis/Parser.luau`
Recursive-descent parser with Pratt expression parsing.

| Symbol | What it does |
|---|---|
| `ParserModule.parse(tokens, name)` | Entry point; returns root Block AST node |
| `Parser:parseBlock(...)` | Parses statements until a stop token; returns `{kind="Block", stmts}` |
| `Parser:parseStatement()` | Dispatches on current token to the right statement rule |
| `Parser:parseExpr(minPrec)` | Pratt loop; calls `parseUnaryExpr` then climbs binary operators |
| `Parser:parseSuffixExpr()` | Chains `.field` `[key]` `(args)` `:method(args)` onto a primary |
| `Parser:parseFunctionBody(isMethod)` | Parses `(params) block end`; prepends `self` if isMethod |
| `Parser:parseTypeExpr()` | Permissive type annotation parser; result is discarded at runtime |
| `BINARY_PREC` table | `op -> {leftPrec, rightPrec}`; right < left means right-associative |

---

## `src/shared/Aegis/Runtime.luau`
AST-walking interpreter. All evaluation and execution lives here.

| Symbol | What it does |
|---|---|
| `Runtime.new(globalScope)` | Constructor; sets `callDepth`, `maxCallDepth` |
| `Runtime:eval(node, scope)` | Evaluates an expression node, returns one value |
| `Runtime:evalMulti(node, scope)` | Like eval but returns a MultiReturn table for calls/varargs |
| `Runtime:evalBinary(node, scope)` | All binary operators; short-circuits `and`/`or`; uses `bit32.*` for bitwise |
| `Runtime:evalUnary(node, scope)` | `-`, `#`, `not`, `~` (bitwise NOT via bit32.bnot) |
| `Runtime:tableGet(tbl, key, line)` | Index with `__index`, string fallback, userdata pcall |
| `Runtime:tableSet(tbl, key, value, line)` | Assign with `__newindex`, userdata pcall |
| `Runtime:callFunctionMulti(fn, args, line)` | Calls native fn, interpreter closure, or `__call`; wraps interpreter closures passed as native callback args |
| `Runtime:callFunction(fn, args, line)` | Convenience; returns singleOf(callFunctionMulti) |
| `Runtime:makeClosure(bodyNode, scope)` | Returns `{__fn=true, params, hasVarArg, block, closure=scope}` |
| `Runtime:evalArgList(argNodes, scope)` | Evaluates arg nodes, flattens last multi-return |
| `Runtime:execStat(node, scope)` | Dispatches all statement kinds |
| `Runtime:execBlock(block, scope)` | Iterates stmts; handles goto by label scan |
| `RuntimeModule.execBlock(runtime, block, scope)` | Public wrapper; catches return signal; returns `ok, MultiReturn` |
| `flattenExprList(results)` | Expands last item's multi-return; truncates all prior to 1 |
| `multiRet(...)` | Packs values into `{__multi=true, n, [1]...}` |

---

## `src/shared/Aegis/Scope.luau`
Lexical scope chain.

| Symbol | What it does |
|---|---|
| `Scope.global(name)` | Creates root scope (parent = nil) |
| `Scope.new(parent, name)` | Creates child scope |
| `scope:child(name)` | Shorthand for `Scope.new(self, name)` |
| `scope:declareLocal(name, value)` | Binds in THIS scope; sets both `variables[name]` and `declared[name]` |
| `scope:get(name)` | Walks chain outward; returns nil if not found |
| `scope:assign(name, value)` | Updates existing binding or creates at global root |
| `scope:defineGlobal(name, value)` | Writes directly to root scope |
| `scope:findOwner(name)` | Returns the scope that declares `name`, or nil |
| `variables` / `declared` | Two parallel tables: value storage + existence flag (needed because nil values can't be stored as table keys) |

---

## `src/shared/Aegis/Error.luau`
Error types and control-flow signal sentinels.

| Symbol | What it does |
|---|---|
| `Error.lexer(msg, line, col)` | Creates a LexerError object |
| `Error.parser(msg, line, col)` | Creates a ParserError object |
| `Error.runtime(msg, line, col)` | Creates a RuntimeError object |
| `Error.returnSignal(values, n)` | `{__signal="__return__", values, n}` -- carries return values |
| `Error.breakSignal()` | Singleton `BREAK_SIG` sentinel |
| `Error.continueSignal()` | Singleton `CONTINUE_SIG` sentinel |
| `Error.gotoSignal(label)` | `{__signal="__goto__", label}` |
| `Error.isReturn/isBreak/isContinue/isGoto(v)` | Signal identity checks |
| `Error.isSignal(v)` | True if any signal type |
| `Error.format(e)` | Formats any error/signal to a string |

---

## `src/shared/Aegis/StdLib.luau`
Sandboxed standard library. Called once via `StdLib.populate(scope, runtime)`.

| Builder function | What it registers |
|---|---|
| `buildCore` | `print`, `warn`, `tostring`, `tonumber`, `type`, `typeof`, `error`, `assert`, `pcall`, `xpcall`, `select`, `ipairs`, `pairs`, `next`, `rawget/set/equal/len`, `unpack`, `setmetatable`, `getmetatable`, `_VERSION`, `loadstring` |
| `buildString` | `string.*` (no metatable rawset) |
| `buildTable` | `table.*` |
| `buildMath` | `math.*` + Luau extensions |
| `buildBit32` | `bit32.*` |
| `buildUtf8` | `utf8.*` |
| `buildCoroutine` | `coroutine.*` |
| `buildTask` | `task.spawn/defer/delay/wait/cancel` |
| `buildRoblox` | `game` (proxy), `workspace`, `Enum`, `Instance`, `shared`, all value-type constructors, time globals, deprecated schedulers |
| `buildGlobalTable` | `_G` |

**`game` proxy intercepts:**
- `game:HttpGet` / `game:HttpGetAsync` -> `HttpService:GetAsync`
- `game:GetObjects(id)` -> `InsertService:LoadAsset(id):GetChildren()`
- Everything else passes through to the real DataModel, with method calls rebinding `self` to `realGame`

---

## `src/shared/Aegis/WebRbxmParser.luau`
Fetches and deserializes JSON-encoded rbxm object trees from the AegisVM convert endpoint. Used internally by the `game:GetObjects` proxy in StdLib. Scripts found in the tree are wrapped in sandboxed AegisVM runners (source stored as an attribute, real source is a template that requires a cloned Aegis module).

---

## `default.project.json`
Rojo sync configuration. Maps `src/shared/Aegis.luau` as the AegisVM ModuleScript with its submodules as children. Currently places Aegis under `ServerScriptService`.

## `aftman.toml`
Declares Rojo 7.7.0-rc.1 as the only managed tool.
