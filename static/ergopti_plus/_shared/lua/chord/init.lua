--- _shared/lua/chord/init.lua

--- ==============================================================================
--- MODULE: Chord Notation (shared core)
--- DESCRIPTION:
--- Canonical parser and formatter for keyboard chords ("Ctrl+Shift+S"). Every
--- driver names the same chord differently at the OS boundary — AutoHotkey wants
--- "^+s", Hammerspoon wants {"ctrl","shift"} plus "s", kanata wants "C-S-s" — and
--- before this module each driver also invented its own canonical spelling for the
--- SAME chord, so the label shown in the Windows tray and the label shown in the
--- macOS menu were produced by two unrelated pieces of code that merely happened
--- to agree.
---
--- This module owns the OS-neutral half: what a chord IS. Turning a parsed chord
--- into an OS call belongs to the HotkeyRegistrar adapter of each driver, which is
--- the only layer allowed to know that "cmd" is `Hotkey("#…")` on Windows.
---
--- FEATURES & RATIONALE:
--- 1. One canonical spelling: modifiers always appear in MOD_ORDER, never in the
---    order the caller happened to write them, so two spellings of one chord
---    compare equal and a menu label cannot drift from a config file entry.
--- 2. Alias tolerance on input: "command", "win", "super", "meta" and "opt" all
---    name modifiers users actually type. Input is forgiving, output never is.
--- 3. Fail fast on nonsense: parse() returns nil plus a reason rather than a
---    half-chord. A chord that silently lost its key would bind to nothing and
---    report success — the exact failure mode this module exists to prevent.
--- ==============================================================================

local M = {}





-- ===================================
-- ===================================
-- ======= 1/ Canonical Tables =======
-- ===================================
-- ===================================

--- Canonical modifier ordering. A formatted chord always lists modifiers in this
--- order regardless of the order the caller supplied, which is what makes two
--- spellings of one chord string-comparable.
M.MOD_ORDER = { "cmd", "ctrl", "alt", "shift", "fn" }

--- Display spelling for each canonical modifier. These strings are deliberately
--- language-neutral: they are key names, not prose, and are rendered verbatim in
--- every locale.
M.MOD_LABELS = { cmd = "Cmd", ctrl = "Ctrl", alt = "Alt", shift = "Shift", fn = "Fn" }

--- Every spelling a user or a config file may write, mapped to its canonical
--- modifier. Input is forgiving because these names come from humans; output uses
--- MOD_LABELS only.
local MOD_ALIASES = {
	cmd = "cmd", command = "cmd", meta = "cmd", super = "cmd", win = "cmd", windows = "cmd",
	ctrl = "ctrl", control = "ctrl",
	alt = "alt", opt = "alt", option = "alt",
	shift = "shift",
	fn = "fn", func = "fn",
}

--- The separator between a chord's parts. Kept as a constant because the parser
--- and the formatter must never disagree about it.
local SEPARATOR = "+"





-- =======================================
-- =======================================
-- ======= 2/ Parsing & Formatting =======
-- =======================================
-- =======================================

--- Normalises a key name to its canonical internal form.
--- Single characters are upper-cased (so "s" and "S" are one key); longer names
--- are lower-cased (so "Space", "SPACE" and "space" are one key).
--- @param key string Raw key name.
--- @return string Canonical key.
local function canonical_key(key)
	if #key == 1 then return key:upper() end
	return key:lower()
end

--- Renders a canonical key for display.
--- Mirrors the spelling drivers already showed before this module existed, so
--- adopting it cannot silently change a single label the user has learned.
--- @param key string Canonical key.
--- @return string Display spelling.
local function display_key(key)
	if #key == 1 then return key:upper() end
	return key:sub(1, 1):upper() .. key:sub(2)
end

--- Builds the canonical label for a chord.
--- @param mods table Array of modifier names, in any order, in any accepted spelling.
--- @param key string The primary key.
--- @return string|nil label Canonical label, or nil when the chord is invalid.
--- @return string|nil err Reason, when label is nil.
function M.format(mods, key)
	if type(key) ~= "string" or key == "" then
		return nil, "a chord must name a key"
	end
	if mods ~= nil and type(mods) ~= "table" then
		return nil, "modifiers must be an array, got " .. type(mods)
	end

	local present = {}
	for _, raw in ipairs(mods or {}) do
		if type(raw) ~= "string" then
			return nil, "modifier names must be strings, got " .. type(raw)
		end
		local canonical = MOD_ALIASES[raw:lower()]
		if not canonical then
			return nil, "unknown modifier: " .. raw
		end
		present[canonical] = true
	end

	local parts = {}
	for _, mod in ipairs(M.MOD_ORDER) do
		if present[mod] then parts[#parts + 1] = M.MOD_LABELS[mod] end
	end
	parts[#parts + 1] = display_key(canonical_key(key))
	return table.concat(parts, SEPARATOR)
end

--- Parses a chord string into its modifiers and key.
--- @param str string Chord string, e.g. "ctrl+shift+s" or "Cmd+Space".
--- @return table|nil chord { mods = {canonical…}, key = canonical } or nil on failure.
--- @return string|nil err Reason, when chord is nil.
function M.parse(str)
	if type(str) ~= "string" or str == "" then
		return nil, "a chord must be a non-empty string"
	end

	local tokens = {}
	for token in str:gmatch("[^%" .. SEPARATOR .. "]+") do
		token = token:match("^%s*(.-)%s*$")
		if token ~= "" then tokens[#tokens + 1] = token end
	end
	if #tokens == 0 then
		return nil, "a chord must name a key"
	end

	-- The last token is always the key: a chord ending in a modifier name binds
	-- to nothing, and treating "Ctrl+Shift" as a valid chord would let it reach
	-- the OS and fail there instead of here.
	local key = table.remove(tokens)
	local present = {}
	for _, token in ipairs(tokens) do
		local canonical = MOD_ALIASES[token:lower()]
		if not canonical then
			return nil, "unknown modifier: " .. token
		end
		present[canonical] = true
	end

	if MOD_ALIASES[key:lower()] then
		return nil, "a chord must end in a key, not the modifier " .. key
	end

	local mods = {}
	for _, mod in ipairs(M.MOD_ORDER) do
		if present[mod] then mods[#mods + 1] = mod end
	end
	return { mods = mods, key = canonical_key(key) }
end

--- Re-spells a chord string in canonical form.
--- @param str string Chord string in any accepted spelling.
--- @return string|nil label Canonical label, or nil when the chord is invalid.
--- @return string|nil err Reason, when label is nil.
function M.canonicalize(str)
	local chord, err = M.parse(str)
	if not chord then return nil, err end
	return M.format(chord.mods, chord.key)
end

--- Reports whether two chord strings name the same chord.
--- Invalid input is never equal to anything, including itself — an unparseable
--- chord has no identity to compare.
--- @param a string
--- @param b string
--- @return boolean
function M.equals(a, b)
	local ca = M.canonicalize(a)
	local cb = M.canonicalize(b)
	if not ca or not cb then return false end
	return ca == cb
end

return M
