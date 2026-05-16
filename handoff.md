# handoff.md - AegisVM Session Context Transfer

Optimized for quick agent onboarding. Read top to bottom; stop when you have enough context for your task.

---

## Project Overview

**AegisVM** is a complete Luau-in-Luau interpreter that runs inside Roblox Studio. It tokenizes, parses, and evaluates Luau source code at runtime without using `loadstring`, `getfenv`, `setfenv`, or any Roblox internals. The pipeline is:

```
source text -> Lexer.tokenize() -> Parser.parse() -> Runtime:execBlock()
```

All core modules are children of the `Aegis` ModuleScript. The public entry point is `Aegis.luau`. Current version: **3** (see `Constants.luau`).

Repo: `AegisLua/AegisVM` | Branch: `main` | Toolchain: Rojo 7.7.0-rc.1 via Aftman

---

## Current State of the System

All core language features are implemented and working:
- Full Luau grammar (closures, metatables, metamethods, coroutines, varargs, goto/break/continue via signals)
- Sandboxed stdlib: core globals, string/table/math/bit32/utf8/coroutine/task/buffer/debug/os/Roblox types
- `getfenv`/`setfenv` present as sandbox-safe proxies (operate on AegisVM global scope, never expose host)
- `loadstring`/`load` re-enter the interpreter pipeline
- `game:GetObjects` proxied through WebRbxmParser (Libraries folder)
- `MainModule` wrapper in the release model enables `require(115970020351857)` directly
- GitHub Actions release workflow: builds `.rbxm`, uploads to release, patches Roblox Creator Store asset

**No automated test runner exists.** All validation requires Roblox Studio.

---

## What Was Just Completed

Three GitHub issues closed and several tasks resolved in commit `df9f46d`:

- **#14** - `Runtime:tableGet` now takes a `depth` parameter (default 0) and raises a RuntimeError when `__index` chains exceed 200 levels. Circular metatables now produce a clean error instead of a host stack overflow.
- **#15** - `Lexer:readLongBracketBody` now scans newlines only over `[contentStart, closePos-1]` (body only), not including the closing bracket range. Keeps `lineStart` correctly anchored to the line containing the closing bracket.
- **#16** - `pairs()` in StdLib no longer guards `__pairs` lookup behind `type(tbl) == "table"`. Non-table values (userdata, Roblox Instances, `newproxy` proxies) now have their `__pairs` metamethod consulted.
- **T-01** - FILEMAP.md updated: StdLib builder table reflects all current builders and globals; WebRbxmParser path corrected to `Libraries/WebRbxmParser.luau`.
- **T-03** - Deprecated `spawn(fn)`/`delay(t, fn)` globals in `buildRoblox` now wrap interpreter closures the same way `buildTask` does.
- **T-06** - StdLib header comment fixed: removed inaccurate "io / os / file are excluded" line; `os` is partially included.

---

## What Should Be Done Next

From `TASKS.md`, in priority order:

1. **T-08 / T-09** - Validate `buffer.*` and closure-wrapped `task.*`/`spawn`/`delay` in Roblox Studio. These were added but have not been tested end-to-end. Requires manual Studio testing.
2. **T-02** - AegisVM-aware `debug.traceback`: currently shows host Runtime stack, not guest code frames. Requires Runtime to maintain a call-stack log of `(chunkName, line)` entries for interpreter frames. This is the most impactful remaining feature gap.
3. **T-07** - `__ipairs` metamethod support for `ipairs`. Low priority; only relevant for code using custom iterator objects.

---

## Known Risks and Gotchas

**Host-level Luau constraints (Roblox)** - these apply to the interpreter source, not to guest code:
- No `goto`/`::label::` at host level. Loop `continue` in the interpreter uses `pcall` + signal re-raise.
- No bitwise operators (`~`, `&`, `|`, `<<`, `>>`). Use `bit32.*` functions.
- No `rawset` on the string metatable (Roblox locks it). String method calls on string values are handled in `Runtime:tableGet` by falling back to the `string` global.

