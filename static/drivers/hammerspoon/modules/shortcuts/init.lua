--- modules/shortcuts/init.lua

--- ==============================================================================
--- MODULE: Shortcuts Core
--- DESCRIPTION:
--- Orchestrates the entire shortcuts subsystem by grouping standard text/system 
--- utilities and the script lifecycle controls (pause, reload).
---
--- FEATURES & RATIONALE:
--- 1. Subsystem Delegation: Isolates standard utility shortcuts from panic buttons.
--- 2. Single API Surface: Exposes a unified set of controls to the UI Menu.
--- ==============================================================================

local hs = hs

local Bindings      = require("modules.shortcuts.bindings")
local ScriptControl = require("modules.shortcuts.script_control")

local M = {}





-- ================================
-- ================================
-- ======= 1/ Default State =======
-- ================================
-- ================================

M.DEFAULT_STATE = {
	shortcuts                = true,
	script_control_enabled   = true,
	script_control_shortcuts = { return_key = "pause", backspace = "reload" },
	ahk_source_path          = "",
	chatgpt_url              = Bindings.DEFAULT_CHATGPT_URL,
}





-- ========================================
-- ========================================
-- ======= 2/ Base API & Forwarding =======
-- ========================================
-- ========================================

-- Proxy Bindings Methods
M.DEFAULT_CHATGPT_URL = Bindings.DEFAULT_CHATGPT_URL
M.list_shortcuts      = Bindings.list_shortcuts
M.enable              = Bindings.enable
M.disable             = Bindings.disable
M.is_enabled          = Bindings.is_enabled
M.start               = Bindings.start
M.stop                = Bindings.stop

-- Proxy Script Control Methods
M.ACTIONS               = ScriptControl.ACTIONS
M.ACTION_LABELS         = ScriptControl.ACTION_LABELS
M.start_script_control  = ScriptControl.start
M.stop_script_control   = ScriptControl.stop
M.is_paused             = ScriptControl.is_paused
M.set_shortcut_action   = ScriptControl.set_shortcut_action
M.set_on_pause_change   = ScriptControl.set_on_pause_change
M.set_extras            = ScriptControl.set_extras
M.toggle_script_control = ScriptControl.toggle

return M
