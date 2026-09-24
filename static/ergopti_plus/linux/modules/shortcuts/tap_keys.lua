--- modules/shortcuts/tap_keys.lua

--- ==============================================================================
--- MODULE: Number-Row Tap Keys (Linux)
--- DESCRIPTION:
--- The three keys at the edges of the number row, the key left of 1
--- (KEY_GRAVE) and the two right of 0 (KEY_MINUS, KEY_EQUAL), each assignable
--- to any catalogue action. A plain tap runs the action and the key is
--- swallowed; with a modifier held, on the AltGr level, or while the key is
--- unassigned, it reaches the application untouched.
---
--- FEATURES & RATIONALE:
--- 1. Decided in the keyboard hook's consumption callback, the one place this
---    daemon can keep a key from the application: under the grab it is the only
---    path to it. The hook then swallows the release and the auto-repeats of the
---    consumed press too.
--- 2. The action runs on the next loop tick, not inside the callback: the hook
---    is mid-decision about a physical event, and an action that types (send_text)
---    must not start injecting before that decision has returned.
--- 3. The key identity, the order and the default action are shared data
---    (_shared/modules/actions/tap_keys.json and the manifest's
---    shortcuts.tap_keys entries), so the three drivers offer the same keys.
--- 4. The menu names each key by what a tap on it types under the keymap the
---    session has loaded (adapters/keyboard_layout over infra/xkb_keymap), a dead
---    key with a hint, never a fixed AZERTY or Ergopti legend.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Paths = require("infra.paths")
local Manifest = require("infra.manifest_reader")

local LOG = "modules.shortcuts.tap_keys"

-- Where the assignments live: one preference per key, so a corrupt entry costs
-- one binding instead of all three.
local PREF_PREFIX = "shortcuts.tap_keys."

-- The binding a tap key's action runs under and stores its parameter under.
local BINDING_PREFIX = "tap_key__"

-- The shared key list.
local KEYS_REL_PATH = "modules/actions/tap_keys.json"

-- The modifiers that make a press "not a plain tap". AltGr is one: it selects a
-- layout level, and the key must type that level's character.
local BLOCKING_MODIFIERS = { "ctrl", "shift", "alt", "altgr", "meta" }

-- Decoded tap_keys.json entries in menu order; nil until read.
local _keys = nil

-- tap key id -> action id, read once from storage over the manifest defaults.
local _assignments = nil

-- Injected by init(): whether the shortcuts feature may act now (on, not paused).
local function NEVER_ACTIVE() return false end
local _is_active = NEVER_ACTIVE

-- Injected by init(): queues a function for the next loop tick.
local _defer = nil




-- =========================================
-- =========================================
-- ======= 1/ Keys and assignments =========
-- =========================================
-- =========================================

--- The shared key list, read once. A missing or malformed file raises: the
--- menu would otherwise show no tap key and nothing would say why.
--- @return table Array of { id, linux }.
function M.keys()
	if _keys then return _keys end
	local path = Paths.shared(KEYS_REL_PATH)
	local handle = path and io.open(path, "r")
	if not handle then error("tap_keys: cannot read " .. tostring(path)) end
	local body = handle:read("*a")
	handle:close()
	local Json = require("json")
	local ok, parsed = pcall(Json.decode, body)
	if not ok or type(parsed) ~= "table" or type(parsed.keys) ~= "table" or #parsed.keys == 0 then
		error("tap_keys: " .. tostring(path) .. " is malformed")
	end
	for _, entry in ipairs(parsed.keys) do
		if type(entry.id) ~= "string" or type(entry.linux) ~= "number" then
			error("tap_keys: an entry of " .. tostring(path) .. " lacks its id or evdev code")
		end
	end
	_keys = parsed.keys
	return _keys
end

--- The binding id a tap key dispatches under.
--- @param id string
--- @return string
function M.binding_id(id)
	return BINDING_PREFIX .. tostring(id)
end

--- The gestures manager, whose catalogue decides which ids a key may hold.
--- @return table|nil
local function action_catalogue()
	local ok, Gestures = pcall(require, "modules.gestures.manager")
	if not ok or type(Gestures) ~= "table" or type(Gestures.is_assignable) ~= "function" then
		Logger.error(LOG, "The action catalogue is unavailable: %s", tostring(Gestures))
		return nil
	end
	return Gestures
end

