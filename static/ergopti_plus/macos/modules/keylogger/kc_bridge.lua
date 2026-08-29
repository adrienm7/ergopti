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
local Logger  = require("infra.logger")
local Timings = require("infra.timings")
local TimerScheduler = require("adapters.timer_scheduler")
local LOG     = "keylogger.kc_bridge"

-- Absolute path to the hand-off log file written by KE shell_command actions.
-- Must match the KE_PHYSICAL_KC_LOG constant in platform/remap/generator.lua.
-- Resolved via the central menu_paths module — no local fallback.
local KC_LOG_PATH
do
	local mp = require("infra.config_paths")
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
local _init_tap_hold_config = nil
local _init_available_actions = nil
local _may_persist = nil

-- Set of numeric HS keycodes that are KE remap outputs (not physical inputs).
-- Populated by _build_managed_output_set() at init time; read by
-- M.is_ke_managed_output_kc() so the keylogger can suppress false kc counts.
local _managed_output_kcs = {}

-- Watcher that fires whenever KC_LOG_PATH is written to.
local _watcher = nil

-- Backup poll timer that drains the log on a fixed cadence.
local _poll_timer = nil
local _watchers_active = false
local _watcher_generation = 0

-- Byte offset into KC_LOG_PATH: we only read lines written since the last drain.
local _file_offset = 0
local _cursor_trusted = false

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
--- Reports whether this bridge may persist an event right now.
---
--- kc_bridge is a FOURTH keylogger writer, and it carried neither guard: no
--- pause predicate and no privacy predicate anywhere in the file. Its drain
--- triggers are torn down only by M.stop(), which pause never calls and focusing
--- a secure field never calls — so physical key press/release kept reaching
--- today.log while a password field had focus.
---
--- Returning false must NOT stop the surrounding bookkeeping: the file offset and
--- the pending-down table still advance, exactly as the existing "no log manager"
--- path does, so nothing is replayed as a backlog when logging resumes.
--- @return boolean
local function may_persist()
	if type(_may_persist) ~= "function" then
		Logger.error(LOG, "Persistence gate is unavailable — physical event discarded.")
		return false
	end
	local ok, allowed_or_err = xpcall(_may_persist, debug.traceback)
	if not ok then
		Logger.error(LOG, "Persistence gate raised — physical event discarded: %s.",
			tostring(allowed_or_err))
		return false
	end
	return allowed_or_err == true
end

local function drain_log()
	local fh = io.open(KC_LOG_PATH, "r")
	if not fh then
		Logger.trace(LOG, "KC log not yet created — nothing to drain.")
		return
	end

	-- Seek to where we left off, or determine file has been rotated (size shrank).
	-- A failed EOF probe is not evidence of truncation: replaying from byte zero
	-- would assign old physical events the current timestamp and application.
	local seek_ok, file_size, seek_error = xpcall(function()
		return fh:seek("end")
	end, debug.traceback)
	if not seek_ok or type(file_size) ~= "number" then
		local close_ok, close_result, close_error = xpcall(function()
			return fh:close()
		end, debug.traceback)
		Logger.error(LOG, "KC log EOF probe failed — drain deferred at byte %d: %s.",
			_file_offset, tostring(seek_ok and seek_error or file_size))
		if not close_ok or close_result ~= true then
			Logger.error(LOG, "KC log close after EOF probe failure did not commit: %s.",
				tostring(close_ok and close_error or close_result))
		end
		return
	end
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
					if _log_manager and type(_log_manager.log_karabiner_release) == "function"
						and may_persist() then
						_log_manager.log_karabiner_release(kc_num, app_name, hold_ms)
					end
				else
					_pending_down[kc_num] = hs.timer.absoluteTime() / 1000000
					if _log_manager and may_persist() then
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
--- Should be called by platform/remap/init.lua after M.apply_config().
--- @param tap_hold_config table Map of key_id → {tap, hold} action ids.
--- @param available_actions table List of action definitions from actions.json.
--- @return boolean refreshed True only after the replacement set is published.
function M.refresh_managed_set(tap_hold_config, available_actions)
	if type(tap_hold_config) ~= "table" or type(available_actions) ~= "table" then
		Logger.warn(LOG, "refresh_managed_set: invalid arguments — skipping rebuild.")
		return false
	end
	build_managed_output_set(tap_hold_config, available_actions)
	return true
end

--- Releases every output-keycode claim without stopping the physical ledger.
--- Personal Karabiner may emit the same virtual keycodes as an Ergopti action;
--- therefore an inert, disabled or failed Ergopti lease must leave this set empty.
function M.clear_managed_set()
	_managed_output_kcs = {}
	return true
end

