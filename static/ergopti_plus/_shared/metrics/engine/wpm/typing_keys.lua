--- _shared/metrics/engine/wpm/typing_keys.lua

--- ==============================================================================
--- MODULE: Typing Burst Keys (Shared)
--- DESCRIPTION:
--- Which physical keys start, keep or end a typing burst for the typing-speed
--- widget, in each driver's native key codes.
---
--- FEATURES & RATIONALE:
--- 1. One rule (maintainer, 2026-11-16, TWD-2): the widget shows only while text
---    is being typed. The canon's [typing_burst] names the ending groups, the
---    modifiers and the neutral keys by KeyboardEvent.code; the physical-key
---    registry maps each code to the evdev, macOS and AutoHotkey codes.
--- 2. Pure. The caller hands the decoded registry and canon, so both Lua drivers
---    and the tests build the same index without a file system.
--- ==============================================================================

local M = {}

--- The role of a key in a burst.
M.ROLE = { ENDS = "ends", MODIFIER = "modifier", NEUTRAL = "neutral", LEVEL = "level" }

--- Builds native code → role from the registry and the canon's [typing_burst].
--- A key absent from the index is a text key.
--- @param registry table Decoded physical_keys.json ({ keys = { [code] = record } }).
--- @param burst table The canon's [typing_burst] section.
--- @param field string The record field holding the native code ("evdev" or "hs").
--- @return table index { [native_code] = role }
function M.index(registry, burst, field)
	if type(registry) ~= "table" or type(registry.keys) ~= "table" then
		error("typing_keys.index: the physical-key registry is missing its keys", 2)
	end
	if type(burst) ~= "table" then error("typing_keys.index: [typing_burst] is missing", 2) end
	local ending = {}
	for _, group in ipairs(burst.ending_groups or {}) do ending[group] = true end
	local index = {}
	for _, record in pairs(registry.keys) do
		local native = type(record) == "table" and record[field] or nil
		if native ~= nil and ending[record.group] then index[native] = M.ROLE.ENDS end
	end
	-- The level modifiers come last: a driver's own extra list (hs_level_codes)
	-- turns a shortcut modifier of the other drivers into a level one there.
	for _, list_role in ipairs({ { "modifier_codes", M.ROLE.MODIFIER }, { "neutral_codes", M.ROLE.NEUTRAL },
		{ "level_codes", M.ROLE.LEVEL }, { field .. "_level_codes", M.ROLE.LEVEL } }) do
		for _, code in ipairs(burst[list_role[1]] or {}) do
			local record = registry.keys[code]
			if type(record) ~= "table" then
				error("typing_keys.index: [typing_burst]." .. list_role[1] .. " names an unknown key " .. tostring(code), 2)
			end
			if record[field] ~= nil then index[record[field]] = list_role[2] end
		end
	end
	return index
end

-- The burst role of each keymap modifier role: Shift and AltGr levels type text,
-- Ctrl, Alt and Super start shortcuts.
local ROLE_OF_KEYMAP_MODIFIER = {
	shift = M.ROLE.LEVEL, altgr = M.ROLE.LEVEL,
	ctrl = M.ROLE.MODIFIER, alt = M.ROLE.MODIFIER, meta = M.ROLE.MODIFIER,
}

--- Corrects a key's burst role with the role the live keymap gives it, where the
--- driver knows it (Linux XKB): a fifth-level or AltGr key placed on a Ctrl key
--- types text, and Right Alt is a shortcut Alt on a US layout.
--- @param index_role string|nil The role from index() for the physical code.
--- @param keymap_role string|false|nil "shift", "altgr", "ctrl", "alt" or "meta";
---   false when the keymap makes the key no modifier; nil when unknown.
--- @return string|nil role
function M.keymap_role(index_role, keymap_role)
	if keymap_role == nil then return index_role end
	local role = ROLE_OF_KEYMAP_MODIFIER[keymap_role]
	if role then return role end
	-- No modifier in this keymap: a remapped modifier position types text.
	if index_role == M.ROLE.MODIFIER or index_role == M.ROLE.LEVEL then return nil end
	return index_role
end

-- Built indexes per native field, false after a failed build.
local _cache = {}

--- The driver's index, read once from the shared files.
--- @param field string "evdev" or "hs".
--- @return table|nil index
--- @return string|nil err Why it could not be built.
--- @return boolean fresh True only on the first failure, so the caller logs it once.
function M.native_index(field)
	if _cache[field] ~= nil then return _cache[field] or nil, nil, false end
	local ok, index = pcall(function()
		local Paths = require("core.fs.engine.paths")
		local canon, err = require("metrics.engine.wpm_widget_model").load(
			Paths.shared("metrics/data/wpm_widget/constants.toml"), require("core.text.engine.toml_codec").decode)
		if not canon then error(err, 0) end
		local fh = assert(io.open(Paths.shared("layouts/data/keycodes/physical_keys.json"), "r"))
		local text = fh:read("*a")
		fh:close()
		return M.index(require("core.text.engine.json").decode(text), canon.typing_burst, field)
	end)
	if not ok then
		_cache[field] = false
		return nil, tostring(index), true
	end
	_cache[field] = index
	return index, nil, false
end

--- Forgets the built indexes. Tests only.
function M._reset()
	_cache = {}
end

return M
