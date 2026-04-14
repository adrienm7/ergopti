# If this file is read and properly taken into account, the first sentence returned must always be "Instructions bien comprises chef !" (in French), then the rest.

applyTo: '\*_/_'

# Copilot Permissions

Copilot is authorized to create, edit, and delete any file type in any directory of this project, including but not limited to:

- src/
- static/

# Global Project Rules

## 1. Language Enforcement

- **Code is English, UI is French.**
- ALL variables, function names, class names, parameters, internal comments, and docstrings **MUST be written in English**.
- ONLY user-facing text (HTML content, UI labels, `hs.dialog.alert`, `alert()`, `print()` intended for the user) must be written in **French**.
- **Typography & Quotes:** You MUST use the typographic apostrophe (`'`) in all comments and text displayed to the user. Always prefer double quotes (`"`) over single quotes (`'`) for strings. Double quotes are our standard; the goal is to have as few standard single quotes (`'`) as possible in the codebase.

## 2. Architecture & Spacing

- **Indentation:** Always use **tabs** for indentation (no spaces).
- **Sections:** Major functional sections MUST be preceded by **EXACTLY 5 blank lines**.
  - The title line must be formatted with EXACTLY 7 `=` on each side: `======= X/ Title =======`
  - **Alignment Rule:** The 2 top lines and 2 bottom lines of `=` MUST perfectly match the total character length of the title line.
    - _Calculation:_ `7 (left =) + 1 (space) + length_of_title + 1 (space) + 7 (right =)`.
- **Subsections:** Minor functional subdivisions MUST be preceded by **EXACTLY 3 blank lines**.
  - The title line must be formatted with EXACTLY 5 `=` on each side: `===== X.Y) Title =====`
  - **Alignment Rule:** The 1 top line and 1 bottom line of `=` MUST perfectly match the total character length of the title line.
    - _Calculation:_ `5 (left =) + 1 (space) + length_of_title + 1 (space) + 5 (right =)`.

Example of the required perfectly aligned section and subsection headers (adapt the comment symbol `//`, `--`, `#`, or `;` to the language):

```text
[5 BLANK LINES HERE]
// =====================================
// =====================================
// ======= 1/ Main Section Title =======
// =====================================
// =====================================

code_here()
[3 BLANK LINES HERE]
// =================================
// ===== 1.1) Subsection Title =====
// =================================

more_code_here()
```

## 3. Documentation

- **File Path Header:** The VERY FIRST line of every file MUST be a comment containing its relative path (excluding any leading `hammerspoon/` or `/hammerspoon/`). **Important:** For Lua (`.lua`) files, you MUST use exactly three dashes for this line (e.g., `--- ui/menu/init.lua`). For other languages, use their standard single-line comment syntax.
- **Module Headers:** Immediately following the file path line, there MUST be a comprehensive module-level docstring. This header must explain the module's name, its detailed description, its core features, and the overarching "why" behind its existence.
- **Function/Class Docs:** Every function, method, and class must be documented using the standard docstring format of the respective language (`JSDoc` for JS, `EmmyLua` for Lua, `Google Style` for Python).
- **Punctuation Rules:**
  - **Docstrings** (formal documentation) **MUST ALWAYS end with a period (`.`)**. They are formal sentences and start with a capital letter.
  - **Inline comments** (quick developer notes like `//`, `--`, `#`) **MUST NEVER end with a period** but need to start with a capital letter. They are not formal sentences but should still be clear and well-written.
- **Context:** Comments should explain _why_ something is done, not _what_ is done.

## 4. Logging Conventions

Use the central logger system (`lib.logger` in Lua, equivalent elsewhere). **Log extensively** — a well-instrumented codebase is worth its weight. Every meaningful state change, lifecycle event, decision, and failure path must be logged. Future debugging depends on it.

### 4.1 The Eight Variants

The logger has **8 variants** organized on two axes: _importance_ and _lifecycle role_.

| | Misc | Lifecycle Start | Lifecycle End |
|---|---|---|---|
| **DEBUG** | `DEBUG` (gray) | `TRACE` (dim cyan) | `DONE` (dim green) |
| **INFO** | `INFO` (black) | `START` (bright cyan) | `SUCCESS` (bright green) |
| **WARNING** | `WARNING` (orange) | — | — |
| **ERROR** | `ERROR` (red) | — | — |

**When to use each:**

