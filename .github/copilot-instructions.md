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
- **Typography & Quotes:** You MUST use the typographic apostrophe (`’`) in all comments and text displayed to the user. Always prefer double quotes (`"`) over single quotes (`'`) for strings. Double quotes are our standard; the goal is to have as few standard single quotes (`'`) as possible in the codebase.

## 2. Architecture & Spacing

- **Indentation:** Always use **tabs** for indentation (no spaces).
- **Sections:** Major functional sections MUST be preceded by **EXACTLY 5 blank lines**.
  - The header must consist of 2 top lines of `=`, the title line, and 2 bottom lines of `=`.
  - The title line must be formatted with 7 `=` on each side: `======= X/ Title =======`
- **Subsections:** Minor functional subdivisions MUST be preceded by **EXACTLY 3 blank lines**.
  - The header must consist of 1 top line of `=`, the title line, and 1 bottom line of `=`.
  - The title line must be formatted with 5 `=` on each side: `===== X.Y) Title =====`

Example of the required section and subsection headers (adapt the comment symbol `//`, `--`, `#`, or `;` to the language):

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

# Language-Specific Guidelines

## JavaScript / SvelteKit (`.js`, `.svelte`)

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

## Hammerspoon / Lua (`.lua`)

- Use `local` for variables and functions to prevent global scope pollution.
- Use `pcall` (protected call) for any OS-level interaction, file system manipulation, or event interception to prevent silent crashes or keyboard lockups.
- Document functions using `EmmyLua` annotations (`---`).

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
    hs.dialog.alert("Erreur", "Le lancement a échoué.")
  else
    print("[keylogger] Système activé.")
  end
end
```

## Python (`.py`)

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

## AutoHotkey (`.ahk`)

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
