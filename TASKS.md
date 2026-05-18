# TASKS.md - AegisVM Active Task Tracker

Last updated: 2026-05-17 (session 2)
Maintainer convention: claim a task by adding `[agent/dev name]` next to its status before starting work. Mark done when merged.

---

## In Progress

_Nothing currently claimed._

---

## Pending

| ID | Description | Status | Notes / Dependencies |
|----|-------------|--------|----------------------|
| T-08 | Validate `buffer` library in Studio | todo | `buildBuffer` was added but not tested. Verify that `buffer.create`, `buffer.readf64`, `buffer.writestring`, etc. all behave correctly from inside a sandbox. Requires Studio. |
| T-09 | Validate `task.*` and `spawn`/`delay` closure wrapping in Studio | todo | `task.spawn`/`defer`/`delay` and deprecated `spawn`/`delay` now wrap interpreter closures. Test that yielding works and errors surface correctly. Requires Studio. |
| T-10 | Validate api.aegislua.xyz endpoint with WebRbxmParser | todo | CONVERT_BASE_URL changed to https://api.aegislua.xyz/rbxm?url= (AegisLua/API). Confirm the endpoint is live and game:GetObjects still resolves rbxm assets correctly. |

---

## Blockers / Issues

_No active blockers._

Note: there is no automated test runner. All validation requires Roblox Studio. If CI is needed, the only path is a Rojo build check (already in the release workflow) - full runtime tests would need a Studio automation harness.

---

## Recently Completed

| ID | Description | Commit |
|----|-------------|--------|
| - | CoreGui emulation: RobloxGui proxy with SendNotification, SetCore, GetCore, ToggleCoreGui, SetCoreGuiEnabled; notification toast UI on client; ClientComm extended with NotificationEvent + CoreGuiAction RemoteEvents | this session |
| T-01 | Update FILEMAP.md - StdLib builders, WebRbxmParser path | `df9f46d` |
| T-03 | Wrap deprecated `spawn`/`delay` globals for interpreter closures | `df9f46d` |
| T-05 | `table.sort` signal propagation - resolved as won't-fix; signals propagate naturally, pathological comparators are out of scope | - |
| T-06 | Fix StdLib header comment (inaccurate os exclusion note) | `df9f46d` |
| #14 | `tableGet` depth limit - RuntimeError on __index chains > 200 deep | `df9f46d` |
| #15 | Lexer column tracking after long string - body-only newline scan | `df9f46d` |
| #16 | `pairs()` now checks `__pairs` on any value type, not just tables | `df9f46d` |
| T-02 | AegisVM-aware `debug.traceback` - call stack log, frame push/pop in callFunctionMulti | `e660a9b` |
| T-07 | `ipairs` `__ipairs` metamethod support | `e660a9b` |
| - | `<close>` attribute enforcement - `__close` called in LIFO order on scope exit for any exit path | `8715005` |
| - | `class`/`extends` keyword, `<const>` enforcement, string interpolation, `if`-expressions, `__iter` metamethod, `table.freeze`/`isfrozen`, `math.noise` | this session |
| - | Add `getfenv`/`setfenv` globals, `buffer` library, `newproxy`; fix `table.sort`/`task.*` closure support | `baa936a` |
| - | Remove host-exposing `debug` functions; proxy `debug.getfenv`/`setfenv` to sandbox-safe Aegis equivalents | `bb59faa` |
| - | Fix `__tostring` priority on closures; add coroutine closure wrapping | `7c6cabc` |
| - | Fix all 8 open issues (#6-#13): type/typeof for closures, _G proxy, tostring metamethod priority, evalBinaryValues metamethod dispatch, pcall error pass-through, assert non-string errors, string.pack/unpack, string.split | `bdd6a7d` |
| - | CI: set Roblox asset name, description, and release version on publish step | `bdd03a0` |
| - | Move WebRbxmParser into Libraries folder; add Libraries module; expose Aegis.Libraries | `217b38c` + `fbe91a7` |
| - | Add `load`, `dofile`, `collectgarbage`, `debug.*`, `_AEGIS_VERSION` | `1de806e` |
| - | Bump version to 2, publish GitHub Release "Version 2" (tag: 2) | `7516ba5` |
| - | Replace .Source mutation with cloned template scripts in WebRbxmParser | `5da1d29` |
