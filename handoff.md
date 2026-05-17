# handoff.md - AegisVM Session Context Transfer

Optimized for quick agent onboarding. Read top to bottom; stop when you have enough context for your task.

---

## Project Overview

**AegisVM** is a complete Luau-in-Luau interpreter that runs inside Roblox Studio. It tokenizes, parses, and evaluates Luau source code at runtime without using `loadstring`, `getfenv`, `setfenv`, or any Roblox internals. The pipeline is:

```
source text -> Lexer.tokenize() -> Parser.parse() -> Runtime:execBlock()
```

All core modules are children of the `Aegis` ModuleScript. The public entry point is `Aegis.luau`. Current version: **4** (see `Constants.luau`).

Repo: `AegisLua/AegisVM` | Branch: `main` | Toolchain: Rojo 7.7.0-rc.1 via Aftman

---

## Current State of the System

All core language features are implemented and working:
- Full Luau grammar (closures, metatables, metamethods, coroutines, varargs, goto/break/continue via signals)
- `class`/`extends` declarations, `<const>` enforcement, interpolated strings, `if`-expressions, `__iter` metamethod
- `local x <const> = v` - enforced at runtime via Scope.consts; reassignment raises RuntimeError
- `class Foo [extends Bar] ... end` - creates class table with `__index = classTable`; `extends` sets metatable chain
- Backtick strings `` `Hello {name}!` `` - fully evaluated including nested expressions
- `if cond then a else b` - expression form (not statement)
- `__iter` metamethod on tables in generic for loops
- Sandboxed stdlib: core globals, string/table/math/bit32/utf8/coroutine/task/buffer/debug/os/Roblox types
- `table.freeze`/`table.isfrozen`, `math.noise` added to stdlib
- `getfenv`/`setfenv` present as sandbox-safe proxies (operate on AegisVM global scope, never expose host)
- `loadstring`/`load` re-enter the interpreter pipeline
- `game:GetObjects` proxied through WebRbxmParser (Libraries folder)
- `MainModule` wrapper in the release model enables `require(115970020351857)` directly
- All 14 scripts have `Capabilities` set to max (`9007199254740991`, all SecurityCapability bits 0-52) via `.meta.json` files
- GitHub Actions release workflow: builds `.rbxm`, uploads to release, patches Roblox Creator Store asset
- Version 4 released (`tag: 4`)

**No automated test runner exists.** All validation requires Roblox Studio.

---

## What Was Just Completed

- **`<close>` attribute enforcement** (commit `8715005`) - `Scope.luau` now tracks a `closeList` array. `declareLocal` gains a 4th `isClose` parameter. Runtime `LocalDeclaration` passes `isClose` when `attrib == "close"`. `execBlock` wraps the statement loop in an outer pcall so any exit path (normal, break, continue, return, error) triggers `runCloseHandlers`. Handlers run LIFO; errors inside `__close` are swallowed so they do not mask the original signal. `closeErr` is nil for control-flow signals, the error object for real errors.
- **T-02 / T-07** - being implemented by a parallel agent in a worktree (debug.traceback call stack + __ipairs metamethod). Not yet merged to main.
- Prior session: `class`/`extends`, `<const>`, interpolated strings, `if`-expressions, `__iter`, `table.freeze`/`isfrozen`, `math.noise` (commit `c5e8096`)

---

## What Should Be Done Next

From `TASKS.md`, in priority order:

1. **T-02 / T-07** - being implemented by parallel agent (debug.traceback call stack; __ipairs). Merge that worktree branch when it completes.
2. **T-08 / T-09** - Validate `buffer.*` and closure-wrapped `task.*`/`spawn`/`delay` in Roblox Studio. Requires manual Studio testing.
3. **Release** - bump version and cut a new GitHub release once T-02 is merged.

---

## Known Risks and Gotchas

**Host-level Luau constraints** - apply to the interpreter source, not guest code:
- No `goto`/`::label::` at host level. Loop `continue` uses `pcall` + signal re-raise.
- No bitwise operators (`~`, `&`, `|`, `<<`, `>>`). Use `bit32.*` functions.
- No `rawset` on the string metatable. String method calls fall back via `Runtime:tableGet` to the `string` global.

