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
- A Python **hotstrings generator** (`static/hotstrings/0_generate_hotstrings.py`) that reads `ErgoptiPlus.ahk` and outputs TOML files consumed by Hammerspoon

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
static/hotstrings/.local_ahk_path   ← gitignored, never committed
```

This plain-text file contains a single line: the absolute path to your private `ErgoptiPlus.ahk`, for example:

- **macOS/Linux:** `/Users/you/private-config/ErgoptiPlus.ahk`
- **Windows:** `C:\Users\you\private-config\ErgoptiPlus.ahk`

### Setting it up on a new machine

#### 1. Create the override file

Create the `.local_ahk_path` file and paste the absolute path to your private `ErgoptiPlus.ahk` inside it.

```bash
echo "/absolute/path/to/your/private/ErgoptiPlus.ahk" > static/hotstrings/.local_ahk_path
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
static/hotstrings/*.toml
        │
        │  git add + commit
        ▼
GitHub
```

> **Note:** If `.local_ahk_path` is absent (e.g., on a contributor's machine or CI), the sync step is silently skipped and the existing public file is used as-is.

---

## ⚙️ Hotstrings generator

`static/hotstrings/0_generate_hotstrings.py` parses `ErgoptiPlus.ahk` and writes TOML files consumed by the Hammerspoon driver.

Run it manually:

```bash
python static/hotstrings/0_generate_hotstrings.py
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
| 7    | `git add static/hotstrings/*.toml`         | Stage the regenerated TOML files                      |

---

## 🧪 AutoHotkey Test Suite (`run_all.ahk`)

Ergopti uses a custom test framework for its AutoHotkey codebase, executing all tests sequentially within a single auto-execute thread.

### ⚠️ Architectural Trap: `Critical("On")` Leaks

A major trap when writing or testing AutoHotkey code is how `Critical("On")` interacts with the test framework:

1. **In Production (Hotkeys/Timers):** Calling `Critical("On")` inside a hotkey or timer callback is perfectly safe. AHK creates a pseudo-thread for the callback, and when it returns, the previous thread resumes with its own `Critical` setting restored automatically.
2. **In Tests (Direct Invocation):** The test framework runs sequentially on the **main auto-execute thread**. If a test directly invokes a function that calls `Critical("On")` without manually restoring it, that `Critical` state permanently "leaks" into the main thread.

**The Consequence:**
If the main thread becomes permanently `Critical`, AHK will **block all background timers** from firing for the remainder of the test suite (even during `Sleep` calls). Tests that rely on `SetTimer` (e.g., hotstring engine suppression releases) will silently hang or fail.

**The Solution:**
Always wrap standalone `Critical("On")` acquisitions in functions in a `try...finally` block, explicitly restoring the previous state:

```autohotkey
_AtCrit := Critical("On")
try {
    ; ... your critical code ...
} finally {
    Critical(_AtCrit)
}
```

> **Note:** The test framework (`test_framework.ahk`) now includes a safety check that throws `Test LEAKED Critical: <TestName>` and resets the state to `0` if a test forgets to restore it, preventing cascading failures.
