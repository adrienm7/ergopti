--- _shared/lua/keycodes/key_names.lua

--- ==============================================================================
--- MODULE: Key Names
--- DESCRIPTION:
--- Names a keyboard key or modifier in visible text, from the one table every
--- driver shares (_shared/data/keycodes/key_names.json, projected to
--- key_names_data.lua). A row used to print the id itself (`lalt`, `caps_lock`)
--- or an abbreviation no locale translated (`LCtrl`, `RShift`).
---
--- FEATURES & RATIONALE:
--- 1. One id, every spelling: `left_control`, `lctrl` and `LCtrl` all name
---    left_ctrl, matched without regard to case.
--- 2. The platform picks the usual name: Alt reads Option on macOS, the system
---    key Super on Linux.
--- 3. Fail fast: an unknown id or an empty translation raises, so a row never
---    falls back to the id it was meant to hide.
--- ==============================================================================

local Data = require("keycodes.key_names_data")

local M = {}

local PLATFORMS = {}
for _, name in ipairs(Data.platforms) do PLATFORMS[name] = true end

--- The key id a spelling names, or nil.
--- @param spelling string Any id or alias, in any case.
--- @return string|nil
function M.canonical(spelling)
	if type(spelling) ~= "string" then return nil end
	local lower = spelling:lower()
	if Data.keys[lower] then return lower end
	return Data.aliases[lower]
end

--- The locale key naming one key on one platform.
--- @param spelling string Any id or alias.
--- @param platform string "windows", "macos" or "linux".
--- @return string
function M.i18n(spelling, platform)
	if not PLATFORMS[platform] then error("key names: unknown platform " .. tostring(platform), 2) end
	local id = M.canonical(spelling)
	if id == nil then error("key names: unknown key " .. tostring(spelling), 2) end
	return Data.keys[id][platform]
end

--- The translated name of one key.
--- @param spelling string Any id or alias.
--- @param platform string "windows", "macos" or "linux".
--- @param translate function Takes a locale key, returns its text.
--- @return string
function M.label(spelling, platform, translate)
	if type(translate) ~= "function" then error("key names: a label needs a translate function", 2) end
	local key = M.i18n(spelling, platform)
	local text = translate(key)
	if type(text) ~= "string" or text == "" or text == key then
		error("key names: " .. key .. " has no translation", 2)
	end
	return text
end

--- The translated names of a combination such as "ctrl+shift", joined with
--- " + " in the order written.
--- @param combo string Ids or aliases joined with "+".
--- @param platform string "windows", "macos" or "linux".
--- @param translate function Takes a locale key, returns its text.
--- @return string
function M.combo_label(combo, platform, translate)
	if type(combo) ~= "string" then error("key names: a combination must be a string", 2) end
	local labels = {}
	for part in combo:gmatch("[^+%s]+") do labels[#labels + 1] = M.label(part, platform, translate) end
	if #labels == 0 then error("key names: an empty combination has no name", 2) end
	return table.concat(labels, " + ")
end

--- The glyph the macOS menus draw for a modifier where they use symbols, the
--- one spelling every such place shares (⌃ for Ctrl, never a caret).
--- @param spelling string Any id or alias of a modifier.
--- @return string
function M.macos_symbol(spelling)
	local id = M.canonical(spelling)
	local symbol = id and Data.macos_symbols[id]
	if symbol == nil then error("key names: no macOS symbol for " .. tostring(spelling), 2) end
	return symbol
end

--- Every key id of the table, sorted.
--- @return table
function M.ids()
	local out = {}
	for id in pairs(Data.keys) do out[#out + 1] = id end
	table.sort(out)
	return out
end

--- Every alias of the table, sorted.
--- @return table
function M.aliases()
	local out = {}
	for alias in pairs(Data.aliases) do out[#out + 1] = alias end
	table.sort(out)
	return out
end

return M
