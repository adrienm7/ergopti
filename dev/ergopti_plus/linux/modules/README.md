# modules/

One folder per feature. Measured 2026-10-24 (production `.lua` only):

| Folder                | Files |  Lines | Role                                                                                                                                                                     |
| --------------------- | ----: | -----: | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `diagnostics/`        |     1 |    226 | crash reporter, the counterpart of the crash reporters on the other two drivers                                                                                          |
| `dynamic_hotstrings/` |     3 |  1 531 | computed expansions (dates, personal info), prefix rules and the user-code sandbox                                                                                       |
| `gestures/`           |     8 |  4 267 | gesture slots and action dispatch, the multi-touch decoder and touchpad finder, system and workspace actions                                                             |
| `hotstrings/`         |    14 |  7 650 | the expansion engine (`engine.lua` delegates to `_shared/lua/hotstring_engine`), TOML loader, device finder, evdev input reader, ydotool injector, magic and repeat keys |
| `keymap/`             |     2 |  1 273 | layout registry and the composer check                                                                                                                                   |
| `keystats/`           |    10 |  7 158 | capture, SQLite writer and reader, metrics collector, text cipher and migration                                                                                          |
| `llm/`                |    35 | 12 394 | inference backends (Ollama, remote API), prediction engine, profiles, agents, model download and inventory                                                               |
| `shortcuts/`          |    12 |  4 856 | keyboard shortcuts, key combinations, tap keys, script chords, wrap on type                                                                                              |
| `updater/`            |     5 |  3 039 | release polling and install: `manager.lua`, `installer.lua`, `archive_transfer.lua`, `config_backup.lua`, `restarter.lua`                                                |

Sibling trees: `adapters/` (43 files, the port implementations), `infra/` (78
files, cross-cutting infrastructure) and `ui/` (53 files, the tray menu and one
bridge per shared webview app).

> The tray menu and the webview hosts live under `ui/` here as on the other two
> drivers. The driver-tree parity gate (`tools/test/test-driver-tree-parity.cjs`)
> measures any divergence of this layout.
