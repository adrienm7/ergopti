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

local hs      = hs
local Logger  = require("lib.logger")
local Timings = require("lib.timings")
local LOG     = "keylogger.kc_bridge"

-- Absolute path to the hand-off log file written by KE shell_command actions.
-- Must match the KE_PHYSICAL_KC_LOG constant in modules/karabiner/generator.lua.
-- Resolved via the central menu_paths module — no local fallback.
local KC_LOG_PATH
do
	local mp = require("ui.menu.menu_paths")
	local d  = mp.get_config_dir()
	if not d:match("[/\\]$") then d = d .. "/" end
	KC_LOG_PATH = d .. "metrics/karabiner_kc.log"
end

-- Maximum lines drained per watcher callback to avoid monopolising the run loop
-- when a burst of key presses writes many lines before the watcher fires.
local MAX_DRAIN_LINES = 200

-- The physical ledger remains append-only while this reader is active. A
-- consumer cannot safely compact a file that Karabiner appends independently.

-- Backup poller interval (seconds). hs.pathwatcher relies on FSEvents which can
-- coalesce or miss rapid append-only writes on some macOS versions; a low-cost
-- timer drains the log on a fixed cadence so no physical kc event is ever lost.
-- Shared cross-driver value ([keylogger] kc_bridge_poll_ms).
local POLL_FALLBACK_SEC = Timings.sec("keylogger", "kc_bridge_poll_ms")

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

-- kc_num → ms timestamp of the most recent "press" line drained for that key.
-- Closed (and cleared) when the matching "U:" release line is read; the delta
-- becomes the hold duration. Per-physical-keycode so multiple modifiers held
-- simultaneously don't clobber each other's down timestamp.
local _pending_down = {}





-- ======================================================
-- ======================================================
-- ======= 1/ Output Suppression Set Construction =======
-- ======================================================
-- ======================================================


-- Karabiner key_code → Hammerspoon hs.keycodes.map alias table.
-- Karabiner uses verbose names ("left_command") while HS uses condensed ones
-- ("cmd"/"rightcmd"). Without this table, every tap-hold press on a modifier
-- resolves to nil via hs.keycodes.map, gets dropped by the bridge, and the
-- heatmap stays empty for keys like left_cmd / right_cmd that the user uses
-- intensively as tap-hold triggers.
local KE_TO_HS_KEYCODE_NAME = {
	-- Modifiers (Karabiner distinguishes left/right; HS too but with different names)
	left_command   = "cmd",        -- macOS keycode 55
	right_command  = "rightcmd",   -- macOS keycode 54
	left_shift     = "shift",      -- 56
	right_shift    = "rightshift", -- 60
	left_option    = "alt",        -- 58
	right_option   = "rightalt",   -- 61
	left_control   = "ctrl",       -- 59
	right_control  = "rightctrl",  -- 62
	-- Common KE-named special keys
	delete_or_backspace = "delete",
	delete_forward      = "forwarddelete",
	return_or_enter     = "return",
	spacebar            = "space",
	caps_lock           = "capslock",
	left_arrow          = "left",
	right_arrow         = "right",
	up_arrow            = "up",
	down_arrow          = "down",
	page_up             = "pageup",
	page_down           = "pagedown",
}

--- Resolves a Karabiner key_code string to a macOS virtual keycode number.
--- Returns nil when the name is unknown or not a string.
--- @param kc_name string Karabiner key_code string (e.g. "delete_or_backspace").
--- @return number|nil
local function ke_name_to_num(kc_name)
	if type(kc_name) ~= "string" then return nil end
	-- Translate KE naming to HS naming first; fall back to direct lookup for
	-- key_codes that already match (letters, digits, fn-keys, etc.)
	local hs_name = KE_TO_HS_KEYCODE_NAME[kc_name] or kc_name
	local num = hs.keycodes.map[hs_name]
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
---
--- F-MED-26 / F-MED-33: KcBridge.init() arms the watcher/poll timer at module
--- load time regardless of whether the keylogger feature is enabled (KE writes
--- to the log unconditionally), but _log_manager is only injected once the
--- feature is turned on. The file-offset bookkeeping below MUST always advance
--- — even while _log_manager is nil and the logging branch is skipped —
--- otherwise every line KE appends while the feature is off piles up unread,
--- and the very first drain_log() after the feature is enabled replays the
--- entire backlog in one burst with fabricated (current-time) timestamps
--- instead of the real press times.
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
		local raw = line:match("^%s*(.-)%s*$")  -- trim whitespace
		if raw ~= "" then
			-- Discriminate release lines (prefix "U:") from press lines (bare
			-- key_code). On release, compute hold duration vs the matching
			-- pending press timestamp and feed log_karabiner_release.
			local is_release, kc_name = false, raw
			local up_kc = raw:match("^U:(.+)$")
			if up_kc then is_release, kc_name = true, up_kc end

			local kc_num = ke_name_to_num(kc_name)
			if kc_num then
				if is_release then
					local now_ms  = hs.timer.absoluteTime() / 1000000
					local down_at = _pending_down[kc_num]
					_pending_down[kc_num] = nil
					local hold_ms = down_at and math.floor(now_ms - down_at) or 0
					-- LogManager is nil while the keylogger feature is off (F-MED-26):
					-- keep advancing the offset/pending_down bookkeeping below, but
					-- there is no consumer for the event, so skip only the log call.
					if _log_manager and type(_log_manager.log_karabiner_release) == "function" then
						_log_manager.log_karabiner_release(kc_num, app_name, hold_ms)
					end
				else
					_pending_down[kc_num] = hs.timer.absoluteTime() / 1000000
					if _log_manager then
						_log_manager.log_karabiner_press(kc_num, app_name)
					end
				end
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

	-- This file is an append-only hand-off from an independent Karabiner shell
	-- process. Any reader-side rewrite has an unavoidable tail-read-to-truncate
	-- window in which a new physical key can be lost, even when the unread tail
	-- is preserved. Keep the ledger append-only: its cursor gives O(new lines)
	-- drains and exact accounting. Storage maintenance must be done by a writer
	-- coordinated rotation, never by this consumer.
