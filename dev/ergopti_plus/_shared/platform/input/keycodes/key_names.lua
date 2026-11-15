--- _shared/platform/input/keycodes/key_names.lua

--- ==============================================================================
--- MODULE: Key Names
--- DESCRIPTION:
--- Names a keyboard key or modifier in visible text, from the one table every
--- driver shares (_shared/layouts/data/keycodes/key_names.json, projected to
--- key_names_data.lua). A row used to print the id itself (`lalt`, `caps_lock`)
--- or an abbreviation no locale translated (`LCtrl`, `RShift`).
---
--- FEATURES & RATIONALE:
--- 1. One id, every spelling: `left_control`, `lctrl` and `LCtrl` all name
---    left_ctrl, matched without regard to case.
--- 2. The platform picks the usual name: Alt reads Option on macOS, the system
---    key Super on Linux.
--- 3. Fail fast: an unknown id or an empty text raises, so a row never falls
---    back to the id it was meant to hide.
--- ==============================================================================

local Data = require("platform.input.keycodes.key_names_data")
local TableUtil = require("core.text.engine.table_util")

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
	-- A catalogue miss comes back as the dotted key, like every other label:
	-- the locale gates and the rendered-row walks refuse it, never the id.
	local key = M.i18n(spelling, platform)
	local text = translate(key)
	if type(text) ~= "string" or text == "" then
		error("key names: " .. key .. " has no text", 2)
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

--- Whether the macOS menus draw a glyph for this key (Fn has none).
--- @param spelling string Any id or alias.
--- @return boolean
function M.has_macos_symbol(spelling)
	local id = M.canonical(spelling)
	return id ~= nil and Data.macos_symbols[id] ~= nil
end

--- The translated names of a set of modifiers, joined with " + " in the order
--- given (« Ctrl + Maj »).
--- @param modifiers table Ids or aliases, in display order.
--- @param platform string "windows", "macos" or "linux".
--- @param translate function Takes a locale key, returns its text.
--- @return string
function M.modifiers_label(modifiers, platform, translate)
	if type(modifiers) ~= "table" or #modifiers == 0 then error("key names: a modifier set must not be empty", 2) end
	local labels = {}
	for index, modifier in ipairs(modifiers) do labels[index] = M.label(modifier, platform, translate) end
	return table.concat(labels, " + ")
end

--- A set of modifiers as a heading names it: on macOS the glyphs its menus
--- draw before the names (« ⌘⇧ Cmd + Maj », « ⌥ Option »), elsewhere the
--- names alone (« Ctrl + Maj »). A set holding a key the table gives no glyph
--- (Fn) reads by its names alone, as a partial row of glyphs would misname it.
--- @param modifiers table Ids or aliases, in display order.
--- @param platform string "windows", "macos" or "linux".
--- @param translate function Takes a locale key, returns its text.
--- @return string
function M.modifiers_heading(modifiers, platform, translate)
	local names = M.modifiers_label(modifiers, platform, translate)
	if platform ~= "macos" then return names end
	local glyphs = {}
	for index, modifier in ipairs(modifiers) do
		local symbol = Data.macos_symbols[M.canonical(modifier)]
		if symbol == nil then return names end
		glyphs[index] = symbol
	end
	return table.concat(glyphs) .. " " .. names
end

--- How one modifier-chord action of modifier_chords.json reads: its modifiers'
--- names, then its key (« Cmd + Option + Maj + Entrée »). A key the table
--- names carries `key_name`; any other prints its legend (A, 1, .), the same in
--- every language. The rows used to print the catalogue's English names.
--- @param modifiers table Ids or aliases, in display order.
--- @param key table A key of modifier_chords.json: { key_name } or { label }.
--- @param platform string "windows", "macos" or "linux".
--- @param translate function Takes a locale key, returns its text.
--- @return string
function M.chord_label(modifiers, key, platform, translate)
	if type(key) ~= "table" then error("key names: a chord needs its key", 2) end
	local key_text
	if key.key_name ~= nil then
		key_text = M.label(key.key_name, platform, translate)
	elseif type(key.label) == "string" and key.label ~= "" then
		key_text = key.label
	else
		error("key names: the chord key " .. tostring(key.id) .. " has neither key_name nor label", 2)
	end
	return M.modifiers_label(modifiers, platform, translate) .. " + " .. key_text
end

--- Fills the {1} of a translated template with one value. A catalogue miss
--- comes back as the dotted key, like every other label, so the locale gates
--- and the rendered-row walks refuse it; a template without {1} raises.
--- @param key string The locale key of the template.
--- @param value string The text {1} stands for.
--- @param translate function Takes a locale key, returns its text.
--- @return string
function M.fill(key, value, translate)
	if type(value) ~= "string" or value == "" then error("key names: " .. tostring(key) .. " needs a value", 2) end
	local template = translate(key)
	if template == key then return template end
	if type(template) ~= "string" or not template:find("{1}", 1, true) then
		error("key names: " .. tostring(key) .. " does not hold {1}", 2)
	end
	return (template:gsub("{1}", function() return value end))
end

--- How one physical position reads in a row: KeyA as A, Digit1 as 1, F5 as
--- F5, a sign position as its legend, a numpad position as « Pavé num. 7 »,
--- any other code as the key it names (PageUp, Escape). A physical slot row
--- used to print the W3C code itself (`KeyA`).
--- @param code string A W3C code of physical_keys.json.
--- @param platform string "windows", "macos" or "linux".
--- @param translate function Takes a locale key, returns its text.
--- @return string
function M.physical_label(code, platform, translate)
	if type(code) ~= "string" then error("key names: a physical code must be a string", 2) end
	local letter = code:match("^Key(%u)$") or code:match("^Digit(%d)$")
	if letter then return letter end
	if code:match("^F%d%d?$") then return code end
	local legend = Data.physical.legends[code]
	local pad = code:match("^Numpad(.+)$")
	if pad then
		local inner = pad:match("^%d$") and pad or legend or (M.canonical(pad) and M.label(pad, platform, translate))
		if not inner then error("key names: no name for the physical key " .. code, 2) end
		local template = translate(Data.physical.numpad)
		-- A catalogue miss shows its dotted key, like every other label.
		if template == Data.physical.numpad then return template .. " " .. inner end
		if type(template) ~= "string" or not template:find("{1}", 1, true) then
			error("key names: " .. Data.physical.numpad .. " does not hold {1}", 2)
		end
		return (template:gsub("{1}", function() return inner end))
	end
	if legend then return legend end
	if not M.canonical(code) then error("key names: no name for the physical key " .. code, 2) end
	return M.label(code, platform, translate)
end

--- Every key id of the table, sorted.
--- @return table
function M.ids()
	return TableUtil.sorted_keys(Data.keys)
end

--- Every alias of the table, sorted.
--- @return table
function M.aliases()
	return TableUtil.sorted_keys(Data.aliases)
end

return M
