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

- **Fix: `requireModule` now sets `script = instance` in child scope** - `StdLib.luau` `requireModule` was creating `Scope.new(scope)` without shadowing `script`. The inherited `script` came from the outer sandbox (the caller's module), so inner modules calling `require(script.Child)` or `script:FindFirstChild("Child")` were resolving against the wrong Instance. `FindFirstChild` returned nil, `require(nil)` threw "Attempted to call require with invalid argument(s)". Fix: one line - `chunkScope:declareLocal("script", instance)` - matches Roblox's native behaviour.

- **Issues #21/#26 - Text filter fixes** - Async mode no longer writes raw text to instance properties (TOS compliance). Raw text is now archived in a weak-key table `rawTexts` inside TextFilter; VM reads of `.Text`/`.PlaceholderText` return the archived raw value so guest scripts see what they assigned. New `TextFilter.filterString(text, userId)` for filtering plain strings (notifications, print/warn). New `Constants.FILTER_OUTPUT = false`: when true, print/warn output is routed through the filter before being displayed. Notifications via `SendNotification:Fire` are filtered when FILTER_TEXT is enabled.
- **Issue #22 - Mouse click data** - `ClientAgent.client.luau` now fires a `MouseUpdate` event immediately alongside every Button1/2 Down/Up event so the server receives current position at click time.
- **Issue #23 - Mouse.KeyDown / KeyUp** - `ClientComm.luau` now fires `keyDnBE`/`keyUpBE` BindableEvents whenever InputBegan/InputEnded arrives for keyboard input. Mouse proxy exposes `KeyDown` and `KeyUp` events backed by these BindableEvents. No client changes needed - InputBegan/Ended were already forwarded.
- **Issue #24 - Per-environment CLIENT_COMMUNICATION** - `buildRoblox` now contains an `isClientComm()` helper that reads `CLIENT_COMMUNICATION` from the sandbox scope first (set via `options.globals`), falling back to `Constants.CLIENT_COMMUNICATION`. All four in-function checks replaced.
- **Issue #25 - REPLICATE_SCRIPTS** - New `Constants.REPLICATE_SCRIPTS = false`. When true, WebRbxmParser creates `Script` (server) instances instead of `LocalScript` for assets. Owner UserId is threaded through `ctx.ownerUserId` -> `NewScript.new(opts.ownerUserId)` -> `_AegisOwnerId` attribute on the script -> `ScriptTemplate.server.luau` reads it, resolves the Player, and injects `owner` and `CLIENT_COMMUNICATION = true` into the sub-sandbox globals.
- **CoreGui emulation** (previous session) - `game:GetService("CoreGui")` now always returns a proxy table (never the real CoreGui). The proxy provides:
  - `CoreGui:WaitForChild("RobloxGui")` / `FindFirstChild` / `GetChildren` / `.RobloxGui` - returns RobloxGui proxy
  - `RobloxGui.SendNotification:Fire(title, text, icon, duration)` - fires a toast notification on the client
  - `RobloxGui.SendNotification.Event` - real BindableEvent signal for server-side Connect()
  - `RobloxGui.SettingsShowSignal` / `PlayerNameDisplayed` - stub signals (no-op Fire, real Event)
  - `CoreGui:SetCore(name, value)` - stores value; routes "SendNotification" table form to fireNotif; others via CoreGuiAction RemoteEvent
  - `CoreGui:GetCore(name)` - returns stored value
  - `CoreGui:GetCoreGuiEnabled(coreGuiEnum)` - returns stored bool, defaults true
  - `CoreGui:ToggleCoreGui(coreGuiEnum, enabled)` / `SetCoreGuiEnabled(...)` - stores + sends to client
  - `CoreGui:IsA("CoreGui")` / `GetFullName()` - identity methods
- **ClientComm extended** - Two new RemoteEvents added to `_AegisComm`: `NotificationEvent` (server->client notification) and `CoreGuiAction` (server->client SetCore/ToggleCoreGui). A hidden `RobloxGui` ScreenGui is created in PlayerGui for instance-hierarchy compatibility. New public API: `ClientComm.sendNotification(player, ...)` and `ClientComm.sendCoreGuiAction(player, ...)`.
- **ClientAgent extended** - Listens for `NotificationEvent` and shows a bottom-right toast UI (`_AegisNotifs` ScreenGui in PlayerGui). Listens for `CoreGuiAction` and applies SetCore/SetCoreGuiEnabled via `StarterGui` on the client.

---

## What Should Be Done Next

From `TASKS.md`, in priority order:

1. **T-10** - Confirm `api.aegislua.xyz/rbxm?url=` is live and `game:GetObjects` still works end-to-end. Requires Studio + a live asset URL to test against.
2. **T-08 / T-09** - Validate `buffer.*` and closure-wrapped `task.*`/`spawn`/`delay` in Studio.
3. **CoreGui + filter validation** - Test SendNotification filtering (FILTER_TEXT + FILTER_ASYNC), text proxy (read-back of raw text), FILTER_OUTPUT for print/warn. Test CoreGui notification toast. All require Studio.
4. **Issues 19/20** - Validate buffer library and task.* closure wrapping in Studio (unchanged from previous session, still needs Studio testing).
5. **Release** - bump version and cut a new GitHub release.

---

## Current State of the System

The CoreGui proxy is always returned (not gated by CLIENT_COMMUNICATION). The `fireNotif`/`fireCoreAction` helpers inside the proxy check `CLIENT_COMMUNICATION` and owner resolution at call time (not at proxy build time), so late owner resolution works correctly.

The proxy is cached once per sandbox (`cachedCoreGuiProxy`). All method returns are closures over the same `setCoreValues`/`coreGuiEnabled` state tables.

`sendNotifProxy.Fire(self, ...)` uses `_` (self) as the first param - the colon-call convention in `SendNotification:Fire(a, b, c, d)` works correctly.

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

**`debug.traceback` uses interpreter call stack** - shows guest frames (chunkName + call-site line), not host Lua internals. Works only for interpreter closures; calls into native Roblox APIs don't add frames.

**`getfenv`/`setfenv` are level-agnostic** - all numeric levels return the same sandbox global environment.

**`table.sort` with closure comparators** - if the comparator raises a control-flow signal, the table is left partially sorted. Intentional; pathological comparators are out of scope.

**NewScript clone path** - `script.Parent.Parent:Clone()` inside NewScript.luau clones Aegis: NewScript -> Libraries -> Aegis. Do not restructure the Libraries folder without updating this path.

**CoreGui proxy WaitForChild does not yield** - it returns the child immediately (or nil for unknown names). Scripts that call WaitForChild on the proxy expecting to block will get nil back instantly if the name is not in `knownChildren`. Known children: `RobloxGui`.

**CoreGui proxy is per-sandbox, not per-player** - each `Aegis.run()` / `Aegis.newSandbox()` call has its own cached proxy. This is correct: each sandbox has its own owner.

**CLIENT_COMMUNICATION must be true for notifications to reach the client** - the proxy exists regardless, but `fireNotif`/`fireCoreAction` are no-ops when the flag is false or no owner is resolved.

**isClientComm() reads scope at call time** - the per-sandbox CLIENT_COMMUNICATION override is resolved lazily (when the first client API is accessed). If the guest script sets `CLIENT_COMMUNICATION = false` after startup, it may not take effect for already-resolved owner state.

**Text proxy and rawTexts weak table** - `rawTexts[instance][key]` is only set after a FILTER_TEXT assignment goes through `TextFilter.apply`. If the instance property was set before FILTER_TEXT was enabled, or set via direct host code, `getRaw` returns nil and the instance's actual value is used.

**REPLICATE_SCRIPTS requires both constants** - `Constants.REPLICATE_SCRIPTS = true` alone does nothing unless the parent environment has CLIENT_COMMUNICATION enabled (via global override or constant). The owner must be resolvable at the time `game:GetObjects` is called.

**Mouse.KeyDown/KeyUp fire the key name lowercased** - matches the Roblox legacy behavior. The key string is `Enum.KeyCode.Name:lower()` (e.g. "a", "leftshift"). Not a character code.

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
| `src/server/Aegis/Constants.luau` | Version string, verbosity levels, and `CONVERT_BASE_URL` (now `api.aegislua.xyz`). Bump `VERSION` before a release. |
| `src/server/Aegis/Libraries/NewScript.luau` | Script instance factory. `NewScript.new(opts)` clones a template and injects `_aegis`. Clone path: `script.Parent.Parent:Clone()`. |
| `src/server/Aegis/Libraries/WebRbxmParser.luau` | Rbxm deserializer. Delegates script creation to NewScript. |
| `default.project.json` | Rojo sync config. Must stay in sync with any new child modules. |
| `model.project.json` | Release build config. Nests Aegis under MainModule for `require(assetId)`. |
| `.github/workflows/release.yml` | CI release pipeline. Builds `.rbxm`, uploads, patches Roblox asset. |
| `FILEMAP.md` | Quick symbol reference for every file and builder function. |
| `TASKS.md` | Active task list. Pending: T-08, T-09, T-10. |
