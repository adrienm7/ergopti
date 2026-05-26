# Ergopti

**An ergonomic keyboard layout optimised for French, English, and code.**

![Base layer](static/img/ergopti_visuel.jpg)

➜ **[ergopti.fr](https://ergopti.fr)** — interactive demo, full documentation, online emulator

---

## Overview

Ergopti is an open-source keyboard layout designed to minimise finger travel and same-finger bigrams while remaining immediately usable — numbers stay on the top row, and the most common shortcuts (<kbd>Ctrl</kbd>+<kbd>A/C/V/X/Z</kbd>) are kept on the left side of the keyboard.

| | |
|---|---|
| **Languages** | French · English · Code |
| **Licence** | MIT |
| **Platforms** | macOS · Windows · Linux |
| **Numbers** | Direct access on top row |
| **AltGr layer** | Programming symbols, logically placed |
| **Special characters** | Full French typographic support (accented capitals, ligatures, punctuation…) |

---

## Install

**→ Download the [latest release](https://github.com/adrienm7/ergopti/releases/latest)**

### macOS — ErgoptiPlus.app

The macOS release is a self-contained app that bundles Hammerspoon and Karabiner-Elements. No separate installs required.

1. Download `ErgoptiPlus.app.zip` and unzip it.
2. Move `Ergopti.app` to `/Applications`.
3. Remove the quarantine flag (the app is not Apple-notarised yet):
   ```bash
   xattr -dr com.apple.quarantine /Applications/Ergopti.app
   ```
4. Launch the app. On first run, Karabiner-Elements will ask for a System Extension approval — this is required for key remapping.

### Windows — ErgoptiPlus.exe

The Windows release is a compiled AutoHotkey v2 executable. The AHK runtime is embedded; no separate installation needed.

1. Download `ErgoptiPlus.exe`.
2. Double-click to run. On first launch, resources are extracted to `%LOCALAPPDATA%\Ergopti`.

### Linux

The Linux driver (XKB) is served from the website. Follow the instructions at **[ergopti.fr/utilisation](https://ergopti.fr/utilisation)**.

---

## Ergopti+

Ergopti+ is the extended variant of the layout. It goes far beyond a simple key remapping — it is a complete typing automation layer that eliminates friction at every level.

![Base layer +](static/img/ergopti_plus.jpg)

### Repeat key <kbd>★</kbd>

A dedicated repeat key eliminates double-letter awkwardness. Typing <kbd>el★e</kbd> produces `elle`; <kbd>★</kbd> always repeats the last character. No more same-finger rolls for doubles.

### Abbreviation expansion

The same <kbd>★</kbd> key doubles as an abbreviation trigger. Type a short code and press <kbd>★</kbd> to expand it — for example `pex★` → `par exemple`. Hundreds of built-in expansions, fully customisable.

### SFB elimination

All remaining same-finger bigrams are resolved via smart substitutions. For instance, pressing <kbd>,t</kbd> outputs `pt` — the layout silently routes around any uncomfortable finger combination.

### Smart <kbd>q</kbd>

The <kbd>q</kbd> key automatically outputs `qu` when followed by a vowel — covering the overwhelming majority of French usage — and outputs `q` in all other contexts. No extra keystrokes.

### Tap-holds

Keys have a secondary function when held. Tap for the letter, hold for a modifier, a layer switch, or a shortcut. Eliminates the need to reach for dedicated modifier keys in many situations.

### Comfort rolls

New rolling sequences are introduced to turn common bigrams into inward rolls. For example, <kbd>hc</kbd> outputs `wh`. These additions are chosen for frequency and ergonomic benefit, not arbitrary remapping.

### And more

- Navigation layer accessible from the home row
- Local LLM integration (on macOS, via the bundled Ollama)
- System tray icon with live status and toggle controls
- Auto-update via Sparkle (macOS) / built-in updater (Windows)

➜ Try the layout in the browser: **[ergopti.fr/utilisation#clavier_emulation](https://ergopti.fr/utilisation#clavier_emulation)**

---

## Layers

**AltGr layer** — programming symbols, logically grouped for memorability:

![AltGr layer](static/img/ergopti_altgr.jpg)

**Ctrl layer** — standard shortcuts preserved on the left side:

![Ctrl layer](static/img/ergopti_ctrl.jpg)

---

## Website development

The project website runs on [SvelteKit](https://kit.svelte.dev/). The keyboard visualiser is built from scratch: a 16×7 grid of empty keys is filled from a JSON file according to the geometry, the active layer, and whether Ergopti+ is enabled.

### Setup

```bash
git clone https://github.com/adrienm7/ergopti.git
cd ergopti
npm install
```

### Dev server

```bash
npm run dev          # start at http://localhost:5173
npm run dev -- --open  # start and open in browser
```

### Production build

```bash
npm run build
npm run preview      # preview the production build locally
```

Deploying to a specific host may require installing the matching SvelteKit adapter.

## Hammerspoon driver — local dev (macOS)

To iterate on the macOS driver from this clone without re-building the production app:

1. Install stock [Hammerspoon](https://www.hammerspoon.org/) into `/Applications/Hammerspoon.app`.
2. From the repo root, run once:

```bash
npm run install:hammerspoon
# or directly: bash scripts/install-hammerspoon.sh
```

3. Launch Hammerspoon (menubar icon appears). The driver now boots from your local clone.

After edits, press `Cmd+Ctrl+R` (the bootstrap binds it to `hs.reload()`) — or click "Reload Config" from the menubar.

The installer is idempotent. Any pre-existing `~/.hammerspoon/init.lua` is backed up to `~/.hammerspoon/init.lua.backup.<timestamp>` before the new one is written; delete the new file and rename the backup to revert.

**Coexistence with the production app**: stock Hammerspoon (`org.hammerspoon.Hammerspoon`, reads `~/.hammerspoon/`) and the bundled `ErgoptiPlus.app` (`com.ergoptiplus.app`, reads its own `Contents/Resources/config/`) have isolated preferences and config directories. Launching one or the other selects which version of the driver runs — don't run both menubar icons at the same time (they would compete for the same OS-level event taps and hotkeys).

---

## CI & Releases

### Automated versioning

Every push to `main` or `dev` triggers [`version.yml`](.github/workflows/version.yml), which calculates the next [SemVer](https://semver.org/) tag from the commit history and pushes it automatically. The tag then triggers [`release.yml`](.github/workflows/release.yml) to build and publish the release.

**Bump rules** (from conventional commit types since the last tag):

| Condition | Bump |
|---|---|
| Any commit subject contains `BREAKING` or uses `!` (e.g. `feat!:`) | Major — `v1.0.0` |
| At least one `feat:` commit | Minor — `v0.7.0` |
| Only `fix:`, `perf:`, `refactor:`, etc. | Patch — `v0.6.7` |

**Channel rules:**

| Condition | Tag format | Release type |
|---|---|---|
| Any commit message contains `alpha` | `v0.6.7-alpha.{run}` | Pre-release |
| Any commit message contains `beta` | `v0.6.7-beta.{run}` | Pre-release |
| Branch is `dev` (default) | `v0.6.7-dev.{run}` | Pre-release |
| Branch is `main` + a commit contains `(release)` | `v0.6.7` | **Stable release** |
| Branch is `main` without `(release)` | `v0.6.7-dev.{run}` | Pre-release |

To cut a stable release, merge to `main` with at least one commit whose message contains `(release)` — for example:

```
feat(keymap): add new rolling sequences (release)
```

### Release builds

[`release.yml`](.github/workflows/release.yml) is triggered by every `v*` tag push. It builds all platform artefacts in parallel — macOS app + Sparkle appcast, Windows AHK executable, Linux XKB bundle — then creates the GitHub Release with all assets attached and an auto-generated changelog.

### Changelog generation

The changelog is generated by [`tools/build_changelog.py`](tools/build_changelog.py). It aggregates all commits since the previous tag, groups them by conventional commit type (Features → Fix → Performance → …), and formats each entry as **Scope: Subject** in bold for quick scanning.

### Test workflows

Tests run independently on every push (with path filters, so only the relevant suite fires):

| Workflow | Trigger paths | Runner |
|---|---|---|
| [`test_ahk.yml`](.github/workflows/test_ahk.yml) | `static/drivers/autohotkey/**` | Windows |
| [`test_hammerspoon.yml`](.github/workflows/test_hammerspoon.yml) | `static/drivers/hammerspoon/**` | Ubuntu (Lua 5.4) |
| [`test_hotstrings.yml`](.github/workflows/test_hotstrings.yml) | `static/hotstrings/*.toml` | Ubuntu |