**Interpreter closure identity** - closures are plain Lua tables `{__fn=true, params, hasVarArg, block, closure=Scope}`, not real Lua functions. Any stdlib function that receives a callback must check `type(fn) == "table" and fn.__fn` and dispatch through `runtime:callFunctionMulti`. Missing this check causes silent nil returns or type errors from native Roblox APIs.

**Control-flow signals** - `break`/`continue`/`return`/`goto` are propagated as sentinel tables thrown via `error(signal, 0)`. Any `pcall` in StdLib that catches errors must re-raise signals it does not own. Check `Error.isBreak/isContinue/isReturn/isGoto`. Swallowing a signal silently breaks control flow in guest code.

**`tableGet` depth limit** - the `__index` chain limit is 200, matching `maxCallDepth`. This was added to fix issue #14. If a legitimate deep chain is reported as an error, the limit can be raised.

**`debug.traceback` reports host stack** - the traceback shown to guest code is the Runtime's Lua call stack, not the guest script's logical stack (T-02).

**`getfenv`/`setfenv` are level-agnostic** - all numeric levels return the same sandbox global environment. This differs from Lua 5.1 per-function environments.

**`table.sort` with closure comparators** - if the comparator raises a control-flow signal, it propagates through native `table.sort` and the table is left in a partially-sorted state. This is intentional: pathological comparators are out of scope.

**WebRbxmParser clone path** - `script.Parent.Parent:Clone()` inside WebRbxmParser clones the Aegis module. The path is WebRbxmParser -> Libraries -> Aegis. Do not restructure the Libraries folder without updating this line.

**`buildRoblox` now takes `runtime`** - added in the T-03 fix. The `populate` function passes it. If you add a new builder that needs `runtime`, follow the same pattern.

---

## Key Files

| File | Why it matters |
|------|----------------|
| `src/shared/Aegis.luau` | Public API. Entry point for all external callers. `Sandbox.new`, `compile`, `execAST`. |
| `src/shared/MainModule.luau` | One-liner: `return require(script.Aegis)`. Enables `require(assetId)` from Creator Store. |
| `src/shared/Aegis/Runtime.luau` | The interpreter. `eval`, `evalBinary`, `tableGet` (now depth-limited), `callFunctionMulti`, `execStat`, `execBlock`. Most bugs live here. |
| `src/shared/Aegis/StdLib.luau` | All sandbox globals. Builder functions: `buildCore`, `buildTable`, `buildTask`, `buildBuffer`, `buildCoroutine`, `buildDebug`, `buildRoblox` (now takes `runtime`), etc. |
| `src/shared/Aegis/Scope.luau` | Scope chain. `declareLocal`, `get`, `assign`, `defineGlobal`, `getGlobalScope`. Understand this before touching variable resolution. |
| `src/shared/Aegis/Error.luau` | All error types and control-flow sentinels. Check here first when signals seem swallowed or mishandled. |
| `src/shared/Aegis/Lexer.luau` | Tokenizer. `readLongBracketBody` was fixed for column tracking (issue #15). |
| `src/shared/Aegis/Constants.luau` | Version string and static name constants. Bump `VERSION` here before a release. Also holds `CONVERT_BASE_URL`. |
| `src/shared/Aegis/Libraries/WebRbxmParser.luau` | Rbxm deserializer. Clone path is `script.Parent.Parent:Clone()` (Libraries -> Aegis). |
| `default.project.json` | Rojo sync config. Must stay in sync with any new child modules. |
| `model.project.json` | Release build config. Nests Aegis under MainModule so `require(assetId)` works. |
| `.github/workflows/release.yml` | CI release pipeline. Builds `.rbxm`, uploads to GitHub release, patches Roblox Open Cloud asset. |
| `FILEMAP.md` | Quick symbol reference for every file. Now up to date as of `df9f46d`. |
| `TASKS.md` | Active task list. 4 pending tasks remaining (T-02, T-07, T-08, T-09). |
