--- _shared/hotstrings/engine/magic_key.lua

--- ==============================================================================
--- MODULE: Magic Key Character Rules (shared)
--- DESCRIPTION:
--- The magic key is a configured character, never a physical key position
--- (maintainer's decision of 2026-11-21). This module holds the two rules every
--- driver applies to that character, read from _shared/hotstrings/data/magic_key.json:
---
--- 1. Its default follows the layout that types: an AZERTY layout gets « ù », a
---    QWERTY layout « ; », any other layout the manifest default « ★ ». A family
---    matches when every key it names types that character at its base level.
--- 2. Every user-facing text shows the real marker followed by the configured
---    character, « ★ (ù) », never a bare ★ for another character and never the
---    configured character alone. Locale keys that name the real ★ character
---    keep their ★ as written.
---
--- Windows mirrors both rules in _shared/hotstrings/data/magic_key.ahk and the
--- hotstring editor in _shared/ui/hotstring_editor/script.js; all three replay
--- _shared/tests/corpus/hotstrings/magic_key_vectors.json.
--- ==============================================================================

local M = {}

local PLACEHOLDER = "{char}"





-- ==================================
-- ==================================
-- ======= 1/ Data validation =======
-- ==================================
-- ==================================

--- Validates the decoded magic_key.json and indexes its literal keys.
--- @param data table Decoded _shared/hotstrings/data/magic_key.json.
--- @return table rules { marker, display_format, layout_families, literal }
function M.new(data)
	assert(type(data) == "table", "magic_key: the shared data is missing")
	assert(type(data.marker) == "string" and data.marker ~= "", "magic_key: the marker is missing")
	assert(type(data.display_format) == "string" and data.display_format:find(PLACEHOLDER, 1, true),
		"magic_key: the display format lacks its {char} placeholder")
	assert(type(data.layout_families) == "table", "magic_key: the layout families are missing")
	for _, family in ipairs(data.layout_families) do
		assert(type(family.id) == "string" and type(family.base) == "table" and next(family.base) ~= nil,
			"magic_key: a layout family lacks its id or base keys")
		assert(type(family.default_char) == "string" and family.default_char ~= "",
			"magic_key: a layout family lacks its default character")
	end
	assert(type(data.literal_marker_keys) == "table", "magic_key: the literal marker keys are missing")
	local literal = {}
	for _, key in ipairs(data.literal_marker_keys) do
		assert(type(key) == "string" and key ~= "", "magic_key: a literal marker key is not a key")
		literal[key] = true
	end
	return setmetatable({
		marker = data.marker,
		display_format = data.display_format,
		layout_families = data.layout_families,
		literal = literal,
	}, { __index = M })
end





-- =================================
-- =================================
-- ======= 2/ Layout default =======
-- =================================
-- =================================

--- The default magic key of the layout that types.
--- @param base_text_of function (code) -> string|nil: what the key types with no modifier.
--- @param fallback string The manifest default of hotstrings.trigger_char.
--- @return string magic_key
--- @return string|nil family The matched family id, nil for the fallback.
function M:layout_default(base_text_of, fallback)
	assert(type(base_text_of) == "function", "magic_key: the layout probe is missing")
	assert(type(fallback) == "string" and fallback ~= "", "magic_key: the manifest default is missing")
	for _, family in ipairs(self.layout_families) do
		local matches = true
		for code, char in pairs(family.base) do
			if base_text_of(code) ~= char then
				matches = false
				break
			end
		end
		if matches then return family.default_char, family.id end
	end
	return fallback, nil
end





-- ==========================
-- ==========================
-- ======= 3/ Display =======
-- ==========================
-- ==========================

--- How the magic key is shown: the marker alone when it is the marker, else
--- the marker followed by the configured character.
--- @param char string Configured magic key.
--- @return string
function M:display(char)
	assert(type(char) == "string" and char ~= "", "magic_key: the configured character is missing")
	if char == self.marker then return self.marker end
	local start = self.display_format:find(PLACEHOLDER, 1, true)
	return self.display_format:sub(1, start - 1) .. char .. self.display_format:sub(start + #PLACEHOLDER)
end

--- Replaces every marker of a user-facing text by the magic key's display.
--- @param text string Text written with the real marker.
--- @param char string Configured magic key.
--- @param key string|nil Locale key of the text; a literal marker key keeps its ★.
--- @return string
function M:display_text(text, char, key)
	if type(text) ~= "string" then return text end
	if key ~= nil and self.literal[key] then return text end
	local shown = self:display(char)
	if shown == self.marker then return text end
	local parts, from = {}, 1
	while true do
		local start, stop = text:find(self.marker, from, true)
		if not start then break end
		parts[#parts + 1] = text:sub(from, start - 1)
		parts[#parts + 1] = shown
		from = stop + 1
	end
	parts[#parts + 1] = text:sub(from)
	return table.concat(parts)
end

return M
