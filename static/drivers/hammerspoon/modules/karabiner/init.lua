--- modules/karabiner/init.lua

--- ==============================================================================
--- MODULE: Karabiner Elements Bridge
--- DESCRIPTION:
--- Bridge between Hammerspoon and Karabiner-Elements.
---
--- FEATURES & RATIONALE:
--- 1. CapsWord Watcher: Detects trackpad scroll/gesture events and deactivates
---    CapsWord (turns off Caps Lock + resets the Karabiner variable) so the user
---    never gets stuck in caps mode after reaching for the trackpad.
--- 2. User Config: karabiner_user_config.json is the single runtime truth.
---    On first launch it is created from defaults. After that it is the full
---    persisted state — Hammerspoon never recomputes defaults at runtime except
---    when the user explicitly clicks "Reset to defaults".
--- 3. Shared Action Dictionary: Loads data/actions.json (shared with the
---    generator) so the menu always lists exactly the same actions, with zero
---    duplication.
--- 4. Modifier Combos: data/mod_combos.json defines all available two-modifier
---    combos (e.g. Right Cmd + CapsLock). Each combo maps to a tap and a hold
---    slot, shown in the Raccourcis menu section.
--- 5. Inline Generation: karabiner.json is built directly in Lua from in-memory
---    state — no Python subprocess, no external dependency.
--- 6. Deployment: The generated file is copied to the Karabiner-Elements config
---    directory via two sequential strategies, each logged separately.
--- ==============================================================================

local M = {}

local hs       = hs
local Logger   = require("lib.logger")
local Layout   = require("lib.layout")
local Defaults = require("modules.karabiner.defaults")

local LOG = "karabiner"

-- Resolve the directory that contains this init.lua at load time.
-- Works whether the file is symlinked, run from the project, or deployed.
local _SELF_DIR = (debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./")

local KARABINER_CLI   = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
local KARABINER_OUT   = os.getenv("HOME") .. "/.config/karabiner/karabiner.json"
local KARABINER_GEN   = _SELF_DIR .. "karabiner.json"

-- Bootstrap KE via its LaunchAgents. The GUI suppressor watcher handles killing
-- any GUI window that opens — we no longer kill daemons during pause (empty config
-- is deployed instead), so this command runs only when daemons are truly absent.
local KARABINER_OPEN_CMD =
	"PLISTS=$(/usr/bin/find /Library/LaunchAgents -name '*karabiner*' 2>/dev/null);"
	.. " if [ -n \"$PLISTS\" ]; then"
	.. "   echo \"$PLISTS\" | /usr/bin/xargs -I{} /bin/launchctl bootstrap gui/$(/usr/bin/id -u) {} 2>/dev/null;"
	.. " else"
	.. "   open -jg -a 'Karabiner-Elements' 2>/dev/null;"
	.. " fi; true"

-- Full user state — created from defaults on first launch, updated on every change.
local USER_CONFIG     = _SELF_DIR .. "karabiner_user_config.json"
local ACTIONS_FILE    = _SELF_DIR .. "data/actions.json"
local TAP_HOLD_FILE   = _SELF_DIR .. "data/tap_hold_keys.json"
local MOD_COMBOS_FILE = _SELF_DIR .. "data/mod_combos.json"

-- Re-export defaults as module constants so callers (e.g. the menu) have a
-- single import path and never need to require defaults.lua themselves.
local TAP_HOLD_TIMEOUT_MS_DEFAULT = Defaults.tap_hold_timeout_ms
local STICKY_TIMEOUT_MS_DEFAULT   = Defaults.sticky_timeout_ms

-- Rules always included in generation regardless of user config.
-- These are complex multi-manipulator rules that cannot be expressed as simple
-- tap / hold pairs and must always be active for the system to function correctly.
local ALWAYS_ON_RULES = {
	"layer_keys.json",  -- Navigation mappings (letter→arrow, number→F-key…)
	"capsword.json",    -- CapsWord activation (AltGr+CapsLock) + deactivation logic
	"combos.json",      -- Fixed Cmd+Shift letter remaps and AltGr shortcuts
}

-- Shell command that exits 0 when KE's core daemon is present.
-- karabiner_grabber is a root-level LaunchDaemon that starts at boot and keeps
-- running regardless of whether the GUI or session_monitor are alive. Using it
-- prevents launch_headless() from re-bootstrapping after a session where we killed the GUI.
local KE_RUNNING_CHECK = "/usr/bin/pgrep -q karabiner_grabber"

-- How long after HS init the startup suppressor stays active.
-- Long enough to catch a slow Login Items auto-launch.
local KE_SUPPRESS_DURATION_SEC = 15

--- Default tap / hold timeout exposed so the menu can display it without duplicating the value.
M.DEFAULT_TAP_HOLD_TIMEOUT_MS = TAP_HOLD_TIMEOUT_MS_DEFAULT

--- Default sticky modifier timeout exposed so the menu can display it without duplicating the value.
M.DEFAULT_STICKY_TIMEOUT_MS = STICKY_TIMEOUT_MS_DEFAULT

--- Populated by M.init() from data/actions.json (shared with other tools).
M.AVAILABLE_ACTIONS = {}

--- Populated by M.init() from data/tap_hold_keys.json (shared with other tools).
--- Each entry carries default_tap and default_hold used for first-launch init and reset.
M.TAP_HOLD_KEYS = {}

--- Populated by M.init() from data/mod_combos.json.
--- Each entry defines a two-modifier simultaneous combo the user can map to an action.
M.MOD_COMBOS = {}

local _state = nil

-- App watcher stored at module level to prevent garbage collection.
local _ke_app_watcher = nil

-- Space ID saved just before the suppressor window opens, used to jump back if
-- KE's GUI causes macOS to switch Spaces before we can kill it.
local _pre_suppress_space = nil


local function require_state(func_name)
	if not _state then
		Logger.error(LOG, "'%s' called before M.init() — module not initialized.", func_name)
		return false
	end
	return true
end




-- ===================================
-- ===================================
-- ======= 1/ CapsWord Watcher =======
-- ===================================
-- ===================================

--- Resets CapsWord: turns off Caps Lock and clears the Karabiner variable.
local function deactivate_capsword()
	local ok_get, is_on = pcall(hs.hid.capslock.get)
	if not ok_get or not is_on then return end

	Logger.trace(LOG, "Trackpad event while CapsWord active — deactivating…")
	pcall(hs.hid.capslock.set, false)

	local cmd = string.format('"%s" --set-variable capsword 0 2>/dev/null', KARABINER_CLI)
	hs.execute(cmd)

	Logger.done(LOG, "CapsWord deactivated via trackpad.")
end

--- Starts the eventtap watching for trackpad scroll and gesture events.
--- @return hs.eventtap The running watcher.
local function start_gesture_watcher()
	local watcher = hs.eventtap.new(
		{ hs.eventtap.event.types.scrollWheel, hs.eventtap.event.types.gesture },
		function(_event)
			deactivate_capsword()
			return false
		end
	)
	watcher:start()
	Logger.success(LOG, "Trackpad CapsWord watcher started.")
	return watcher
end




-- ==========================================
-- ==========================================
-- ======= 2/ KE GUI Lifecycle Helpers =======
-- ==========================================
-- ==========================================

--- Removes Karabiner-Elements from macOS Login Items so it never auto-launches.
--- Uses hs.osascript.applescript which runs inside HS's process (already granted
--- Accessibility access) — unlike hs.execute which spawns a shell with no such rights.
--- Takes effect on the next login; harmless if KE is not in Login Items.
local function remove_ke_from_login_items()
	local ok, _, raw = hs.osascript.applescript(
		'tell application "System Events"\n'
		.. '  set items_found to every login item whose name is "Karabiner-Elements"\n'
		.. '  if (count of items_found) > 0 then\n'
		.. '    delete items_found\n'
		.. '    return "removed"\n'
		.. '  else\n'
		.. '    return "not_found"\n'
		.. '  end if\n'
		.. 'end tell'
	)
	if ok then
		Logger.debug(LOG, "Login Items (System Events): %s.", tostring(raw))
	else
		Logger.debug(LOG, "Login Items removal skipped — no Accessibility access or not found.")
	end
