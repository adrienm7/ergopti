--- _shared/lua/keystats/physical_position_observation.lua

--- Reduces one admitted native press and its exact held roster to editor facts.
--- This is observation only: it never assigns a shortcut or grants delivery.
local M = {}
local MODIFIERS = { [0xE0] = "ctrl", [0xE1] = "shift", [0xE2] = "alt", [0xE3] = "super",
	[0xE4] = "ctrl", [0xE5] = "shift", [0xE6] = "alt", [0xE7] = "super" }

--- Shares form-independent eligibility between fixed inventory and fresh presses.
---@param page number Native HID page.
---@param usage number Native HID usage.
---@param keycode number|nil Registry-resolved native keycode, without a guessed form.
---@return boolean eligible
function M.primary(page, usage, keycode)
	return page == 7 and type(usage) == "number" and usage % 1 == 0 and usage >= 4 and usage <= 255
		and not MODIFIERS[usage] and usage ~= 0x39 and type(keycode) == "number"
		and keycode >= 0 and keycode % 1 == 0 and keycode ~= 10 and keycode ~= 50
end

--- Produces detached form-independent facts from the native owner's closed snapshot.
--- Raw device, cookie and keyboard form remain inside that owner.
---@param press table Qualified fresh primary press and per-row held roster.
---@return table|nil facts Closed native_code/mods payload, or a refused observation.
function M.facts(press)
	if type(press) ~= "table" or getmetatable(press) ~= nil
		or not M.primary(press.page, press.usage, press.keycode)
		or type(press.device) ~= "string" or type(press.cookie) ~= "number"
		or type(press.held) ~= "table" or getmetatable(press.held) ~= nil then return nil end
	local mods, own = {}, false
	for _, key in ipairs(press.held) do
		if type(key) ~= "table" or getmetatable(key) ~= nil then return nil end
		if key.device == press.device and key.cookie == press.cookie then
			if key.page ~= press.page or key.usage ~= press.usage
				or key.keyboard_type ~= press.keyboard_type then return nil end
			own = true
		end
		local modifier = key.page == 7 and MODIFIERS[key.usage] or nil
		if modifier then
			-- A closed editor payload cannot prove a chord assembled across devices.
			if key.device ~= press.device or key.keyboard_type ~= press.keyboard_type then return nil end
			mods[modifier] = true
		elseif key.page == 7 and key.usage == 0x39
			or (key.page == 0xFF or key.page == 0xFF01) and key.usage == 3 then
			-- Caps and fn have no representation in the existing editor modifier set.
			return nil
		end
	end
	if not own then return nil end
	return { native_code = press.keycode, mods = mods }
end

return M