--- Arms the path watcher and backup poll timer. Idempotent: skips creation when
--- the handles already exist so stop/start cycles can call this repeatedly.
--- Must only be called after _state is set.
local function stop_path_watcher()
	if not _watcher then return true end
	local watcher = _watcher
	local ok, stopped = xpcall(function()
		if type(watcher.stop) ~= "function" then error("path watcher has no stop method") end
		return watcher:stop()
	end, debug.traceback)
	-- hs.pathwatcher:stop() is a void API; non-throw is its exact commitment.
	if not ok then
		Logger.error(LOG, "Path watcher cleanup failed; exact handle retained: %s.",
			tostring(stopped))
		return false
	end
	if _watcher == watcher then _watcher = nil end
	return true
end

--- Releases the exact backup poller while retaining refused cleanup debt.
--- @return boolean settled True only when no native timer remains owned.
local function stop_poll_timer()
	if not _poll_timer then return true end
	local handle = _poll_timer
	local ok, settled = xpcall(function()
		return TimerScheduler.cancel(handle)
	end, debug.traceback)
	if not ok or settled ~= true then
		Logger.error(LOG, "Poll timer cleanup failed; exact handle retained: %s.",
			tostring(ok and settled or settled))
		return false
	end
	if _poll_timer == handle then _poll_timer = nil end
	return true
end

--- Releases both drain producers without hiding a sibling cleanup failure.
--- @return boolean settled True only when both exact capabilities were released.
local function stop_watchers()
	local watcher_stopped = stop_path_watcher()
	local poll_stopped = stop_poll_timer()
	return watcher_stopped and poll_stopped
end

--- Moves the ledger cursor to a proven EOF and releases the exact read handle.
--- A transient cold-start read refusal leaves active drain producers at offset
--- zero. This proof is therefore separate from watcher ownership and must be
--- retried before persistence can become eligible.
--- @return boolean committed True only after open, seek and close all commit.
--- @return number|string eof_or_error Proven EOF or failure detail.
local function resync_cursor_to_eof()
	_cursor_trusted = false
	local open_ok, handle_or_err, open_err = xpcall(function()
		return io.open(KC_LOG_PATH, "r")
	end, debug.traceback)
	if not open_ok or not handle_or_err then
		return false, "open failed: " .. tostring(open_ok and open_err or handle_or_err)
	end

	local handle = handle_or_err
	local seek_ok, eof_or_err = xpcall(function()
		return handle:seek("end")
	end, debug.traceback)
	local close_ok, closed_or_err = xpcall(function()
		return handle:close()
	end, debug.traceback)
	if not seek_ok or type(eof_or_err) ~= "number" then
		return false, "seek failed: " .. tostring(eof_or_err)
	end
	if not close_ok or closed_or_err ~= true then
		return false, "close failed: " .. tostring(closed_or_err)
	end

	_file_offset = eof_or_err
	_cursor_trusted = true
	return true, eof_or_err
end

local function _arm_watchers()
	if not require_state("_arm_watchers") then return false end
	if _watchers_active then return true end
	if not stop_watchers() then
		Logger.error(LOG, "Watcher start refused: prior cleanup remains pending.")
		return false
	end
	_watcher_generation = _watcher_generation + 1
	local generation = _watcher_generation

	-- Touch: hs.pathwatcher binds to an inode; the file must exist before
	-- watcher:start() or creation events may be missed on some macOS versions.
	local fh_touch = io.open(KC_LOG_PATH, "a")
	if fh_touch then fh_touch:close()
	else Logger.warn(LOG, "Cannot create '%s' — bridge may not receive KE events.", KC_LOG_PATH)
	end

	local watcher_ok, watcher_candidate = xpcall(function()
		return hs.pathwatcher.new(KC_LOG_PATH, function()
			if not _watchers_active or generation ~= _watcher_generation then return end
			local ok, err = pcall(drain_log)
			if not ok then Logger.error(LOG, "drain_log() raised (watcher): %s.", tostring(err)) end
		end)
	end, debug.traceback)
	if not watcher_ok or watcher_candidate == nil or watcher_candidate == false then
		Logger.error(LOG, "Path watcher construction failed: %s.", tostring(watcher_candidate))
		return false
	end
	_watcher = watcher_candidate
	local watcher_start_ok, watcher_started = xpcall(function()
		if type(watcher_candidate.start) ~= "function" then error("path watcher has no start method") end
		return watcher_candidate:start()
	end, debug.traceback)
	if not watcher_start_ok or (watcher_started ~= true and watcher_started ~= watcher_candidate) then
		_watcher_generation = _watcher_generation + 1
		stop_path_watcher()
		Logger.error(LOG, "Path watcher start failed: %s.",
			tostring(watcher_start_ok and watcher_started or watcher_started))
		return false
	end

	local timer_ok, timer_candidate, timer_committed = xpcall(function()
		return TimerScheduler.every(POLL_FALLBACK_SEC, function()
			if not _watchers_active or generation ~= _watcher_generation then return end
			local ok, err = pcall(drain_log)
			if not ok then Logger.error(LOG, "drain_log() raised (poll): %s.", tostring(err)) end
		end)
	end, debug.traceback)
	if type(timer_candidate) == "table" then _poll_timer = timer_candidate end
	if not timer_ok or type(timer_candidate) ~= "table" or timer_committed ~= true then
		_watcher_generation = _watcher_generation + 1
		stop_watchers()
		Logger.error(LOG, "Poll timer acquisition failed: %s.",
			tostring(timer_ok and timer_committed or timer_candidate))
		return false
	end

	_watchers_active = true
	Logger.trace(LOG, "Path watcher and poll timer armed.")
	return true
