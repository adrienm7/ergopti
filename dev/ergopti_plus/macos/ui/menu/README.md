# menu (Hammerspoon)

## Purpose

macOS menu bar icon (system tray) orchestrator. Creates the `hs.menubar` item, wires it to the full-menu builder, manages OS watchers (input source, app focus, network), and coordinates the updater lifecycle. All section construction is delegated to dedicated `menu_*.lua` sub-modules; the orchestrator's only responsibility is assembly order and shared-state wiring.

## Key files

| File                 | Description                                                            |
| -------------------- | ---------------------------------------------------------------------- |
| `init.lua`           | `M.init(state)` / `M.start()` — lifecycle; assembles the menu on click  |
| `menu_gestures.lua`  | Gesture slot assignments sub-menu builder                               |
| `menu_hotstrings.lua`| Hotstring group toggles and delay/colour editor entries                 |
| `menu_llm.lua`       | LLM backend, model, profile, and generation parameter entries           |
| `menu_karabiner.lua` | Karabiner-Elements layout and combo sub-menu                            |
| `menu_shortcuts.lua` | Shortcut-group toggles                                                  |
| `menu_about.lua`     | Version info, updater channel/interval, debug tools                     |
| `menu_metrics.lua`   | WPM widget and metrics dashboard entries                                |
| `manifest_menu.lua`  | Manifest-driven dynamic section renderer                                |
