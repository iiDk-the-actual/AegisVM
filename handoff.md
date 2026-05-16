# handoff.md - AegisVM Session Context Transfer

Optimized for quick agent onboarding. Read top to bottom; stop when you have enough context for your task.

---

## Project Overview

**AegisVM** is a complete Luau-in-Luau interpreter that runs inside Roblox Studio. It tokenizes, parses, and evaluates Luau source code at runtime without using `loadstring`, `getfenv`, `setfenv`, or any Roblox internals. The pipeline is:

```
source text -> Lexer.tokenize() -> Parser.parse() -> Runtime:execBlock()
```

All six core modules are children of the `Aegis` ModuleScript. The public entry point is `Aegis.luau`. Current version: **2** (see `Constants.luau`).

Repo: `iiDk-the-actual/AegisVM` | Branch: `main` | Toolchain: Rojo 7.7.0-rc.1 via Aftman

---

## Current State of the System

All core language features are implemented and working:
- Full Luau grammar (closures, metatables, metamethods, coroutines, varargs, goto/break/continue via signals)
- Sandboxed stdlib: core globals, string/table/math/bit32/utf8/coroutine/task/buffer/debug/os/Roblox types
- `getfenv`/`setfenv` present as sandbox-safe proxies (operate on AegisVM global scope, never expose host)
- `loadstring`/`load` re-enter the interpreter pipeline
- `game:GetObjects` proxied through WebRbxmParser (Libraries folder)
- GitHub Actions release workflow: builds `.rbxm`, uploads to release, PATCHes Roblox Open Cloud asset

**No automated test runner exists.** All validation requires Roblox Studio.

---

## What Was Just Completed

1. `getfenv`/`setfenv` added as top-level globals (sandbox-safe proxies matching `debug.getfenv`/`debug.setfenv` behavior added in the previous session)
2. `buffer` library added - full Roblox buffer API was entirely missing before
3. `newproxy` forwarded into the sandbox
4. `table.sort` now wraps interpreter closure comparators so native `table.sort` accepts them
5. `table.foreach`/`table.foreachi` added as Lua 5.1 compat shims with closure support
6. `task.spawn`/`defer`/`delay` now wrap interpreter closures before passing to the Roblox scheduler

Commit: `baa936a`

Prior session: removed host-exposing `debug` functions (`getlocal`/`setlocal`/`getupvalue`/`setupvalue`/`sethook`); proxied `debug.getfenv`/`debug.setfenv` to sandbox equivalents. Commit: `bb59faa`

---

## What Should Be Done Next

Priority order from `TASKS.md`:

1. **T-01** - Update `FILEMAP.md`: StdLib builder table is stale (missing `getfenv`/`setfenv` in buildCore, missing `buildBuffer` row, wrong path for WebRbxmParser). Small, safe, no logic.
2. **T-04** - Review GitHub issues #14-#16 filed during the v2 bug hunt. Check if any are regressions from recent stdlib changes.
3. **T-08 / T-09** - Validate `buffer` and `task.*` closure wrapping in Roblox Studio (must be done manually).
4. **T-02** - AegisVM-aware `debug.traceback`: currently shows host Runtime stack, not guest code frames. Requires Runtime to accumulate a `(chunkName, line)` call log.
5. **T-03** - Wrap deprecated `spawn`/`delay` globals in `buildRoblox` for interpreter closures (low priority, task.* is preferred).

---

## Known Risks and Gotchas

**Host-level Luau constraints (Roblox)** - these apply to the interpreter's own source, not to guest code:
- No `goto`/`::label::` at host level. Loop `continue` in the interpreter itself uses `pcall` + signal re-raise.
- No bitwise operators (`~`, `&`, `|`, `<<`, `>>`). Use `bit32.*` functions.
- No `rawset` on the string metatable (Roblox locks it). String method calls on string values are handled in `Runtime:tableGet` by falling back to the `string` global.

**Interpreter closure identity** - closures are plain Lua tables `{__fn=true, params, hasVarArg, block, closure=Scope}`, not real Lua functions. Any stdlib function that receives a callback must check `type(fn) == "table" and fn.__fn` and dispatch through `runtime:callFunctionMulti`. Forgetting this check causes silent nil returns or type errors from native Roblox APIs.

**Control-flow signals** - `break`/`continue`/`return`/`goto` are propagated as sentinel tables thrown via `error(signal, 0)`. Any `pcall` in StdLib that catches errors **must** re-raise signals it does not own. Check `Error.isBreak/isContinue/isReturn/isGoto`. Failing to do this swallows control flow silently.

**`debug.traceback` reports host stack** - the traceback shown to guest code is the Runtime's Lua call stack, not the guest script's logical stack. A future task (T-02) would fix this.

**`getfenv`/`setfenv` are level-agnostic** - in Lua 5.1, `getfenv(2)` returns the environment of the function 2 levels up. AegisVM returns the same global environment for all numeric levels because there is no per-function environment in the scope chain model.

**`table.sort` with closure comparators** - if the comparator raises a control-flow signal, it propagates through native `table.sort` and the table is left in a partially-sorted state (T-05).

**`setfenv` semantics differ from Lua 5.1** - because AegisVM uses a single shared global scope rather than per-function environments, `setfenv(fn, env)` merges `env` into the global scope rather than replacing a function-local env. This is the closest safe approximation within the AegisVM model.

**WebRbxmParser path** - the module was moved to `src/shared/Aegis/Libraries/WebRbxmParser.luau`. FILEMAP.md still shows the old path (T-01).

---

## Key Files

| File | Why it matters |
|------|----------------|
| `src/shared/Aegis.luau` | Public API. Entry point for all external callers. `Sandbox.new`, `compile`, `execAST`. |
| `src/shared/Aegis/Runtime.luau` | The interpreter. `eval`, `evalBinary`, `tableGet`, `tableSet`, `callFunctionMulti`, `execStat`, `execBlock`. Largest file; most bugs live here. |
| `src/shared/Aegis/StdLib.luau` | All sandbox globals. If a built-in behaves wrong, start here. Builder functions: `buildCore`, `buildTable`, `buildTask`, `buildCoroutine`, `buildDebug`, `buildRoblox`, etc. |
| `src/shared/Aegis/Scope.luau` | Scope chain. `declareLocal`, `get`, `assign`, `defineGlobal`, `getGlobalScope`. Understand this before touching variable resolution. |
| `src/shared/Aegis/Error.luau` | All error types and control-flow sentinels. Check here first when signals seem to be swallowed or mishandled. |
| `src/shared/Aegis/Constants.luau` | Version string and static name constants. Bump `VERSION` here before a release. |
| `src/shared/Aegis/Libraries/WebRbxmParser.luau` | Rbxm deserializer. `makeAegisScript` clones template scripts and parents a full Aegis clone named `_aegis`. Uses `script.Parent.Parent:Clone()` (Libraries -> Aegis) - do not change without re-checking the clone path. |
| `default.project.json` | Rojo sync config. Mirrors the module tree; must stay in sync with any new child modules. |
| `.github/workflows/release.yml` | CI release pipeline. Builds `.rbxm`, uploads to GitHub release, PATCHes Roblox Open Cloud asset with version and description. |
| `FILEMAP.md` | Quick symbol reference for every file. Currently stale on StdLib builders and WebRbxmParser path (T-01). |
| `TASKS.md` | Active task list. Claim tasks before starting; mark done when merged. |
