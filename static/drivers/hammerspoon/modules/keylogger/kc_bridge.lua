--- modules/keylogger/kc_bridge.lua

--- ==============================================================================
--- MODULE: Karabiner Physical Keycode Bridge
--- DESCRIPTION:
--- Drains the append-only log file written by Karabiner-Elements shell_command
--- actions and feeds physical key press events into the keylogger's kc dict,
--- so the heatmap and Keycodes tab reflect the TRUE physical keys the user
--- pressed — not the remapped outputs that the Hammerspoon event tap observes.
---
--- FEATURES & RATIONALE:
--- 1. Correct Heatmap: Karabiner rewrites keycodes before macOS delivers them
---    to any application, making it impossible for the HS event tap to see the
---    original physical key. A shell_command in each tap/hold manipulator appends
---    the physical key_code name to a log file; this module reads that file.
--- 2. Output Suppression: Builds a set of all output keycodes produced by
---    remapped tap/hold keys. The keylogger init skips meta.kc logging for those
---    keycodes so physical and remapped counts are never double-counted.
--- 3. File Watcher: Uses hs.pathwatcher so draining is event-driven — no timer
---    polling — and never blocks the HID event tap.
--- 4. Atomic Read: Each drain pass records the byte offset reached so partial
---    lines (from a shell_command still running) are not consumed prematurely.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")
local LOG    = "keylogger.kc_bridge"

-- Absolute path to the log file written by KE shell_command actions.
-- Must match the KE_PHYSICAL_KC_LOG constant in modules/karabiner/generator.lua.
local KC_LOG_PATH = hs.configdir .. "/karabiner_kc.log"

-- Maximum lines drained per watcher callback to avoid monopolising the run loop
-- when a burst of key presses writes many lines before the watcher fires.
local MAX_DRAIN_LINES = 200

-- Backup poller interval (seconds). hs.pathwatcher relies on FSEvents which can
-- coalesce or miss rapid append-only writes on some macOS versions; a low-cost
-- timer drains the log on a fixed cadence so no physical kc event is ever lost.
local POLL_FALLBACK_SEC = 0.5

local _state      = nil   -- injected by M.init()
local _log_manager = nil  -- injected by M.init()

-- Set of numeric HS keycodes that are KE remap outputs (not physical inputs).
-- Populated by _build_managed_output_set() at init time; read by
-- M.is_ke_managed_output_kc() so the keylogger can suppress false kc counts.
local _managed_output_kcs = {}

-- Watcher that fires whenever KC_LOG_PATH is written to.
local _watcher = nil

-- Backup poll timer that drains the log on a fixed cadence.
local _poll_timer = nil

-- Byte offset into KC_LOG_PATH: we only read lines written since the last drain.
local _file_offset = 0

-- Cumulative count of physical kc events drained — surfaced via M.get_stats()
-- so the user can verify in the console that the bridge is actually receiving
-- events from Karabiner without manually inspecting the log file.
local _drained_total = 0




-- ======================================================
-- ======================================================
-- ======= 1/ Output Suppression Set Construction =======
-- ======================================================
-- ======================================================


--- Resolves a Karabiner key_code string to a macOS virtual keycode number.
--- Returns nil when the name is unknown or not a string.
--- @param kc_name string Karabiner key_code string (e.g. "delete_or_backspace").
--- @return number|nil
local function ke_name_to_num(kc_name)
	if type(kc_name) ~= "string" then return nil end
	local num = hs.keycodes.map[kc_name]
	if type(num) == "number" then return num end
	return nil
end

--- Walks a karabiner_to array and collects every key_code that would be emitted.
--- @param to_array table|nil List of KE event objects.
--- @param out table Set (kc_num → true) mutated in place.
local function collect_output_kcs(to_array, out)
	if type(to_array) ~= "table" then return end
	for _, ev in ipairs(to_array) do
		if type(ev) == "table" and type(ev.key_code) == "string" then
			local num = ke_name_to_num(ev.key_code)
			if num then out[num] = true end
		end
	end