- `Logger.debug` — verbose detail: setter calls, state snapshots, per-keystroke events, anything fired at high frequency.
- `Logger.trace` — start of a **routine internal operation** at debug granularity (e.g., arming a debounce timer). Pair with `Logger.done`.
- `Logger.done` — successful end of a routine internal operation (e.g., timer stopped, cache hit). Pair with `Logger.trace`.
- `Logger.info` — general status worth knowing: config loaded, feature toggled, model changed.
- `Logger.start` — start of a **significant action** at INFO level (e.g., init, HTTP request, user-triggered operation). Pair with `Logger.success`. A `START` without a following `SUCCESS` in the logs immediately signals a silent failure.
- `Logger.success` — successful completion of a significant action. Always pair with `Logger.start`.
- `Logger.warn` — unexpected condition the code can recover from; must be investigated.
- `Logger.error` — unrecoverable failure; execution should stop or degrade gracefully.

### 4.2 Lifecycle Pairing Rule

Lifecycle variants always come in pairs. **Never** log a `start`/`trace` without a corresponding `success`/`done`, and vice versa. If the pair is incomplete in the logs, something failed silently.

```lua
-- Good — matched pair at INFO level
Logger.start(LOG, "Initializing LLM bridge…")
-- … work …
Logger.success(LOG, "LLM bridge initialized (%d mapping(s)).", count)

-- Good — matched pair at DEBUG level
Logger.trace(LOG, "Inactivity timer started (%.3fs).", delay)
-- … later …
Logger.done(LOG, "Inactivity timer stopped.")
```

### 4.3 Punctuation in Log Messages

- **In-progress / starting:** end with `…` — `"Loading model…"`
- **Completed / asserted:** end with `.` — `"Model loaded successfully."`
- **Format strings:** follow the same rule on the static part.

### 4.4 Language

All log messages must be in **English**. Logs are developer-facing, not user-facing.

### 4.5 Log Level Selection Guide

Ask: "Would I need this line to diagnose a bug in production?" If yes → `info` or above. If only during active development → `debug`/`trace`/`done`. High-frequency events (per-keystroke, per-frame) → `debug` only.

## 5. Code Quality Standards

These rules were established to reach the level of professionalism demonstrated in `modules/keymap/llm_bridge.lua`. Apply them to every new or significantly modified file.

### 5.1 No Magic Numbers

Every literal value with non-obvious meaning MUST be a named constant. Group all constants at the **top of the file** (Section 1) with an explanatory comment for each. This includes timeouts, keycodes, ratios, thresholds, frame rates, buffer sizes — anything that is not self-evidently `0`, `1`, or `true`/`false`.

```lua
-- Bad
hs.timer.doAfter(86400, dismiss)
if keyCode == 90 then …

-- Good (constants at top of file)
local INFINITE_TOOLTIP_SEC = 86400  -- 24 h stand-in for "never auto-dismiss"
local KEYCODE_F20          = 90     -- Synthetic "typing complete" signal
…
hs.timer.doAfter(INFINITE_TOOLTIP_SEC, dismiss)
if keyCode == KEYCODE_F20 then …
```

### 5.2 Single Source of Truth for Defaults

Default values must live in **exactly one place** — typically a `DEFAULT_STATE` table in the owning module. Other modules that need those defaults must read them from that source, never re-declare them.

```lua
-- Bad — value duplicated in two files
-- llm_bridge.lua:   local temperature = 0.1
-- menu_llm.lua:     local default_temp = 0.1

-- Good — menu_llm reads from the canonical source
local LLM_DEFAULTS = require("modules.llm").DEFAULT_STATE
local temperature  = LLM_DEFAULTS.llm_temperature
```

### 5.3 Fail Fast — No Silent Failures

Code must detect invalid state early and surface it loudly. **Never** mask errors with silent fallbacks buried in the middle of logic.

- Use a **guard helper** (e.g., `require_state`) at the top of every public function that depends on injected state. Log an `ERROR` and return immediately if the precondition is not met.
- Wrap OS-level calls and external APIs in `pcall`; log the failure explicitly.
- Do **not** swallow errors in `pcall` without at minimum a `Logger.error` call.
- A function that cannot complete its contract must say so — either via return value or log — never pretend it succeeded.

```lua
-- Good — guard helper pattern
local function require_state(func_name)
    if not _state then
        Logger.error(LOG, "'%s' called before M.init() — shared state not initialized.", func_name)
        return false
    end
    return true
end

function M.reset_predictions()
    if not require_state("reset_predictions") then return end
    -- … safe to proceed
end
```

