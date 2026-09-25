--- _shared/lua/tap_hold/hold_options.lua

--- ==============================================================================
--- MODULE: Tap-Hold Hold Options (shared)
--- DESCRIPTION:
--- Builds the ordered list of choices a hold picker offers, from the catalogue
--- in `_shared/tap_hold/defaults.toml`: the "none" sentinel, every non-empty
--- combination of the declared modifiers, then one entry per declared layer.
---
--- WHY THIS IS SHARED:
--- the list was a hardcoded array in windows/platform/remap/tap_hold_writer.ahk
--- whose own comment claimed it mirrored a shared key that has never existed —
--- so the canonical list was a copy pointing at nothing, and the two Lua drivers
--- had no hold picker at all. A driver that offers a different set of holds than
--- another is a keyboard that behaves differently per OS from one config file.
---
--- WHY ENUMERATED AND NOT LISTED:
--- thirty-one combinations written out is thirty-one chances to write one twice
--- and none. The ORDER is the thing that must not differ, so it is stated once,
--- here: depth-first, left to right — ctrl, ctrl+shift, ctrl+shift+alt, … The
--- AutoHotkey driver's own enumerator produces the same sequence, and
--- tools/test/test-tap-hold-hold-options-parity.cjs holds the two together.
--- ==============================================================================

local M = {}

--- The ordered modifier and layer ids of a picker catalogue.
--- @param catalogue table|nil The `[tap_hold.hold_picker]` table.
--- @return table modifiers, table layers
local function catalogue_ids(catalogue)
	catalogue = type(catalogue) == "table" and catalogue or {}
	local modifiers = type(catalogue.modifiers) == "table" and catalogue.modifiers or {}
	local layers    = type(catalogue.layers) == "table" and catalogue.layers or {}
	return modifiers, layers
end

--- The modifier id an alias of the catalogue means, or nil. The aliases live
--- in the catalogue (`modifier_aliases`, `left_modifier_aliases`) because the
--- Windows loader (ResolveHoldModifierKey) reads the same two tables: one file
--- must mean one hold everywhere. This driver always holds the left key, so
--- the two mean the same here.
--- @param catalogue table|nil The `[tap_hold.hold_picker]` table.
--- @param alias string A lower-case spelling.
--- @return string|nil
local function aliased(catalogue, alias)
	catalogue = type(catalogue) == "table" and catalogue or {}
	for _, field in ipairs({ "modifier_aliases", "left_modifier_aliases" }) do
		local table_of = catalogue[field]
		if type(table_of) == "table" and type(table_of[alias]) == "string" then return table_of[alias] end
	end
	return nil
end

