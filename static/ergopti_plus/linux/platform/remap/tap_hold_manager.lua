--- platform/remap/tap_hold_manager.lua

--- ==============================================================================
--- MODULE: Tap-Hold Manager (Linux)
--- DESCRIPTION:
--- Owns the daemon's tap-hold engine: loads the configuration, installs the
--- engine in the keyboard hook, runs the tap actions, and takes it out again on
--- pause or when the feature is switched off.
---
--- FEATURES & RATIONALE:
--- 1. One owner for "is a tap-hold active right now": the feature switch, the
---    [tap_hold] enabled flag of the user's file and the daemon's pause all
---    meet in _apply(), so none of them can leave a half-installed engine.
--- 2. Every change goes through the hook's set_remapper(), which releases what
---    the previous engine held first — switching off or pausing while CapsLock
---    is down cannot leave Ctrl pressed.
--- 3. reload() re-reads the files and swaps the engine live: a change made from
---    the tray takes effect on the next keystroke, with no process to restart.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Config = require("platform.remap.tap_hold_loader")
local Engine = require("platform.remap.tap_hold_engine")
local Timings = require("infra.timings")
local HoldOptions = require("tap_hold.hold_options")
local EmitActions = require("_generated.gesture_emit_actions")

local LOG = "platform.remap.tap_hold_manager"
local MS_PER_SECOND = 1000


-- =========================================
-- =========================================
-- ======= 1/ State ========================
-- =========================================
-- =========================================

local _initialized = false
local _hook = nil            -- The keyboard hook the engine is installed in.
local _execute_action = nil  -- Runs a catalogue action by name.
local _action_names = nil    -- The action catalogue's ids.
local _defaults_path = nil
local _user_path = nil
local _loaded = nil          -- Config.load() result.
local _engine = nil          -- Built from _loaded; nil when there is nothing to run.
local _enabled = true        -- The runtime feature switch (« Disable all »).
local _paused = false        -- The daemon's pause.


-- =========================================
-- =========================================
-- ======= 2/ Internals ====================
-- =========================================
-- =========================================

--- Runs one tap action: the engine returns the catalogue actions it cannot
--- express as key events of its own.
--- @param action string
local function _run_tap(action)
	Logger.debug(LOG, "Tap action '%s'.", action)
	local ok, err = pcall(_execute_action, action, "tap_hold")
	if not ok then Logger.error(LOG, "Tap action '%s' failed: %s.", action, tostring(err)) end
end

--- Whether the engine should be in the hook now.
--- @return boolean
local function _active()
	return _enabled and not _paused and _engine ~= nil and _loaded ~= nil and _loaded.enabled
end

--- Installs or removes the engine to match the current state.
local function _apply()
	if _active() then
		_hook.set_remapper(_engine, _run_tap)
	else
		_hook.set_remapper(nil)
	end
end

--- Reads the files and builds a fresh engine; the old one stays until _apply().
local function _load()
	_loaded = Config.load(_defaults_path, _user_path)
	local count = 0
	for _, key in pairs(_loaded.keys) do
		if key.enabled ~= false then count = count + 1 end
	end
	_engine = Engine.new({
		keys = _loaded.keys,
		tap_min_ms = Timings.ms("tap_hold", "tap_min_duration_ms"),
		one_shot_timeout_ms = Timings.ms("tap_hold", "one_shot_shift_timeout_ms"),
	})
	Logger.info(LOG, "Tap-holds loaded: %d key(s), feature %s.", count, _loaded.enabled and "on" or "off")
end

local function _require_init()
	if not _initialized then error("tap-hold manager used before init()", 2) end
end


-- =========================================
-- =========================================
-- ======= 3/ Public API ===================
-- =========================================
-- =========================================

--- Loads the configuration and installs the engine.
--- @param opts table { keyboard_hook, execute_action(action, binding),
---   action_names() -> ids, defaults_path, user_path }
function M.init(opts)
	if _initialized then error("tap-hold manager already initialised", 2) end
	if type(opts) ~= "table" then error("tap-hold manager options must be a table", 2) end
	if type(opts.keyboard_hook) ~= "table" or type(opts.keyboard_hook.set_remapper) ~= "function" then
		error("tap-hold manager requires a keyboard hook with set_remapper()", 2)
	end
	for _, name in ipairs({ "execute_action", "action_names" }) do
		if type(opts[name]) ~= "function" then error("tap-hold manager requires " .. name, 2) end
	end
	for _, name in ipairs({ "defaults_path", "user_path" }) do
		if type(opts[name]) ~= "string" or opts[name] == "" then
			error("tap-hold manager requires " .. name, 2)
		end
	end
	Logger.start(LOG, "Initialising tap-holds…")
	_hook = opts.keyboard_hook
	_execute_action = opts.execute_action
	_action_names = opts.action_names
	_defaults_path = opts.defaults_path
	_user_path = opts.user_path
	_enabled, _paused = true, false
	_load()
	_initialized = true
	_apply()
	Logger.success(LOG, "Tap-holds initialised (%s).", _active() and "active" or "inactive")
