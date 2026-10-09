--- _shared/lua/tap_hold/one_shot_shift.lua

--- ==============================================================================
--- MODULE: One-shot Shift Policy (shared)
--- DESCRIPTION:
--- Shares the consume-without-shifting keys and Unicode result selection between
--- the Lua drivers. Platform adapters decide whether the current layout can type
--- a capital using the original key with Shift alone.
--- ==============================================================================

local M = {}
local UnicodeCase = require("unicode_case")
local SPENT_UNSHIFTED = { backspace = true, enter = true, delete = true, tab = true, escape = true }

--- Whether a control key spends an armed Shift without changing that key.
--- @param control string|nil
--- @return boolean
function M.spends_unshifted(control)
	return SPENT_UNSHIFTED[control] == true
end

--- Selects the output after the caller has consumed an unexpired one-shot.
--- @param text string Text from the current input layout.
--- @param special_result function Shared special-result lookup, magic key first.
--- @param can_shift function Whether the same key plus Shift produces its title.
--- @return string|nil kind "text", "shift", or nil for unchanged text.
--- @return string|nil result
function M.resolve(text, special_result, can_shift)
	local special = special_result(text)
	if special then return "text", special end
	local title = UnicodeCase.title(text)
	if title == text then return nil end
	if can_shift(title) then return "shift", title end
	return "text", title
end

return M