end

--- Initializes the bridge: wires dependencies, builds the suppression set, and
--- starts watching KC_LOG_PATH for new physical key events.
--- @param core_state table The shared keylogger CoreState table.
--- @param log_manager table The LogManager module reference.
--- @param tap_hold_config table Map of key_id → {tap, hold} action ids.
--- @param available_actions table List of action definitions from actions.json.
--- @param may_persist_fn function Canonical root enable/pause/privacy predicate.
function M.init(core_state, log_manager, tap_hold_config, available_actions, may_persist_fn)
	Logger.start(LOG, "Initializing KE physical-kc bridge…")

	if type(core_state) ~= "table" then
		Logger.error(LOG, "M.init(): core_state must be a table — bridge non-functional.")
		return false
	end
	if type(may_persist_fn) ~= "function" then
		Logger.error(LOG, "M.init(): may_persist_fn must be a function — bridge non-functional.")
		return false
	end
	if _state then
		local same_dependencies = _state == core_state
			and _log_manager == log_manager
			and _init_tap_hold_config == tap_hold_config
			and _init_available_actions == available_actions
			and _may_persist == may_persist_fn
		if same_dependencies and _watchers_active then
			Logger.warn(LOG, "M.init() called more than once with the same dependencies — reusing the committed bridge.")
			return true
		end
		Logger.error(LOG, "M.init() called again with different dependencies or an uncommitted lifecycle.")
		return false
	end

	_state        = core_state
	_log_manager  = log_manager
	_init_tap_hold_config = tap_hold_config
	_init_available_actions = available_actions
	_may_persist = may_persist_fn

	if type(tap_hold_config) == "table" and type(available_actions) == "table" then
		build_managed_output_set(tap_hold_config, available_actions)
	else
		Logger.debug(LOG, "Tap/hold configuration is deferred; suppression set starts empty.")
	end

	-- Set _file_offset to current end so we ignore stale lines from a prior session
	-- (those have already been counted in the persisted kc dict on disk).
	local cursor_ready, eof_or_err = resync_cursor_to_eof()
	if cursor_ready then
		Logger.debug(LOG, "KC log opened (%d bytes) — draining only future writes.", eof_or_err)
	else
		Logger.warn(LOG,
			"KC log EOF is untrusted at cold start — persistence stays denied until retry: %s.",
			tostring(eof_or_err))
	end

	if not _arm_watchers() then
		Logger.error(LOG, "M.init(): watcher transaction failed — bridge non-functional.")
		return false
	end

	Logger.success(LOG, "KE physical-kc bridge initialized (watching '%s').", KC_LOG_PATH)
	return true
end

--- Re-arms the path watcher and poll timer after a stop/start cycle.
--- Idempotent: _arm_watchers() skips creation when handles already exist, so
--- calling start() while already running is a safe no-op. Calling it before
--- M.init() is also a no-op (no _state yet). Called unconditionally from
--- keylogger M.start() so the bridge survives toggle OFF/ON.
function M.start()
	if not require_state("start") then return false end
	if not _watchers_active or not _cursor_trusted then
		local previous_offset = _file_offset
		local resynced, eof_or_err = resync_cursor_to_eof()
		if not resynced then
			Logger.error(LOG, "KE bridge start refused: cannot prove EOF resync: %s.",
				tostring(eof_or_err))
			return false
		end
		if eof_or_err > previous_offset then
			Logger.info(LOG, "Skipping %d byte(s) written outside a trusted session.",
				eof_or_err - previous_offset)
		end
	end
	if _watchers_active then return true end
	if not stop_watchers() then
		Logger.error(LOG, "KE bridge start refused: prior producer cleanup remains pending.")
		return false
	end

	if not _arm_watchers() then return false end
	Logger.done(LOG, "KE bridge watchers ensured.")
	return true
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
	_watchers_active = false
	_watcher_generation = _watcher_generation + 1
	local stopped = stop_watchers()
	-- Clear any keys held at stop time. Without this, a key pressed before stop()
	-- and released after start() computes (now - old_down_at) as an aberrant hold_ms.
	_pending_down = {}
	if not stopped then
		Logger.error(LOG, "KE physical-kc bridge stop incomplete: cleanup remains pending.")
		return false
	end
	Logger.done(LOG, "KE physical-kc bridge stopped.")
	return true
end

return M
