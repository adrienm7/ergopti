# Contributing & developer notes

## Table of contents

- [Contributing \& developer notes](#contributing--developer-notes)
  - [Table of contents](#table-of-contents)
  - [🏗️ Project overview](#️-project-overview)
  - [💻 Local development setup](#-local-development-setup)
  - [🔒 Private AHK file workflow](#-private-ahk-file-workflow)
    - [The problem](#the-problem)
    - [The solution](#the-solution)
    - [Setting it up on a new machine](#setting-it-up-on-a-new-machine)
      - [1. Create the override file](#1-create-the-override-file)
      - [2. Start the watcher](#2-start-the-watcher)
      - [3. Make it survive reboots (OS-Specific)](#3-make-it-survive-reboots-os-specific)
      - [🛑 Stopping the watcher](#-stopping-the-watcher)
    - [What happens automatically at commit time](#what-happens-automatically-at-commit-time)
  - [⚙️ Hotstrings generator](#️-hotstrings-generator)
  - [🪝 Pre-commit hooks](#-pre-commit-hooks)

---

## 🏗️ Project overview

This repo contains:

- The **Ergopti website** (SvelteKit, `src/`)
- The **driver files** distributed to users (AutoHotkey, Hammerspoon, Karabiner…), under `static/drivers/`
- A Python **hotstrings generator** (`static/drivers/hotstrings/0_generate_hotstrings.py`) that reads `ErgoptiPlus.ahk` and outputs TOML files consumed by Hammerspoon

---

## 💻 Local development setup

> **Note for Windows users:** Do not add inline comments (`#`) when copy-pasting commands in `cmd.exe` as it can cause `npm` to crash.

```bash
# 1. Install JS dependencies (also sets up Husky hooks and pm2)
npm install

# 2. Install Python dependencies
uv sync

# 3. Start the dev server
npm run dev
```

---

## 🔒 Private AHK file workflow

### The problem

`static/drivers/autohotkey/ErgoptiPlus.ahk` is the **public** version of the AutoHotkey script — it is stripped of any personal shortcuts (section 2) before every commit.

On the author's machine, the real file lives in a **private repo** at a different path and contains a personal section 2 that must never be pushed here.

### The solution

A **gitignored override file** tells the tooling where your private AHK file is:

```text
static/drivers/hotstrings/.local_ahk_path   ← gitignored, never committed
```

This plain-text file contains a single line: the absolute path to your private `ErgoptiPlus.ahk`, for example:

- **macOS/Linux:** `/Users/you/private-config/ErgoptiPlus.ahk`
- **Windows:** `C:\Users\you\private-config\ErgoptiPlus.ahk`

### Setting it up on a new machine

#### 1. Create the override file

Create the `.local_ahk_path` file and paste the absolute path to your private `ErgoptiPlus.ahk` inside it.

```bash
echo "/absolute/path/to/your/private/ErgoptiPlus.ahk" > static/drivers/hotstrings/.local_ahk_path
```

#### 2. Start the watcher

Install the pm2 watcher — it triggers the full pipeline automatically on every save of your private file, no terminal needed:

```bash
npm run install-watcher
```

_(Logs are available at `logs/ahk-watcher.log` inside the project)._

#### 3. Make it survive reboots (OS-Specific)

**🍎 macOS & 🐧 Linux**
Run the following command once, and execute the command it prints in your terminal (requires `sudo` on Linux):

```bash
npx pm2 startup
```

**🪟 Windows**
Windows requires a specific package to handle pm2 on startup. Open a terminal **as Administrator** and run:

```bash
npm install -g pm2-windows-startup
pm2-startup install
npx pm2 save
```

#### 🛑 Stopping the watcher

To stop the watcher permanently on any OS:

```bash
npm run uninstall-watcher
```

> **Manual update:** Alternatively, you can run the pipeline manually at any time using `npm run update`.

### What happens automatically at commit time

```text
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

> **Note:** If `.local_ahk_path` is absent (e.g., on a contributor's machine or CI), the sync step is silently skipped and the existing public file is used as-is.

---

## ⚙️ Hotstrings generator

`static/drivers/hotstrings/0_generate_hotstrings.py` parses `ErgoptiPlus.ahk` and writes TOML files consumed by the Hammerspoon driver.

Run it manually:

```bash
python static/drivers/hotstrings/0_generate_hotstrings.py
```

When `.local_ahk_path` is present, the script reads from your private file directly. Otherwise, it falls back to the public `ErgoptiPlus.ahk`.

---

## 🪝 Pre-commit hooks

Managed by [Husky](https://typicode.github.io/husky/). The hook runs in order:

| Step | Script                                     | Description                                           |
| ---- | ------------------------------------------ | ----------------------------------------------------- |
| 1    | `npm run sync-ahk`                         | Copy private AHK → public (no-op if no override)      |
| 2    | `npm run clean-ahk`                        | Strip section 2 from public AHK                       |
| 3    | `node scripts/update-ahk-date.js`          | Update the "Last modified" date                       |
| 4    | `git add static/drivers/autohotkey/*.ahk`  | Stage the cleaned file                                |
| 5    | Windows only: local Ahk2Exe compile        | If AHK is staged, compile and stage `ErgoptiPlus.exe` |
| 6    | `uv run python … 0_generate_hotstrings.py` | Regenerate TOML hotstrings from the cleaned AHK       |
| 7    | `git add static/drivers/hotstrings/*.toml` | Stage the regenerated TOML files                      |

```

```
