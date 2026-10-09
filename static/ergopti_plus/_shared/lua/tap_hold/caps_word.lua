--- _shared/lua/tap_hold/caps_word.lua

--- ==============================================================================
--- MODULE: Persistent CapsWord Policy (shared)
--- DESCRIPTION:
--- Defines the conservative initial Linux word/control boundary and alphabetic
--- conversion. Native drivers retain exclusive input and output admission.
--- Existing Windows/macOS policies are not migrated by this initial owner.
--- ==============================================================================

local M = {}
local UnicodeCase = require("unicode_case")
local CANCEL = { space = true, enter = true, tab = true, escape = true,
	delete = true, left = true, right = true, up = true, down = true,
	home = true, ["end"] = true, pageup = true, pagedown = true }

--- Whether a control withdraws the word before forwarding that control.
--- @param control string|nil Native semantic control identity.
--- @return boolean
function M.cancels(control)
	return CANCEL[control] == true
end

--- Resolves alphabetic case only; punctuation and digits never acquire Shift.
--- @param text string|nil Original current-layout text.
--- @return string|nil Uppercase text only when conversion is necessary.
function M.uppercase(text)
	if type(text) ~= "string" or text == "" then return nil end
	local upper = UnicodeCase.upper(text)
	return upper ~= text and upper or nil
end

return M
