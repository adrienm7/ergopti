--- _shared/lua/brightness_actions.lua

--- ==============================================================================
--- MODULE: Screen Brightness Actions
--- DESCRIPTION:
--- Owns the native action vocabulary and strict backlight readback policy.
--- An accepted media event is a request, not proof that an attached screen changed.
--- ==============================================================================

local M = {}
local Canonical = require("brightness_actions_data")

--- Copies data-only generated metadata so each native owner retains its own tree.
local function copy(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, item in pairs(value) do result[key] = copy(item) end
	return result
end

--- Loads canonical native encodings without filesystem work in an input callback.
--- @return table
function M.load()
	return copy(Canonical)
end

--- Builds the existing screen-only tool request from the same percentage policy.
--- @param data table Canonical action data.
--- @param action string Brightness action id.
--- @return string
function M.linux_command(data, action)
	local row = assert(data.actions[action], "unknown screen brightness action")
	local amount = tostring(data.step_percent) .. "%"
	local change = row.direction == 1 and ("+" .. amount) or (amount .. "-")
	return data.linux_program .. " --class=" .. data.linux_class .. " set " .. change
end

--- Computes the requested screen percentage, including the native endpoint.
--- @param data table Canonical action data.
--- @param action string Canonical brightness action.
--- @param before number Integer backlight percentage.
--- @return number
function M.target(data, action, before)
	assert(type(before) == "number" and before % 1 == 0 and before >= 0 and before <= 100,
		"a screen brightness percentage must be an integer between zero and one hundred")
	local row = assert(data.actions[action], "unknown screen brightness action")
	return math.max(0, math.min(100, before + row.direction * data.step_percent))
end

--- Accepts only complete, bounded native readbacks for the requested action.
--- @param data table Canonical policy.
--- @param action string Requested action.
--- @param receipt any Native worker receipt.
--- @return boolean
function M.acknowledged(data, action, receipt)
	if type(receipt) ~= "table" or receipt.version ~= data.version
		or receipt.action ~= action or receipt.status ~= "applied"
		or type(receipt.displays) ~= "table" or #receipt.displays == 0
		or #receipt.displays > data.max_displays then return false end
	for _, row in ipairs(receipt.displays) do
		if type(row) ~= "table" or type(row.before) ~= "number"
			or row.before % 1 ~= 0 or row.before < 0 or row.before > 100 then return false end
		local target = M.target(data, action, row.before)
		if row.target ~= target or row.after ~= target then return false end
	end
	return true
end

return M
