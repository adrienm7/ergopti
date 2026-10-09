# Linux Driver

LuaJIT-based implementation of the ergopti hexagonal port adapters for Linux
desktop environments.

## How it works

```
┌──────────────────────────────────────────────────────────────────┐
│  Ergopti Linux — architecture overview                           │
│                                                                  │
│  Key remapping + tap-hold  →  platform/remap/ (in the daemon)    │
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

| Layer                    | Technology                      | Rationale                                                                              |
| ------------------------ | ------------------------------- | -------------------------------------------------------------------------------------- |
| Runtime                  | **LuaJIT 2.x**                  | Same language as the Hammerspoon driver; reuses all `_shared/lua/` modules directly.   |
| Keyboard input           | **/dev/input/eventN** (evdev)   | Raw 24-byte `input_event` structs; works on X11, Wayland, and TTY identically.         |
| Text injection           | **ydotool** (uinput backend)    | Works on both X11 and Wayland; no display-server coupling.                             |
| Key remapping + tap-hold | **platform/remap/** (in-daemon) | Tap-hold engine in the keyboard hook; same evdev grab and `uinput` output as the rest. |
| Notifications            | **notify-send**                 | D-Bus `org.freedesktop.Notifications` — works on GNOME, KDE, XFCE, wlroots.            |
| Tray icon                | **StatusNotifierItem** (D-Bus)  | De-facto Linux standard; KDE/Plasma, GNOME (with AppIndicator ext), wlroots.           |
| HTTP                     | **curl** via io.popen           | Zero extra dependencies; async path via lua-http planned.                              |

## Directory structure

```
linux/
  ergopti_hotstrings.lua      Daemon entry point (CLI: --config --device --layout --tray)
  adapters/                   22 files: the 20 port implementations + shell_runner + event_loop
  lib/                        6 files: file_watchers, i18n, locale, monotonic, timings, version
  modules/                    11 feature folders — see modules/README.md for the measured table
  ui/                         webkit_host.lua (WebKitGTK page builder)
  install.sh                  Standalone installer (apt/dnf/pacman)
  uninstall.sh                Removes an owned installation; preserves personal data
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
> delegating to it would _narrow_ password-app coverage and leak keystrokes.

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

For Ubuntu, Zorin OS and Debian desktops, open the downloaded `.deb` in the
software installer and choose **Install**, then open Ergopti from the application
menu. The package installs its icon, dependencies, input permissions and startup
entries. The first launch refreshes the application's input groups without
requiring a terminal or a new login. If another desktop account launches it
later, a graphical administrator prompt grants that account the required access.

The `.rpm` provides the same permission setup on supported RPM desktops.
For an installation from the standalone archive or a source checkout:

```bash
bash static/ergopti_plus/linux/install.sh
```

The installer detects apt/dnf/pacman, installs dependencies (luajit,
libnotify-bin, …), copies files to `~/.local/lib/ergopti/`, and installs
a systemd user service.

### First use and automatic startup

The first graphical launch opens the setup wizard. Completing it saves your
choices; closing it without finishing offers it again at the next launch. You
can also reopen **Setup wizard** from the menu. The `.deb` requires the WebKitGTK
window dependencies so the wizard is available on a normal Zorin installation.

Use **Global actions → Start at login** to enable or disable automatic startup.
Disabling it leaves Ergopti running in the current session and applies to the
next login. Opening Ergopti manually does not turn automatic startup back on,
and reinstalling or updating preserves the choice made in this menu.

### Uninstallation

Choose **Version / Updates → Uninstall Ergopti…** in the tray menu and confirm.
Ergopti finishes saving its data and closes before removing the application.
Native packages request administrator authorization through the desktop.

For a standalone installation, the installed removal script is independent of
the directory from which it is called:

```bash
bash "$HOME/.local/lib/ergopti/linux/uninstall.sh" --yes
```

If installation used `--prefix`, pass that same absolute prefix to
`uninstall.sh --prefix "/your/prefix" --yes`. The script verifies its file
ownership record before removing the runtime, launcher and startup entries.
It retains unknown files and modified payload files, including personal files
inside the installation directory. A modified service must be reviewed before
removal, because it could now start a different application.

For a `.deb` or `.rpm` installation, remove **ergopti** through the distribution's
software manager. The command `bash /usr/lib/ergopti/uninstall.sh --yes` delegates
to the owning package manager with graphical administrator authentication.

Removal preserves configuration, hotstrings, metrics and credentials. It does
not remove shared dependencies, input groups, or the separately installed Ergopti
keyboard layout. Reinstalling the application can reuse the retained settings.

## Known limitations by feature

| Feature                  | X11          | Wayland                | Notes                                                                                                                                                                                                     |
| ------------------------ | ------------ | ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Key remapping + tap-hold | ✅ in-daemon | ✅ in-daemon           | Bypasses display server via `/dev/input` + `uinput`                                                                                                                                                       |
| Hotstrings + metrics     | ✅           | ✅                     | evdev read works on both; injection via ydotool                                                                                                                                                           |
| Text injection           | ✅ ydotool   | ✅ ydotool             | Requires `ydotoold` daemon + uinput permissions                                                                                                                                                           |
| Window info (active app) | ✅ xdotool   | ⚠️ compositor-specific | No universal Wayland protocol                                                                                                                                                                             |
| Tray icon                | ✅ SNI       | ⚠️ partial             | Every packaged systemd unit passes `--tray` (pinned by `test:linux-package-layout`); a manual launch without it runs headless and says so in the log. GNOME Wayland also needs the AppIndicator extension |
| Tooltip overlay          | ✅ GTK       | ✅ GTK                 | Hotstring previews and selectable LLM suggestions share the focus-free tooltip renderer                                                                                                                   |
| Secure field detection   | ✅ AT-SPI    | ✅ AT-SPI              | Secure applications, private windows and focused password fields suppress capture and prediction; an inconclusive focus probe fails closed                                                                |
| Config UI                | ✅ WebKitGTK | ✅ WebKitGTK           | Shared configuration, diagnostics, onboarding, metrics and editor pages are routed through page-scoped bridges                                                                                            |

## Distribution support

Target distributions: **Ubuntu 22.04+, Fedora 38+, Arch Linux, Debian 12+**.

Requirements:

- `uinput` kernel module loaded (`modprobe uinput`)
- User in `input` group: `sudo usermod -aG input $USER` (re-login required)
- OR udev rule: `KERNEL=="uinput", GROUP="input", MODE="0660"`
- `ydotool` + `ydotoold` for text injection
- LuaJIT 2.1+ (available in all target distros)

## Managed HTTP redirect admission

`adapters.http_client.get` and the default `get_owned` preserve the historical
credential-header no-follow policy. `follow_redirects=true` retains the original
origin's HTTP response when the shared credential inventory forbids native
following; empty credential fields also count as present. An observed HTTPS
downgrade stays refused and returns the original HTTP redirect status/error.

A caller deliberately owning the complete buffered GET hop sequence may pass
`managed_redirects=true` to `get_owned`, together with `follow_redirects=true`.
This strictly Boolean option requires that owned buffered GET port and excludes
path output, ETag and archive output targets. The shared transition then resolves
each exact hop under the original deadline, waits for actual prior-child
retirement and strips canonical credentials at an origin boundary. HTTPS
downgrade, malformed metadata and unsafe destinations remain strict managed
refusals. The option is captured under the native reservation; changing the
caller's options later cannot opt another operation in. Other ports refuse this
opt-in before acquiring a transport. Archive output already owns a separate
`archive_redirects` contract and never borrows buffered GET permission.