end





-- ====================================
-- ====================================
-- ======= 3/ Guard Enforcement =======
-- ====================================
-- ====================================

--- Guards every _state-dependent function against being called before
--- M.init(). Kc_bridge was the sole keylogger sibling module missing this
--- canonical guard (F-LOW-14) — every _state-touching function had
--- independently hand-rolled its own ad hoc `if not _state then return end`
--- check instead of routing through one shared, consistently-logged helper.
--- @param func_name string The calling function name for the error message.
--- @return boolean False if _state is not initialized yet, true otherwise.
local function require_state(func_name)
	if not _state then
		Logger.error(LOG, "'%s' called before M.init() — bridge not functional.", func_name)
		return false
	end
	return true
end





-- =============================
-- =============================
-- ======= 4/ Public API =======
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

--- Arms the path watcher and backup poll timer. Idempotent: skips creation when
--- the handles already exist so stop/start cycles can call this repeatedly.
--- Must only be called after _state is set.
local function _arm_watchers()
	if not require_state("_arm_watchers") then return end

	-- Touch: hs.pathwatcher binds to an inode; the file must exist before
	-- watcher:start() or creation events may be missed on some macOS versions.
	local fh_touch = io.open(KC_LOG_PATH, "a")
	if fh_touch then fh_touch:close()
	else Logger.warn(LOG, "Cannot create '%s' — bridge may not receive KE events.", KC_LOG_PATH)
	end

	if not _watcher then
		_watcher = hs.pathwatcher.new(KC_LOG_PATH, function()
			local ok, err = pcall(drain_log)
			if not ok then Logger.error(LOG, "drain_log() raised (watcher): %s.", tostring(err)) end
		end)
		_watcher:start()
		Logger.trace(LOG, "Path watcher armed.")
	end

	if not _poll_timer then
		_poll_timer = hs.timer.new(POLL_FALLBACK_SEC, function()
			local ok, err = pcall(drain_log)
			if not ok then Logger.error(LOG, "drain_log() raised (poll): %s.", tostring(err)) end
		end)
		_poll_timer:start()
		Logger.trace(LOG, "Poll timer armed.")
	end
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
	if _state then
		Logger.warn(LOG, "M.init() called more than once — ignoring duplicate call.")
		return
	end

	_state        = core_state
	_log_manager  = log_manager

	if type(tap_hold_config) == "table" and type(available_actions) == "table" then
		build_managed_output_set(tap_hold_config, available_actions)
	else
		Logger.debug(LOG, "Tap/hold configuration is deferred; suppression set starts empty.")
	end

	-- Set _file_offset to current end so we ignore stale lines from a prior session
	-- (those have already been counted in the persisted kc dict on disk).
	local fh_init = io.open(KC_LOG_PATH, "r")
	if fh_init then
		_file_offset = fh_init:seek("end") or 0
		fh_init:close()
		Logger.debug(LOG, "KC log opened (%d bytes) — draining only future writes.", _file_offset)
	end

	_arm_watchers()

	Logger.success(LOG, "KE physical-kc bridge initialized (watching '%s').", KC_LOG_PATH)
end

--- Re-arms the path watcher and poll timer after a stop/start cycle.
--- Idempotent: _arm_watchers() skips creation when handles already exist, so
--- calling start() while already running is a safe no-op. Calling it before
--- M.init() is also a no-op (no _state yet). Called unconditionally from
--- keylogger M.start() so the bridge survives toggle OFF/ON.
function M.start()
	if not require_state("start") then return end

	-- Re-sync the cursor to EOF, exactly as M.init() does above. M.stop() tears
	-- down both drain triggers, so the offset cannot advance on its own while the
	-- bridge is off — every physical key Karabiner appended during that window was
	-- still pending, and the next drain replayed the whole backlog. Those events
	-- were then stamped with the CURRENT time and attributed to the CURRENTLY
	-- focused app, so switching Metrics off, working for an hour, and switching it
	-- back on injected an hour of keystrokes into the wrong app at the wrong time.
	-- Discarding is the only correct choice: the events were deliberately not
	-- recorded, and their real timestamps and context are gone.
	local fh_resync = io.open(KC_LOG_PATH, "r")
	if fh_resync then
		local eof = fh_resync:seek("end") or _file_offset
		fh_resync:close()
		if eof > _file_offset then
			Logger.info(LOG, "Skipping %d byte(s) appended while the bridge was stopped.",
				eof - _file_offset)
		end
		_file_offset = eof
	end

	_arm_watchers()
	Logger.done(LOG, "KE bridge watchers ensured.")
end

--- Injects the LogManager reference after deferred initialization.
--- Called by keylogger/init.lua when M.start() enables the feature.
--- @param lm table The LogManager module reference.
function M.set_log_manager(lm)
	_log_manager = lm
	Logger.debug(LOG, "LogManager injected into KcBridge.")
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
	-- Clear any keys held at stop time. Without this, a key pressed before stop()
	-- and released after start() computes (now - old_down_at) as an aberrant hold_ms.
	_pending_down = {}
	Logger.done(LOG, "KE physical-kc bridge stopped.")
end

return M
