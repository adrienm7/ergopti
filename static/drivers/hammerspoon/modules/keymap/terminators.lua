--- modules/keymap/terminators.lua

--- ==============================================================================
--- MODULE: Keymap Terminators (Hammerspoon shim)
--- DESCRIPTION:
--- Hammerspoon-local re-export of the shared terminator catalogue. Delegates
--- all logic to drivers/_shared/lua/keymap/terminators.lua and post-processes
--- the TERMINATOR_DEFS labels via lib.i18n so the menu shows localised strings
--- in the user's active language.
--- ==============================================================================

local M    = require("keymap.terminators")
local i18n = require("lib.i18n")

-- Resolve i18n keys for the five labels that vary by locale. All other labels
-- are plain French strings that match the French locale value and need no
-- resolution. This pass runs once at load time — keystroke-path cost is zero.
local I18N_LABEL_KEYS = {
	nbsp           = "terminators.label_nbsp",
	nnbsp          = "terminators.label_nnbsp",
	enter          = "terminators.label_enter",
	parenright     = "terminators.label_close_paren",
	equal          = "terminators.label_equal",
}

for _, def in ipairs(M.TERMINATOR_DEFS) do
	if def.key and I18N_LABEL_KEYS[def.key] then
		def.label = i18n.get(I18N_LABEL_KEYS[def.key])
	end
end

return M
