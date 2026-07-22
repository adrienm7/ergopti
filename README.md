<div align="center">

<img src="static/img/logo/logo_simple.svg" alt="Ergopti logo" width="90" />

# Ergopti

**An ergonomic keyboard layout optimised for French, English and code —
and Ergopti+, the free, 100 % local typing-automation suite that works on _any_ layout.**

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
bonuses, but is entirely optional. Everything is **free, open-source, local-only,
with no account and no telemetry**.

![Base layer +](static/img/ergopti_plus.jpg)

| Feature                  |                                                                                                                                              |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| **Hotstrings**           | ~3 000 ready-made corrections and expansions, plus your own — with the magic <kbd>★</kbd> key (`pex★` → `par exemple`, `el★e` → `elle`)      |
| **Local AI predictions** | Sentence completion and correction via Ollama or MLX (Apple Silicon), 110-model curated catalogue; optional remote APIs with encrypted keys   |
| **Tap-holds**            | 7 default dual-role keys (tap = action, hold = modifier) + a home-row navigation layer                                                        |
| **Trackpad gestures**    | 36 gesture slots + 3 continuous axes on macOS (10 slots on Windows)                                                                           |
| **Typing metrics**       | Local SQLite dashboards (WPM over time, delegated keystrokes, n-grams, heatmaps) + a floating live WPM widget                                 |
| **Fully configurable**   | 335 settings, 21 interface languages, every feature optional and toggleable from the menu                                                     |

The three drivers share a single source of truth (`static/ergopti_plus/_shared/`)
for hotstrings, the LLM catalogue, locales, menus and webview UIs — so Windows,
macOS and Linux behave the same by construction.

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

A self-contained app bundling Hammerspoon and Karabiner-Elements.

1. Download `ErgoptiPlus.app.zip`, unzip, move the app to `/Applications`.
2. Remove the quarantine flag (the app is not Apple-notarised yet):
   ```bash
   xattr -dr com.apple.quarantine /Applications/Ergopti.app
   ```
3. Launch it. On first run, Karabiner-Elements asks for a System Extension
   approval — required for key remapping.

**Linux — alpha**

The Linux driver (kanata + a Lua daemon) is feature-complete on paper but still
looking for its first real-world testers. Grab `kanata.kbd` from the release and
see [`static/ergopti_plus/linux/`](static/ergopti_plus/linux/) — feedback via
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
  linux/                  Lua daemon + kanata integration (alpha)
  _shared/                Cross-driver single source of truth
                          (hotstrings TOML, LLM catalogue, locales, menus, webview UIs…)
static/drivers/           Ergopti layout artefacts (keylayout, XKB, …)
tools/                    Build, codegen, lint and test tooling
docs/                     Engineering docs — start with docs/PROJECT_MEMORY.md
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
(entry: `ergopti_hotstrings.lua`, launcher: `bin/ergopti-hotstrings`) and pairs
with [kanata](https://github.com/jtroo/kanata) for tap-holds. Read the header of
the entry file before running — the driver is untested on real hardware.

### Tests and quality gates

| Suite                       | Command                                                             |
| --------------------------- | ------------------------------------------------------------------- |
| Site + cross-driver gates   | `npm run test:js`                                                   |
| macOS driver (Lua)          | `cd static/ergopti_plus/macos && lua tests/run.lua`                 |
| Windows driver (AHK)        | run `static/ergopti_plus/windows/tests/run_all.ahk` with AHK v2     |
| Linux driver                | `npm run test:linux`                                                |

House rules: every bug fix ships with a regression test, and the shared
constants between drivers are pinned by single-source parity tests — see
[docs/PROJECT_MEMORY.md](docs/PROJECT_MEMORY.md) for the accumulated engineering
knowledge.

---

## CI and releases

Every push to `main` or `dev` runs the unified [`ci.yml`](.github/workflows/ci.yml)
pipeline: validation gates (hotstrings, domain, JS, translations), the three
driver suites, then — once everything is green — automated SemVer release builds
for all platforms with an auto-generated changelog.

**Version bump** (from conventional commit types since the last tag):

| Condition                                          | Bump  |
| -------------------------------------------------- | ----- |
| Subject contains `BREAKING` or uses `!` (`feat!:`) | Major |
| At least one `feat:` commit                        | Minor |
| Only `fix:`, `perf:`, `refactor:`, …               | Patch |

**Channels:** `main` cuts stable releases (`v0.6.7`); `dev` cuts pre-releases
(`v0.7.0-dev.{run}`); a commit message containing `alpha`/`beta` selects those
channels.

---

## Website deployment

[`deploy-site.yml`](.github/workflows/deploy-site.yml) publishes the site to
GitHub Pages (branch mode, `gh-pages`) whenever site-relevant paths change:

| Branch | URL                                              |
| ------ | ------------------------------------------------ |
| `main` | [ergopti.fr](https://ergopti.fr)                 |
| `dev`  | [ergopti.fr/dev/](https://ergopti.fr/dev/)       |

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
  [docs/PROJECT_MEMORY.md](docs/PROJECT_MEMORY.md) so they never evaporate.

---

## License

[MIT](LICENSE) © Adrien MOYAUX
