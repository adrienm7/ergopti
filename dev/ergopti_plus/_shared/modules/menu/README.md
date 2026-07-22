# menu (shared data)

## Purpose

Generated tray-menu manifest consumed by both drivers' menu renderers. `menu_manifest.json` is produced by `npm run build:menu` from `_shared/modules/features/manifest.toml` and defines the full hierarchical menu tree: item types (toggle, action, separator, submenu), platform filters, ordered section arrays, and dynamic-slot placeholders for gesture assignments and hotstring groups.

## Key files

| File                | Description                                                               |
| ------------------- | ------------------------------------------------------------------------- |
| `menu_manifest.json`| Machine-generated full menu tree; never hand-edited                       |

## Editing rules

1. Modify `_shared/modules/features/manifest.toml` (the SSoT).
2. Run `npm run build:menu` (or `npm run build:domain` which includes it) to regenerate.
3. Commit the updated `menu_manifest.json` alongside the manifest change.

Both drivers read `menu_manifest.json` at boot through their manifest-loading adapters (`windows/lib/menu_manifest.ahk` and `macos/modules/keymap/manifest.lua`); any hand-edit will be overwritten on the next build run.
