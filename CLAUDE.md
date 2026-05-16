# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Security

Before committing or pushing anything, run the `security-vulnerability-scanner` agent to check for secrets, API keys, tokens, or credentials in staged files.

API keys and secrets must NEVER be pushed to GitHub. Files containing them must always be listed in `.gitignore` before they are ever staged. The following are already covered:

- `.claude/settings.local.json` (Claude Code local settings, contains personal tokens)
- `*.local.json`

If you discover a secret was already pushed, immediately: rewrite history to remove the commit (`git reset`, then force push), and tell the user to revoke the exposed key at the provider.

## Permissions

Claude Code has permission to commit, push, create branches, open pull requests, and create GitHub issues in this repository autonomously without asking for confirmation first.

## Commits

Every commit must be co-authored by both the user and Claude. Always use this trailer format:

```
Co-authored-by: iiDk-the-actual <54154105+iiDk-the-actual@users.noreply.github.com>
Co-authored-by: Claude <noreply@anthropic.com>
```

## Writing style

Do not use fancy Unicode characters anywhere in this repo - not in code comments, not in markdown, not in commit messages. Specifically:

- Em dashes (--) and en dashes: use a regular hyphen - instead
- Fancy arrows (-> <- => <= -- > <): use plain > or < or -> or <-
- Box-drawing characters and other non-ASCII symbols: do not use them

## File map

See [`FILEMAP.md`](FILEMAP.md) for a per-file breakdown of every source file's purpose and key symbols - faster than reading the source when navigating unfamiliar code.

## Toolchain

