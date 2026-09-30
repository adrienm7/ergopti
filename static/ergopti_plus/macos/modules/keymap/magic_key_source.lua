--- modules/keymap/magic_key_source.lua

--- ==============================================================================
--- MODULE: Physical Magic Key (macOS)
--- DESCRIPTION:
--- Owns the physical key that types the magic key on this driver: the
--- `hotstrings.magic_key_source` value in effect, its virtual keycode, and the
--- per-press decision the keymap event tap applies. With the automatic value
--- nothing is remapped and the input source types the magic key itself, as it
--- always did (the Ergopti+ keylayouts put ★ on KeyC).
---
--- FEATURES & RATIONALE:
--- 1. The shared rules (_shared/lua/keymap/magic_key_source.lua) decide which
---    values are keys and which keycode a value names, from the manifest entry
---    and the physical-key registry, read in the ISO form the navigation layer
---    uses (platform/remap/nav_layer.lua), so a key captured by pressing it
---    round-trips to the same keycode.
--- 2. Nothing on the typing path. The keycode is resolved when the value is set;
---    the tap compares one integer and asks nothing more of any other key.
--- 3. An outdated stored value is automatic here; infra/preferences.lua reports
---    it once and leaves it to the config cleanup.
--- ==============================================================================

local M = {}

local Logger     = require("infra.logger")
local Manifest   = require("infra.manifest_reader")
local Paths      = require("infra.paths")
local FileSystem = require("adapters.file_system")
local Json       = require("json")
local Shared     = require("keymap.magic_key_source")
local NavLayer   = require("platform.remap.nav_layer")

local LOG = "keymap.magic_key_source"

-- The canonical configuration path of the setting, and its automatic value.
M.PATH = "hotstrings.magic_key_source"
local AUTOMATIC = Manifest.default_for(M.PATH)

-- Built on first use: the registry is 37 KB of JSON nobody needs while the
-- automatic value is in effect and no menu asks for the candidates.
local _resolver = nil
local _value = AUTOMATIC
local _keycode = nil





-- ===========================
-- ===========================
-- ======= 1/ Resolver =======
-- ===========================
-- ===========================

--- The shared resolver for macOS keycodes, built once.
--- @return table resolver
function M.resolver()
	if _resolver then return _resolver end
	local path = Paths.shared("data/keycodes/physical_keys.json")
	local text = path and FileSystem.read(path)
	if type(text) ~= "string" then
		error("the physical-key registry is unreadable: " .. tostring(path))
	end
	_resolver = Shared.new({
		entry    = Manifest.find_entry_by_path(M.PATH),
		registry = Json.decode(text),
		field    = "hs",
		override = "macos_" .. NavLayer.KEYBOARD_FORM,
	})
	return _resolver
end





-- ========================
-- ========================
-- ======= 2/ State =======
-- ========================
-- ========================

--- Applies a stored value. An outdated one is the automatic value.
--- @param value any Stored value, nil when absent.
--- @return string value The value now in effect.
function M.set(value)
	-- Every boot applies the stored value: the automatic one, by far the most
	-- common, remaps nothing and needs no registry.
	if value == nil or value == AUTOMATIC then
		_value, _keycode = AUTOMATIC, nil
		Logger.info(LOG, "Physical magic key: %s.", AUTOMATIC)
		return AUTOMATIC
	end
	local resolver = M.resolver()
	local applied, outdated = resolver.normalize(value)
	-- The preference reader already named an outdated entry with its one
	-- WARNING (config_outdated); this only records which value took effect.
	if outdated then
		Logger.debug(LOG, "Physical magic key %s — the layout keeps its own magic key.", outdated)
	end
	_value = applied
	_keycode = resolver.native(applied)
	Logger.info(LOG, "Physical magic key: %s.", _keycode and (applied .. " (keycode " .. _keycode .. ")") or applied)
	return applied
end

--- The value in effect.
--- @return string
function M.get()
	return _value
end

--- The virtual keycode remapped to the magic key, nil while automatic.
--- @return number|nil
function M.keycode()
	return _keycode
end

--- Whether a key press must type the magic key: the chosen key, pressed with no
--- modifier, while `replace_on` confirms the magic key's replace section.
--- @param key_code number Virtual keycode of the press.
--- @param flags table Event flags (cmd, alt, ctrl, shift…).
--- @param replace_on function Returns whether the replace section is on.
--- @return boolean
function M.remaps(key_code, flags, replace_on)
	if _keycode == nil or key_code ~= _keycode then return false end
	return Shared.unmodified(flags) and replace_on() == true
end

return M