**Interpreter closure identity** - closures are plain Lua tables `{__fn=true, params, hasVarArg, block, closure=Scope}`. Any stdlib function receiving a callback must check `type(fn) == "table" and fn.__fn` and dispatch through `runtime:callFunctionMulti`. Missing this causes silent nil returns or type errors.

**Control-flow signals** - `break`/`continue`/`return`/`goto` are sentinel tables thrown via `error(signal, 0)`. Any `pcall` in StdLib must re-raise signals it does not own (`Error.isBreak/isContinue/isReturn/isGoto`). Swallowing one silently breaks control flow.

**`tableGet` depth limit** - `__index` chains are capped at 200 levels (matches `maxCallDepth`). Circular metatables produce a clean RuntimeError.

**`<close>` handlers swallow their own errors** - if `__close` itself throws, the error is silently discarded (matching Luau semantics). The original signal still propagates.

**`execBlock` now has two levels of pcall** - the inner per-statement pcall handles goto; the outer wraps the whole loop for close-handler cleanup. This is intentional and correct; do not collapse them.

**`debug.traceback` reports host stack** - shows the Runtime's internal Lua frames, not guest script locations (T-02 tracks this; parallel agent implementing).

**`getfenv`/`setfenv` are level-agnostic** - all numeric levels return the same sandbox global environment.

**`table.sort` with closure comparators** - if the comparator raises a control-flow signal, the table is left partially sorted. Intentional; pathological comparators are out of scope.

**NewScript clone path** - `script.Parent.Parent:Clone()` inside NewScript.luau clones Aegis: NewScript -> Libraries -> Aegis. Do not restructure the Libraries folder without updating this path.

**`buildRoblox` takes `runtime`** - added when deprecated scheduler wrapping was implemented. Follow the same pattern for any new builder needing `runtime`.

**`.meta.json` files** - 14 files sit alongside every `.luau` in `src/`. If a new `.luau` file is added to the project, a matching `.meta.json` must be created to give it max capabilities. The value is always `{ "SecurityCapabilities": 9007199254740991 }`.

---

## Key Files

| File | Why it matters |
|------|----------------|
| `src/server/Aegis.luau` | Public API. `Sandbox.new`, `compile`, `execAST`. |
| `src/server/MainModule.luau` | `return require(script.Aegis)` - enables `require(assetId)`. |
| `src/server/Aegis/Runtime.luau` | The interpreter. `tableGet` (depth-limited), `callFunctionMulti`, `execStat`, `execBlock`. Most bugs live here. |
| `src/server/Aegis/StdLib.luau` | All sandbox globals. `buildRoblox` takes `runtime`. |
| `src/server/Aegis/Scope.luau` | Scope chain. `declareLocal`, `get`, `assign`, `defineGlobal`, `getGlobalScope`. |
| `src/server/Aegis/Error.luau` | Error types and control-flow sentinels. Check here first when signals are swallowed. |
| `src/server/Aegis/Lexer.luau` | Tokenizer. `readLongBracketBody` scans body only (not closing bracket) for newlines. |
| `src/server/Aegis/Constants.luau` | Version string and `CONVERT_BASE_URL`. Bump `VERSION` before a release. |
| `src/server/Aegis/Libraries/NewScript.luau` | Script instance factory. `NewScript.new(opts)` clones a template and injects `_aegis`. Clone path: `script.Parent.Parent:Clone()`. |
| `src/server/Aegis/Libraries/WebRbxmParser.luau` | Rbxm deserializer. Delegates script creation to NewScript. |
| `default.project.json` | Rojo sync config. Must stay in sync with any new child modules. |
| `model.project.json` | Release build config. Nests Aegis under MainModule for `require(assetId)`. |
| `.github/workflows/release.yml` | CI release pipeline. Builds `.rbxm`, uploads, patches Roblox asset. |
| `FILEMAP.md` | Quick symbol reference for every file and builder function. |
| `TASKS.md` | Active task list. 3 pending tasks: T-02, T-07, T-08/T-09. |
