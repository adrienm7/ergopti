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
