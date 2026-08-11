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

local Bindings          = require("modules.shortcuts.bindings")
local ScriptControl     = require("modules.shortcuts.script_control")
local KeyboardShortcuts = require("modules.shortcuts.keyboard_shortcuts")
local HotkeyRegistrar   = require("adapters.hotkey_registrar")

local M = {}

-- One live fence covers every adapter-owned native hotkey, including UI
-- shortcuts that are intentionally kept registered while the bindings layer is
-- stopped. The callback resolves ScriptControl at delivery time, so a pause or
-- resume takes effect without a fragile rebind sweep.
HotkeyRegistrar.set_delivery_guard(function()
	return ScriptControl.is_paused() ~= true
end)





-- ================================
-- ================================
-- ======= 1/ Default State =======
-- ================================
-- ================================

M.DEFAULT_STATE = {
	shortcuts                = true,
	script_control_enabled   = true,
	script_control_shortcuts = { return_key = "script_pause_toggle", backspace = "script_reload", escape = "script_quit" },
	chatgpt_url              = Bindings.DEFAULT_CHATGPT_URL,
}





-- ========================================
-- ========================================
-- ======= 2/ Base API & Forwarding =======
-- ========================================
-- ========================================

-- Proxy Bindings Methods
M.DEFAULT_CHATGPT_URL    = Bindings.DEFAULT_CHATGPT_URL
M.list_shortcuts         = Bindings.list_shortcuts
M.enable                 = Bindings.enable
M.disable                = Bindings.disable
M.is_enabled             = Bindings.is_enabled
M.set_wrap_pairs_getter  = Bindings.set_wrap_pairs_getter
M.set_chatgpt_url        = Bindings.set_chatgpt_url

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

-- Proxy Keyboard Shortcuts Methods
M.start_keyboard_shortcuts = KeyboardShortcuts.start
M.stop_keyboard_shortcuts  = KeyboardShortcuts.stop
M.set_keyboard_action      = KeyboardShortcuts.set_action
M.get_keyboard_action      = KeyboardShortcuts.get_action
M.get_keyboard_slot_label  = KeyboardShortcuts.get_slot_label
M.get_keyboard_assignments = KeyboardShortcuts.get_assignments
M.get_keyboard_slot_groups = function() return KeyboardShortcuts.SLOT_GROUPS end
M.available_keyboard_slots = KeyboardShortcuts.available_slots
M.assigned_keyboard_slots  = KeyboardShortcuts.assigned_slots

--- Starts the user-facing shortcut layer: the static Bindings AND the
--- configurable keyboard shortcuts. Symmetric with stop() and resume_bindings()
--- — both manage KeyboardShortcuts, so the initial start must too (otherwise the
--- configurable Cmd/Ctrl/Option shortcuts stay dead until the first pause/resume).
--- ScriptControl has its own dedicated start/stop (start_script_control) so its
--- pause/quit/reload tap survives a bindings toggle.
function M.start()
	Bindings.start()
	KeyboardShortcuts.start()
end

function M.stop()
	Bindings.stop()
	ScriptControl.stop()
	KeyboardShortcuts.stop()
end

--- Stops only the user-facing bindings and keyboard shortcuts, leaving the
--- script-control eventtap alive so AltGr+Enter/Escape/Backspace can still
--- un-pause the script. Called by pause_all() in script_control.lua instead
--- of stop() which would also kill the script-control tap itself.
function M.pause_bindings()
	Bindings.stop()
	KeyboardShortcuts.stop()
end

--- Restores user-facing bindings after a pause. Symmetric to pause_bindings().
function M.resume_bindings()
	Bindings.start()
	KeyboardShortcuts.start()
end

--- Re-arms the layout-dependent hotkeys after a keyboard-layout change, so they
--- track the new physical key positions (hs.hotkey.bind resolves key names to
--- scancodes at bind time).
--- Unlike the pause_bindings()/resume_bindings() pair, this NEVER changes whether
--- the layer is running: it is a no-op when the bindings are stopped. That pair is
--- a symmetric round-trip only when the layer was ON to begin with — used here it
--- silently re-enabled every shortcut the user had switched off from the menu on
--- each layout change, while the tray checkbox still displayed OFF. A caller that
--- merely wants to rebind must not be able to resurrect a layer the user turned
--- off, so the running/stopped decision stays exclusively with the menu and with
--- script_control (which snapshots the state before pausing).
--- @return boolean True when the layer was running and was actually re-armed.
function M.rebind_for_layout()
	if not Bindings.is_started() then return false end
	Bindings.rebind()
	KeyboardShortcuts.stop()
	KeyboardShortcuts.start()
	return true
end

--- Returns true when the binding layer is active (started and not stopped).
--- @return boolean
function M.is_bindings_started()
	return Bindings.is_started()
end

return M