--- Every non-empty combination of `modifiers`, depth-first and left to right.
--- @param modifiers table Ordered modifier ids.
--- @return table Array of combination ids joined with "+".
local function enumerate_combos(modifiers)
	local out = {}
	local function walk(prefix, start_index)
		for index = start_index, #modifiers do
			local combo = (prefix == "") and modifiers[index] or (prefix .. "+" .. modifiers[index])
			out[#out + 1] = combo
			walk(combo, index + 1)
		end
	end
	walk("", 1)
	return out
end

--- The ordered options a hold picker shows.
---
--- Each entry is `{ id, kind, i18n }`:
---   - `kind = "none"`     — the sentinel that clears the hold. `id` is "".
---   - `kind = "modifier"` — `id` is the value stored in `hold_modifier`.
---   - `kind = "layer"`    — `id` is the value stored in `hold_layer`.
---
--- `i18n` is the label key of the sentinel and of a layer; a modifier
--- combination is labelled from its modifiers' own keys (see M.label).
--- @param catalogue table|nil The `[tap_hold.hold_picker]` table.
--- @return table Array of option tables.
function M.build(catalogue)
	local modifiers, layers = catalogue_ids(catalogue)

	local options = { { id = "", kind = "none", i18n = "tap_hold.hold.none" } }
	for _, combo in ipairs(enumerate_combos(modifiers)) do
		options[#options + 1] = { id = combo, kind = "modifier", i18n = "" }
	end
	for _, layer in ipairs(layers) do
		options[#options + 1] = { id = layer, kind = "layer", i18n = "tap_hold.hold." .. layer .. "_layer" }
	end
	return options
end

--- The canonical form of a `hold_modifier` value: its modifiers spelled by
--- their ids, joined in the picker's order, so "Ctrl + Shift", "shift+ctrl"
--- and "CTRL shift" are all "ctrl+shift" and "AltGr" is "alt_gr". "" (or only
--- separators) is no hold. The loader and the writer both go through this, so
--- the engine and the tray only ever see the ids the picker offers.
--- @param value string
--- @param catalogue table|nil The `[tap_hold.hold_picker]` table.
--- @return string|nil canonical, string|nil err Why the value was refused.
function M.canonical_modifier(value, catalogue)
	if type(value) ~= "string" then return nil, "a hold modifier must be a string" end
	local modifiers = catalogue_ids(catalogue)
	local known = {}
	for _, id in ipairs(modifiers) do known[id] = true end
	local chosen, unknown = {}, {}
	for token in value:gmatch("[^+%s]+") do
		local id = token:lower()
		id = aliased(catalogue, id) or id
		if known[id] then chosen[id] = true else unknown[#unknown + 1] = "'" .. token .. "'" end
	end
	if #unknown > 0 then
		return nil, string.format("unknown modifier %s (expected %s)",
			table.concat(unknown, ", "), table.concat(modifiers, ", "))
	end
	local ordered = {}
	for _, id in ipairs(modifiers) do
		if chosen[id] then ordered[#ordered + 1] = id end
	end
	return table.concat(ordered, "+")
end

--- The canonical form of a `hold_layer` value: a declared layer id, matched
--- without regard to case or surrounding blanks; "" is no layer.
--- @param value string
--- @param catalogue table|nil The `[tap_hold.hold_picker]` table.
--- @return string|nil canonical, string|nil err Why the value was refused.
function M.canonical_layer(value, catalogue)
	if type(value) ~= "string" then return nil, "a hold layer must be a string" end
	local _, layers = catalogue_ids(catalogue)
	local wanted = value:match("^%s*(.-)%s*$"):lower()
	if wanted == "" then return "" end
	for _, layer in ipairs(layers) do
		if layer == wanted then return layer end
	end
	return nil, string.format("unknown layer '%s' (expected %s)", value, table.concat(layers, ", "))
end

--- The canonical id of one hold picker choice.
--- @param kind string "none", "modifier" or "layer".
--- @param id string
--- @param catalogue table|nil The `[tap_hold.hold_picker]` table.
--- @return string|nil canonical, string|nil err Why it is not a choice.
function M.canonical(kind, id, catalogue)
	if kind == "none" then
		if id == "" then return "" end
		return nil, "the no-hold choice takes no id"
	end
	local canonical, err
	if kind == "modifier" then
		canonical, err = M.canonical_modifier(id, catalogue)
	elseif kind == "layer" then
		canonical, err = M.canonical_layer(id, catalogue)
	else
		return nil, "unknown hold kind '" .. tostring(kind) .. "'"
	end
	if canonical == "" then return nil, "a " .. kind .. " hold needs a " .. kind end
	return canonical, err
end

--- The label key of one modifier of a combination.
--- @param modifier string A modifier id, e.g. "alt_gr".
--- @return string
function M.modifier_i18n(modifier)
	return "tap_hold.hold." .. modifier
end

--- The label a driver shows for one option.
---
--- A modifier combination is its modifiers' translated labels joined with
--- " + " ("Ctrl + Shift", "AltGr"), as the Windows menu shows it. The stored id
--- ("ctrl+shift", "alt_gr") used to be shown as is, in every locale.
--- @param option table One entry of M.build().
--- @param translate function Takes an i18n key, returns the translated string.
--- @return string
function M.label(option, translate)
	if type(option) ~= "table" then error("a hold option must be a table", 2) end
	if type(translate) ~= "function" then error("a hold option label needs a translate function", 2) end
	if option.kind == "modifier" then
		local labels = {}
		for modifier in tostring(option.id):gmatch("[^+]+") do
			labels[#labels + 1] = translate(M.modifier_i18n(modifier))
		end
		if #labels == 0 then error("a modifier hold option has no modifier", 2) end
		return table.concat(labels, " + ")
	end
	if type(option.i18n) ~= "string" or option.i18n == "" then
		error(string.format("hold option '%s' has no label key", tostring(option.id)), 2)
	end
	return translate(option.i18n)
end

return M