--- Reads every assignment: the stored value, or the manifest default.
local function load_assignments()
	if _assignments then return end
	local Storage = require("adapters.storage")
	local Gestures = action_catalogue()
	local loaded = {}
	for _, key in ipairs(M.keys()) do
		local value = Storage.get(PREF_PREFIX .. key.id, nil)
		if value == nil then value = Manifest.default_for("shortcuts.tap_keys." .. key.id) end
		if value ~= "none" and not (Gestures and Gestures.is_assignable(value)) then
			Logger.warn(LOG, "Tap key '%s' holds unknown action '%s' — left unassigned.",
				key.id, tostring(value))
			value = "none"
		end
		loaded[key.id] = value
	end
	_assignments = loaded
	Logger.info(LOG, "Tap keys loaded.")
end

--- The action a tap key runs, or "none".
--- @param id string
--- @return string
function M.get_action(id)
	load_assignments()
	return _assignments[id] or "none"
end

--- Assigns an action to a tap key ("none" gives the key back).
--- @param id string
--- @param action_id string
--- @return boolean Whether the assignment was stored.
function M.set_action(id, action_id)
	load_assignments()
	if _assignments[id] == nil then
		Logger.error(LOG, "set_action(): '%s' is not a tap key — nothing bound.", tostring(id))
		return false
	end
	local Gestures = action_catalogue()
	if action_id ~= "none" and not (Gestures and Gestures.is_assignable(action_id)) then
		Logger.warn(LOG, "set_action(): refusing unknown action '%s' for tap key '%s'.",
			tostring(action_id), id)
		return false
	end
	local Storage = require("adapters.storage")
	if not Storage.set(PREF_PREFIX .. id, action_id) then
		Logger.error(LOG, "set_action(): could not persist tap key '%s'.", id)
		return false
	end
	_assignments[id] = action_id
	Logger.info(LOG, "Tap key '%s' → '%s'.", id, action_id)
	return true
end





-- ===========================================
-- ===========================================
-- ======= 2/ The consumption decision =======
-- ===========================================
-- ===========================================

--- Wires the daemon's state in.
--- @param opts table { is_active = fn() -> boolean, defer = fn(fn) -> boolean }
function M.init(opts)
	if type(opts) ~= "table" or type(opts.is_active) ~= "function" or type(opts.defer) ~= "function" then
		error("tap_keys.init() needs is_active and defer functions")
	end
	_is_active = opts.is_active
	_defer = opts.defer
end

--- Decides one key press from the keyboard hook's consumption callback.
--- @param detail table { code, mods } as the hook reports it.
--- @return boolean consumed True when the press ran a tap key's action and
---   must not reach the application.
function M.on_key(detail)
	if type(detail) ~= "table" or type(detail.code) ~= "number" then return false end
	local id = nil
	for _, key in ipairs(M.keys()) do
		if key.linux == detail.code then id = key.id break end
	end
	if not id then return false end
	local mods = type(detail.mods) == "table" and detail.mods or {}
	for _, name in ipairs(BLOCKING_MODIFIERS) do
		if mods[name] then return false end
	end
	local action = M.get_action(id)
	if action == "none" or not _is_active() then return false end
	if not _defer then
		Logger.error(LOG, "Tap key '%s' pressed before init() — the key is typed instead.", id)
		return false
	end
	local queued = _defer(function()
		local Gestures = action_catalogue()
		if not Gestures then return end
		Logger.debug(LOG, "Tap key '%s' fired → '%s'.", id, action)
		Gestures.execute_action(action, M.binding_id(id))
	end)
	if queued ~= true then
		Logger.error(LOG, "Tap key '%s' could not queue '%s' — the key is typed instead.", id, action)
		return false
	end
	return true
end




-- =========================================
-- =========================================
-- ======= 3/ Live key labels ==============
-- =========================================
-- =========================================

--- The key's name in a menu row: what a tap types under the loaded keymap, a
--- dead key's symbol with a hint, or a localized description of its position.
--- @param id string
--- @param layout table The keyboard layout adapter (base_symbol(keycode)).
--- @param i18n table The i18n module.
--- @return string
function M.display_name(id, layout, i18n)
	local code = nil
	for _, key in ipairs(M.keys()) do
		if key.id == id then code = key.linux end
	end
	local symbol = code and layout and type(layout.base_symbol) == "function"
		and layout.base_symbol(code) or nil
	if type(symbol) ~= "table" or type(symbol.text) ~= "string" or symbol.text == "" then
		return i18n.get("menu.shortcuts.tap_keys." .. tostring(id))
	end
	if symbol.dead then
		local template = i18n.get("menu.shortcuts.tap_keys.dead_key")
		local at = template:find("{1}", 1, true)
		if not at then return symbol.text end
		return template:sub(1, at - 1) .. symbol.text .. template:sub(at + 3)
	end
	return symbol.text
end

--- Test seam: forgets what was loaded.
function M._reset()
	_keys = nil
	_assignments = nil
	_is_active = NEVER_ACTIVE
	_defer = nil
end

return M
