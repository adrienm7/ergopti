--- ui/menu/script_chord_labels.lua

--- ==============================================================================
--- MODULE: Script Chord Labels
--- DESCRIPTION:
--- Names each script-management chord the way this driver's menus show it:
--- « Opt droit + Entrée », since this driver's AltGr is the right Option key.
--- The Shortcuts submenu labels its slot rows with it and the tray shows it
--- beside « Suspendre », « Recharger » and « Quitter », so both read the same.
--- ==============================================================================

local M = {}
local i18n = require("core.i18n.engine.i18n")

-- Slot id (_shared/shortcuts/data/actions/script_chords.json) -> label key.
local LABEL_KEYS = {
	script_altgr_enter     = "sg_labels.script_ropt_return",
	script_altgr_backspace = "sg_labels.script_ropt_backspace",
	script_altgr_delete    = "sg_labels.script_ropt_delete",
	script_altgr_escape    = "sg_labels.script_ropt_escape",
}

--- The localized name of a chord slot.
--- @param slot_id string A slot of script_chords.json; any other id raises.
--- @return string label
function M.label(slot_id)
	local key = LABEL_KEYS[slot_id]
	if key == nil then error("script chord labels: unknown slot " .. tostring(slot_id), 2) end
	return i18n.get(key)
end

return M
