--- modules/keymap/magic_key_source.lua

--- ==============================================================================
--- MODULE: Physical Magic Key (macOS)
--- DESCRIPTION:
--- Owns the physical key that types the magic key on this driver: the
--- `hotstrings.magic_key_source` value in effect, its virtual keycodes, and the
--- per-press decision the keymap event tap applies. With the automatic value
--- nothing is remapped and the input source types the magic key itself, as it
--- always did (the Ergopti+ keylayouts put ★ on KeyC).
---
--- FEATURES & RATIONALE:
--- 1. The shared rules (_shared/lua/keymap/magic_key_source.lua) decide which
---    values are keys and which keycode a value names, from the manifest entry
---    and the physical-key registry.
--- 2. The event's keyboard model determines which of the ISO-swapped virtual
---    codes denotes the chosen physical key. The other key stays untouched.
--- 3. Nothing on the typing path. The keycodes are resolved when the value is
---    set; the tap looks one integer up and asks nothing more of any other key.
--- 4. An outdated stored value is automatic here; infra/preferences.lua reports
---    it once and leaves it to the config cleanup.
--- ==============================================================================

local M = {}

local Logger     = require("infra.logger")
local Manifest   = require("infra.manifest_reader")
local Paths      = require("infra.paths")
local FileSystem = require("adapters.file_system")
local Json       = require("json")
local Shared     = require("keymap.magic_key_source")
local Geometry   = require("adapters.keyboard_geometry")

local LOG = "keymap.magic_key_source"

-- The canonical configuration path of the setting, and its automatic value.
M.PATH = "hotstrings.magic_key_source"
local AUTOMATIC = Manifest.default_for(M.PATH)

-- The registry record holding a key's keycode on a bare ISO board, where the
-- key left of 1 and the key left of Z trade keycodes.
local ISO_FORM = "macos_iso"

-- Built on first use: the registry is 37 KB of JSON nobody needs while the
-- automatic value is in effect and no menu asks for the candidates.
local _registry = nil
local _resolver = nil
local _value = AUTOMATIC
local _keycode = nil
-- The chosen key's ISO identity, nil while automatic.
local _iso_keycode = nil





-- ===========================
-- ===========================
-- ======= 1/ Resolver =======
-- ===========================
-- ===========================

--- The decoded physical-key registry, read once.
--- @return table registry
local function registry()
	if _registry then return _registry end
	local path = Paths.shared("data/keycodes/physical_keys.json")
	local text = path and FileSystem.read(path)
	if type(text) ~= "string" then
		error("the physical-key registry is unreadable: " .. tostring(path))
	end
	_registry = Json.decode(text)
	return _registry
end

--- The shared resolver's ANSI identities define canonical physical positions.
--- Event dispatch and capture project those positions through their model.
--- @return table resolver
function M.resolver()
	if _resolver then return _resolver end
	_resolver = Shared.new({
		entry    = Manifest.find_entry_by_path(M.PATH),
		registry = registry(),
		field    = "hs",
	})
	return _resolver
end

--- Resolves a captured virtual code using that event's keyboard geometry.
--- Call resolver() before acquiring capture so this lookup performs no IO.
--- @param keycode integer Captured virtual keycode.
--- @param keyboard_type integer|nil Captured keyboard model.
--- @return string|nil candidate Canonical physical-key identity.
function M.code_for(keycode, keyboard_type)
	if type(keycode) ~= "number" then return nil end
	for _, candidate in ipairs(M.resolver().candidates()) do
		if Geometry.physical_code(registry().keys[candidate], keyboard_type) == keycode then return candidate end
	end
	return nil
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
		_value, _keycode, _iso_keycode = AUTOMATIC, nil, nil
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
	local record = _keycode and registry().keys[applied] or nil
	_iso_keycode = record and type(record[ISO_FORM]) == "table" and record[ISO_FORM].hs or _keycode
	Logger.info(LOG, "Physical magic key: %s.", _keycode and (applied .. " (keycode " .. _keycode .. ")") or applied)
	return applied
end

--- The value in effect.
--- @return string
function M.get()
	return _value
end

--- The keycode of the chosen key behind Karabiner's ANSI virtual keyboard,
--- nil while automatic.
--- @return number|nil
function M.keycode()
	return _keycode
end

--- The refusal reason for a candidate reserved by a configured tap assignment.
--- @param value string Candidate or automatic value.
--- @return string|nil reason_key
function M.choice_reason(value)
	local resolver = M.resolver()
	if value == resolver.automatic then return nil end
	if not resolver.is_candidate(value) then return "dialog.magic_key_source.not_a_candidate" end
	local TapKeys = require("modules.shortcuts.tap_keys")
	TapKeys.ensure_loaded(require("modules.gestures.actions").is_assignable)
	-- Both inputs to the shared policy name canonical physical positions. ISO
	-- arrival aliases cannot reserve a different key in the stored settings.
	local positions = {}
	for _, key in ipairs(TapKeys.keys()) do positions[#positions + 1] = { id = key.id, hs = key.hs[1] } end
	if Shared.tap_conflict(resolver, value, positions, "hs", TapKeys.get_action) then
		return Shared.TAP_CONFLICT_REASON
	end
	return nil
end

--- Whether a keycode can be the chosen key: the tap's one cheap question.
--- @param key_code number Virtual keycode of the press.
--- @param keyboard_type integer|nil Originating keyboard model.
--- @return boolean
function M.owns(key_code, keyboard_type)
	return _keycode ~= nil and type(key_code) == "number"
		and Geometry.native_code(_keycode, _iso_keycode, keyboard_type) == key_code
end

--- Whether this candidate press requires its originating keyboard model.
--- @param key_code integer Virtual keycode.
--- @return boolean required
function M.needs_geometry(key_code)
	return _keycode ~= _iso_keycode and (key_code == _keycode or key_code == _iso_keycode)
end

--- Whether a key press must type the magic key: the chosen key, pressed with no
--- modifier, while `replace_on` confirms the magic key's replace section.
--- @param key_code number Virtual keycode of the press.
--- @param flags table Event flags (cmd, alt, ctrl, shift…).
--- @param replace_on function Returns whether the replace section is on.
--- @param keyboard_type integer|nil Originating keyboard model.
--- @return boolean
function M.remaps(key_code, flags, replace_on, keyboard_type)
	if not M.owns(key_code, keyboard_type) then return false end
	if not Shared.unmodified(flags) or replace_on() ~= true then return false end
	-- Only the already-loaded, acknowledged dispatcher can own this press.
	-- No native module, file or layout probe is loaded from the keyDown path.
	local System = package.loaded["modules.shortcuts.actions.system"]
	if type(System) == "table" and type(System.has_tap_key_claim) == "function" then
		return System.has_tap_key_claim(key_code, flags, keyboard_type) == false
	end
	return true
end

return M
