# TASKS.md - AegisVM Active Task Tracker

Last updated: 2026-05-16
Maintainer convention: claim a task by adding `[agent/dev name]` next to its status before starting work. Mark done when merged.

---

## In Progress

_Nothing currently claimed._

---

## Pending

| ID | Description | Status | Notes / Dependencies |
|----|-------------|--------|----------------------|
| T-01 | Update FILEMAP.md - StdLib builder table is stale | todo | `buildCore` missing `getfenv`/`setfenv`; `buildTask`/`buildBuffer`/`buildRoblox` entries need updating; WebRbxmParser path still listed as `Aegis/WebRbxmParser.luau` instead of `Aegis/Libraries/WebRbxmParser.luau` |
| T-02 | AegisVM-aware `debug.traceback` | todo | Currently delegates to host `debug.traceback`, which reports the Runtime internals rather than guest code location. Requires Runtime to maintain a call-stack log of `(chunkName, line)` entries for interpreter frames. |
| T-03 | Wrap deprecated global schedulers for closures | todo | `spawn(fn)` / `delay(t, fn)` globals in `buildRoblox` pass `fn` directly to the host scheduler. If `fn` is an interpreter closure this silently fails. Low priority (task.* is the modern API) but should be consistent with how `task.*` was fixed. |
| T-04 | Review open GitHub issues #14-#16 | todo | Three issues were filed after the v2 bug hunt. Triage and fix as needed. |
| T-05 | `table.sort` signal propagation risk | todo | If a closure comparator throws a control-flow signal, it propagates through native `table.sort` leaving the table in a partially-sorted state. Decide whether to wrap the sort call in pcall and document or suppress. |
| T-06 | Fix StdLib header comment | todo | Line 18: "io / os / file are excluded" is inaccurate - `os` is included (time/clock/date/difftime). Small doc-only fix. |
| T-07 | `ipairs` metamethod support | todo | `buildCore` exposes the raw host `ipairs`. Lua 5.2 defined `__ipairs` (since removed), but AegisVM could support a custom `__ipairs` metamethod for consistency with `__pairs`. Low priority. |
| T-08 | Validate `buffer` library in Studio | todo | `buildBuffer` was added but not tested. Verify that `buffer.create`, `buffer.readf64`, `buffer.writestring`, etc. all behave correctly from inside a sandbox. Depends on: T-01 (doc update). |
| T-09 | Validate `task.*` closure wrapping in Studio | todo | `task.spawn`/`defer`/`delay` now wrap interpreter closures. Test that yielding inside a spawned closure works and that errors surface correctly. |

---

## Blockers / Issues

_No active blockers._

Note: there is no automated test runner. All validation requires Roblox Studio. If CI is needed, the only path is a Rojo build check (already in the release workflow) - full runtime tests would need a Studio automation harness.

---

## Recently Completed

| ID | Description | Commit |
|----|-------------|--------|
| - | Add `getfenv`/`setfenv` globals, `buffer` library, `newproxy`; fix `table.sort`/`task.*` closure support | `baa936a` |
| - | Remove host-exposing `debug` functions; proxy `debug.getfenv`/`setfenv` to sandbox-safe Aegis equivalents | `bb59faa` |
| - | Fix `__tostring` priority on closures; add coroutine closure wrapping | `7c6cabc` |
| - | Fix all 8 open issues (#6-#13): type/typeof for closures, _G proxy, tostring metamethod priority, evalBinaryValues metamethod dispatch, pcall error pass-through, assert non-string errors, string.pack/unpack, string.split | `bdd6a7d` |
| - | CI: set Roblox asset name, description, and release version on publish step | `bdd03a0` |
| - | Move WebRbxmParser into Libraries folder; add Libraries module; expose Aegis.Libraries | `217b38c` + `fbe91a7` |
| - | Add `load`, `dofile`, `collectgarbage`, `debug.*`, `_AEGIS_VERSION` | `1de806e` |
| - | Bump version to 2, publish GitHub Release "Version 2" (tag: 2) | `7516ba5` |
| - | Replace .Source mutation with cloned template scripts in WebRbxmParser | `5da1d29` |
