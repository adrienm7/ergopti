--- modules/keymap/terminators.lua

--- ==============================================================================
--- MODULE: Keymap Terminators
--- DESCRIPTION:
--- Owns the terminator catalogue (definitions, enable/disable state, custom
--- user-added entries) and the O(1) lookup sets used by the per-keystroke
--- hot path. Previously lived inline in registry.lua, which bundled two
--- unrelated concerns (mapping storage vs. terminator detection) in the
--- same file.
---
--- FEATURES & RATIONALE:
--- 1. Single Catalogue: TERMINATOR_DEFS is the only place that lists which
---    characters can end a hotstring — menu builders and the expander read
---    from here rather than re-declaring their own sets.
--- 2. O(1) Hot Path: is_terminator() and terminator_is_consumed() go through
---    pre-built hash sets rather than walking the definition list; the sets
---    are rebuilt only on mutation (enable/disable, custom add/remove, magic-
---    key rename), so keystroke-time cost is constant.
--- 3. Multi-Codepoint Safety: both lookups also probe the first codepoint of
---    `chars`, so dead-key / IME composition events whose leading codepoint
---    is a terminator still fire their expansion.
--- ==============================================================================

local M      = {}
local Logger = require("lib.logger")
local LOG    = "keymap.terminators"




-- =========================================
-- =========================================
-- ======= 1/ Constants & Definitions ======
-- =========================================
-- =========================================

--- Built-in terminator definitions. Each entry with a key produces one entry
--- in the enable/disable table. Separators (type = "separator") are UI-only.
M.TERMINATOR_DEFS = {
	{ key = "space",                chars = { " " },          label = "␣ : Espace",                   default_enabled = true },
	{ key = "nbsp",                 chars = { "\u{00A0}" },   label = "⍽ : Espace insécable",         default_enabled = true },
	{ key = "nnbsp",                chars = { "\u{202F}" },   label = "⍽ : Espace fine insécable",    default_enabled = true },
	{ key = "minus",                chars = { "-" },          label = "- : Tiret",                    default_enabled = false },
	{ key = "underscore",           chars = { "_" },          label = "_ : Tiret bas",                default_enabled = false },
	{ type = "separator" },
	{ key = "tab",                  chars = { "\t" },         label = "⇥ : Tabulation",               default_enabled = false },
	{ key = "enter",                chars = { "\r", "\n" },   label = "⏎ : Entrée",                   default_enabled = false },
	{ key = "star",                 chars = { "★" },          label = "★ : Touche magique",           default_enabled = true, consume = true },
	{ type = "separator" },
	{ key = "comma",                chars = { "," },          label = ", : Virgule",                  default_enabled = true },
	{ key = "period",               chars = { "." },          label = ". : Point",                    default_enabled = false },
	{ key = "exclam",               chars = { "!" },          label = "! : Point d'exclamation",      default_enabled = false },
	{ key = "question",             chars = { "?" },          label = "? : Point d'interrogation",    default_enabled = false },
	{ key = "colon",                chars = { ":" },          label = ": : Deux-points",              default_enabled = false },
	{ type = "separator" },
	{ key = "parenright",           chars = { ")" },          label = ") : Parenthèse fermante",      default_enabled = false },
	{ key = "braceright",           chars = { "}" },          label = "} : Accolade fermante",        default_enabled = false },
	{ key = "bracketright",         chars = { "]" },          label = "] : Crochet fermant",          default_enabled = false },
	{ key = "anglebracketright",    chars = { ">" },          label = "> : Guillemet fermant",        default_enabled = false },
	{ type = "separator" },
	{ key = "apostrophe_typo",      chars = { "'" },          label = "' : Apostrophe typographique", default_enabled = false },
	{ key = "apostrophe_straight",  chars = { "'" },          label = "' : Apostrophe droite",        default_enabled = false },
	{ key = "quote",                chars = { '"' },          label = '" : Guillemet double',         default_enabled = false },
	{ key = "equal",                chars = { "=" },          label = "= : Égal",                     default_enabled = false },
	{ key = "slash",                chars = { "/" },          label = "/ : Slash",                    default_enabled = false },
	{ key = "backslash",            chars = { "\\" },         label = "\\ : Backslash",               default_enabled = false },
}


-- Flat enable/disable table keyed by terminator key, seeded from default_enabled.
local _enabled = {}
for _, def in ipairs(M.TERMINATOR_DEFS) do
	if def.key then
		_enabled[def.key] = (def.default_enabled ~= false)
	end
end


-- Cached O(1) lookup sets for the per-keystroke hot path. Every call to
-- is_terminator() used to walk TERMINATOR_DEFS and each def's chars list
-- (linear scan on every keydown); terminator_is_consumed() did the same.
-- We rebuild these maps whenever terminator state changes so the keystroke
-- path stays O(1).
local _chars_set   = {}
local _consume_set = {}
local function rebuild_cache()
	_chars_set   = {}
	_consume_set = {}
	for _, def in ipairs(M.TERMINATOR_DEFS) do
		if def.key and _enabled[def.key] and def.chars then
			for _, c in ipairs(def.chars) do
				if type(c) == "string" and c ~= "" then
					_chars_set[c] = true
					if def.consume then _consume_set[c] = true end
				end
			end
		end
	end