Tools are managed by [Aftman](https://github.com/LPGhatguy/aftman). The only tool declared is Rojo 7.7.0-rc.1.

```bash
# Install tools (run once after cloning)
aftman install

# Sync files into a running Roblox Studio session
rojo serve

# Build a place file without Studio
rojo build -o "rojoproj.rbxlx"
```

There are no test runners, linters, or build scripts. Validation is done by running code in Roblox Studio.

## Roblox Luau Constraints

This codebase targets Roblox's Luau runtime, which differs from standard Lua 5.3/5.4 and generic Luau:

- **No `goto` / `::label::`** - not supported in this Roblox build. Loop `continue` is emulated via `pcall` + signal checks.
- **No Lua 5.3 bitwise operators** (`~`, `&`, `|`, `<<`, `>>`) - use `bit32.band`, `bit32.bor`, `bit32.bxor`, `bit32.bnot`, `bit32.lshift`, `bit32.rshift`.
- **No `rawset` on the string metatable** - Roblox locks it. String method calls on string values are handled in `Runtime:tableGet` by falling back to the `string` global.
- **No `getfenv`, `setfenv`, `load`, `loadstring`** (at host level).

## Architecture

AegisVM is a Luau-in-Luau interpreter. Source text > tokens > AST > execution. All six modules live as children of the `Aegis` ModuleScript.

### Data flow

```
source text
  Lexer.tokenize()       -> token list  { type, value, line, col }
  Parser.parse()         -> AST block   { kind="Block", stmts={...} }
  Runtime:execBlock()    -> side effects / return signal
  RuntimeModule.execBlock() (public wrapper, catches return signal)
  Aegis.execAST()        -> unpacks MultiReturn -> true, v1, v2, ...
```

### Multiple return values

Packed as `{ __multi=true, n=count, [1]=v1, [2]=v2, ... }`. `eval()` always returns one value; `evalMulti()` returns the table. In expression lists only the **last** expression expands — all prior ones are truncated to one value (`flattenExprList`). `Aegis.run()` / `Aegis.runIn()` unpack this so callers receive `true, v1, v2, ...`.

### Control-flow signals

`break`, `continue`, `return`, and `goto` are propagated by throwing sentinel tables via `error(signal, 0)` and catching with `pcall`. Sentinels are defined in `Error.luau`. Loop bodies catch signals, check identity, and re-raise anything that isn't theirs. `pcall`/`xpcall` in StdLib re-raise signals so guest code cannot accidentally swallow them.

### Scope chain

Each block opens a `Scope.new(parent)`. Variables use two parallel tables: `variables[name] = value` and `declared[name] = true`. The `declared` table is needed because Lua tables cannot store `nil` at a key. `scope:assign()` walks the chain and writes at the first declaring scope, or falls through to the global (root) scope.

### Closure format

Interpreter closures are plain tables: `{ __fn=true, params, hasVarArg, block, closure=Scope }`. `closure` is the scope in which the function was **defined** (not called). When passed to native Roblox APIs (e.g. `Signal:Connect`), `callFunctionMulti` wraps them in real Lua `function(...)` adapters so Roblox accepts them.

### game proxy

The `game` global inside the sandbox is a proxy table, not the real DataModel. It intercepts:
- `game:HttpGet` / `game:HttpGetAsync` -> `HttpService:GetAsync`
- `game:GetObjects` -> `InsertService:LoadAsset():GetChildren()`

All other property reads and method calls pass through to `realGame`, with method calls rebinding `self` to `realGame` so Roblox accepts an Instance as the receiver.

### loadstring

Implemented in StdLib, not forbidden - it re-enters the interpreter pipeline (Lexer -> Parser -> Runtime) and returns a native Lua function. Each invocation of that function runs in a fresh child scope of the sandbox's global scope.

### StdLib population order

`buildCore` -> `buildString` -> `buildTable` -> `buildMath` -> `buildBit32` -> `buildUtf8` -> `buildCoroutine` -> `buildTask` -> `buildRoblox` -> `buildGlobalTable`. `buildRoblox` runs last and overwrites `typeof` with the Roblox-native version.

## Public API

```lua
Aegis.run(source, sourceName?, options?)           -- fresh sandbox, returns true, ...
Aegis.runIn(sandbox, source, sourceName?)          -- existing sandbox, returns true, ...
Aegis.compile(source, sourceName?)                 -- tokenise+parse only, returns ast or nil,err
Aegis.execAST(sandbox, ast)                        -- execute pre-compiled AST
Aegis.newSandbox({ maxCallDepth, noStdLib, globals })
sandbox.scope:defineGlobal(name, value)            -- inject host values
```

## Creating a Release

Follow these steps in order. Do not skip or reorder them.

### 1. Bump the version constant

Edit `src/shared/Aegis/Constants.luau` and increment `Constants.VERSION`.
Use a plain integer string: "1", "2", "3", and so on.

### 2. Commit the bump

```
chore: bump version to {N}
```

### 3. Create the GitHub release

```bash
gh release create "{N}" \
  --repo AegisLua/AegisVM \
  --title "Version {N}" \
  --notes "..."
```

Tag and title must match exactly: tag is the bare number (e.g. `3`), title is `Version 3`.

After the release is published, the CI workflow triggers automatically and:
- Builds the `.rbxm` with Rojo using `model.project.json`
- Uploads the `.rbxm` as a release asset
- Patches the Roblox Creator Store asset with the new file, name, and description

### GitHub release body template

Use `gh release view {prev}` or `git log {prev}..HEAD --oneline` to gather the
changelog since the last tag, then fill in this template:

```
AegisVM Version {N}

Changes since Version {N-1}:

New features:
- ...

Bug fixes:
- ...

The module is available on the Roblox Creator Store (asset 115970020351857)
and via require(115970020351857).

Full changelog: https://github.com/AegisLua/AegisVM/compare/{N-1}...{N}
```

Keep each bullet short (one line). Do not use em dashes, en dashes, or fancy
Unicode anywhere in the release body (same rule as the rest of this repo).

---

## Sandbox restrictions

Direct service globals (`Players`, `RunService`, etc.) are intentionally absent. Guest code must use `game:GetService("ServiceName")`. The sole exception is `workspace` (lowercase), which Roblox itself exposes as a global.
