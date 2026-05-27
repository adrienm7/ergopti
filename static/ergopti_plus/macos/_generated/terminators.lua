--- static/ergopti_plus/macos/_generated/terminators.lua
--- AUTO-GENERATED from shared/domain/terminators.spec.js.
--- DO NOT EDIT BY HAND — run `npm run codegen:terminators` to refresh.

--- ==============================================================================
--- CLASS: Terminators
--- DESCRIPTION:
--- Hammerspoon Lua implementation of the Terminators port contract. Owns the
--- terminator catalogue and the O(1) lookup tables used by the hotstring
--- engine. Generated from the shared spec so catalogue data is identical
--- across all drivers.
---
--- CONTRACT METHODS:
---   isTerminator(char)              — true if char belongs to an enabled slot.
---   isConsumed(char)                — true if the matching slot is consumed.
---   setEnabled(key, enabled)        — enable/disable a slot by key.
---   isEnabled(key)                  — query enabled state of a slot.
---   updateMagicKey(char)            — reassign the magic_key slot character.
---   addCustom(key, chars, label, consumed) — add a user-defined slot.
---   all()                           — return the full catalogue array.
--- ==============================================================================

local M = {}




-- ===========================================
-- ===========================================
-- ======= 1/ Constants & Catalogue =======
-- ===========================================
-- ===========================================

--- Built-in terminator definitions seeded from the shared spec.
M.TERMINATOR_DEFS = {
	{ key = "space", chars = { " " }, label = "Espace", default_enabled = true, consume = false },
	{ key = "tab", chars = { "\t" }, label = "Tab", default_enabled = true, consume = false },
	{ key = "enter", chars = { "\r", "\n" }, label = "Entrée", default_enabled = true, consume = false },
	{ key = "period", chars = { "." }, label = "Point", default_enabled = true, consume = false },
	{ key = "comma", chars = { "," }, label = "Virgule", default_enabled = true, consume = false },
	{ key = "semicolon", chars = { ";" }, label = "Point-virgule", default_enabled = true, consume = false },
	{ key = "colon", chars = { ":" }, label = "Deux-points", default_enabled = true, consume = false },
	{ key = "exclamation", chars = { "!" }, label = "Point d'excl.", default_enabled = true, consume = false },
	{ key = "question", chars = { "?" }, label = "Point d'interr.", default_enabled = true, consume = false },
	{ key = "slash", chars = { "/" }, label = "Slash", default_enabled = false, consume = false },
	{ key = "backslash", chars = { "\\" }, label = "Antislash", default_enabled = false, consume = false },
	{ key = "magic_key", chars = { "★" }, label = "Touche magique", default_enabled = true, consume = true }
}


-- Flat enable/disable table keyed by terminator key, seeded from default_enabled.
local _enabled = {}
for _, def in ipairs(M.TERMINATOR_DEFS) do
	_enabled[def.key] = (def.default_enabled ~= false)
end


-- Cached O(1) lookup tables for the per-keystroke hot path. Rebuilt whenever
-- the catalogue is mutated (enable/disable, custom add, magic-key rename).
local _chars_set   = {}
local _consume_set = {}
local function rebuild_cache()
	_chars_set   = {}
	_consume_set = {}
	for _, def in ipairs(M.TERMINATOR_DEFS) do
		if _enabled[def.key] and def.chars then
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




-- =========================================
-- =========================================
-- ======= 2/ Hot-Path Detection =======
-- =========================================
-- =========================================

--- Returns true if char belongs to any enabled terminator slot.
--- @param char string A single UTF-8 codepoint.
--- @return boolean
function M.isTerminator(char)
	return _chars_set[char] == true
end


--- Returns true if the enabled terminator for char is consumed (not echoed).
--- @param char string A single UTF-8 codepoint.
--- @return boolean
function M.isConsumed(char)
	return _consume_set[char] == true
end




-- =========================================
-- =========================================
-- ======= 3/ Enable / Disable =======
-- =========================================
-- =========================================

--- Enables or disables a terminator slot by key.
--- Logs and returns on unknown key per contract error_behavior.
--- @param key string The terminator key identifier.
--- @param enabled boolean True to enable, false to disable.
function M.setEnabled(key, enabled)
	if _enabled[key] == nil then
		print(string.format("[Terminators] setEnabled: unknown key '%s'", tostring(key)))
		return
	end
	_enabled[key] = (enabled ~= false)
	rebuild_cache()
end


--- Returns true if the given terminator key is currently enabled.
--- @param key string The terminator key identifier.
--- @return boolean
function M.isEnabled(key)
	return _enabled[key] == true
end




-- =========================================
-- =========================================
-- ======= 4/ Magic Key Update =======
-- =========================================
-- =========================================

--- Reassigns the magic_key slot to a new character.
--- Rebuilds the O(1) lookup cache after the swap.
--- @param char string A single UTF-8 codepoint.
function M.updateMagicKey(char)
	for _, def in ipairs(M.TERMINATOR_DEFS) do
		if def.key == "magic_key" then
			def.chars = { char }
			break
		end
	end
	rebuild_cache()
end




-- =========================================
-- =========================================
-- ======= 5/ Custom Terminators =======
-- =========================================
-- =========================================

--- Adds a user-defined terminator slot.
--- Logs and returns on key collision per contract error_behavior.
--- @param key string Unique identifier (must not collide with built-in keys).
--- @param chars table Array of characters for this slot.
--- @param label string Display label.
--- @param consumed boolean Whether to swallow the character after expansion.
function M.addCustom(key, chars, label, consumed)
	if _enabled[key] ~= nil then
		print(string.format("[Terminators] addCustom: key collision '%s'", tostring(key)))
		return
	end
	table.insert(M.TERMINATOR_DEFS, {
		key             = key,
		chars           = chars,
		label           = label,
		default_enabled = true,
		consume         = consumed or false,
		custom          = true,
	})
	_enabled[key] = true
	rebuild_cache()
end




-- =========================================
-- =========================================
-- ======= 6/ Catalogue Export =======
-- =========================================
-- =========================================

--- Returns a shallow copy of the full catalogue (enabled + disabled).
--- @return table
function M.all()
	local copy = {}
	for _, def in ipairs(M.TERMINATOR_DEFS) do
		copy[#copy + 1] = def
	end
	return copy
end


return M