end

--- Builds _managed_output_kcs from the current tap_hold_config and actions.
--- Called once at init; re-called after KE regeneration when the config changes.
--- @param tap_hold_config table Map of key_id → {tap, hold} action ids.
--- @param available_actions table List of action definitions from actions.json.
local function build_managed_output_set(tap_hold_config, available_actions)
	local action_index = {}
	for _, act in ipairs(available_actions) do
		action_index[act.id] = act
	end

	local new_set  = {}
	local count    = 0

	for _key_id, cfg in pairs(tap_hold_config) do
		for _, slot_id in ipairs({ cfg.tap or "none", cfg.hold or "none" }) do
			if slot_id ~= "none" then
				local act = action_index[slot_id]
				if act then
					collect_output_kcs(act.karabiner_to, new_set)
				end
			end
		end
	end

	for _ in pairs(new_set) do count = count + 1 end
	_managed_output_kcs = new_set
	Logger.info(LOG, "Managed output kc set rebuilt: %d unique kc(s) suppressed.", count)
end




-- ====================================
-- ====================================
-- ======= 2/ Log File Draining =======
-- ====================================
-- ====================================

--- Drains new lines from KC_LOG_PATH since _file_offset.
--- Each line is a Karabiner key_code name (e.g. "left_command").
--- Converts to numeric kc and calls LogManager.log_karabiner_press().
local function drain_log()
	local fh = io.open(KC_LOG_PATH, "r")
	if not fh then
		Logger.trace(LOG, "KC log not yet created — nothing to drain.")
		return
	end

	-- Seek to where we left off, or determine file has been rotated (size shrank)
	local ok_seek = fh:seek("end")
	local file_size = ok_seek or 0
	if file_size < _file_offset then
		-- File was truncated/rotated — restart from the beginning
		Logger.info(LOG, "KC log rotated or truncated (was %d bytes, now %d) — resetting offset.", _file_offset, file_size)
		_file_offset = 0
	end
	fh:seek("set", _file_offset)

	local app_name = (_state and type(_state.active_app_name) == "string")
		and _state.active_app_name or "Unknown"

	local drained = 0
	for line in fh:lines() do
		local kc_name = line:match("^%s*(.-)%s*$")  -- trim whitespace
		if kc_name ~= "" then
			local kc_num = ke_name_to_num(kc_name)
			if kc_num then
				_log_manager.log_karabiner_press(kc_num, app_name)
				drained = drained + 1
			else
				Logger.warn(LOG, "Unknown KE key_code name '%s' — skipped.", kc_name)
			end
		end
		if drained >= MAX_DRAIN_LINES then break end
	end

	_file_offset = fh:seek("cur") or _file_offset
	fh:close()

	if drained > 0 then
		_drained_total = _drained_total + drained
		Logger.debug(LOG, "Drained %d physical kc event(s) (total since start: %d).",
			drained, _drained_total)
	end
end




-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

--- Returns true when the given macOS virtual keycode is a KE remap output.
--- The keylogger calls this to skip meta.kc logging for remapped output keys,
--- preventing double-counting when the physical key is already logged here.
--- @param kc_num number The macOS virtual keycode to test.
--- @return boolean
function M.is_ke_managed_output_kc(kc_num)
	return _managed_output_kcs[kc_num] == true
end

--- Rebuilds the output suppression set after the user changes their KE config.
--- Should be called by modules/karabiner/init.lua after M.apply_config().
--- @param tap_hold_config table Map of key_id → {tap, hold} action ids.
--- @param available_actions table List of action definitions from actions.json.
function M.refresh_managed_set(tap_hold_config, available_actions)
	if type(tap_hold_config) ~= "table" or type(available_actions) ~= "table" then
		Logger.warn(LOG, "refresh_managed_set: invalid arguments — skipping rebuild.")
		return
	end
	build_managed_output_set(tap_hold_config, available_actions)
end