end

--- Quits the Karabiner-Elements GUI app if it is running.
--- The background daemons are NOT affected — they are launchd-managed services.
local function quit_ke_gui()
	local apps = hs.application.applicationsForBundleID("org.pqrs.Karabiner-Elements")
	for _, app in ipairs(apps or {}) do
		app:kill()
		Logger.debug(LOG, "Karabiner-Elements GUI killed.")
	end
	hs.execute(
		"osascript -e 'tell application \"Karabiner-Elements\" to quit' 2>/dev/null"
	)
end

--- Stops the KE GUI suppressor watcher, if active.
--- Called before the user intentionally opens KE so the watcher does not fight them.
function M.stop_gui_suppressor()
	if not _ke_app_watcher then return end
	_ke_app_watcher:stop()
	_ke_app_watcher = nil
	Logger.debug(LOG, "Karabiner-Elements GUI suppressor stopped by user request.")
end

--- Quits any KE GUI instance that launches during the startup suppression window.
--- Also moves KE windows to the current Space before killing to avoid any animation.
--- Call M.stop_gui_suppressor() (or M.open_gui()) to end the window early.
local function suppress_ke_gui_at_startup()
	if _ke_app_watcher then return end

	-- Save the current Space so we can jump back in the unlikely case KE switches anyway
	pcall(function() _pre_suppress_space = hs.spaces.focusedSpace() end)

	-- Quit any GUI already open right now (covers HS reload / previous session)
	quit_ke_gui()

	_ke_app_watcher = hs.application.watcher.new(function(name, event, _app)
		if name ~= "Karabiner-Elements" then return end
		-- Watch both launched (new process) and activated (existing process comes to front,
		-- e.g. when KE reloads its config via FSEvents and activates its preferences window)
		if event == hs.application.watcher.launched
		or event == hs.application.watcher.activated then
			Logger.debug(LOG, "Karabiner-Elements GUI appeared during suppression window — quitting…")
			quit_ke_gui()
			-- Jump back to original Space if KE triggered a switch
			if _pre_suppress_space then
				hs.timer.doAfter(0.3, function()
					local ok, cur = pcall(hs.spaces.focusedSpace)
					if ok and cur ~= _pre_suppress_space then
						Logger.debug(LOG, "Restoring Space after Karabiner-Elements GUI switch.")
						pcall(hs.spaces.gotoSpace, _pre_suppress_space)
					end
				end)
			end
		end
	end)
	_ke_app_watcher:start()

	-- Auto-stop after the grace period
	hs.timer.doAfter(KE_SUPPRESS_DURATION_SEC, function()
		if _ke_app_watcher then
			_ke_app_watcher:stop()
			_ke_app_watcher = nil
			_pre_suppress_space = nil
			Logger.debug(LOG, "Karabiner-Elements GUI suppressor expired — manual open now allowed.")
		end
	end)

	Logger.debug(LOG, "Karabiner-Elements GUI suppressor active for %ds.", KE_SUPPRESS_DURATION_SEC)
end

