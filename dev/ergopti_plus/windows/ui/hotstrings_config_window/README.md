# hotstrings_config_window (AHK)

## Purpose

Native Gui v2 editor for per-group and per-section hotstring configuration (expansion delay in milliseconds and tooltip colour). A three-tier selector (Commun / Personnel / extension) routes saves to the correct backing store: the shared `config.toml`, the personal `personal.toml`, or the extension-specific override file. Changes are applied immediately on Save without a full driver reload.

## Key files

| File       | Description                                                                |
| ---------- | -------------------------------------------------------------------------- |
| `init.ahk` | `HCW_Show()` — opens or focuses the singleton; owns all Gui controls       |

## Usage

```ahk
HCW_Show()  ; called from the Hotstrings → Configure tray-menu item
```
