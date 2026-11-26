--- _shared/layouts/engine/emulation/recents.lua

--- ==============================================================================
--- MODULE: Recently Emulated Layouts (Shared)
--- DESCRIPTION:
--- The layouts chosen last for the emulation (layout.emulated_layout_recents),
--- most recent first, and the quick choices the « Layout to emulate » menu
--- draws from them above « Others… » (maintainer decision of 2026-11-25).
--- macOS and Linux run this module; Windows runs its twin in
--- modules/keymap/keylayout/emulation_recents.ahk, and both replay
--- _shared/tests/corpus/layouts/emulation_recents_vectors.json.
---
--- FEATURES & RATIONALE:
--- 1. One length: emulation.recent_count of _shared/layouts/data/defaults.json,
---    read here, never a literal in a driver.
--- 2. « None » is never recorded: it is always the first row of the menu, so a
---    recent slot spent on it would hide a layout.
--- 3. The menu always shows the layout in force: it leads the quick choices
---    even when another owner (the onboarding, a hand edit) chose it, so the
---    radio group keeps exactly one checked row.
--- ==============================================================================

local M = {}

local ID_PATTERN = "^[a-z][a-z0-9_]*$"
-- The length, read once: the defaults file ships with the app.
local _count = nil

--- How many recent layouts the menu offers.
--- @return number count A whole number of at least one.
function M.count()
	if _count ~= nil then return _count end
	local Paths = require("core.fs.engine.paths")
	local path = Paths.shared("layouts/data/defaults.json")
	local handle = io.open(path, "rb")
	if not handle then error("The layout defaults are unreadable: " .. tostring(path)) end
	local text = handle:read("*a")
	handle:close()
	local decoded = require("core.text.engine.json").decode(text)
	local count = type(decoded) == "table" and type(decoded.emulation) == "table" and decoded.emulation.recent_count
	if type(count) ~= "number" or count ~= math.floor(count) or count < 1 then
		error("_shared/layouts/data/defaults.json declares no whole emulation.recent_count of at least 1.")
	end
	_count = count
	return count
end

--- Validates a stored list: distinct layout ids, « None » excluded.
--- @param value any The stored value.
--- @return boolean valid
--- @return string|nil detail Why it is refused.
function M.valid(value)
	if type(value) ~= "table" then return false, "the value is not a list" end
	local seen = {}
	for index = 1, #value do
		local id = value[index]
		if type(id) ~= "string" or not id:match(ID_PATTERN) or id == "none" then
			return false, "the list holds something other than a layout id"
		end
		if seen[id] then return false, "the list names a layout twice" end
		seen[id] = true
	end
	for key in pairs(value) do
		if type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > #value then
			return false, "the value is not a list"
		end
	end
	return true
end

--- The list after a choice: the chosen layout first, then the others in order.
--- @param recents table The stored list (M.valid).
--- @param choice string "none", a built-in variant or a registry id.
--- @param count number|nil The length; M.count() when omitted.
--- @return table recents A new list; « None » leaves the order unchanged.
function M.after(recents, choice, count)
	count = count or M.count()
	local result = {}
	if choice ~= "none" then result[1] = choice end
	for _, id in ipairs(recents) do
		if #result >= count then break end
		if id ~= choice then result[#result + 1] = id end
	end
	return result
end

--- The quick choices under « None »: the layout in force first, then the
--- recent ones the catalogue still offers, at most count of them.
--- @param current string The choice in force ("none" when nothing is emulated).
--- @param recents table The stored list (M.valid).
--- @param offered function (id) -> whether the catalogue offers the layout.
--- @param count number|nil The length; M.count() when omitted.
--- @return table ids
function M.quick(current, recents, offered, count)
	count = count or M.count()
	local ids, seen = {}, {}
	if current ~= "none" then
		ids[1], seen[current] = current, true
	end
	for _, id in ipairs(recents) do
		if #ids >= count then break end
		if not seen[id] and offered(id) then
			ids[#ids + 1], seen[id] = id, true
		end
	end
	return ids
end

return M
