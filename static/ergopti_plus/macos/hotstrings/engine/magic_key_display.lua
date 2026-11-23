--- hotstrings/engine/magic_key_display.lua

--- ==============================================================================
--- MODULE: Magic Key Rules (macOS)
--- DESCRIPTION:
--- The macOS side of the shared magic key rules (_shared/hotstrings/engine/magic_key_rules.lua,
--- data in _shared/hotstrings/data/magic_key.json): the layout default of
--- `hotstrings.trigger_char` and the « ★ (ù) » display every macOS surface shows.
---
--- FEATURES & RATIONALE:
--- 1. The layout default probes the selected input source's base level on the
---    keys the shared data names (platform.input.keycodes). An emulated layout types
---    over that source, so while one is active the manifest default applies.
--- 2. The display is idempotent here: a text that already shows « ★ (ù) » is
---    folded back before the shared rule runs, so a label translated through
---    the locale layer and then through a menu helper never doubles it.
--- ==============================================================================

local M = {}

local MagicKey   = require("hotstrings.engine.magic_key_rules")
local JsonCodec  = require("core.fs.adapters.json_codec")
local Keycodes   = require("platform.input.keycodes")
local Paths      = require("core.fs.engine.paths")
local Manifest   = require("menu.engine.manifest_reader")
local ConfigKeys = require("settings.engine.keys")

local _rules = nil
local _registry = nil





-- ==============================
-- ==============================
-- ======= 1/ Shared data =======
-- ==============================
-- ==============================

--- Reads one bundled shared data file. Read directly, as other bundled data
--- is: these files ship with the driver and are never user configuration.
--- @param relative string Path under _shared/.
--- @return table parsed
local function read_json(relative)
	local parsed, detail = JsonCodec.decode_file(Paths.shared(relative))
	assert(type(parsed) == "table", "magic key rules: " .. relative .. " is unreadable: " .. tostring(detail))
	return parsed
end

--- The validated shared rules, read once.
--- @return table rules MagicKey.new(magic_key.json).
function M.rules()
	if _rules == nil then _rules = MagicKey.new(read_json("hotstrings/data/magic_key.json")) end
	return _rules
end





-- =================================
-- =================================
-- ======= 2/ Layout default =======
-- =================================
-- =================================

--- What the selected input source types on a key with no modifier.
--- @param code string W3C KeyboardEvent.code.
--- @return string|nil text
local function input_source_text(code)
	if _registry == nil then _registry = read_json("layouts/data/keycodes/physical_keys.json").keys end
	local entry = _registry[code]
	if type(entry) ~= "table" or type(entry.hs) ~= "number" then return nil end
	return Keycodes.character_for(entry.hs)
end

--- Whether an emulated layout types over the input source.
--- @return boolean
local function emulation_types()
	local emulation = package.loaded["modules.keymap.layout_emulation"]
	if type(emulation) ~= "table" or type(emulation.status) ~= "function" then return false end
	return emulation.status().active == true
end

--- The default magic key of the layout that types: « ù » on AZERTY, « ; » on
--- QWERTY, the manifest default elsewhere and while an emulation types.
--- @param probe function|nil (code) -> base-level text; the input source by default.
--- @return string magic_key
function M.layout_default(probe)
	local fallback = Manifest.default_for(ConfigKeys.KEY.HOTSTRINGS_TRIGGER_CHAR)
	if probe == nil then
		if emulation_types() then return fallback end
		probe = input_source_text
	end
	return (M.rules():layout_default(probe, fallback))
end





-- ==========================
-- ==========================
-- ======= 3/ Display =======
-- ==========================
-- ==========================

--- How the configured magic key is shown: « ★ » or « ★ (ù) ».
--- @param char string Configured magic key.
--- @return string
function M.display(char)
	return M.rules():display(char)
end

--- Shows every marker of a user-facing text as the magic key's display.
--- @param text string Text written with the real ★.
--- @param char string Configured magic key.
--- @param key string|nil Locale key of the text; a literal marker key keeps its ★.
--- @return string
function M.display_text(text, char, key)
	if type(text) ~= "string" then return text end
	local rules = M.rules()
	local shown = rules:display(char)
	if shown ~= rules.marker then
		local folded, from = {}, 1
		while true do
			local start, stop = text:find(shown, from, true)
			if not start then break end
			folded[#folded + 1] = text:sub(from, start - 1)
			folded[#folded + 1] = rules.marker
			from = stop + 1
		end
		folded[#folded + 1] = text:sub(from)
		text = table.concat(folded)
	end
	return rules:display_text(text, char, key)
end

--- Forgets the cached data, for tests.
function M._reset_for_test()
	_rules, _registry = nil, nil
end

return M
