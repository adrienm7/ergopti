--- modules/hotstrings/magic_key.lua

--- ==============================================================================
--- MODULE: Magic Key
--- DESCRIPTION:
--- Owns the character that triggers a dynamic hotstring, and lets the user change
--- it.
---
--- WHY THIS EXISTS:
--- Every reader on this driver called `ManifestReader.default_for(…)` directly,
--- which is the DEFAULT and never the user's choice — so the key could not be
--- changed at all here, while Windows and macOS both offer an editor. The menu
--- manifest recorded that honestly, as `platforms = ["ahk","hs"]` with a
--- translated reason, and the right way to close a declared gap is to write the
--- feature rather than to widen the declaration over an absence.
---
--- FEATURES & RATIONALE:
--- 1. One reader, one writer. The manifest supplies the default and nothing else;
---    the stored value wins when there is one. Six call sites reading the default
---    independently is six places for the user's choice to be ignored, which is
---    exactly the state this replaces.
--- 2. Validated before stored. A magic key must be exactly one character, and it
---    must not be one the user types in ordinary text — accepting "e" would make
---    every word containing an e a potential trigger, and the only way back would
---    be to edit the config file the menu exists to avoid.
--- 3. Persisted. A key that resets on restart is worse than no setting: the user
---    reconfigures once, sees it work, and loses it silently.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Storage = require("adapters.storage")
local ManifestReader = require("infra.manifest_reader")
local Terminators = require("keymap.terminators")

local LOG = "magic_key"

-- Where the user's choice lives. Namespaced under hotstrings because that is the
-- feature it belongs to, not because the storage layer needs it.
local STORAGE_KEY = "hotstrings.trigger_char"

-- The manifest path the default comes from. Named once so the two readers below
-- cannot drift onto different keys.
local MANIFEST_PATH = "hotstrings.trigger_char"

-- Set by M.init, so a change can rebuild the menu and re-register the dynamic
-- rules that bake the character into their triggers.
local _on_change = nil




-- =========================================
-- =========================================
-- ======= 1/ Reading ======================
-- =========================================
-- =========================================

--- The character the manifest declares, with no user override applied.
--- @return string
function M.default()
	local value = ManifestReader.default_for(MANIFEST_PATH)
	if Terminators.validate_magic_key(value) then return value end
	-- Reaching here means the manifest lost the key, which is a build problem
	-- rather than a user one. Said loudly rather than papered over with a literal:
	-- a hardcoded fallback here is what put "\" in 21 languages last time.
	Logger.error(LOG, "The manifest declares no default for '%s' — the magic key is unusable.", MANIFEST_PATH)
	return ""
end

--- The character in effect: the user's choice, or the manifest default.
--- @return string
function M.get()
	local stored = Storage.get(STORAGE_KEY, nil)
	if stored ~= nil then
		if M.validate(stored) then return stored end
		Logger.error(LOG, "Stored magic key is unsafe or malformed — using the shipped default.")
	end
	return M.default()
end

--- Whether the user has chosen a key different from the shipped one.
--- @return boolean
function M.is_customised()
	local stored = Storage.get(STORAGE_KEY, nil)
	return M.validate(stored) == true and stored ~= M.default()
end





-- =========================================
-- =========================================
-- ======= 2/ Validating and writing =======
-- =========================================
-- =========================================

--- Whether a candidate can serve as the magic key.
---
--- Length is counted in CODEPOINTS, not bytes: "★" is three bytes and one
--- character, so a byte-length check would reject every non-ASCII key — including
--- the shipped default.
--- @param candidate any
--- @return boolean ok, string|nil reason_key The i18n key explaining a refusal.
function M.validate(candidate)
	if type(candidate) ~= "string" or candidate == "" then
		return false, "dialog.magic_key.error_empty"
	end

	local valid, reason = Terminators.validate_magic_key(candidate)
	if reason == "invalid_character" then
		return false, "dialog.magic_key.error_length"
	end
	if not valid then
		return false, "dialog.magic_key.error_common"
	end

	return true, nil
end

--- Stores a new magic key.
--- @param candidate string
--- @return boolean ok, string|nil reason_key
function M.set(candidate)
	local ok, reason = M.validate(candidate)
	if not ok then
		Logger.warn(LOG, "Refused magic key '%s': %s.", tostring(candidate), tostring(reason))
		return false, reason
	end

	if not Storage.set(STORAGE_KEY, candidate) then
		Logger.error(LOG, "Could not persist the magic key — the change would be lost at restart.")
		return false, "dialog.magic_key.error_persist"
	end

	Logger.info(LOG, "Magic key set to '%s'.", candidate)
	if type(_on_change) == "function" then _on_change(candidate) end
	return true, nil
end

--- Restores the shipped default by removing the stored override.
--- @return boolean
function M.reset()
	Storage.delete(STORAGE_KEY)
	Logger.info(LOG, "Magic key reset to the shipped default '%s'.", M.default())
	if type(_on_change) == "function" then _on_change(M.default()) end
	return true
end




-- =========================================
-- =========================================
-- ======= 3/ Lifecycle ====================
-- =========================================
-- =========================================

--- Registers the callback fired when the key changes.
---
--- The dynamic hotstring rules bake the character into their triggers at
--- registration time, so changing it has to re-register them; the menu has to
--- redraw for the same reason. Both are the daemon's business, not this module's.
--- @param on_change function Called with the new character.
function M.init(on_change)
	Logger.start(LOG, "Initializing…")
	if on_change ~= nil and type(on_change) ~= "function" then
		Logger.error(LOG, "M.init(): on_change must be a function — change notifications disabled.")
		on_change = nil
	end
	_on_change = on_change
	Logger.success(LOG, "Initialized (magic key '%s'%s).",
		M.get(), M.is_customised() and ", user-chosen" or ", shipped default")
end

return M
