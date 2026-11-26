--- hotstrings/engine/magic_key.lua

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
--- 2. Validated before stored. A magic key is exactly one character, any one,
---    as on Windows and macOS (maintainer's decision of 2026-11-21): the layout
---    defaults are « ù » on AZERTY and « ; » on QWERTY.
--- 3. Persisted as the canonical `hotstrings.trigger_char` leaf of config.toml,
---    sparse against the manifest default. A key that resets on restart is worse
---    than no setting: the user reconfigures once, sees it work, and loses it.
--- 4. Its default follows the layout that types (_shared/hotstrings/data/magic_key.json,
---    rules in _shared/hotstrings/engine/magic_key_rules.lua), latched once at
---    boot by M.resolve_layout_default, and every UI shows it as « ★ (ù) »
---    through M.display / M.display_text.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local Preferences = require("hotstrings.engine.matcher.preferences")
local ManifestReader = require("menu.engine.manifest_reader")
local Terminators = require("layouts.engine.layers.terminators")
local ConfigOutdated = require("settings.engine.migration.outdated")
local ConfigKeys = require("settings.engine.keys")
local MagicKeyRules = require("hotstrings.engine.magic_key_rules")

local LOG = "magic_key"

-- The canonical leaf the user's choice lives in and the manifest path its
-- default comes from: one name, so the reader and the writer cannot drift apart.
local MANIFEST_PATH = ConfigKeys.KEY.HOTSTRINGS_TRIGGER_CHAR

-- Set by M.init, so a change can rebuild the menu and re-register the dynamic
-- rules that bake the character into their triggers.
local _on_change, _publisher = nil, nil

-- The shared rules, decoded once, and the layout default latched at boot (nil
-- until then: the manifest default applies).
local _rules, _layout_default = nil, nil

--- The shared magic key rules (_shared/hotstrings/data/magic_key.json).
--- @return table
local function rules()
	if _rules == nil then
		local text = require("core.fs.adapters.file_system").read(
			require("core.fs.engine.paths").shared("hotstrings/data/magic_key.json"))
		if type(text) ~= "string" then error("magic_key: the shared magic key data is unreadable", 2) end
		_rules = MagicKeyRules.new(require("core.text.engine.json").decode(text))
	end
	return _rules
end




-- =========================================
-- =========================================
-- ======= 1/ Reading ======================
-- =========================================
-- =========================================

--- The real marker hotstring data writes, which the configured key replaces.
--- @return string
function M.marker()
	return rules().marker
end

--- Latches the layout default from the base level of the layout that types.
--- @param base_text_of function (code) -> string|nil, KeyboardEvent.code to its unmodified text.
--- @return string magic_key The default now in effect.
--- @return string|nil family The matched layout family, nil for the manifest default.
function M.resolve_layout_default(base_text_of)
	local manifest = ManifestReader.default_for(MANIFEST_PATH)
	if Terminators.validate_character(manifest) ~= true then
		error("magic_key: the manifest declares no valid default for " .. MANIFEST_PATH, 2)
	end
	local magic, family = rules():layout_default(base_text_of, manifest)
	_layout_default = magic
	Logger.info(LOG, "Magic key default: '%s' (%s).", magic, family or "manifest default")
	return magic, family
end

--- Latches the layout default from the session: the XKB keymap's base level,
--- or the manifest default while the layout emulation types the base layer
--- (no emulated layout is an AZERTY or a QWERTY). The caller loads the keymap
--- first (adapters/keyboard_layout.lua refresh).
--- @return string magic_key
--- @return string|nil family
function M.resolve_session_default()
	local Paths = require("core.fs.engine.paths")
	local bytes, status, detail = require("core.text.engine.toml_codec.writer").read_classified(
		require("settings.engine.paths").config("config.toml"))
	if status ~= "ok" and status ~= "absent" then error("magic_key: config.toml is unreadable: " .. tostring(detail), 2) end
	local config = require("core.text.engine.toml_codec").decode(bytes or "")
	local emulated = require("modules.keymap.layout_emulation").configured_base(config, ManifestReader.default_for)
	local text = require("core.fs.adapters.file_system").read(Paths.shared("layouts/data/keycodes/physical_keys.json"))
	if type(text) ~= "string" then error("magic_key: the physical key registry is unreadable", 2) end
	local keys = require("core.text.engine.json").decode(text).keys
	local KeyboardLayout = require("adapters.keyboard_layout")
	return M.resolve_layout_default(function(code)
		if emulated then return nil end
		local key = keys[code]
		if type(key) ~= "table" or type(key.evdev) ~= "number" then return nil end
		local base = KeyboardLayout.base_symbol(key.evdev)
		return type(base) == "table" and base.dead ~= true and base.text or nil
	end)
end

--- How the magic key is shown: « ★ », or « ★ (ù) » for another character.
--- @param char string|nil A character; the key in effect when nil.
--- @return string
function M.display(char)
	return rules():display(char or M.get())
end

--- Shows a user-facing text with every ★ as the magic key in effect is shown.
--- @param text string Text written with the real marker.
--- @param key string|nil Locale key of the text; a literal marker key keeps its ★.
--- @return string
function M.display_text(text, key)
	return rules():display_text(text, M.get(), key)
end

--- The default in effect: the layout default once latched, else the manifest's.
--- @return string
function M.default()
	if _layout_default ~= nil then return _layout_default end
	local value = ManifestReader.default_for(MANIFEST_PATH)
	if Terminators.validate_character(value) then return value end
	-- Reaching here means the manifest lost the key, which is a build problem
	-- rather than a user one. Said loudly rather than papered over with a literal:
	-- a hardcoded fallback here is what put "\" in 21 languages last time.
	Logger.error(LOG, "The manifest declares no default for '%s' — the magic key is unusable.", MANIFEST_PATH)
	return ""
end

--- The character in effect: the user's choice, or the manifest default. A
--- stored key today's policy refuses (one an older build accepted) is an
--- outdated entry: warned once, offered by the cleanup, the default used.
--- @return string
function M.get()
	if Preferences.is_explicit(MANIFEST_PATH) then
		local stored = Preferences.get(MANIFEST_PATH)
		if M.validate(stored) then return stored end
		ConfigOutdated.report(MANIFEST_PATH, ConfigOutdated.REFUSED, Logger)
	end
	return M.default()
end

--- Whether the user has chosen a key different from the shipped one.
--- @return boolean
function M.is_customised()
	if not Preferences.is_explicit(MANIFEST_PATH) then return false end
	local stored = Preferences.get(MANIFEST_PATH)
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

	if Terminators.validate_character(candidate) ~= true then
		return false, "dialog.magic_key.error_length"
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

	if _publisher then
		if _publisher(candidate) ~= true then return false, "dialog.magic_key.error_persist" end
		return true, nil
	end
	if not Preferences.set(MANIFEST_PATH, candidate) then
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
	if _publisher then return _publisher(M.default()) == true end
	if not Preferences.set(MANIFEST_PATH, M.default()) then
		Logger.error(LOG, "Could not remove the stored magic key — the active key was not changed.")
		return false
	end
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
function M.init(on_change, publisher)
	Logger.start(LOG, "Initializing…")
	if on_change ~= nil and type(on_change) ~= "function" then
		Logger.error(LOG, "M.init(): on_change must be a function — change notifications disabled.")
		on_change = nil
	end
	_on_change = on_change
	_publisher = type(publisher) == "function" and publisher or nil
	Logger.success(LOG, "Initialized (magic key '%s'%s).",
		M.get(), M.is_customised() and ", user-chosen" or ", shipped default")
end

--- Test seam: forgets the latched layout default.
function M._reset_for_test()
	_layout_default = nil
end

return M