--- Opens the Karabiner-Elements GUI for the user.
--- Stops the startup suppressor first so the watcher does not immediately kill the app.
function M.open_gui()
	M.stop_gui_suppressor()
	-- Small delay so the watcher stop propagates before the app launches
	hs.timer.doAfter(0.1, function()
		local ok = pcall(hs.application.launchOrFocus, "Karabiner-Elements")
		if not ok then
			-- Fallback: open via shell if launchOrFocus fails
			hs.execute("open -a 'Karabiner-Elements' 2>/dev/null")
		end
	end)
	Logger.info(LOG, "Karabiner-Elements GUI opened by user request.")
end

--- Ensures Karabiner-Elements background services are running.
--- Logs a warning if KE cannot be started (app not installed or disabled).
--- @return boolean True if services are (or were already) running after this call.
function M.launch_headless()
	local _, already_running = hs.execute(KE_RUNNING_CHECK)
	if already_running then
		Logger.debug(LOG, "Karabiner-Elements services already running.")
		return true
	end
	Logger.debug(LOG, "Karabiner-Elements not running — bootstrapping daemon plists…")
	hs.execute(KARABINER_OPEN_CMD)

	-- Verify that the daemons actually started after the bootstrap command
	hs.timer.doAfter(3, function()
		local _, now_running = hs.execute(KE_RUNNING_CHECK)
		if not now_running then
			Logger.warn(LOG, "Karabiner-Elements daemons did not start — integration may be unavailable.")
			local ok_notif, notifications = pcall(require, "lib.notifications")
			if ok_notif then
				notifications.notify("⚠️ Karabiner-Elements non disponible — les remappages clavier sont inactifs.")
			end
		end
	end)
	return false
end




-- ====================================
-- ====================================
-- ======= 3/ JSON Data Loaders =======
-- ====================================
-- ====================================

--- Loads and parses a JSON file. Logs an error and returns nil on any failure.
--- @param path string Absolute path to the JSON file.
--- @return table|nil Decoded table, or nil.
local function load_json_file(path)
	local fh = io.open(path, "r")
	if not fh then
		Logger.error(LOG, "Cannot open file '%s'.", path)
		return nil
	end
	local raw = fh:read("*a")
	fh:close()
	local ok, data = pcall(hs.json.decode, raw)
	if not ok or type(data) ~= "table" then
		Logger.error(LOG, "Cannot decode JSON from '%s': %s.", path, tostring(data))
		return nil
	end
	return data
end