end
rebuild_cache()


--- Returns the first UTF-8 codepoint of `s`. Used by terminator matching so
--- that a multi-codepoint event (e.g. dead-key sequences, IME composition)
--- whose first codepoint is a single-char terminator still triggers.
--- @param s string The input string.
--- @return string The first UTF-8 character, or "" when s is empty.
local function first_codepoint(s)
	if type(s) ~= "string" or s == "" then return "" end
	local ok, off = pcall(utf8.offset, s, 2)
	if ok and off then return s:sub(1, off - 1) end
	return s:sub(1, 1)
end




-- =========================================
-- =========================================
-- ======= 2/ Hot-Path Detection ===========
-- =========================================
-- =========================================

--- Returns true if `chars` matches an enabled terminator. If `chars` is a
--- multi-codepoint event, we also compare against its first codepoint so that
--- dead-key / IME-composed sequences whose leading codepoint is a terminator
--- still fire the expansion. Lookups go through a pre-built set so the hot
--- path is O(1) regardless of how many terminator definitions exist.
--- @param chars string The typed character(s) to check.
--- @return boolean
function M.is_terminator(chars)
	if _chars_set[chars] then return true end
	if #chars > 0 then
		local first = first_codepoint(chars)
		if first ~= chars and _chars_set[first] then return true end
	end
	return false
end

--- Returns true if `chars` matches an enabled terminator that should be consumed
--- (i.e., not re-typed after the expansion fires). Also recognises the first
--- codepoint of multi-codepoint events for the same reason as is_terminator().
--- @param chars string The typed character(s) to check.
--- @return boolean
function M.terminator_is_consumed(chars)
	if _consume_set[chars] then return true end
	if #chars > 0 then
		local first = first_codepoint(chars)
		if first ~= chars and _consume_set[first] then return true end
	end
	return false
end




-- =========================================
-- =========================================
-- ======= 3/ Enable / Disable =============
-- =========================================
-- =========================================

--- Enables or disables a terminator by key.
--- @param key string The terminator key identifier.
--- @param en boolean True to enable, false to disable.
function M.set_terminator_enabled(key, en)
	_enabled[key] = (en ~= false)
	rebuild_cache()
	Logger.debug(LOG, "Terminator '%s': %s.", key, en and "enabled" or "disabled")
end

--- Returns true if the given terminator key is currently enabled.
--- @param key string The terminator key identifier.
--- @return boolean
function M.is_terminator_enabled(key)
	return _enabled[key] ~= false
end

--- Returns the full terminator definitions table (by reference — do not mutate).
--- @return table
function M.get_terminator_defs()
	return M.TERMINATOR_DEFS
end




-- =========================================
-- =========================================
-- ======= 4/ Custom Terminators ===========
-- =========================================
-- =========================================

--- Adds or updates a user-defined terminator.
--- Idempotent: calling with the same key updates the existing definition in place.
--- @param key string Unique identifier (e.g. "custom_dot").
--- @param char string The trigger character.
--- @param label string Human-readable label shown in the menu.
--- @param consume boolean Whether to swallow the character after expansion.
function M.add_custom_terminator(key, char, label, consume)
	if type(key) ~= "string" or type(char) ~= "string" then
		Logger.error(LOG, "add_custom_terminator: invalid key or char (key='%s', char='%s').",
			tostring(key), tostring(char))
		return
	end
	-- Update in place if the key already exists (idempotent on reload).
	for _, def in ipairs(M.TERMINATOR_DEFS) do
		if def.key == key then
			def.chars   = { char }
			def.label   = label
			def.consume = consume or false
			rebuild_cache()
			Logger.debug(LOG, "Custom terminator '%s' updated.", key)
			return
		end
	end
	table.insert(M.TERMINATOR_DEFS, {
		key             = key,
		chars           = { char },
		label           = label,
		consume         = consume or false,
		default_enabled = true,
		custom          = true,
	})
	_enabled[key] = true
	rebuild_cache()
	Logger.info(LOG, "Custom terminator '%s' added.", key)
end

--- Removes a user-defined terminator (no-op on built-in terminators).
--- @param key string The unique identifier of the terminator to remove.
function M.remove_custom_terminator(key)
	for i, def in ipairs(M.TERMINATOR_DEFS) do
		if def.key == key and def.custom then
			table.remove(M.TERMINATOR_DEFS, i)
			_enabled[key] = nil
			rebuild_cache()
			Logger.info(LOG, "Custom terminator '%s' removed.", key)
			return
		end
	end
	Logger.warn(LOG, "remove_custom_terminator: key '%s' not found or not custom.", tostring(key))
end




-- =========================================
-- =========================================
-- ======= 5/ Magic Key Sync ===============
-- =========================================
-- =========================================

--- Reassigns the magic-key character carried by the "star" terminator entry.
--- Called by Registry.update_trigger_char() whenever the user picks a new
--- magic key, so both the mapping database AND the terminator set stay in
--- sync on the same character.
--- @param magic_key string The new trigger character.
function M.update_magic_key(magic_key)
	for _, def in ipairs(M.TERMINATOR_DEFS) do
		if def.key == "star" then
			def.chars = { magic_key }
			def.label = magic_key .. " : Touche magique"
		end
	end
	rebuild_cache()
end


return M
