# updater (shared data)

## Purpose

Single source of truth for cross-driver updater scalars. Eliminates the triplicated literals (`owner`, `repo`, interval, boot-delay) that previously lived independently in `windows/lib/updater/core.ahk`, `macos/lib/updater.lua`, and a dead `constants.toml`. Both drivers now read from `defaults.json` through their JSON adapters.

## Key files

| File           | Description                                                         |
| -------------- | ------------------------------------------------------------------- |
| `defaults.json`| Owner, repo, check interval (s), boot-delay (s) — all cross-driver scalars |

## Drift gate

`tools/test/test-updater-constants-single-source.cjs` asserts that both AHK and Lua implementations read the scalars from `defaults.json` rather than re-declaring them. CI fails on any regression (P10.1).

## Adding a new scalar

1. Add the key to `defaults.json`.
2. Read it in both `windows/lib/updater/core.ahk` (via `_Updater_ReadSharedDefaults`) and `macos/lib/updater.lua` (via `JsonCodec` + `FileSystem` adapters).
3. Add an assertion to `test-updater-constants-single-source.cjs`.