--- Loads all action definitions from data/actions.json.
--- Entries with a "logical_char" field have their "karabiner_to" resolved at load
--- time via lib.layout, so the physical key_code always matches the current OS
--- keyboard layout — no hardcoded QWERTY positions.
--- Populates M.AVAILABLE_ACTIONS.
local function load_available_actions()
	local list = load_json_file(ACTIONS_FILE)
	if not list then
		Logger.error(LOG, "Cannot load actions — module will be non-functional.")
		return
	end

	-- Resolve layout-dependent actions: logical_char → physical key_code
	for _, action in ipairs(list) do
		if action.logical_char then
			local key_code = Layout.key_code_for_char(action.logical_char)
			local mods     = action.karabiner_modifiers
			local entry    = { key_code = key_code }
			if type(mods) == "table" and #mods > 0 then
				entry.modifiers = mods
			end
			action.karabiner_to = { entry }
			Logger.debug(LOG, "Action '%s': logical '%s' → key_code '%s'.",
				action.id, action.logical_char, key_code)
		end
	end

	M.AVAILABLE_ACTIONS = list
	Logger.info(LOG, "Loaded %d action(s) from actions.json.", #list)
end

--- Loads configurable key definitions from data/tap_hold_keys.json.
--- Populates M.TAP_HOLD_KEYS.
local function load_tap_hold_keys()
	local list = load_json_file(TAP_HOLD_FILE)
	if not list then
		Logger.error(LOG, "Cannot load tap_hold_keys — module will be non-functional.")
		return
	end
	M.TAP_HOLD_KEYS = list
	Logger.info(LOG, "Loaded %d configurable tap / hold key(s).", #list)
end

--- Loads modifier combo definitions from data/mod_combos.json.
--- Populates M.MOD_COMBOS.
local function load_mod_combos()
	local list = load_json_file(MOD_COMBOS_FILE)
	if not list then
		Logger.error(LOG, "Cannot load mod_combos — module will be non-functional.")
		return
	end
	M.MOD_COMBOS = list
	Logger.info(LOG, "Loaded %d modifier combo(s).", #list)
end




-- =========================================
-- =========================================
-- ======= 4/ Default State Builder ========
-- =========================================
-- =========================================

--- Builds the default full state from tap / hold keys and modifier combos.
--- Used only at first launch and when the user resets to defaults.
--- @return table { enabled, tap_hold_config, mod_combos_config, tap_hold_timeout_ms, sticky_timeout_ms }
local function build_default_state()
	local tap_hold_config = {}
	for _, key_def in ipairs(M.TAP_HOLD_KEYS) do
		local d = Defaults.tap_hold[key_def.id]
		if not d then
			Logger.warn(LOG, "No default entry for key '%s' in defaults.lua — using none/none.", key_def.id)
		end
		tap_hold_config[key_def.id] = {
			tap  = d and d[1] or "none",
			hold = d and d[2] or "none",
		}
	end

	-- Modifier combos — defaults come from defaults.lua, fall back to "none" if missing
	local mod_combos_config = {}
	for _, combo_def in ipairs(M.MOD_COMBOS) do
		local d = Defaults.combos[combo_def.id]
		if not d then
			Logger.warn(LOG, "No default entry for combo '%s' in defaults.lua — using none/none.", combo_def.id)
		end
		mod_combos_config[combo_def.id] = {
			tap  = d and d[1] or "none",
			hold = d and d[2] or "none",
		}
	end

	return {
		enabled               = false,
		tap_hold_config       = tap_hold_config,
		mod_combos_config     = mod_combos_config,
		tap_hold_timeout_ms   = TAP_HOLD_TIMEOUT_MS_DEFAULT,
		sticky_timeout_ms     = STICKY_TIMEOUT_MS_DEFAULT,
	}
end




-- ==============================================
-- ==============================================
-- ======= 5/ User Config Persistence ===========
-- ==============================================
-- ==============================================

--- Loads karabiner_user_config.json.
--- If the file is absent (first launch), builds and returns the default state.
--- @return table { enabled, tap_hold_config, mod_combos_config, tap_hold_timeout_ms, sticky_timeout_ms }
local function load_user_config()
	local data = load_json_file(USER_CONFIG)

	if not data then
		Logger.info(LOG, "No user config found — initializing from defaults.")
		return build_default_state()
	end

	local defaults = build_default_state()

	if type(data.tap_hold_config) ~= "table" then
		Logger.warn(LOG, "Missing tap_hold_config in saved config — using defaults.")
		data.tap_hold_config = defaults.tap_hold_config
	end

	if type(data.mod_combos_config) ~= "table" then
		Logger.warn(LOG, "Missing mod_combos_config in saved config — using defaults.")
		data.mod_combos_config = defaults.mod_combos_config
	else
		-- Migrate old format (single string per combo) to {tap, hold} table.
		-- Treat the old action id as the hold slot (combos were hold-only before).
		for id, entry in pairs(data.mod_combos_config) do
			if type(entry) == "string" then
				Logger.info(LOG, "Migrating combo '%s' from legacy string format.", id)
				data.mod_combos_config[id] = { tap = "none", hold = entry }
			end
		end
		-- Seed any combos that are missing from the persisted config (new combos added after save)
		for _, combo_def in ipairs(M.MOD_COMBOS) do
			if not data.mod_combos_config[combo_def.id] then
				local d = Defaults.combos[combo_def.id]
				Logger.info(LOG, "New combo '%s' not in saved config — seeding from defaults.", combo_def.id)
				data.mod_combos_config[combo_def.id] = {
					tap  = d and d[1] or "none",
					hold = d and d[2] or "none",
				}
			end
		end
	end

	-- Migration: fields absent in old saves get the canonical default, not a silent magic number
	local timeout_ms = tonumber(data.tap_hold_timeout_ms)
	if not timeout_ms then
		Logger.warn(LOG, "Missing tap_hold_timeout_ms in saved config — using default (%d ms).",
			TAP_HOLD_TIMEOUT_MS_DEFAULT)
		timeout_ms = TAP_HOLD_TIMEOUT_MS_DEFAULT
	end

	local sticky_ms = tonumber(data.sticky_timeout_ms)
	if not sticky_ms then
		Logger.warn(LOG, "Missing sticky_timeout_ms in saved config — using default (%d ms).",
			STICKY_TIMEOUT_MS_DEFAULT)
		sticky_ms = STICKY_TIMEOUT_MS_DEFAULT
	end

	Logger.info(LOG, "User config loaded.")
	return {
		enabled             = data.enabled == true,
		tap_hold_config     = data.tap_hold_config,
		mod_combos_config   = data.mod_combos_config,
		tap_hold_timeout_ms = timeout_ms,
		sticky_timeout_ms   = sticky_ms,
	}
end

--- Persists the current full state to karabiner_user_config.json.
local function save_user_config()
	if not require_state("save_user_config") then return end

	local payload = hs.json.encode({
		enabled             = _state.enabled,
		tap_hold_config     = _state.tap_hold_config,
		mod_combos_config   = _state.mod_combos_config,
		tap_hold_timeout_ms = _state.tap_hold_timeout_ms,
		sticky_timeout_ms   = _state.sticky_timeout_ms,
	}, true)

	local fh = io.open(USER_CONFIG, "w")
	if not fh then
		Logger.error(LOG, "Cannot write user config at '%s'.", USER_CONFIG)
		return
	end
	fh:write(payload)
	fh:close()
	Logger.debug(LOG, "User config saved.")
end




-- =====================================================
-- =====================================================
-- ======= 6/ State Accessors and Mutators =============
-- =====================================================
-- =====================================================

--- Returns true when the Karabiner integration is enabled.
--- @return boolean
function M.get_enabled()
	if not _state then return false end
	return _state.enabled == true
end

--- Enables or disables the Karabiner integration and persists the choice.
--- When enabling, Karabiner-Elements is launched in the background.
--- When disabling, Karabiner-Elements is quit.
--- @param value boolean
function M.set_enabled(value)
	if not require_state("set_enabled") then return end
	_state.enabled = value == true
	Logger.info(LOG, "Karabiner integration %s.", _state.enabled and "enabled" or "disabled")
	save_user_config()
	if _state.enabled then
		M.launch_headless()
	else
		hs.execute("osascript -e 'tell application \"Karabiner-Elements\" to quit' 2>/dev/null")
	end
end


--- Returns the current tap action id for a key.
--- @param key_id string Key id as defined in tap_hold_keys.json.
--- @return string action_id
function M.get_tap_action(key_id)
	if not require_state("get_tap_action") then return "none" end
	local cfg = _state.tap_hold_config[key_id]
	return cfg and cfg.tap or "none"
end

--- Returns the current hold action id for a key.
--- @param key_id string Key id as defined in tap_hold_keys.json.
--- @return string action_id
function M.get_hold_action(key_id)
	if not require_state("get_hold_action") then return "none" end
	local cfg = _state.tap_hold_config[key_id]
	return cfg and cfg.hold or "none"
end

--- Sets the tap action for a key and saves the user config.
--- Does NOT regenerate — call M.regenerate() explicitly when ready.
--- @param key_id string Key id.
--- @param action_id string Action id from actions.json.
function M.set_tap_action(key_id, action_id)
	if not require_state("set_tap_action") then return end
	local cfg = _state.tap_hold_config[key_id] or {}
	_state.tap_hold_config[key_id] = { tap = action_id, hold = cfg.hold or "none" }
	Logger.debug(LOG, "Key '%s' tap → '%s'.", key_id, action_id)
	save_user_config()
end

--- Sets the hold action for a key and saves the user config.
--- Does NOT regenerate — call M.regenerate() explicitly when ready.
--- @param key_id string Key id.
--- @param action_id string Action id from actions.json.
function M.set_hold_action(key_id, action_id)
	if not require_state("set_hold_action") then return end
	local cfg = _state.tap_hold_config[key_id] or {}
	_state.tap_hold_config[key_id] = { tap = cfg.tap or "none", hold = action_id }
	Logger.debug(LOG, "Key '%s' hold → '%s'.", key_id, action_id)
	save_user_config()
end


--- Returns the tap action id for a modifier combo.
--- @param combo_id string Combo id.
--- @return string action_id
function M.get_combo_tap_action(combo_id)
	if not require_state("get_combo_tap_action") then return "none" end
	local cfg = _state.mod_combos_config[combo_id]
	return (type(cfg) == "table" and cfg.tap) or "none"
end

--- Returns the hold action id for a modifier combo.
--- @param combo_id string Combo id.
--- @return string action_id
function M.get_combo_hold_action(combo_id)
	if not require_state("get_combo_hold_action") then return "none" end
	local cfg = _state.mod_combos_config[combo_id]
	return (type(cfg) == "table" and cfg.hold) or "none"
end

--- Sets the tap action for a modifier combo and saves the user config.
--- Does NOT regenerate — call M.regenerate() explicitly when ready.
--- @param combo_id string Combo id.
--- @param action_id string Action id from actions.json.
function M.set_combo_tap_action(combo_id, action_id)
	if not require_state("set_combo_tap_action") then return end
	local cfg = _state.mod_combos_config[combo_id] or {}
	-- Always write a fresh table to avoid mutating a shared reference
	-- (hs.json.decode may reuse identical objects across entries)
	_state.mod_combos_config[combo_id] = {
		tap  = action_id,
		hold = type(cfg) == "table" and cfg.hold or "none",
	}
	Logger.debug(LOG, "Combo '%s' tap → '%s'.", combo_id, action_id)
	save_user_config()
end

--- Sets the hold action for a modifier combo and saves the user config.
--- Does NOT regenerate — call M.regenerate() explicitly when ready.
--- @param combo_id string Combo id.
--- @param action_id string Action id from actions.json.
function M.set_combo_hold_action(combo_id, action_id)
	if not require_state("set_combo_hold_action") then return end
	local cfg = _state.mod_combos_config[combo_id] or {}
	-- Always write a fresh table to avoid mutating a shared reference
	_state.mod_combos_config[combo_id] = {
		tap  = type(cfg) == "table" and cfg.tap or "none",
		hold = action_id,
	}
	Logger.debug(LOG, "Combo '%s' hold → '%s'.", combo_id, action_id)
	save_user_config()
end


--- Returns the current tap / hold timeout in milliseconds.
--- Maps to KE's basic.to_if_alone_timeout_milliseconds.
--- @return number milliseconds
function M.get_tap_hold_timeout()
	if not require_state("get_tap_hold_timeout") then return nil end
	return _state.tap_hold_timeout_ms
end

--- Sets the tap / hold timeout and persists it.
--- Logs an error and returns without saving if the value is invalid.
--- @param ms number Timeout in milliseconds (must be a positive integer).
function M.set_tap_hold_timeout(ms)
	if not require_state("set_tap_hold_timeout") then return end
	local value = tonumber(ms)
	if not value or value <= 0 then
		Logger.error(LOG, "set_tap_hold_timeout: invalid value '%s' — ignoring.", tostring(ms))
		return
	end
	_state.tap_hold_timeout_ms = math.floor(value)
	Logger.debug(LOG, "Tap/hold timeout: %d ms.", _state.tap_hold_timeout_ms)
	save_user_config()
end

--- Returns the sticky/one-shot modifier timeout in milliseconds.
--- @return number milliseconds
function M.get_sticky_timeout()
	if not require_state("get_sticky_timeout") then return nil end
	return _state.sticky_timeout_ms
end

--- Sets the sticky modifier timeout and persists it.
--- Logs an error and returns without saving if the value is invalid.
--- @param ms number Timeout in milliseconds (must be a positive integer).
function M.set_sticky_timeout(ms)
	if not require_state("set_sticky_timeout") then return end
	local value = tonumber(ms)
	if not value or value <= 0 then
		Logger.error(LOG, "set_sticky_timeout: invalid value '%s' — ignoring.", tostring(ms))
		return
	end
	_state.sticky_timeout_ms = math.floor(value)
	Logger.debug(LOG, "Sticky timeout: %d ms.", _state.sticky_timeout_ms)
	save_user_config()
end


--- Resets all settings to their defaults and saves the user config.
--- Does NOT regenerate — call M.regenerate() explicitly when ready.
function M.reset_to_defaults()
	if not require_state("reset_to_defaults") then return end
	Logger.start(LOG, "Resetting all settings to defaults…")
	local defaults              = build_default_state()
	_state.tap_hold_config      = defaults.tap_hold_config
	_state.mod_combos_config    = defaults.mod_combos_config
	_state.tap_hold_timeout_ms  = defaults.tap_hold_timeout_ms
	_state.sticky_timeout_ms    = defaults.sticky_timeout_ms
	save_user_config()
	Logger.success(LOG, "All settings reset to defaults.")
end




-- ==============================================
-- ==============================================
-- ======= 7/ Karabiner JSON Generator ==========
-- ==============================================
-- ==============================================

--- Builds an index of action id → action definition from M.AVAILABLE_ACTIONS.
--- @return table Map of id → action definition.
local function build_action_index()
	local index = {}
	for _, action in ipairs(M.AVAILABLE_ACTIONS) do
		index[action.id] = action
	end
	return index
end

--- Returns true when two karabiner_to arrays produce identical JSON output.
--- Used to detect tap == hold (in which case to_if_alone is omitted).
--- @param a table First karabiner_to array.
--- @param b table Second karabiner_to array.
--- @return boolean
local function same_output(a, b)
	return hs.json.encode(a) == hs.json.encode(b)
end

--- Deploys a file to its destination using two strategies.
---
--- S1 — direct io.open: works for regular paths and Unix symlinks.
--- S2 — mkdir + io.open retry: covers fresh Karabiner installs where
---   ~/.config/karabiner/ was never created.
---
--- @param src string Source path (real POSIX path, not an alias).
--- @param dst string Destination path.
--- @return boolean success, string detail Human-readable result.
local function deploy_file(src, dst)
	Logger.trace(LOG, "Deploy: '%s' → '%s'…", src, dst)

	-- Read source — fail fast before touching the destination
	local src_fh = io.open(src, "r")
	if not src_fh then
		Logger.error(LOG, "Deploy aborted — source not readable: '%s'.", src)
		return false, "source file not found: " .. src
	end
	local content = src_fh:read("*a")
	src_fh:close()
	Logger.debug(LOG, "Deploy: read %d byte(s) from source.", #content)

	local parent = dst:match("^(.*)/[^/]+$")

	-- S1: direct write — works for regular paths and Unix symlinks
	local dst_fh = io.open(dst, "w")
	if dst_fh then
		dst_fh:write(content)
		dst_fh:close()
		Logger.done(LOG, "Deploy S1 (direct write) succeeded: '%s'.", dst)
		return true, "ok"
	end
	Logger.debug(LOG, "Deploy S1 failed — destination not directly writable: '%s'.", dst)

	-- S2: parent directory may not exist yet — create it then retry
	if parent then
		local mkdir_out, _, _, mkdir_rc = hs.execute(
			string.format("/bin/mkdir -p '%s' 2>&1", parent:gsub("'", "'\\''"))
		)
		Logger.debug(LOG, "Deploy S2 mkdir -p rc=%s: %s",
			tostring(mkdir_rc), (mkdir_out or ""):gsub("%s+$", ""))
		dst_fh = io.open(dst, "w")
		if dst_fh then
			dst_fh:write(content)
			dst_fh:close()
			Logger.done(LOG, "Deploy S2 (mkdir + write) succeeded: '%s'.", dst)
			return true, "ok"
		end
		Logger.debug(LOG, "Deploy S2 failed — still not writable after mkdir: '%s'.", dst)
	end

	-- Both strategies exhausted — surface a clear error with actionable context.
	-- Common causes: Finder alias (convert to Unix symlink), permission denied,
	-- or Karabiner config directory living at an unexpected path.
	local detail = "cannot open destination for writing: " .. dst
	Logger.error(LOG, "Deploy aborted — %s.", detail)
	Logger.error(LOG, "Tip: if '%s' is a Finder alias, replace it with a Unix symlink:", dst)
	Logger.error(LOG, "  ln -sfn /real/karabiner/dir '%s'", parent or dst)
	return false, detail
end

--- Builds a Karabiner rule table for a single tap / hold key.
--- When tap and hold produce the same output the rule uses only "to" so the
--- action fires immediately with no timing window.
--- Returns nil when both slots are "none" (nothing to generate).
--- @param key_def table Entry from M.TAP_HOLD_KEYS.
--- @param tap_action table Resolved action definition for the tap slot.
--- @param hold_action table Resolved action definition for the hold slot.
--- @return table|nil Karabiner rule object.
local function build_tap_hold_rule(key_def, tap_action, hold_action)
	local tap_to  = tap_action.karabiner_to  or {}
	local hold_to = hold_action.karabiner_to or {}

	if #tap_to == 0 and #hold_to == 0 then return nil end

	-- When one slot is "none", fall through to the original key for that slot.
	-- This preserves the physical key behaviour while still applying the other action.
	local passthrough       = { { key_code = key_def.from.key_code } }
	local effective_tap_to  = (#tap_to  > 0) and tap_to  or passthrough
	local effective_hold_to = (#hold_to > 0) and hold_to or passthrough

	local manipulator = { type = "basic", from = key_def.from }

	manipulator.to = effective_hold_to

	-- to_if_alone only when tap output differs from hold output
	if not same_output(effective_tap_to, effective_hold_to) then
		manipulator.to_if_alone = effective_tap_to
	end

	-- to_after_key_up for hold actions that need explicit release (e.g. layer)
	if hold_action.karabiner_to_after_key_up then
		manipulator.to_after_key_up = hold_action.karabiner_to_after_key_up
	end

	return {
		description  = string.format(
			"%s: %s (tap) / %s (hold)",
			key_def.label, tap_action.label, hold_action.label
		),
		manipulators = { manipulator },
	}
end

--- Builds a Karabiner rule table for a single modifier combo with tap + hold.
--- Returns nil when both slots are "none" (combo disabled).
--- Hold fires immediately via "to" (acts as modifier for a 3rd key).
--- Tap fires via "to_if_alone" when no 3rd key is pressed before release.
--- @param combo_def  table Entry from M.MOD_COMBOS.
--- @param tap_action table Resolved action definition for tap slot.
--- @param hold_action table Resolved action definition for hold slot.
--- @return table|nil Karabiner rule object.
local function build_combo_rule(combo_def, tap_action, hold_action)
	local tap_to  = tap_action.karabiner_to  or {}
	local hold_to = hold_action.karabiner_to or {}

	if #tap_to == 0 and #hold_to == 0 then return nil end

	local manipulator = { type = "basic", from = combo_def.from }

	if #hold_to > 0 then
		manipulator.to = hold_to
		if hold_action.karabiner_to_after_key_up then
			manipulator.to_after_key_up = hold_action.karabiner_to_after_key_up
		end
	end

	-- to_if_alone fires only when tap differs from hold (otherwise hold alone suffices)
	if #tap_to > 0 and not same_output(tap_to, hold_to) then
		manipulator.to_if_alone = tap_to
		if tap_action.karabiner_to_after_key_up and #hold_to == 0 then
			manipulator.to_after_key_up = tap_action.karabiner_to_after_key_up
		end
	end

	return {
		description  = string.format(
			"%s: %s (tap) / %s (hold)",
			combo_def.label, tap_action.label, hold_action.label
		),
		manipulators = { manipulator },
	}
end

--- Assembles the full Karabiner JSON structure from current in-memory state.
--- @return table Karabiner config table ready for hs.json.encode.
local function build_karabiner_json()
	local action_index = build_action_index()
	local all_rules    = {}
	local none_action  = action_index["none"] or { label = "none", karabiner_to = {} }


	-- Dynamic modifier combo manipulators (FIRST — takes priority over layer_keys).
	-- Placing combos before layer_keys ensures a user-defined combo that involves a key
	-- remapped by the navigation layer is matched by the combo rule first.

	for _, combo_def in ipairs(M.MOD_COMBOS) do
		-- Skip combos handled outside KE (menu_hidden = handled by Hammerspoon directly)
		if combo_def.menu_hidden then goto continue end

		local cfg        = _state.mod_combos_config[combo_def.id] or {}
		local tap_id     = (type(cfg) == "table" and cfg.tap)  or "none"
		local hold_id    = (type(cfg) == "table" and cfg.hold) or "none"
		local tap_action  = action_index[tap_id]  or none_action
		local hold_action = action_index[hold_id] or none_action

		local rule = build_combo_rule(combo_def, tap_action, hold_action)
		if rule then all_rules[#all_rules + 1] = rule end

		::continue::
	end


	-- Always-on rules (complex logic that cannot be expressed as tap / hold)

	for _, fname in ipairs(ALWAYS_ON_RULES) do
		local rule = load_json_file(_SELF_DIR .. "data/" .. fname)
		if rule then
			all_rules[#all_rules + 1] = rule
		else
			Logger.warn(LOG, "Always-on rule file not found: '%s' — skipped.", fname)
		end
	end


	-- Dynamic tap / hold manipulators

	for _, key_def in ipairs(M.TAP_HOLD_KEYS) do
		local cfg         = _state.tap_hold_config[key_def.id] or {}
		local tap_id      = cfg.tap  or "none"
		local hold_id     = cfg.hold or "none"
		local tap_action  = action_index[tap_id]
		local hold_action = action_index[hold_id]

		if not tap_action then
			Logger.warn(LOG, "Unknown tap action '%s' for key '%s' — falling back to none.", tap_id, key_def.id)
			tap_action = none_action
		end
		if not hold_action then
			Logger.warn(LOG, "Unknown hold action '%s' for key '%s' — falling back to none.", hold_id, key_def.id)
			hold_action = none_action
		end

		local rule = build_tap_hold_rule(key_def, tap_action, hold_action)
		if rule then all_rules[#all_rules + 1] = rule end
	end


	-- Assemble profile template

	local timeout_ms = _state.tap_hold_timeout_ms
	Logger.debug(LOG, "Building config: tap/hold timeout=%d ms, %d rule(s).", timeout_ms, #all_rules)

	return {
		profiles = {
			{
				complex_modifications = {
					-- Global timeout applies to ALL tap / hold rules uniformly without
					-- per-manipulator overrides.
					parameters = {
						["basic.to_if_alone_timeout_milliseconds"] = timeout_ms,
					},
					rules = all_rules,
				},
				devices               = { { identifiers = { is_keyboard = true }, simple_modifications = {} } },
				name                  = "Default profile",
				selected              = true,
				virtual_hid_keyboard  = { country_code = 0, keyboard_type_v2 = "ansi" },
			}
		}
	}
end




-- ==================================
-- ==================================
-- ======= 8/ Regeneration ==========
-- ==================================
-- ==================================

--- Builds karabiner.json from the current in-memory state and deploys it to
--- the Karabiner-Elements config directory.
--- KE watches karabiner.json with FSEvents and reloads automatically on change.
function M.regenerate()
	if not require_state("regenerate") then return end
	Logger.start(LOG, "Regenerating Karabiner config…")

	local ok_build, result = pcall(build_karabiner_json)
	if not ok_build then
		Logger.error(LOG, "JSON generation failed: %s.", tostring(result))
		return
	end

	local json_str = hs.json.encode(result, true)

	local fh = io.open(KARABINER_GEN, "w")
	if not fh then
		Logger.error(LOG, "Cannot write generated config at '%s'.", KARABINER_GEN)
		return
	end
	fh:write(json_str)
	fh:close()

	local ok_copy, cp_detail = deploy_file(KARABINER_GEN, KARABINER_OUT)
	if not ok_copy then
		Logger.error(LOG, "Deploy failed → '%s': %s.", KARABINER_OUT, cp_detail)
		return
	end

	local active_combos = 0
	for _, combo_def in ipairs(M.MOD_COMBOS) do
		local cfg = _state.mod_combos_config[combo_def.id] or {}
		if type(cfg) == "table" and (cfg.tap ~= "none" or cfg.hold ~= "none") then
			active_combos = active_combos + 1
		end
	end

	Logger.success(LOG,
		"Karabiner config regenerated: %d combo(s) + %d tap/hold key(s) deployed.",
		active_combos, #M.TAP_HOLD_KEYS)
end




-- ======================================
-- ======================================
-- ======= 9/ Pause / Resume ============
-- ======================================
-- ======================================

-- Minimal karabiner.json deployed on pause: same profile structure as normal but
-- with zero rules, so KE's FSEvents watcher reloads and applies no remapping.
-- Daemons stay alive — no process kill, no restart, no Space switch.
local EMPTY_KE_CONFIG = {
	profiles = {
		{
			complex_modifications = { rules = {} },
			devices               = { { identifiers = { is_keyboard = true }, simple_modifications = {} } },
			name                  = "Default profile",
			selected              = true,
			virtual_hid_keyboard  = { country_code = 0, keyboard_type_v2 = "ansi" },
		}
	}
}

--- Deploys an empty Karabiner config so remapping stops without killing any process.
--- KE reloads via FSEvents — daemons stay alive, no Space switch.
--- Does nothing when the integration is disabled.
function M.pause()
	if not _state or not _state.enabled then return end
	Logger.start(LOG, "Pausing Karabiner-Elements…")
	local json_str = hs.json.encode(EMPTY_KE_CONFIG, true)
	local fh = io.open(KARABINER_GEN, "w")
	if not fh then
		Logger.error(LOG, "Cannot write empty config for pause at '%s'.", KARABINER_GEN)
		return
	end
	fh:write(json_str)
	fh:close()
	local ok, detail = deploy_file(KARABINER_GEN, KARABINER_OUT)
	if not ok then
		Logger.error(LOG, "Pause deploy failed: %s.", detail)
		return
	end
	Logger.success(LOG, "Karabiner-Elements paused (empty config deployed).")
end

--- Restores the full Karabiner config so remapping resumes.
--- Does nothing when the integration is disabled.
function M.resume()
	if not _state or not _state.enabled then return end
	Logger.start(LOG, "Resuming Karabiner-Elements…")
	M.regenerate()
	Logger.success(LOG, "Karabiner-Elements resumed.")
end




-- ==================================
-- ==================================
-- ======= 10/ Lifecycle ============
-- ==================================
-- ==================================

--- Initializes the Karabiner bridge.
--- No arguments needed — the module resolves its own directory at load time.
function M.init()
	Logger.start(LOG, "Initializing Karabiner bridge…")

	if _state then
		Logger.warn(LOG, "M.init() called more than once — ignoring duplicate call.")
		return
	end

	-- Try to remove KE from Login Items so it no longer auto-launches on next login
	remove_ke_from_login_items()

	-- Load shared data files first — required before load_user_config() can
	-- call build_default_state() on first launch
	load_available_actions()
	load_tap_hold_keys()
	load_mod_combos()

	if #M.AVAILABLE_ACTIONS == 0 or #M.TAP_HOLD_KEYS == 0 or #M.MOD_COMBOS == 0 then
		Logger.error(LOG, "One or more data files failed to load — aborting initialization.")
		return
	end

	local first_launch = io.open(USER_CONFIG, "r") == nil
	local user_cfg     = load_user_config()

	_state = {
		enabled             = user_cfg.enabled,
		tap_hold_config     = user_cfg.tap_hold_config,
		mod_combos_config   = user_cfg.mod_combos_config,
		tap_hold_timeout_ms = user_cfg.tap_hold_timeout_ms,
		sticky_timeout_ms   = user_cfg.sticky_timeout_ms,
		watcher             = nil,
	}

	-- Arm the suppressor watcher first so it catches any GUI activation triggered
	-- by the config reload below (KE may activate its window on FSEvents reload).
	suppress_ke_gui_at_startup()

	if _state.enabled then
		Logger.info(LOG, "Integration enabled — deploying config…")
		M.launch_headless()
		M.regenerate()
	end

	-- Persist immediately on first launch so the file exists for future runs
	if first_launch then
		save_user_config()
		Logger.info(LOG, "Default config written to '%s'.", USER_CONFIG)
	end

	_state.watcher = start_gesture_watcher()

	local active_combos = 0
	for _, combo_def in ipairs(M.MOD_COMBOS) do
		local cfg = _state.mod_combos_config[combo_def.id] or {}
		if type(cfg) == "table" and (cfg.tap ~= "none" or cfg.hold ~= "none") then
			active_combos = active_combos + 1
		end
	end

	Logger.success(LOG,
		"Karabiner bridge initialized (%d action(s), %d combo(s) active).",
		#M.AVAILABLE_ACTIONS, active_combos)
end

--- Stops the trackpad watcher.
function M.stop()
	if not _state or not _state.watcher then return end
	Logger.start(LOG, "Stopping Karabiner bridge…")
	pcall(function() _state.watcher:stop() end)
	_state.watcher = nil
	Logger.success(LOG, "Karabiner bridge stopped.")
end

return M
