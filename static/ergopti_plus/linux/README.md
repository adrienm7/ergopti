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

| Layer | Technology | Rationale |
|-------|-----------|-----------|
| Runtime | **LuaJIT 2.x** | Same language as the Hammerspoon driver; reuses all `_shared/lua/` modules directly. |
| Keyboard input | **/dev/input/eventN** (evdev) | Raw 24-byte `input_event` structs; works on X11, Wayland, and TTY identically. |
| Text injection | **ydotool** (uinput backend) | Works on both X11 and Wayland; no display-server coupling. |
| Key remapping + tap-hold | **kanata** | Rust daemon; reads `/dev/input` + writes `uinput`; already in the repo. |
| Notifications | **notify-send** | D-Bus `org.freedesktop.Notifications` — works on GNOME, KDE, XFCE, wlroots. |
| Tray icon | **StatusNotifierItem** (D-Bus) | De-facto Linux standard; KDE/Plasma, GNOME (with AppIndicator ext), wlroots. |
| HTTP | **curl** via io.popen | Zero extra dependencies; async path via lua-http planned. |

## Directory structure

```
linux/
  adapters/              9 port adapters (one per _shared/ports/*.spec.js)
  modules/
    hotstrings/
      engine.lua         Pure-Lua trigger matching (HotstringMatcher spec)
      loader.lua         TOML hotstring definition loader
      injector.lua       Backspace + text injection via ydotool
      input_reader.lua   Raw evdev binary reader (/dev/input/eventN)
      device_finder.lua  Auto-detect keyboard from /proc/bus/input/devices
    keylogger/
      metrics_collector.lua  WPM, n-grams, session stats (pure Lua)
  ergopti_hotstrings.lua Daemon entry point (CLI: --config --device --layout)
  install.sh             Standalone installer (apt/dnf/pacman)
  ergopti-hotstrings.service  systemd user unit
  bin/
    ergopti-hotstrings   Shell wrapper (sets LUA_PATH, checks deps)
  tests/
    helpers.lua          Assertion + describe/it harness
    run.lua              Auto-discovers test_*.lua recursively
    unit/meta/
      test_port_adapter_presence.lua
  vendor/                Bundled third-party Lua libs (not in git)
```

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
cd static/drivers/linux
luajit tests/run.lua
```

Requires LuaJIT 2.x. Plain Lua 5.4 works for the meta tests (no luv dependency).

## Installation

```bash
bash static/drivers/linux/install.sh
```

The installer detects apt/dnf/pacman, installs dependencies (luajit, ydotool,
kanata, libnotify-bin), copies files to `~/.local/lib/ergopti/`, and installs
a systemd user service.

## Known limitations by feature

| Feature | X11 | Wayland | Notes |
|---------|-----|---------|-------|
| Key remapping + tap-hold | ✅ kanata | ✅ kanata | Bypasses display server via `/dev/input` + `uinput` |
| Hotstrings + metrics | ✅ | ✅ | evdev read works on both; injection via ydotool |
| Text injection | ✅ ydotool | ✅ ydotool | Requires `ydotoold` daemon + uinput permissions |
| Window info (active app) | ✅ xdotool | ⚠️ compositor-specific | No universal Wayland protocol |
| Tray icon | ✅ SNI | ⚠️ partial | GNOME Wayland needs AppIndicator extension |
| Tooltip overlay | ✅ cairo window | ❌ protocol blocks it | Use notify-send as fallback on Wayland |
| Secure field detection | ⚠️ AT-SPI2 | ❌ not standardised | Keylogger disabled by default; opt-in only |
| Config UI | ➡️ ergopti.com WebUI | ➡️ same | No native GUI planned |

## Distribution support

Target distributions: **Ubuntu 22.04+, Fedora 38+, Arch Linux, Debian 12+**.

Requirements:
- `uinput` kernel module loaded (`modprobe uinput`)
- User in `input` group: `sudo usermod -aG input $USER` (re-login required)
- OR udev rule: `KERNEL=="uinput", GROUP="input", MODE="0660"`
- `ydotool` + `ydotoold` for text injection
- LuaJIT 2.1+ (available in all target distros)
