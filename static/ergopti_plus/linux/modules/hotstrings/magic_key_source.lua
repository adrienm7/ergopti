--- modules/hotstrings/magic_key_source.lua

--- ==============================================================================
--- MODULE: Physical Magic Key (Linux)
--- DESCRIPTION:
--- Owns the physical key that types the magic key on this driver: the
--- `hotstrings.magic_key_source` value, its evdev code, and the decision the
--- keyboard hook's consumption callback takes for each press. With the
--- automatic value nothing is remapped and the XKB layout types the magic key
--- itself, as it always did (the Ergopti+ symbols put ★ on <AB03>, KeyC).
---
--- FEATURES & RATIONALE:
--- 1. The shared rules (_shared/lua/keymap/magic_key_source.lua) decide which
---    values are keys and which evdev code a value names, from the manifest
---    entry and the physical-key registry; the value is one canonical
---    config.toml leaf (infra/hotstring_preferences.lua), sparse against the
---    automatic default like the magic key character itself.
--- 2. Consumed, then typed, then read. The grabbed press never reaches the
---    application; the magic key is injected in its place and then handed to
---    the character path, so the buffer, the metrics and a ★-triggered
---    expansion see exactly what the application shows — the order a
---    re-emitted key follows (adapters/keyboard_hook.lua).
--- 3. Fail safe. A paused driver, the replace section off, a modifier held or
---    an injection that did not happen lets the key through untouched, so it is
---    typed exactly once, as its own character.
--- ==============================================================================

local M = {}

local Logger      = require("logger.shim")
local Preferences = require("infra.hotstring_preferences")
local Manifest    = require("infra.manifest_reader")
local Paths       = require("infra.paths")
local FileSystem  = require("adapters.file_system")
local Json        = require("json")
local Shared      = require("keymap.magic_key_source")

local LOG = "magic_key_source"

-- The canonical configuration path of the setting, and its automatic value.
M.PATH = "hotstrings.magic_key_source"
local AUTOMATIC = Manifest.default_for(M.PATH)

-- Built on first use: the registry is 37 KB of JSON nobody needs while the
-- automatic value is in effect and no menu asks for the candidates.
local _resolver = nil

-- The daemon's collaborators, set once by M.init.
local _deps = nil





-- ================================
-- ================================
-- ======= 1/ Value and key =======
-- ================================
-- ================================

--- The shared resolver for evdev codes, built once.
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
		field    = "evdev",
	})
	return _resolver
end

--- The value in effect: the stored key, or the automatic value. An outdated
--- stored value was already reported and reads as absent (the preferences).
--- @return string
function M.get()
	return Preferences.get(M.PATH)
end

--- The evdev code remapped to the magic key, nil while automatic. Asked on
--- every grabbed key-down: the automatic value answers before the registry is
--- ever read.
--- @return number|nil
function M.evdev_code()
	local value = M.get()
	if value == AUTOMATIC then return nil end
	return M.resolver().native(value)
end





-- =========================================
-- =========================================
-- ======= 2/ Keyboard hook decision =======
-- =========================================
-- =========================================

--- Wires the daemon's collaborators, once.
--- @param deps table {
---   is_active     fn() -> boolean  The driver runs and is not paused.
---   replace_on    fn() -> boolean  The magic key's replace section is on.
---   magic_key     fn() -> string   The magic key character.
---   type_text     fn(text) -> boolean  Injects text at the caret.
---   dispatch_char fn(char, code)   The character path a typed key takes. }
function M.init(deps)
	if _deps ~= nil then error("magic_key_source: already initialized", 2) end
	if type(deps) ~= "table" then error("magic_key_source.init needs its collaborators", 2) end
	for _, name in ipairs({ "is_active", "replace_on", "magic_key", "type_text", "dispatch_char" }) do
		if type(deps[name]) ~= "function" then error("magic_key_source.init needs " .. name, 2) end
	end
	Logger.start(LOG, "Initializing…")
	_deps = deps
	Logger.success(LOG, "Initialized (physical magic key %s).", M.get())
end

--- Decides one grabbed key press from the keyboard hook's consumption callback.
--- @param detail table { code, mods, char } as the hook reports a key-down.
--- @return boolean consumed True when the magic key was typed in its place.
function M.on_key(detail)
	if _deps == nil or type(detail) ~= "table" then return false end
	local code = M.evdev_code()
	if code == nil or detail.code ~= code then return false end
	if not Shared.unmodified(detail.mods) then return false end
	if _deps.is_active() ~= true or _deps.replace_on() ~= true then return false end
	local magic = _deps.magic_key()
	if type(magic) ~= "string" or magic == "" then return false end
	local called, typed = pcall(_deps.type_text, magic)
	if not called or typed ~= true then
		Logger.error(LOG, "The magic key could not be typed (%s) — the key types its own character.",
			tostring(called and "injection refused" or typed))
		return false
	end
	_deps.dispatch_char(magic, detail.code)
	return true
end

--- Forgets the collaborators and the resolver (test seam).
function M._reset_for_test()
	_deps = nil
	_resolver = nil
end

return M
