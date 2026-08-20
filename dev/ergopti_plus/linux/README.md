# Linux Driver

LuaJIT-based implementation of the ergopti hexagonal port adapters for Linux
desktop environments.

## How it works

```
┌──────────────────────────────────────────────────────────────────┐
│  Ergopti Linux — architecture overview                           │
│                                                                  │
│  Key remapping + tap-hold  →  kanata (/dev/input + uinput)       │
│  Hotstrings + keylogger    →  ergopti_hotstrings.lua (LuaJIT)    │
│    ├─ input_reader.lua     →  /dev/input/eventN (raw evdev)      │
│    ├─ engine.lua           →  trigger matching (pure Lua)        │
│    ├─ injector.lua         →  ydotool / uinput injection         │
│    └─ metrics_collector.lua→  WPM, n-grams, session stats        │
│  LLM expansions            →  HTTP → local Ollama                │
└──────────────────────────────────────────────────────────────────┘
```

### Why a native LuaJIT daemon and not espanso?

[espanso](https://espanso.org) is a good generic text expander, but ergopti
needs more than trigger→replacement:

- **Per-keystroke logging** for WPM metrics and n-gram analysis — espanso only
  sees triggers, not every key.
- **Configurable terminators** — whether space, tab, comma, or nothing triggers
  an expansion is a per-entry setting in ergopti's TOML; espanso has no
  equivalent.
- **Magic key** — ergopti's star-key combinator is a first-class concept with
  no espanso analogue.
- **Shared state with the keymap engine** — rolls, SFB reduction, and
  context-aware expansions need the same in-process state as tap-hold and layer
  switching.

The daemon reads raw `input_event` structs from `/dev/input/eventN` — the same
mechanism espanso uses internally — so the approach is identical, just in
LuaJIT instead of Rust.

## Stack

| Layer                    | Technology                     | Rationale                                                                            |
| ------------------------ | ------------------------------ | ------------------------------------------------------------------------------------ |
| Runtime                  | **LuaJIT 2.x**                 | Same language as the Hammerspoon driver; reuses all `_shared/lua/` modules directly. |
| Keyboard input           | **/dev/input/eventN** (evdev)  | Raw 24-byte `input_event` structs; works on X11, Wayland, and TTY identically.       |
| Text injection           | **ydotool** (uinput backend)   | Works on both X11 and Wayland; no display-server coupling.                           |
| Key remapping + tap-hold | **kanata**                     | Rust daemon; reads `/dev/input` + writes `uinput`; already in the repo.              |
| Notifications            | **notify-send**                | D-Bus `org.freedesktop.Notifications` — works on GNOME, KDE, XFCE, wlroots.          |
| Tray icon                | **StatusNotifierItem** (D-Bus) | De-facto Linux standard; KDE/Plasma, GNOME (with AppIndicator ext), wlroots.         |
| HTTP                     | **curl** via io.popen          | Zero extra dependencies; async path via lua-http planned.                            |

## Directory structure

```
linux/
  ergopti_hotstrings.lua      Daemon entry point (CLI: --config --device --layout --tray)
  adapters/                   22 files: the 20 port implementations + shell_runner + event_loop
  lib/                        6 files: file_watchers, i18n, locale, monotonic, timings, version
  modules/                    11 feature folders — see modules/README.md for the measured table
  ui/                         webkit_host.lua (WebKitGTK page builder)
  install.sh                  Standalone installer (apt/dnf/pacman)
  ergopti-hotstrings.service  systemd user unit
  bin/
    ergopti-hotstrings        Shell wrapper (sets LUA_PATH, checks deps)
  _generated/                 Codegen output
  tests/
    helpers.lua               Assertion + describe/it harness
    run.lua                   Auto-discovers test_*.lua under tests/unit
    unit/                     unit + meta tests
    e2e/run_e2e.lua           corpus-driven end-to-end harness
  vendor/                     Bundled third-party Lua libs (not in git)
```

> ⚠ **Eleven of the 22 adapters have no production consumer** (≈ 1 750 lines):
> `tooltip_renderer`, `graphics_renderer`, `window_manager`, `clipboard`,
> `secure_field_detector`, `network_info`, `mouse_control`, `notifier`, `key_state`,
> `app_launcher`, `crypto`. They are implemented and unit-tested but no Linux feature
> calls them, so there is currently no tooltip surface, no notification, no clipboard
> action and no window management on Linux. The `secure_field_detector` case is
> **deliberate** — see the comment at `modules/keylogger/keylogger.lua:90-98`:
> delegating to it would *narrow* password-app coverage and leak keystrokes.

## Running the daemon

```bash
# Auto-detect keyboard device and config dir
luajit ergopti_hotstrings.lua

# Explicit options
luajit ergopti_hotstrings.lua --device /dev/input/event3 \
                              --config ~/.config/ergopti/hotstrings/ \
                              --layout azerty

# Dry-run (log matches without injecting)
luajit ergopti_hotstrings.lua --dry-run --verbose
```

## Running the tests

```bash
cd static/ergopti_plus/linux
luajit tests/run.lua
```

Requires LuaJIT 2.x. Plain Lua 5.4 works for the meta tests (no luv dependency).

## Installation

```bash
bash static/ergopti_plus/linux/install.sh
```

The installer detects apt/dnf/pacman, installs dependencies (luajit, ydotool,
kanata, libnotify-bin), copies files to `~/.local/lib/ergopti/`, and installs
a systemd user service.

## Known limitations by feature

| Feature                  | X11                  | Wayland                | Notes                                               |
| ------------------------ | -------------------- | ---------------------- | --------------------------------------------------- |
| Key remapping + tap-hold | ✅ kanata            | ✅ kanata              | Bypasses display server via `/dev/input` + `uinput` |
| Hotstrings + metrics     | ✅                   | ✅                     | evdev read works on both; injection via ydotool     |
| Text injection           | ✅ ydotool           | ✅ ydotool             | Requires `ydotoold` daemon + uinput permissions     |
| Window info (active app) | ✅ xdotool           | ⚠️ compositor-specific | No universal Wayland protocol                       |
| Tray icon                | ✅ SNI               | ⚠️ partial             | Every packaged systemd unit passes `--tray` (pinned by `test:linux-package-layout`); a manual launch without it runs headless and says so in the log. GNOME Wayland also needs the AppIndicator extension |
| Tooltip overlay          | ❌ not implemented   | ❌ not implemented     | no hotstring preview, no LLM prediction preview. The `yad`/`zenity` adapter that existed for it was deleted under ADR-008: it had zero callers, so it was a claim rather than an implementation |
| Secure field detection   | ❌ not wired         | ❌ not standardised    | The AT-SPI adapter has no consumer; the only protection is a substring match on eight hardcoded app names, and the keylogger **cannot be turned off** |
| Config UI                | ⚠️ WebKitGTK, 3 of 14 windows | ⚠️ same       | `modules/ui/` hosts the shared webviews, but only `healthcheck`, `onboarding` and `hotstrings_config_window` are ever opened |

## Distribution support

Target distributions: **Ubuntu 22.04+, Fedora 38+, Arch Linux, Debian 12+**.

Requirements:

- `uinput` kernel module loaded (`modprobe uinput`)
- User in `input` group: `sudo usermod -aG input $USER` (re-login required)
- OR udev rule: `KERNEL=="uinput", GROUP="input", MODE="0660"`
- `ydotool` + `ydotoold` for text injection
- LuaJIT 2.1+ (available in all target distros)
