<div align="center">

<img src="static/img/logo/logo_simple.svg" alt="Ergopti logo" width="90" />

# Ergopti

**An ergonomic keyboard layout optimised for French, English and code —
and Ergopti+, the free, local-first typing-automation suite that works on _any_ layout.**

[![CI](https://github.com/adrienm7/ergopti/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/adrienm7/ergopti/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/adrienm7/ergopti)](https://github.com/adrienm7/ergopti/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Website](https://img.shields.io/badge/website-ergopti.fr-31beff)](https://ergopti.fr)

**[ergopti.fr](https://ergopti.fr)** — interactive demo, documentation, online emulator ·
**[ergopti.fr/ergopti-plus](https://ergopti.fr/ergopti-plus)** — the Ergopti+ tour

</div>

---

## Table of contents

- [The Ergopti layout](#the-ergopti-layout)
- [The Ergopti+ suite](#the-ergopti-suite)
  - [See it in action](#see-it-in-action)
- [Installation](#installation)
  - [Install the layout](#install-the-layout)
  - [Install Ergopti+](#install-ergopti)
- [Try it in your browser](#try-it-in-your-browser)
- [Repository layout](#repository-layout)
- [Development](#development)
  - [Website (SvelteKit)](#website-sveltekit)
  - [Windows driver (AutoHotkey v2)](#windows-driver-autohotkey-v2)
  - [macOS driver (Hammerspoon)](#macos-driver-hammerspoon)
  - [Linux driver (alpha)](#linux-driver-alpha)
  - [Tests and quality gates](#tests-and-quality-gates)
- [CI and releases](#ci-and-releases)
- [Website deployment](#website-deployment)
- [Contributing](#contributing)
- [License](#license)

---

## The Ergopti layout

An open-source keyboard layout designed to minimise finger travel and same-finger
bigrams while remaining immediately usable — numbers stay on the top row, and the
most common shortcuts (<kbd>Ctrl</kbd>+<kbd>A/C/V/X/Z</kbd>) stay on the left hand.

![Base layer](static/img/ergopti_visuel.jpg)

|                        |                                                                              |
| ---------------------- | ---------------------------------------------------------------------------- |
| **Languages**          | French · English · Code                                                      |
| **Platforms**          | Windows · macOS · Linux                                                      |
| **Numbers**            | Direct access on the top row                                                 |
| **AltGr layer**        | Programming symbols, logically placed                                        |
| **Special characters** | Full French typographic support (accented capitals, ligatures, punctuation…) |

**AltGr layer** — programming symbols grouped for memorability:

![AltGr layer](static/img/ergopti_altgr.jpg)

**Ctrl layer** — standard shortcuts preserved on the left side:

![Ctrl layer](static/img/ergopti_ctrl.jpg)

---

## The Ergopti+ suite

Ergopti+ is the companion software — a complete typing-automation layer that runs
on **any** layout (AZERTY, QWERTY, Bépo, …). The Ergopti layout unlocks extra
bonuses, but is entirely optional. Everything is **free, open-source and
local-first, with no account and no telemetry**: typing data never leaves the
machine, and the AI runs locally or through the API you choose.

![Base layer +](static/img/ergopti_plus.jpg)

| Feature                  |                                                                                                                                             |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------- |
| **Hotstrings**           | ~3 000 ready-made corrections and expansions, plus your own — with the magic <kbd>★</kbd> key (`pex★` → `par exemple`, `el★e` → `elle`)     |
| **Local AI predictions** | Sentence completion and correction via Ollama or MLX (Apple Silicon), 110-model curated catalogue; optional remote APIs with encrypted keys |
| **Tap-holds**            | 7 default dual-role keys (tap = action, hold = modifier) + a home-row navigation layer                                                      |
| **Trackpad gestures**    | 36 gesture slots + 3 continuous axes on macOS (10 slots on Windows)                                                                         |
| **Typing metrics**       | Local SQLite dashboards (WPM over time, delegated keystrokes, n-grams, heatmaps) + a floating live WPM widget                               |
| **Fully configurable**   | 335 settings, 21 interface languages, every feature optional and toggleable from the menu                                                   |

The three drivers share a single source of truth (`static/ergopti_plus/_shared/`)
for hotstrings, the LLM catalogue, locales, menus and webview UIs — so Windows,
macOS and Linux behave the same by construction.

### See it in action

Each clip is rendered from the driver's own windows and data by the
[`video/`](video/STORYBOARD.md) project, so it shows the current UI.

<table>
<tr>
<td width="50%"><b>Works on every system</b><br><img src="static/media/ergopti_plus/three-os.gif" alt="Hotstrings firing on Windows, macOS and Linux"></td>
<td width="50%"><b>The tray menu</b><br><img src="static/media/ergopti_plus/menu.gif" alt="Every feature in the tray menu"></td>
</tr>
<tr>
<td width="50%"><b>Tap-holds</b><br><img src="static/media/ergopti_plus/tap-holds.gif" alt="One key with a tap action and a hold action"></td>
<td width="50%"><b>Navigation layer</b><br><img src="static/media/ergopti_plus/nav-layer.gif" alt="Arrows, words and selections on the home row"></td>
</tr>
<tr>
<td width="50%"><b>Shortcuts</b><br><img src="static/media/ergopti_plus/shortcuts.gif" alt="Win + letter shortcuts, each re-assignable"></td>
<td width="50%"><b>Wrap any selection</b><br><img src="static/media/ergopti_plus/shortcut-wrap.gif" alt="Typing a bracket or a quote wraps the selected text"></td>
</tr>
<tr>
<td width="50%"><b>Trackpad gestures</b><br><img src="static/media/ergopti_plus/gestures.gif" alt="Three-finger tap and swipe gestures"></td>
<td width="50%"><b>Your own hotstrings</b><br><img src="static/media/ergopti_plus/personal-hotstrings.gif" alt="Creating a hotstring in the editor, then using it"></td>
</tr>
<tr>
<td width="50%"><b>A few keys, a whole phrase</b><br><img src="static/media/ergopti_plus/extreme-hotstrings.gif" alt="Short abbreviations and an AI prediction writing a sentence"></td>
<td width="50%"><b>Typing metrics</b><br><img src="static/media/ergopti_plus/metrics.gif" alt="The typing metrics dashboard: savings, speed, words, shortcuts"></td>
</tr>
<tr>
<td width="50%"><b>Screen time</b><br><img src="static/media/ergopti_plus/screen-time.gif" alt="Time spent per application"></td>
<td width="50%"><b>AI predictions</b><br><img src="static/media/ergopti_plus/ai-predictions.gif" alt="A prediction tooltip fixing and completing a sentence"></td>
</tr>
<tr>
<td width="50%"><b>AI in every app</b><br><img src="static/media/ergopti_plus/ai-everywhere.gif" alt="Predictions in a terminal, an IDE, a browser, Teams and WhatsApp"></td>
<td width="50%"><b>Local models or an API</b><br><img src="static/media/ergopti_plus/ai-local.gif" alt="The model catalogue window"></td>
</tr>
<tr>
<td width="50%"><b>Rewrite, translate, ask</b><br><img src="static/media/ergopti_plus/ai-actions.gif" alt="AI actions on a selected sentence"></td>
<td></td>
</tr>
</table>

---

## Installation

Ergopti (the layout) and Ergopti+ (the software) install independently — use
either without the other, or both together for the maximum gain.

### Install the layout

Follow the per-OS instructions (installers, keylayout bundle, XKB files) at
**[ergopti.fr/utilisation](https://ergopti.fr/utilisation)**.

### Install Ergopti+

**→ Download from the [latest release](https://github.com/adrienm7/ergopti/releases/latest)**

**Windows — `ErgoptiPlus.exe`**

A compiled AutoHotkey v2 executable; the AHK runtime is embedded, nothing else to
install.

1. Download `ErgoptiPlus.exe` and double-click it.
2. On first launch, resources are extracted to `%LOCALAPPDATA%\Ergopti`.

**macOS — `ErgoptiPlus.app.zip`**

A self-contained app bundling Hammerspoon. On first run, it downloads and
installs Karabiner-Elements when it is missing. The AI runtimes are not
bundled: the first time you select the Ollama backend, the app reuses an
installed Ollama or offers to download the official release, and the first
time you select the MLX backend, it installs its Python runtime.

With [Homebrew](https://brew.sh), pick the stable or the dev channel:

```bash
brew tap adrienm7/ergopti
brew install --cask ergoptiplus        # stable releases
brew install --cask ergoptiplus@dev   # every dev prerelease
```

`brew upgrade` updates it with your other casks, and the app still updates
itself from its About menu and its automatic checks; see [Homebrew](static/ergopti_plus/macos/README.md#install-with-homebrew)
for switching channels and uninstalling.

Or by hand:

1. Download `ErgoptiPlus.app.zip`, unzip, move the app to `/Applications`.
2. Remove the quarantine flag (the app is not Apple-notarised yet):
   ```bash
   xattr -dr com.apple.quarantine /Applications/ErgoptiPlus.app
   ```

Then launch it. On first run, Karabiner-Elements asks for a System Extension
approval — required for key remapping.

**Linux — alpha**

The Linux driver (a Lua daemon, tap-holds included) is feature-complete on paper
but still looking for its first real-world testers. Grab a Linux package (.deb,
.rpm, AppImage or Flatpak) from the release and see [`static/ergopti_plus/linux/`](static/ergopti_plus/linux/) — feedback via
[issues](https://github.com/adrienm7/ergopti/issues) is very welcome.

---

## Try it in your browser

No install needed: **[ergopti.fr/utilisation#clavier_emulation](https://ergopti.fr/utilisation#clavier_emulation)**
emulates the layout (including the Ergopti+ magic key) directly on the website.

---

## Repository layout

```text
src/                      SvelteKit website (ergopti.fr)
static/ergopti_plus/      The Ergopti+ driver suite
  windows/                AutoHotkey v2 driver (entry: ErgoptiPlus.ahk)
  macos/                  Hammerspoon driver (entry: init.lua) + bundled apps
  linux/                  Lua daemon, tap-hold engine included (alpha)
  _shared/                Cross-driver single source of truth
                          (hotstrings TOML, LLM catalogue, locales, menus, webview UIs…)
static/ergopti/           Ergopti layout artefacts (keylayout, XKB, XCompose)
static/drivers/           Driver support assets (alfred, espanso, kalamine)
tools/                    Build, codegen, lint and test tooling
docs/                     Engineering docs — start with docs/memory/README.md
video/                    Remotion promo film and README GIFs, rendered from the
                          driver's own windows and data (see video/README.md)
```

---

## Development

### Website (SvelteKit)

Requires **Node 22.22+** (or 24.15+ / 26+).

```bash
git clone https://github.com/adrienm7/ergopti.git
cd ergopti
npm install
npm run dev            # dev server at http://localhost:5173
npm run dev -- --open  # …and open the browser
npm run build          # production build (static site)
npm run preview        # preview the production build
```

The keyboard visualiser is built from scratch: a 16×7 grid of empty keys filled
from JSON according to the geometry, the active layer, and whether Ergopti+ is
enabled.

### Windows driver (AutoHotkey v2)

Install [AutoHotkey v2](https://www.autohotkey.com/), then run the driver
straight from the clone:

```powershell
AutoHotkey64.exe static\ergopti_plus\windows\ErgoptiPlus.ahk
```

Source files are UTF-8 **with BOM** + LF — run `npm run test:ahk-encoding` after
editing `.ahk` files.

### macOS driver (Hammerspoon)

To iterate on the macOS driver from this clone without rebuilding the app:

1. Install stock [Hammerspoon](https://www.hammerspoon.org/) into `/Applications`.
2. From the repo root, run once:
   ```bash
   npm run install:hammerspoon
   ```
3. Launch Hammerspoon — the driver now boots from your local clone. After edits,
   press <kbd>Cmd</kbd>+<kbd>Ctrl</kbd>+<kbd>R</kbd> to reload.

The installer is idempotent; any pre-existing `~/.hammerspoon/init.lua` is backed
up first. **Don't run stock Hammerspoon and the bundled `ErgoptiPlus.app` at the
same time** — they compete for the same event taps.

### Linux driver (alpha)

The daemon lives in [`static/ergopti_plus/linux/`](static/ergopti_plus/linux/)
(entry: `ergopti_hotstrings.lua`, launcher: `bin/ergopti-hotstrings`). It runs
the tap-holds and the navigation layer itself, in its keyboard hook
(`platform/remap/`); no external remapper is needed.

**Runtime — LuaJIT.** The test suite runs on any Lua (`npm run test:linux` probes
`luajit`, then `lua5.4`, then `lua`), but the daemon binds `/dev/uinput`,
`nanosleep` and `libayatana-appindicator` through FFI, so LuaJIT is what actually
runs it.

**1. Dependencies**

```bash
bash static/ergopti_plus/linux/install.sh             # deps, files, permissions, autostart
bash static/ergopti_plus/linux/install.sh --no-deps   # …same, minus the package installs
```

| Package                         | Without it                                                                                                                                                                                                                                                         |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `luajit`                        | the launcher refuses to start                                                                                                                                                                                                                                      |
| `libnotify` (`notify-send`)     | the launcher refuses to start                                                                                                                                                                                                                                      |
| `libxkbcommon-tools` (`xkbcli`) | no keymap source on Wayland without XWayland, so the keyboard is refused; before libxkbcommon 1.8 (Ubuntu 24.04, Debian 12) the keymap is read from XWayland (`xkbcomp`) or compiled from the session's layout names (GNOME, Plasma, `XKB_DEFAULT_*`, `localectl`) |
| `libayatana-appindicator3`      | `--tray` has nothing to host the icon in                                                                                                                                                                                                                           |
| `lua-luv`                       | no inotify — the loop falls back to an FFI sleep and file watching to `stat()` polling                                                                                                                                                                             |
| `lua-posix`                     | no `SIGTERM`/`SIGHUP` handlers, and no `stat()` polling to fall back on                                                                                                                                                                                            |
| `lua-lgi`                       | no typing-speed pill and no WebKit2GTK windows                                                                                                                                                                                                                     |
| `lua-filesystem`                | existence checks fall back from `stat()` to opening the path                                                                                                                                                                                                       |

`install.sh` installs every row, plus the WebKit2GTK typelib the tray's windows
are drawn with, and on GNOME the AppIndicator shell extension — GNOME shows no
tray icon without one (Ubuntu enables its own; Fedora and Debian GNOME do not). The tray and window backends are best effort — a headless
machine still gets working hotstrings — but each is re-probed after its package
is installed and reported when it stays unavailable. Every Lua library is loaded
through `pcall(require, …)`, so a bare box starts and silently does less rather
than failing. The Lua modules are installed as LuaJIT (Lua 5.1 ABI) builds —
`lua51-*` on Arch, `luajit-*` on openSUSE, `lua5.1-*` on Alpine and Fedora —
because the generic `lua-*` packages there are Lua 5.4 builds LuaJIT cannot
load. **Known limitation:** Fedora packages `lgi` for Lua 5.4 only, so there the
tray icon and hotstrings work but the tray's WebKit windows (settings, editor,
metrics) cannot open.

**2. Permissions** — this is where people get stuck

The daemon reads `/dev/input/eventN` and writes `/dev/uinput`, and a normal user
may do neither. `install.sh` handles it; re-run just that part (after a kernel
update, say) with:

```bash
bash static/ergopti_plus/linux/install.sh --setup-perms
```

It adds you to **both** `input` and `uinput`, drops `uinput` into
`/etc/modules-load.d/`, and writes `/etc/udev/rules.d/99-ergopti-uinput.rules`:

```udev
KERNEL=="uinput", MODE="0660", GROUP="uinput", OPTIONS+="static_node=uinput"
```

`static_node=uinput` is **not** optional: `/dev/uinput` does not exist until the
module is loaded, so a rule without it matches nothing on a fresh boot and the
permissions look as though they were never applied. Log out and back in
afterwards — group membership is only read at session start. Note that `input`
grants read access to every keystroke of the session; that is what a hotstring
engine needs, and it is why `uaccess` is deliberately not used here.

**3. Run it from the clone**

```bash
cd static/ergopti_plus/linux
luajit ergopti_hotstrings.lua --dry-run    # log matches, inject nothing
luajit ergopti_hotstrings.lua --tray       # the real thing, with a tray icon
```

`bin/ergopti-hotstrings` does the same after exporting `LUA_PATH`, but it prefers
an installed tree if `/usr/lib/ergopti` exists — call the entry file directly
when iterating on a checkout. With no `~/.config/ergopti/hotstrings/`, the daemon
falls back to the TOML definitions bundled in `_shared/modules/hotstrings/`.

| Flag                      | Effect                                                                                            |
| ------------------------- | ------------------------------------------------------------------------------------------------- |
| `--config <path>`         | TOML file or directory (default `~/.config/ergopti/hotstrings/`)                                  |
| `--device <path>`         | evdev device to listen on; auto-detected when omitted                                             |
| `--layout qwerty\|azerty` | INPUT layout, keycode → character (default: `$XKBLAYOUT`)                                         |
| `--keymap <path>`         | OUTPUT keymap dump, for a session whose layout cannot be probed                                   |
| `--tray`                  | system tray icon                                                                                  |
| `--no-grab`               | observe instead of grabbing — physical keys then interleave with an expansion and can scramble it |
| `--dry-run`               | log matches without injecting                                                                     |
| `--verbose`, `-v`         | log at debug level for that run                                                                   |
| `--help`, `-h`            | usage                                                                                             |

**4. Before trusting it on your own keyboard**

The driver is alpha and has never been validated on real hardware.
[`HARDWARE.md`](static/ergopti_plus/linux/HARDWARE.md) is the checklist for
everything CI cannot answer — capture under X11 and Wayland, the keymap dump, the
grab, the tray — and most of it is scripted:

```bash
bash static/ergopti_plus/linux/tests/hardware/validate.sh
```

### Tests and quality gates

| Suite                     | Command                                                         |
| ------------------------- | --------------------------------------------------------------- |
| Site + cross-driver gates | `npm run test:js`                                               |
| macOS driver (Lua)        | `cd static/ergopti_plus/macos && lua tests/run.lua`             |
| Windows driver (AHK)      | run `static/ergopti_plus/windows/tests/run_all.ahk` with AHK v2 |
| Linux driver              | `npm run test:linux`                                            |

House rules: every bug fix ships with a regression test, and the shared
constants between drivers are pinned by single-source parity tests — see
[docs/memory/README.md](docs/memory/README.md) for the accumulated engineering
knowledge.

---

## CI and releases

[`ci.yml`](.github/workflows/ci.yml) runs on every push to `main` or `dev`, on
every pull request into them, and on manual dispatch:

1. **Validate and plan** is the single root of the run graph. It first runs
   the repository-wide gates: hotstring TOML formatting, the property tests,
   the mutation tests (on `main` only) and `npm run test:js`. Then it reads the
   git tags and commit subjects and decides whether the run publishes, and with
   which tag, version and update channel.
2. Once it passes, three lanes run in parallel, one reusable workflow per OS:
   **macOS** ([`ci-macos.yml`](.github/workflows/ci-macos.yml)), **Windows**
   ([`ci-windows.yml`](.github/workflows/ci-windows.yml)) and **Linux**
   ([`ci-linux.yml`](.github/workflows/ci-linux.yml)). Each lane starts with
   its driver's `tests` job (`tests (stubbed)` on macOS, whose tests run on
   Ubuntu against a stubbed Hammerspoon) and continues with its `package` job.
   The macOS lane then launches the package over realistic user states; the
   Linux lane installs and runs the `.deb`, the `.rpm` and the AppImage and
   installs the driver on several distributions, then checks every result in
   its `evidence gate`; the Windows lane packages on a release run only. On a
   release run, each lane builds the files that will be published, checks
   those exact files, and uploads them.
3. **Release** runs only when the plan says the run publishes and all three
   lanes succeeded. It creates the tag and the GitHub release with every
   platform's files and an auto-generated changelog, then publishes the macOS
   Sparkle update feed.

```text
Validate and plan ─┬─ macOS / tests (stubbed) ─ package ─ launch (matrix) ─────┬─ Release
                   ├─ Windows / tests ─ package ───────────────────────────────┤
                   └─ Linux / tests ─ package ─ run the .deb, run the .rpm,    │
                                                run the AppImage, install,     │
                                                first install ─ evidence gate ─┘
```

Each lane has one entry job and one exit job, so the run graph draws one line
per OS; Release also reads the plan from the root.

**Channels:** a push to `main` publishes a stable release (`vX.Y.Z`); a push to
`dev` publishes a pre-release, `v0.0.0-dev.N`, one past the last dev tag. If the
tag already exists, or a tag of its branch already contains the commit (an older
commit, a re-run of one that was published, or one a force push left behind),
the run is a plain CI run and publishes nothing. When Release fails part-way,
_Re-run failed jobs_ on that run resumes it: it reuses a tag or a published
release that an earlier attempt created and finishes the update feed and the
release notes. If a newer release of the channel was published in the
meantime, nothing more is published, except the notes of a release that already
exists; the newer update feed stays.

**Version bump** on `main` (from conventional commit subjects since the last
stable tag):

| Condition                                       | Bump  |
| ----------------------------------------------- | ----- |
| Subject contains `BREAKING:` or `!:` (`feat!:`) | Major |
| At least one `feat:` commit                     | Minor |
| Only `fix:`, `perf:`, `refactor:`, …            | Patch |

---

## Website deployment

[`deploy-site.yml`](.github/workflows/deploy-site.yml) publishes the site to
GitHub Pages (branch mode, `gh-pages`) whenever site-relevant paths change:

| Branch | URL                                        |
| ------ | ------------------------------------------ |
| `main` | [ergopti.fr](https://ergopti.fr)           |
| `dev`  | [ergopti.fr/dev/](https://ergopti.fr/dev/) |

Each push rebuilds only the pushed branch's subdirectory, so the two stay
independent.

---

## Contributing

Issues and PRs are welcome — in **English**, so everyone can collaborate.

- Read [CONTRIBUTING.md](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md) (shared
  agent/tooling index) first.
- Commits follow [Conventional Commits](https://www.conventionalcommits.org/);
  `main` and `dev` keep a **linear history** (squash, no merge commits).
- Non-obvious lessons about the codebase belong in
  [docs/memory/README.md](docs/memory/README.md) so they never evaporate.

---

## License

[MIT](LICENSE) © Adrien MOYAUX