--- Initializes the bridge: wires dependencies, builds the suppression set, and
--- starts watching KC_LOG_PATH for new physical key events.
--- @param core_state table The shared keylogger CoreState table.
--- @param log_manager table The LogManager module reference.
--- @param tap_hold_config table Map of key_id → {tap, hold} action ids.
--- @param available_actions table List of action definitions from actions.json.
function M.init(core_state, log_manager, tap_hold_config, available_actions)
	Logger.start(LOG, "Initializing KE physical-kc bridge…")

	if type(core_state) ~= "table" then
		Logger.error(LOG, "M.init(): core_state must be a table — bridge non-functional.")
		return
	end
	if type(log_manager) ~= "table" or type(log_manager.log_karabiner_press) ~= "function" then
		Logger.error(LOG, "M.init(): log_manager must expose log_karabiner_press() — bridge non-functional.")
		return
	end
	if _state then
		Logger.warn(LOG, "M.init() called more than once — ignoring duplicate call.")
		return
	end

	_state        = core_state
	_log_manager  = log_manager

	if type(tap_hold_config) == "table" and type(available_actions) == "table" then
		build_managed_output_set(tap_hold_config, available_actions)
	else
		Logger.warn(LOG, "No tap_hold_config or available_actions — suppression set empty.")
	end

	-- Ensure the log file exists BEFORE the watcher starts: hs.pathwatcher binds
	-- to an inode and may miss creation events if the file does not yet exist.
	-- Touching it here also lets the KE shell_command "echo … >> file" succeed
	-- on first write without a parent-directory race.
	local fh_touch = io.open(KC_LOG_PATH, "a")
	if fh_touch then
		fh_touch:close()
	else
		Logger.warn(LOG, "Cannot create '%s' — bridge may not receive KE events.", KC_LOG_PATH)
	end

	-- Set _file_offset to current end so we ignore stale lines from a prior session
	-- (those have already been counted in the persisted kc dict on disk).
	local fh_init = io.open(KC_LOG_PATH, "r")
	if fh_init then
		_file_offset = fh_init:seek("end") or 0
		fh_init:close()
		Logger.debug(LOG, "KC log opened (%d bytes) — draining only future writes.", _file_offset)
	end

	-- Path watcher fires whenever the log file is written to by KE shell_command
	_watcher = hs.pathwatcher.new(KC_LOG_PATH, function(_paths)
		local ok, err = pcall(drain_log)
		if not ok then
			Logger.error(LOG, "drain_log() raised (watcher): %s.", tostring(err))
		end
	end)
	_watcher:start()

	-- Backup poll timer — covers FSEvents misses. Cheap: only opens the file and
	-- seeks to _file_offset; bails out immediately when there is no new data.
	if _poll_timer then _poll_timer:stop() end
	_poll_timer = hs.timer.new(POLL_FALLBACK_SEC, function()
		local ok, err = pcall(drain_log)
		if not ok then
			Logger.error(LOG, "drain_log() raised (poll): %s.", tostring(err))
		end
	end)
	_poll_timer:start()

	Logger.success(LOG, "KE physical-kc bridge initialized (watching '%s').", KC_LOG_PATH)
end

--- Diagnostic: returns the cumulative number of physical kc events drained,
--- the number of suppressed output kcs, and the current log byte offset.
--- Useful from the HS console to verify the bridge is wired correctly:
---   require("modules.keylogger.kc_bridge").get_stats()
--- @return table { drained_total = number, suppressed = number, offset = number }
function M.get_stats()
	local n = 0
	for _ in pairs(_managed_output_kcs) do n = n + 1 end
	return {
		drained_total = _drained_total,
		suppressed    = n,
		offset        = _file_offset,
		log_path      = KC_LOG_PATH,
	}
end

--- Stops the path watcher. Called from keylogger M.stop().
function M.stop()
	if _watcher then
		_watcher:stop()
		_watcher = nil
	end
	if _poll_timer then
		_poll_timer:stop()
		_poll_timer = nil
	end
	Logger.done(LOG, "KE physical-kc bridge stopped.")
end

return M