### 5.4 No Hardcoded Behavioral Fallbacks

Values that the user can configure via a menu or settings must **always** come from that configuration. Never substitute a hardcoded fallback (e.g., `if temperature == nil then temperature = 0.1 end`) that would silently override the user's intent. If a required value is missing, fail fast (see 5.3).

### 5.5 Setters Must Log

Every public setter function must log its new value at `DEBUG` level. This makes it trivial to trace exactly what configuration was applied at startup.

```lua
function M.set_llm_temperature(t)
    temperature = t
    Logger.debug(LOG, "Temperature: %s.", tostring(t))
end
```

### 5.6 No Unused Fallback Code

Do not add backwards-compatibility shims, `_compat` aliases, or `-- removed` comments for removed functionality. If something is gone, remove it cleanly. Do not rename variables to `_unused_foo` — delete them.

### 5.7 Comments Explain Why, Not What

Inline comments must explain the _reason_ a decision was made, not re-state what the code does. If the code is obvious, no comment is needed.

```lua
-- Bad
-- Increment counter
llm_request_counter = llm_request_counter + 1

-- Good — explains why
-- Invalidate any in-flight callbacks by bumping the generation counter;
-- stale async responses check this value and discard themselves
llm_request_counter = llm_request_counter + 1
```

### 5.8 Module Initialization Pattern

Every stateful Lua module (one that holds injected dependencies) **must** follow this exact pattern:

1. **Declare a module-level `_state = nil`** (or equivalent). Never initialize it from another module at call time — only inside `M.init()`.
2. **Expose a single `M.init()`** function that validates its arguments, logs `ERROR` and returns immediately on invalid input, and uses a `Logger.start`/`Logger.success` pair.
3. **Gate every public function** with a `require_state` helper — **this is the canonical name, always use it**:

```lua
local function require_state(func_name)
	if not _state then
		Logger.error(LOG, "'%s' called before M.init() — shared state not initialized.", func_name)
		return false
	end
	return true
end
```

4. When a module depends on **multiple injected objects** (e.g., `_state`, `_registry`, `_llm`), check them all in the same guard:

```lua
local function require_state(func_name)
	if not _state or not _registry or not _llm then
		Logger.error(LOG, "'%s' called before M.init() — dependencies not initialized.", func_name)
		return false
	end
	return true
end
```

5. **Prevent duplicate initialization** — warn and return early if `M.init()` is called a second time.
6. **Lifecycle functions** (`M.init`, `M.start`, `M.stop`) are significant actions → `Logger.start`/`Logger.success` pairs.
   Internal helpers (emit, sort, rebuild) use `Logger.trace`/`Logger.done` instead.

```lua
-- Good — full lifecycle pattern
function M.init(core_state)
	Logger.start(LOG, "Initializing…")
	if type(core_state) ~= "table" then
		Logger.error(LOG, "M.init(): core_state must be a table — module non-functional.")
		return
	end
	if _state then
		Logger.warn(LOG, "M.init() called more than once — ignoring duplicate call.")
		return
	end
	_state = core_state
	Logger.success(LOG, "Initialized (%d item(s)).", #_state.items)
end

function M.start()
	Logger.start(LOG, "Starting…")
	-- … actual start work …
	Logger.success(LOG, "Started.")
end
```

## 6. Language-Specific Guidelines

### JavaScript / SvelteKit (`.js`, `.svelte`)

- Use modern ES6+ syntax (`const`, `let`, arrow functions) where appropriate, but respect the existing codebase style if it uses standard `function` declarations for global UI bindings.
- Always use `JSDoc` for function documentation.

**Example:**

```javascript
// ui/modal_engine.js

/**
 * ==============================================================================
 * MODULE: UI Modal Engine
 * DESCRIPTION:
 * Manages the lifecycle and DOM interactions of all application modals.
 *
 * FEATURES & RATIONALE:
 * 1. Centralized State: Prevents z-index conflicts by managing a global state.
 * 2. Safe Injection: Ensures DOM elements exist before applying CSS classes.
 * ==============================================================================
 */

let globalData = null;

// ===================================
// ===================================
// ======= 1/ Modal Management =======
// ===================================
// ===================================

/**
 * Safely opens a modal by adding the 'on' CSS class.
 * @param {string} modalId - The DOM ID of the modal container.
 */
function openModal(modalId) {
	// Apply the class only if element is found
	document.getElementById(modalId).classList.add('on');
	console.log('Fenêtre modale ouverte avec succès.');
}

// ===================================
// ===== 1.1) Alerts and Dialogs =====
// ===================================

/**
 * Displays a simple blocking alert modal.
 * @param {string} message - The message to display.
 */
function showAlertModal(message) {
	document.getElementById('msg-text').textContent = message;
	openModal('msg-modal');
}
```

