--- platform/remap/control_signals.lua

--- ==============================================================================
--- MODULE: Karabiner Control Signal Contract
--- DESCRIPTION:
--- Defines the modifier tag that distinguishes one-shot Shift from bare F20
--- navigation entry. Generation and event decoding consume the same tag list.
--- ==============================================================================

local M = {}
local TAGS = { { key = "left_control", flag = "ctrl" }, { key = "left_option", flag = "alt" } }

--- Returns a fresh Karabiner output-modifier list.
--- @return table
function M.one_shot_modifiers()
	local result = {}
	for _, tag in ipairs(TAGS) do result[#result + 1] = tag.key end
	return result
end

--- Whether an event carries exactly the one-shot tag, ignoring Caps Lock.
--- @param flags table|nil
--- @return boolean
function M.is_one_shot(flags)
	if type(flags) ~= "table" then return false end
	local expected = {}
	for _, tag in ipairs(TAGS) do
		if flags[tag.flag] ~= true then return false end
		expected[tag.flag] = true
	end
	for _, flag in ipairs({ "ctrl", "alt", "cmd", "shift", "fn" }) do
		if flags[flag] == true and not expected[flag] then return false end
	end
	return true
end

return M
