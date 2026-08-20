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
--- `i18n` is set only where a translated label exists; a modifier combination is
--- labelled from its own id, which is what every driver already displays.
--- @param catalogue table|nil The `[tap_hold.hold_picker]` table.
--- @return table Array of option tables.
function M.build(catalogue)
	catalogue = type(catalogue) == "table" and catalogue or {}
	local modifiers = type(catalogue.modifiers) == "table" and catalogue.modifiers or {}
	local layers    = type(catalogue.layers) == "table" and catalogue.layers or {}

	local options = { { id = "", kind = "none", i18n = "tap_hold.hold.none" } }
	for _, combo in ipairs(enumerate_combos(modifiers)) do
		options[#options + 1] = { id = combo, kind = "modifier", i18n = "" }
	end
	for _, layer in ipairs(layers) do
		options[#options + 1] = { id = layer, kind = "layer", i18n = "tap_hold.hold." .. layer .. "_layer" }
	end
	return options
end

--- The label a driver shows for one option.
--- @param option table One entry of M.build().
--- @param translate function Takes an i18n key, returns the translated string.
--- @return string
function M.label(option, translate)
	if type(option) ~= "table" then return "" end
	if option.i18n ~= nil and option.i18n ~= "" and type(translate) == "function" then
		return translate(option.i18n)
	end
	-- A modifier combination reads as itself: "ctrl+shift" is already the clearest
	-- name it has, and it is what the TOML stores.
	return tostring(option.id or "")
end

return M
