--- _shared/lua/keymap/control_signals.lua

--- ==============================================================================
--- MODULE: Native Remap Control Signal Policy
--- DESCRIPTION:
--- Owns the named modifier tags shared by Karabiner emission and Quartz event
--- consumption. Exact tags separate CapsWord edges from one-shot Shift.
--- ==============================================================================

local M = {}
local TAGS = {
	one_shot_shift = { { key = "left_control", flag = "ctrl" }, { key = "left_option", flag = "alt" } },
	capsword_activated = { { key = "left_control", flag = "ctrl" }, { key = "left_option", flag = "alt" },
		{ key = "left_shift", flag = "shift" } },
	capsword_deactivated = { { key = "left_control", flag = "ctrl" }, { key = "left_option", flag = "alt" },
		{ key = "left_command", flag = "cmd" } },
}

--- Returns a fresh Karabiner output-modifier list for one owned signal.
--- @param signal string Canonical signal name.
--- @return table modifiers Detached native names.
function M.modifiers_for(signal)
	local tags = assert(TAGS[signal], "unknown remap control signal")
	local result = {}
	for _, tag in ipairs(tags) do result[#result + 1] = tag.key end
	return result
end

--- Decodes exactly one known modifier tag, ignoring Caps Lock.
--- @param flags table|nil Quartz modifier flags.
--- @return string|nil signal
function M.decode(flags)
	if type(flags) ~= "table" then return nil end
	for signal, tags in pairs(TAGS) do
		local expected, matches = {}, true
		for _, tag in ipairs(tags) do
			if flags[tag.flag] ~= true then matches = false end
			expected[tag.flag] = true
		end
		for _, flag in ipairs({ "ctrl", "alt", "cmd", "shift", "fn" }) do
			if flags[flag] == true and not expected[flag] then matches = false end
		end
		if matches then return signal end
	end
	return nil
end

--- Returns the owned one-shot Shift output modifiers.
--- @return table modifiers
function M.one_shot_modifiers()
	return M.modifiers_for("one_shot_shift")
end

--- Whether an event carries exactly the one-shot Shift tag.
--- @param flags table|nil Quartz modifier flags.
--- @return boolean
function M.is_one_shot(flags)
	return M.decode(flags) == "one_shot_shift"
end

return M
