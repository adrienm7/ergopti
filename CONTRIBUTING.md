# Contributing & developer notes

## Table of contents

- [Contributing \& developer notes](#contributing--developer-notes)
  - [Table of contents](#table-of-contents)
  - [Project overview](#project-overview)
  - [Local development setup](#local-development-setup)
  - [Private AHK file workflow](#private-ahk-file-workflow)
    - [The problem](#the-problem)
    - [The solution](#the-solution)
    - [Setting it up on a new machine](#setting-it-up-on-a-new-machine)
    - [What happens automatically at commit time](#what-happens-automatically-at-commit-time)
  - [Hotstrings generator](#hotstrings-generator)
  - [Pre-commit hooks](#pre-commit-hooks)

---

## Project overview

This repo contains:

- The **Ergopti website** (SvelteKit, `src/`)
- The **driver files** distributed to users (AutoHotkey, Hammerspoon, Karabiner…), under `static/drivers/`
- A Python **hotstrings generator** (`static/drivers/hotstrings/0_generate_hotstrings.py`) that reads `ErgoptiPlus.ahk` and outputs TOML files consumed by Hammerspoon

---

## Local development setup

```bash
npm install        # install JS dependencies (also sets up Husky hooks)
uv sync            # install Python dependencies
npm run dev        # start the dev server
```

---

## Private AHK file workflow

### The problem

`static/drivers/autohotkey/ErgoptiPlus.ahk` is the **public** version of the
AutoHotkey script — it is stripped of any personal shortcuts (section 2) before
every commit.

On the author's machine, the real file lives in a **private repo** at a
different path and contains a personal section 2 that must never be pushed here.

### The solution

A **gitignored override file** tells the tooling where your private AHK file is:

```
static/drivers/hotstrings/.local_ahk_path   ← gitignored, never committed
```

This plain-text file contains a single line: the absolute path to your private
`ErgoptiPlus.ahk`, for example:

```
/Users/you/private-config/ErgoptiPlus.ahk
```

### Setting it up on a new machine

1. Create the override file:

   ```bash
   echo "/absolute/path/to/your/private/ErgoptiPlus.ahk" \
     > static/drivers/hotstrings/.local_ahk_path
   ```

2. Install the launchd watcher (macOS only) — triggers the full pipeline
   automatically on every save of your private file, no terminal needed:

   ```bash
   npm run install-watcher
   ```

   To stop it:

   ```bash
   npm run uninstall-watcher
   ```

   Logs are available at `~/Library/Logs/ergopti-ahk-watcher.log`.

3. Alternatively, run the pipeline manually at any time:

   ```bash
   npm run update
   ```

### What happens automatically at commit time

```
private ErgoptiPlus.ahk
        │
        │  sync-private-ahk.js  (copies private → public)
        ▼
static/drivers/autohotkey/ErgoptiPlus.ahk  (full file, with section 2)
        │
        │  remove_ahk_personal_configuration.js  (strips section 2)
        ▼
static/drivers/autohotkey/ErgoptiPlus.ahk  (public version, no section 2)
        │
        │  0_generate_hotstrings.py  (regenerate TOML files)
        ▼
static/drivers/hotstrings/*.toml
        │
        │  git add + commit
        ▼
GitHub
```

> If `.local_ahk_path` is absent (e.g. on a contributor's machine or CI), the
> sync step is silently skipped and the existing public file is used as-is.

---

## Hotstrings generator

`static/drivers/hotstrings/0_generate_hotstrings.py` parses `ErgoptiPlus.ahk`
and writes TOML files consumed by the Hammerspoon driver.

Run it manually:

```bash
python static/drivers/hotstrings/0_generate_hotstrings.py
```

When `.local_ahk_path` is present the script reads from your private file
directly. Otherwise it falls back to the public `ErgoptiPlus.ahk`.

---

## Pre-commit hooks

Managed by [Husky](https://typicode.github.io/husky/). The hook runs in order:

| Step | Script                                     | Description                                      |
| ---- | ------------------------------------------ | ------------------------------------------------ |
| 1    | `npm run sync-ahk`                         | Copy private AHK → public (no-op if no override) |
| 2    | `npm run clean-ahk`                        | Strip section 2 from public AHK                  |
| 3    | `node scripts/update-ahk-date.js`          | Update the "Last modified" date                  |
| 4    | `git add static/drivers/autohotkey/*.ahk`  | Stage the cleaned file                           |
| 5    | `uv run python … 0_generate_hotstrings.py` | Regenerate TOML hotstrings from the cleaned AHK  |
| 6    | `git add static/drivers/hotstrings/*.toml` | Stage the regenerated TOML files                 |