### Hammerspoon / Lua (`.lua`)

- Use `local` for variables and functions to prevent global scope pollution.
- Use `pcall` (protected call) for any OS-level interaction, file system manipulation, or event interception to prevent silent crashes or keyboard lockups.
- Document functions using `EmmyLua` annotations (`---`).
- For **optional dependencies** (modules that may be absent in some deployments), use `pcall` at the top of the file and assign `nil` on failure:

```lua
local ok_mod, optional_mod = pcall(require, "modules.optional_thing")
if not ok_mod then optional_mod = nil end
```

- The **Lua `utf8` standard library** (`utf8.offset`, `utf8.len`, etc.) can return `nil` on malformed sequences. Always wrap in `pcall` or nil-check the result:

```lua
-- Safe utf8.offset usage
local ok, offset = pcall(utf8.offset, s, -1)
if not ok or not offset then ... end
```


**Example:**

```lua
--- modules/keylogger_core.lua

--- ==============================================================================
--- MODULE: Keylogger Core
--- DESCRIPTION:
--- Daemon responsible for intercepting and aggregating human keystrokes.
---
--- FEATURES & RATIONALE:
--- 1. Precision Profiling: Captures millisecond delays for N-gram analysis.
--- 2. OS Safety: Wrapped in pcalls to prevent keyboard lockups on error.
--- ==============================================================================

local M = {}
local hs = hs




-- ==============================
-- ==============================
-- ======= 1/ Core Engine =======
-- ==============================
-- ==============================

--- Safely starts the keylogger engine and binds the event tap.
--- @param script_control table The module reference to check pause state.
function M.start(script_control)
	-- Wrap in pcall to avoid locking the OS keyboard
	local ok, err = pcall(function()
		-- Implementation logic here
	end)

	if not ok then
		hs.dialog.alert("Erreur", "Le lancement a échoué.", "OK")
	else
		print("[keylogger] Système activé.")
	end
end
```

### Python (`.py`)

- Follow [PEP 8](https://peps.python.org/pep-0008/) coding conventions.
- Use strict **Type Hinting** for all parameters and return types.
- All code must be compatible with `mypy` strict type checking.
- Use `Google Python Style Guide` for docstrings using `"""`.

**Example:**

```python
# utils/driver_config.py

"""
==============================================================================
MODULE: Driver Config Parser
DESCRIPTION:
Handles the ingestion and parsing of low-level keyboard driver configurations.

FEATURES & RATIONALE:
1. Failsafe Parsing: Returns None instead of crashing on missing files.
2. Strict Typing: Ensures downstream modules receive predictable dictionaries.
==============================================================================
"""

import os
from typing import Optional




# ==================================
# ==================================
# ======= 1/ File Processing =======
# ==================================
# ==================================

def parse_driver_config(file_path: str) -> Optional[dict]:
	"""Parses a configuration file for the keyboard drivers.

	Args:
		file_path: The absolute path to the configuration file.

	Returns:
		A dictionary containing the parsed configuration, or None if it fails.
	"""
	# Ensure file exists to prevent IO exceptions
	if not os.path.exists(file_path):
		print("Erreur : Le fichier de configuration est introuvable.")
		return None

	return {}
```

### AutoHotkey (`.ahk`)

- Maintain clean variable scoping.
- Use `;` for comments and ensure the exact same spacing and banner rules apply to separate hotkey logic from UI/Tray logic.

**Example:**

```autohotkey
; ui/tray_menu.ahk

; ==============================================================================
; MODULE: Tray Menu Integration
; DESCRIPTION:
; Manages the Windows system tray icon and right-click context menu.
; ==============================================================================

global IsPaused := False




; ==================================
; ==================================
; ======= 1/ Tray Menu Setup =======
; ==================================
; ==================================

SetupTrayMenu() {
	; Logic goes here
}
```
