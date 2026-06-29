# menu (AHK)

## Purpose

Tray context menu orchestrator. Assembles the full menu from category-specific builder modules; all actionable items must go through `RegisterMenuItem` (in `lib/menu_dispatcher.ahk`) rather than raw `Menu.Add` to avoid the AHK 2.0 silent callback-drop bug. The menu is rebuilt on every tray icon click, not cached, so it always reflects current runtime state.

## Key files

| File                | Description                                                                      |
| ------------------- | -------------------------------------------------------------------------------- |
| `init.ahk`          | `BuildTrayMenu()` — assembles the complete tray menu; called on every tray click  |
| `menu_gestures.ahk` | Gesture slot sub-menu builder                                                     |
| `menu_llm.ahk`      | LLM sub-menu builder (backend, model, profile, temperature)                       |
| `menu_shortcuts.ahk`| Shortcut-group toggles sub-menu builder                                           |
| `menu_manifest.ahk` | TOML-manifest-driven dynamic section loader                                       |

## Key invariant

Every `Menu.Add` call that registers an action handler must go through `RegisterMenuItem` — never `Menu.Add` directly. Violating this causes the AHK 2.0 callback-drop bug where ~30–50 % of tray menu clicks are silently ignored.