end

--- Re-reads the configuration and swaps the engine in place.
--- @return boolean True when the new configuration is in force.
function M.reload()
	_require_init()
	local ok, err = pcall(_load)
	if not ok then
		Logger.error(LOG, "Tap-hold reload failed, the previous configuration stays: %s.", tostring(err))
		return false
	end
	_apply()
	return true
end

--- Whether the runtime feature switch is on.
--- @return boolean
function M.is_enabled()
	return _enabled
end

--- Sets the runtime feature switch.
--- @param enabled boolean
--- @return boolean True when the requested state is in force.
function M.set_enabled(enabled)
	_require_init()
	if type(enabled) ~= "boolean" then
		Logger.error(LOG, "Tap-hold state must be a boolean — nothing changed.")
		return false
	end
	_enabled = enabled
	_apply()
	Logger.info(LOG, "Tap-holds switched %s.", enabled and "on" or "off")
	return true
end

--- Follows the daemon's pause: a paused script remaps nothing.
--- @param paused boolean
function M.set_paused(paused)
	_require_init()
	_paused = paused == true
	_apply()
end

--- Whether the engine is in the hook right now.
--- @return boolean
function M.is_active()
	return _initialized and _active()
end

--- The effective keys, key id → fields, as the engine runs them.
--- @return table
function M.keys()
	_require_init()
	return _loaded.keys
end

--- Whether the user's file sets the feature on (its [tap_hold] enabled).
--- @return boolean
function M.file_enabled()
	_require_init()
	return _loaded.enabled
end

--- The user's tap_hold.toml path, the file the menu edits.
--- @return string
function M.user_path()
	_require_init()
	return _user_path
end

--- The shared defaults path.
--- @return string
function M.defaults_path()
	_require_init()
	return _defaults_path
end

--- The ids a tap can be set to, sorted: the key taps the engine types itself,
--- the one-shot Shift, and every catalogue action this driver can run.
--- @return table
function M.tap_actions()
	_require_init()
	local seen = { none = true }
	local ids = {}
	local function add(id)
		if type(id) == "string" and id ~= "" and not seen[id] then
			seen[id] = true
			ids[#ids + 1] = id
		end
	end
	for id in pairs(Engine.KEY_TAPS) do add(id) end
	add("one_shot_shift")
	for id in pairs(EmitActions) do add(id) end
	for _, id in ipairs(_action_names()) do add(id) end
	table.sort(ids)
	return ids
end

--- Whether `action` is an id a tap can be set to.
--- @param action string
--- @return boolean
function M.is_tap_action(action)
	for _, id in ipairs(M.tap_actions()) do
		if id == action then return true end
	end
	return false
end

--- The hold picker's options, in the shared order: none, every modifier
--- combination, then the layers.
--- @return table { { id, kind, i18n } }
function M.hold_options()
	_require_init()
	return HoldOptions.build(_loaded.hold_picker)
end

--- Whether a hold option exists.
--- @param kind string
--- @param id string
--- @return boolean
function M.is_hold_option(kind, id)
	for _, option in ipairs(M.hold_options()) do
		if option.kind == kind and option.id == id then return true end
	end
	return false
end

--- The one tap/hold threshold of the configuration, in milliseconds, for the
--- metrics' tap/hold split. nil when the keys disagree or none is configured:
--- the metrics then decline to split rather than use a number nobody chose.
--- @return number|nil
function M.threshold_ms()
	if not _initialized then return nil end
	local value = nil
	for _, key in pairs(_loaded.keys) do
		if key.enabled ~= false then
			local ms = math.floor(key.time_activation_seconds * MS_PER_SECOND + 0.5)
			if value == nil then
				value = ms
			elseif ms ~= value then
				return nil
			end
		end
	end
	return value
end

--- Test seam: forgets the initialisation so a test can init again.
function M._reset_for_test()
	if _hook then _hook.set_remapper(nil) end
	_initialized, _hook, _execute_action, _action_names, _loaded, _engine = false, nil, nil, nil, nil, nil
	_enabled, _paused = true, false
end

return M
