# modules/

One folder per feature. Measured contents (production `.lua` only):

| Folder | Files | Lines | Role |
| --- | ---: | ---: | --- |
| `diagnostics/` | 1 | 163 | crash reporter — the counterpart of `lib/crash_reporter.*` on the other two drivers |
| `dynamic_hotstrings/` | 1 | 249 | computed expansions (dates, personal info) |
| `gestures/` | 1 | 850 | gesture slots + action dispatch. **The libinput reader is a stub**: `start_reading()` sets a flag and logs, nothing spawns a reader |
| `hotstrings/` | 6 | 1 191 | the expansion engine (`engine.lua` delegates to `_shared/lua/hotstring_engine`), TOML loader, evdev reader, ydotool injector, device finder |
| `kanata/` | 1 | 419 | generates and supervises the kanata `.kbd` (key remap + tap-hold) |
| `keylogger/` | 4 | 1 870 | capture, SQLite writer/reader, metrics collector |
| `llm/` | 3 | 898 | Ollama backend, prediction engine, profiles |
| `menu/` | 1 | 833 | the tray menu, hand-built. On Windows and macOS the equivalent lives in `ui/menu/` |
| `shortcuts/` | 1 | 385 | text utilities. **Registers no hotkey**: Linux has no global keyboard-grab API in userland |
| `ui/` | 16 | 2 379 | WebKitGTK hosting + one bridge handler per shared webview app. On Windows and macOS the equivalent lives in `ui/<window>/` |
| `updater/` | 1 | 798 | GitHub release polling and install |

Sibling trees: `adapters/` (22 files — the port implementations), `lib/` (6 files —
cross-cutting infra), `ui/` (1 file — `webkit_host.lua`).

> Two divergences from the other drivers that this layout makes visible, and that
> [`docs/PLAN_SIMPLIFICATION.md`](../../../../docs/PLAN_SIMPLIFICATION.md) closes:
> the tray menu and the webview hosts live under `modules/` here and under `ui/`
> elsewhere, and `linux/` therefore has **two** `ui` namespaces (`ui.*` →
> `linux/ui/`, `modules.ui.*` → `linux/modules/ui/`).
