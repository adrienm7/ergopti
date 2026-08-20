--- infra/logger.lua

--- ==============================================================================
--- MODULE: Logger
--- DESCRIPTION:
--- Centralized, level-aware logging system for the entire Hammerspoon runtime.
--- Provides consistent formatting, level filtering, colored console output, and
--- a unified rotating file sink so every subsystem's output lands in one place.
---
--- WHAT IS THIS MODULE'S, AND WHAT IS THE SHARED CORE'S.
--- _shared/lua/logger owns the canonical line format, the eight variants, the
--- 200-entry ring and the five-second dedup window — items 4, 5 and 8 below. This
--- file owns the production in-memory handoff, topical routing policy, deferred
--- console/notification delivery, and the synchronous early-boot/test fallback.
--- The native launcher worker owns production file persistence, daily rotation,
--- retention purge and errors/topical fan-out. The split is not cosmetic: the
--- core's half is replayed against a cross-driver corpus so all three drivers are
--- held to ONE implementation of those rules, and this half is pinned as
--- behaviour by tests/unit/lib/test_logger_file_sinks.lua.
---
--- FEATURES & RATIONALE:
--- 1. Level Filtering: Avoids console noise in production while preserving full
---    detail in development — just lower the level once and all modules comply.
--- 2. Module Tagging: Every call includes a short module identifier so log triage
---    never requires grepping the source.
--- 3. Plain Console Output: each variant is printed with its label tag via
---    print() — hs.styledtext/hs.console are no longer a dependency.
--- 4. Two-axis Lifecycle Logs:
---    - DEBUG axis: Logger.trace (start) / Logger.done (end) — fine-grained ops
---    - INFO  axis: Logger.start (start) / Logger.success (end) — significant ops
---    Seeing a START without a following SUCCESS points to a silent failure.
--- 5. Deduplication: consecutive identical lines are suppressed automatically;
---    a count summary is printed when the run breaks, using the same color/level.
--- 6. Unified rotating file sink: the acknowledged native worker writes one file
---    per calendar day under <config>/logs/,
---    named ErgoptiPlus_YYYY-MM-DD.log (mirrors the AHK driver naming convention).
---    Files older than max_age_days are purged automatically on init and after
---    the first successful write of each new calendar day.
--- 7. Topical sub-files: lines are fan-out to per-subsystem logs (llm, karabiner…)
---    based on module tag matching, giving focused tail targets per feature area.
--- 8. Timestamp format: HHhMMminSSsNNNms — matches the AHK driver exactly so both
---    log files look identical when tailed side by side.
--- 9. Errors-only sink: the native worker also writes WARNING and ERROR lines to
---    ErgoptiPlus_errors_YYYY-MM-DD.log (daily rotation + purge). Provides a
---    small dedicated file for quick triage of failures.
--- ==============================================================================

local M = {}

-- socket.gettime() gives sub-second precision for the millisecond component.
-- Loaded via pcall so headless unit tests that lack the hs sandbox still work.
local _ok_socket, _socket = pcall(require, "socket")
local _gettime = (_ok_socket and _socket and _socket.gettime) or os.time

-- Main unified log file. Set to a safe early-boot fallback; overridden by
-- M.init_log_path() once the user config directory is known.
M.UNIFIED_LOG_FILE = "/tmp/ErgoptiPlus_boot.log"

-- Dedicated errors-only log (WARNING + ERROR levels). Daily file under the
-- driver logs directory. Purpose: quick triage of problems without the volume
-- of the full unified daily log.
M.ERRORS_LOG_FILE = "/tmp/ErgoptiPlus_errors_boot.log"

-- Log directory resolved after M.init_log_path(); used by sub-file fan-out.
local _log_dir = "/tmp/"

-- Delay (seconds) after which the daily old-log purge runs. The purge is pure
-- housekeeping (deleting stale files) and nothing downstream waits on it, so it
-- stays off the boot critical path; the freshly-resolved log file is already
-- writable by the time it runs.
local LOG_PURGE_DELAY_SEC = 5.0

-- Default retention window for the daily unified and errors-only logs
local DEFAULT_LOG_RETENTION_DAYS = 14

-- Seconds in a calendar day — the unit in which the retention window is expressed.
local SECONDS_PER_DAY = 86400

-- Hour used when turning a YYYY-MM-DD filename back into an epoch timestamp.
-- Anchoring at noon keeps the age comparison DST-safe: a ±1 h shift can never
-- push a file across a day boundary the way a midnight anchor would.
local PURGE_NOON_HOUR = 12

-- Topical sub-files: lines whose rendered "[tag]" matches any pattern are
-- fan-out here in addition to the main unified file. Sub-files are ephemeral
-- (today only) — they are a filtered view of the main log, not an archive.
-- Sub-file routing table, generated from _shared/modules/logger/sub_files.toml.
--
-- This used to be a 120-line hand-rolled [[array_of_tables]] parser plus a
-- hardcoded fallback list. Both were liabilities. The parser was one of TWO
-- copies of the same grammar (the AHK driver had its own), so the same bug had
-- to be found and fixed twice — a "]" inside a quoted pattern closed the array
-- early, silently dropping every pattern after it, and the file's own guidance
-- is to prefer bracketed tag patterns like "[gestures". The fallback was a
-- second copy of the data, and it had already drifted: it routed gestures on
-- one pattern where the canonical file has two, so a stripped build quietly
-- stopped collecting every bare "gesture" line.
--
-- The generated file is committed and loaded like any other module, so there is
-- no grammar to get wrong and no "file unavailable" branch to diverge in.
local SUB_LOG_NAMES = require("_generated.logger_sub_files")

-- LogTransport routes a hostile oversized record in bounded 8 KiB windows.
-- Retaining exactly the longest-pattern-minus-one suffix makes a literal that
-- crosses a window boundary observable without ever rescanning the full line.
local ROUTE_OVERLAP_BYTES = 0
for _, sub in ipairs(SUB_LOG_NAMES) do
	for _, pattern in ipairs(sub.patterns) do
		ROUTE_OVERLAP_BYTES = math.max(ROUTE_OVERLAP_BYTES, #pattern - 1)
	end
end

-- The platform-neutral core, shared with the Linux daemon and mirrored by the
-- AutoHotkey driver. It owns the four algorithms this file used to carry its own
-- copy of: the canonical line format, the eight variants, the 200-entry ring, and
-- the five-second dedup window. Each copy carried a comment claiming to match the
-- other drivers byte for byte — and a claim is not a mechanism. The corpus at
-- _shared/tests/corpus/logger/behaviour_vectors.json is the mechanism, and it can
-- only hold ONE implementation to those rules.
--
-- Everything the core deliberately has no opinion about stays here: the unified
-- daily file, the errors-only mirror, the topical fan-out, the level-aware flush
-- policy, and the print() tee. That half is pinned by
-- tests/unit/lib/test_logger_file_sinks.lua as BEHAVIOUR rather than as source
-- text, which is what made this migration provable instead of merely plausible.
--
-- LIFETIME: the core is required under a BARE name, so tests/run.lua's
-- between-file purge (prefixes ^modules%. ^adapters%. ^infra%. ^ui%.) never
-- evicts it. Its ring and its dedup streak are therefore per PROCESS — which is
-- also true of the running driver. A test that needs either one clean asks for
-- it: ring_buffer_clear() / reset_dedup().
local Core = require("logger")
local LogTransport = require("adapters.log_transport")





-- ==========================================
-- ==========================================
-- ======= 0/ Sub-file TOML Bootstrap =======
-- ==========================================
-- ==========================================





-- ====================================
-- ====================================
-- ======= 1/ Level Definitions =======
-- ====================================
-- ====================================

--- Numeric severity levels used for filtering, read from the core rather than
--- re-declared here.
---
--- The spacing is spec § 4's, shared with the AutoHotkey driver's
--- LOGGER_SEVERITY. It used to be 1/2/3/4 in this file, which meant a level
--- NUMBER meant two different things depending on which driver read it, and made
--- the core impossible to adopt without silently changing what every threshold
--- filtered. Two tables of the same four numbers is exactly how that happened, so
--- there is now one table. The gaps still leave room for a level between two
--- existing ones without renumbering anything.
M.LEVELS = Core.LEVELS

-- Full variant table: each entry drives its label, color, and severity level.
--
-- Two lifecycle axes. Each axis shares ONE level so a threshold can never emit
-- half a pair: a TRACE with no DONE, or a START with no SUCCESS, is how a silent
-- failure looks in the log, and splitting an axis would manufacture one on every
-- run.
--   DEBUG axis (level 10): TRACE → start of a routine internal op  |  DONE → end
--   INFO  axis (level 20): START → start of a significant action   |  SUCCESS → end
--
-- This driver's public vocabulary is UPPERCASE — every call site, M.LEVELS, and
-- the log-level submenu use it; the core's is lowercase. One table maps between
-- them, and it is the only place the two spellings meet.
local CORE_VARIANT = {
	-- ── Debug axis ──────────────────────────────────────────────────────────
	DEBUG   = "debug",
	TRACE   = "trace",
	DONE    = "done",
	-- ── Info axis ───────────────────────────────────────────────────────────
	INFO    = "info",
	START   = "start",
	SUCCESS = "success",
	-- ── Warning / Error ─────────────────────────────────────────────────────
	WARNING = "warn",
	ERROR   = "error",
}

-- Derived from the core, never re-declared. A variant's label and severity are
-- the core's answer; a second table here would be a second answer, and the two
-- would agree right up until one of them was edited.
local VARIANTS = {}
for upper_key, core_name in pairs(CORE_VARIANT) do
	VARIANTS[upper_key] = {
		level = Core.level_of(core_name),
		label = Core.label_of(core_name),
	}
end

--- Current active level — only messages at or above this level are emitted.
M.current_level = M.LEVELS.WARNING

-- Optional hook set by the bootstrapper after all modules are loaded.
-- Called with (module_name, formatted_message) on every Logger.error call.
local _error_notification_handler = nil

-- Optional test sink registered by unit tests to capture formatted log lines
-- without touching the filesystem or hs.console. Set via M.set_sink() and
-- cleared by passing nil.
local _test_sink = nil





-- =======================================
-- =======================================
-- ======= 2/ Public Configuration =======
-- =======================================
-- =======================================

-- File sink state — handle kept open for the life of the HS process to avoid
-- open/close overhead. _last_log_date detects day rollovers; _last_log_path
-- detects init_log_path() re-points after early-boot.
--
-- Declared HERE, above every function that touches them. A `local` declared
-- textually BELOW a closure is not captured by it: the closure silently binds
-- the nil global of the same name instead. While these lived down in section 3.1,
-- init_log_path()'s "close the handle before re-pointing" block tested a nil
-- global, so it never fired and assigned to globals — dead code that only looked
-- alive, and that made _ensure_log_file()'s own re-point check look redundant.
local _file_handle    = nil
local _last_log_date  = nil
local _last_log_path  = nil

-- Retention selected by init_log_path(). Kept beside the sink state so a
-- midnight rollover can schedule the same housekeeping policy without relying
-- on a process restart to call init_log_path() again
local _log_retention_days = nil

-- One-shot purge timers must remain Lua-owned until delivery. Hammerspoon's
-- hs.timer userdata stops its NSTimer from __gc, so merely checking the handle
-- returned by doAfter() still leaves the callback vulnerable to an arbitrary GC
-- cycle. Slots are token-keyed because a config re-point and a midnight rollover
-- may legitimately have separate purges pending at the same time.
local _pending_purge_timers = {}
local _next_purge_timer_token = 0

-- Per-sub-file calendar date, playing for the topical fan-out the role
-- _last_log_date plays for the main handle: it records the date this process last
-- wrote to each sub-file, so the first write of a new day truncates it instead of
-- appending. Deciding this at write time is the only correct moment — the purge
-- pass runs LOG_PURGE_DELAY_SEC after boot, by which point the fan-out has already
-- stamped every active sub-file with today's mtime, so its "mtime is not today"
-- test can never fire for the files that actually need resetting.
local _sub_file_date  = {}

-- Open append handles for the topical sub-files, keyed by path. Declared here
-- with the other sink state and ABOVE every closure that touches it.
local _sub_handles    = {}

-- Forward declarations — implementations are in Section 3.2. Declared here for
-- the same reason as the handles above: init_log_path(), _purge_old_logs() and
-- M.set_sink() are defined before them and must reach the real functions, not a
-- nil global. A `local` declared textually BELOW a closure that names it is not
-- captured by that closure at all; it silently binds the global instead, and the
-- surrounding pcall then swallows the "attempt to call a nil value" that follows.
local _log
local _driver_sink
local _route_line

-- Production switches to the native ACKed transport before any input owner is
-- activated. Early boot and headless unit tests deliberately retain the local
-- sink until M.start_async_sink() commits the socket and its owned pump timer.
local _async_sink_active = false
local _async_sink_error = nil
local ASYNC_SINK_SHUTDOWN_TIMEOUT_SEC = 2.0
local _async_sink_failure_handler = nil
local _pending_async_sink_failure = nil
local _async_sink_failure_handler_error = nil
local ASYNC_SINK_MANAGED_ENV_KEYS = {
	"ERGOPTI_LAUNCHER_PID",
	"ERGOPTI_LAUNCHER_BUNDLE_ID",
	"ERGOPTI_LOG_PORT",
	"ERGOPTI_LOG_TOKEN",
}

-- M.error() sets this only while the shared core emits that exact error line.
-- Core may first deliver a dedup summary for the PREVIOUS streak, but always
-- delivers the actual accepted line last. The sink therefore remembers each
-- record and M.error attaches to the final one after emit() returns. This avoids
-- copying and suffix-scanning an arbitrarily large user-derived message on HID.
local _pending_error_notification = nil

--- Delivers one transport failure at a protected non-HID boundary. The adapter
--- invokes this function only from its pump callback; queue exhaustion reached
--- from keyDown merely stores adapter state until that pump runs.
--- @param detail any Exact transport failure detail.
local function _on_async_sink_failed(detail)
	local exact = tostring(detail or "unknown asynchronous logger transport failure")
	_async_sink_error = exact
	if _pending_async_sink_failure == nil then _pending_async_sink_failure = exact end
	if type(_async_sink_failure_handler) ~= "function" then return end

	local pending = _pending_async_sink_failure
	local ok, handler_err = xpcall(_async_sink_failure_handler, debug.traceback, pending)
	if ok then
		_pending_async_sink_failure = nil
		_async_sink_failure_handler_error = nil
	else
		_async_sink_failure_handler_error = tostring(handler_err)
	end
end

--- Executes one purge boundary and makes an unexpected callback failure visible.
--- Hammerspoon reports timer exceptions only to its Console, while the file log
--- is the artifact users can export. This local guard is required because the
--- boot purge is scheduled before process-wide timer wrapping is installed.
--- @param log_dir string Absolute logs directory.
--- @param max_age_days integer Retention window for daily logs.
--- @return boolean completed True when the purge returned without raising.
local function _execute_log_purge(log_dir, max_age_days)
	local ok, err = xpcall(M._purge_old_logs, debug.traceback, log_dir, max_age_days)
	if not ok then
		_log("ERROR", "logger", "Old-log purge failed for \"%s\": %s.", log_dir, tostring(err))
	end
	return ok
end

--- Commits one deferred purge, or executes inline only in a headless environment.
--- A protected constructor call is not sufficient evidence that a timer exists:
--- the API can return nil without raising, so both outcomes are checked and
--- logged. Rollover callers never opt into inline execution because they run on
--- the write path and housekeeping must remain deferred.
--- @param log_dir string Absolute logs directory.
--- @param max_age_days integer Retention window for daily logs.
--- @param inline_without_timer boolean Whether a missing timer may run inline.
--- @return boolean committed True when a timer was committed or inline work completed.
local function _schedule_log_purge(log_dir, max_age_days, inline_without_timer)
	local hs_ref = rawget(_G, "hs")
	local timer_ref = (type(hs_ref) == "table") and hs_ref.timer or nil
	if type(timer_ref) ~= "table" or type(timer_ref.doAfter) ~= "function" then
		if inline_without_timer then return _execute_log_purge(log_dir, max_age_days) end
		_log("ERROR", "logger", "Old-log purge was not scheduled for \"%s\" — timer service unavailable.", log_dir)
		return false
	end

	_next_purge_timer_token = _next_purge_timer_token + 1
	local token = _next_purge_timer_token
	local slot = { delivered = false, timer = nil }
	_pending_purge_timers[token] = slot
	local ok_schedule, timer_or_err = pcall(timer_ref.doAfter, LOG_PURGE_DELAY_SEC, function()
		slot.delivered = true
		_pending_purge_timers[token] = nil
		_execute_log_purge(log_dir, max_age_days)
	end)
	if not ok_schedule then
		_pending_purge_timers[token] = nil
		_log("ERROR", "logger", "Old-log purge could not be scheduled for \"%s\": %s.", log_dir,
			tostring(timer_or_err))
		return false
	end
	if not timer_or_err then
		_pending_purge_timers[token] = nil
		_log("ERROR", "logger", "Old-log purge was not scheduled for \"%s\" — timer constructor returned no handle.",
			log_dir)
		return false
	end
	-- A faithful asynchronous timer cannot deliver before doAfter returns, but
	-- test doubles and future ports may. Never resurrect a slot whose callback
	-- already completed synchronously.
	if not slot.delivered then slot.timer = timer_or_err end
	return true
end

--- Stops every still-owned Lua purge timer before the native logger assumes
--- retention ownership. A timer is removed only after stop() and its observable
--- running state both prove that its callback can no longer fire.
--- @return boolean settled True when no Lua purge timer remains live.
--- @return string|nil detail First exact cleanup refusal, when unsettled.
local function _stop_pending_purge_timers()
	local settled = true
	local first_error = nil
	for token, slot in pairs(_pending_purge_timers) do
		local timer = slot and slot.timer or nil
		if timer ~= nil then
			local method_ok, stop_method = pcall(function() return timer.stop end)
			local stop_ok, stop_result = false, nil
			if method_ok and type(stop_method) == "function" then
				stop_ok, stop_result = pcall(stop_method, timer)
			end

			local state_ok = false
			if stop_ok and stop_result ~= false then
				local member_ok, running_member = pcall(function() return timer.running end)
				if member_ok and type(running_member) == "function" then
					local probe_ok, running = pcall(running_member, timer)
					state_ok = probe_ok and running == false
				elseif member_ok and type(running_member) == "boolean" then
					state_ok = running_member == false
				elseif type(timer) == "table" then
					-- Narrow compatibility for injected test doubles: a successful
					-- stop method is their only observable native-state contract.
					state_ok = true
				end
			end

			if state_ok then
				slot.timer = nil
				_pending_purge_timers[token] = nil
			else
				settled = false
				if first_error == nil then
					first_error = string.format("purge timer %s refused exact stop: %s",
						tostring(token), tostring(stop_result or stop_method))
				end
			end
		else
			_pending_purge_timers[token] = nil
		end
	end
	return settled, first_error
end

--- Configures the log file path under <config_dir>/hammerspoon/logs/ with
--- daily rotation (ErgoptiPlus_YYYY-MM-DD.log) and purges files older than
--- max_age_days. Best-effort: an I/O failure cannot block init, but every
--- rejected or throwing asynchronous purge boundary is logged explicitly.
--- @param config_dir string Absolute path to the user config directory (trailing slash optional).
--- @param max_age_days integer Days to keep before purging (default 14).
function M.init_log_path(config_dir, max_age_days)
	max_age_days = max_age_days or DEFAULT_LOG_RETENTION_DAYS
	if type(config_dir) ~= "string" or config_dir == "" then return end
	if not config_dir:match("[/\\]$") then config_dir = config_dir .. "/" end

	local log_dir = config_dir .. "hammerspoon/logs/"

	-- Created in-process, not by forking /bin/sh.
	--
	-- This runs on the boot critical path, and `mkdir -p` through the fully
	-- synchronous ShellRunner is a fork+exec paid on every launch for a directory
	-- that already exists on all but the first. Four other modules in this driver
	-- create directories in-process already. hs.fs.mkdir creates ONE level, so the
	-- components are walked; every call is best-effort, because a permission
	-- problem must not block boot — exactly as the shell version's discarded exit
	-- status did not.
	local hs_ref = rawget(_G, "hs")
	local fs_ref = (type(hs_ref) == "table") and hs_ref.fs or nil
	if type(fs_ref) == "table" and type(fs_ref.mkdir) == "function" then
		local built = (log_dir:sub(1, 1) == "/") and "/" or ""
		for part in log_dir:gmatch("[^/]+") do
			built = built .. part .. "/"
			pcall(fs_ref.mkdir, built)
		end
	end
	_log_dir = log_dir
	_log_retention_days = max_age_days

	-- Close every sub-file handle open on the OLD directory. They are keyed by
	-- absolute path, so a re-point would otherwise keep writing the topical logs
	-- into the previous config directory for the rest of the session — and the
	-- per-day truncation decision, cached alongside them, would be stale too.
	for path, entry in pairs(_sub_handles) do
		pcall(function() entry.fh:close() end)
		_sub_handles[path]   = nil
		_sub_file_date[path] = nil
	end

	-- Close any handle open on the old path so the next write re-opens cleanly
	if _file_handle then
		pcall(function() _file_handle:close() end)
		_file_handle   = nil
		_last_log_date = nil
		_last_log_path = nil
	end

	M.UNIFIED_LOG_FILE = log_dir .. "ErgoptiPlus_" .. os.date("%Y-%m-%d") .. ".log"
	M.ERRORS_LOG_FILE = log_dir .. "ErgoptiPlus_errors_" .. os.date("%Y-%m-%d") .. ".log"


	-- Old-log purge is pure housekeeping — defer it off the boot critical path.
	-- The dated log file resolved just above is already writable, so nothing
	-- downstream waits on the purge.
	_schedule_log_purge(log_dir, max_age_days, true)
end

--- Removes one stale log and records any OS refusal without fabricating success.
--- @param path string Absolute file path selected by the retention policy.
--- @return boolean removed True only when os.remove confirms deletion.
local function _remove_stale_log(path)
	local ok_remove, removed, remove_err = pcall(os.remove, path)
	if ok_remove and removed then return true end

	local reason = ok_remove and remove_err or removed
	if reason == nil or reason == "" then reason = "unknown error" end
	_log("WARNING", "logger", "Cannot remove stale log \"%s\": %s.", path, tostring(reason))
	return false
end

--- Deletes stale log files under `log_dir`. Split out of init_log_path() so it can
--- be deferred off the boot critical path and exercised directly in tests. Two passes:
---   1. Main daily logs — BOTH ErgoptiPlus_YYYY-MM-DD.log and the errors-only
---      ErgoptiPlus_errors_YYYY-MM-DD.log — aged by the date carried in the
---      FILENAME (not mtime) so moved or copied files still age correctly.
---   2. Topical sub-files, which are ephemeral (today only) — any whose last
---      modification is not today is removed (a filtered view, not an archive).
---
--- Spawns zero subprocesses. The previous implementation shelled out through the
--- fully synchronous ShellRunner: one `find | while read` pipeline forking
--- basename + sed + two `date` calls PER file, plus a `stat` per sub-file. Deferring
--- it by a few seconds moved that off the boot path but not off the MAIN THREAD —
--- it landed while the keystroke event tap was armed and the user was typing.
--- That pipeline also never matched the errors sink: stripping the "ErgoptiPlus_"
--- prefix from ErgoptiPlus_errors_2026-06-01.log yields "errors_2026-06-01", which
--- `date -j -f %Y-%m-%d` cannot parse, so the comparison short-circuited and the
--- errors file grew without bound. Everything needed is in the filename and in the
--- filesystem attributes, so neither cost is necessary.
--- @param log_dir string Absolute logs directory (trailing slash).
--- @param max_age_days integer Retention window for the main daily logs.
function M._purge_old_logs(log_dir, max_age_days)
	if type(log_dir) ~= "string" or log_dir == "" then return end
	max_age_days = max_age_days or 14

	local hs_ref = rawget(_G, "hs")
	local fs_ref = (type(hs_ref) == "table") and hs_ref.fs or nil
	if type(fs_ref) ~= "table" or type(fs_ref.dir) ~= "function" then
		_log("WARNING", "logger", "Filesystem port unavailable — old-log purge skipped.")
		return
	end

	-- The directory listing throws (rather than returning nil) on an unreadable or
	-- missing path, so both the call and the walk are protected.
	local ok_dir, iter, dir_obj = pcall(fs_ref.dir, log_dir)
	if not ok_dir or type(iter) ~= "function" then
		_log("WARNING", "logger", "Cannot list \"%s\" — old-log purge skipped: %s", log_dir, tostring(iter))
		return
	end

	local entries = {}
	local ok_walk, walk_err = pcall(function()
		for name in iter, dir_obj do
			entries[#entries + 1] = name
		end
	end)
	if not ok_walk then
		_log("WARNING", "logger", "Log directory walk aborted for \"%s\": %s", log_dir, tostring(walk_err))
	end

	-- Exact-name set so the ephemeral sub-file pass is a single hash lookup.
	local is_sub_file = {}
	for _, sub in ipairs(SUB_LOG_NAMES) do is_sub_file[sub.name] = true end

	local today   = os.date("%Y-%m-%d")
	local cutoff  = os.time() - (max_age_days * SECONDS_PER_DAY)
	local removed = 0

	for _, name in ipairs(entries) do
		-- The errors sink needs its OWN pattern: the main-log pattern anchors the
		-- date immediately after "ErgoptiPlus_", so it can never match the "errors_"
		-- infix. Missing that second pattern is exactly what let the errors file
		-- escape every purge since the sink was introduced.
		local year, month, day = name:match("^ErgoptiPlus_errors_(%d%d%d%d)%-(%d%d)%-(%d%d)%.log$")
		if not year then
			year, month, day = name:match("^ErgoptiPlus_(%d%d%d%d)%-(%d%d)%-(%d%d)%.log$")
		end

		if year then
			local stamp = os.time({
				year  = tonumber(year),
				month = tonumber(month),
				day   = tonumber(day),
				hour  = PURGE_NOON_HOUR,
			})
			if stamp and stamp < cutoff then
				if _remove_stale_log(log_dir .. name) then removed = removed + 1 end
			end
		elseif is_sub_file[name] then
			local ok_attr, attrs = pcall(fs_ref.attributes, log_dir .. name)
			if ok_attr and type(attrs) == "table" and attrs.modification
				and os.date("%Y-%m-%d", attrs.modification) ~= today then
				if _remove_stale_log(log_dir .. name) then removed = removed + 1 end
			end
		end
	end

	if removed > 0 then
		_log("INFO", "logger", "Old-log purge removed %d stale file(s).", removed)
	end
end

--- Registers a callback invoked on every Logger.error call to surface errors as
--- system notifications. Set once from init.lua after all modules are loaded.
--- @param fn function|nil Callback with signature fn(module_name, message).
function M.set_error_notification_handler(fn)
	_error_notification_handler = (type(fn) == "function") and fn or nil
end

--- Registers the fail-safe invoked when the native transport reports an exact
--- runtime failure. Transport failures are never delivered from enqueue()/HID;
--- the adapter reports them from its pump. A failure that predated registration
--- is retained and delivered synchronously here so boot ordering cannot lose it.
--- @param fn function Callback with signature fn(exact_error).
--- @return boolean installed True when the handler accepted pending delivery.
--- @return string|nil error_message Protected handler failure detail.
function M.set_async_sink_failure_handler(fn)
	if type(fn) ~= "function" then
		return false, "async sink failure handler must be a function"
	end
	_async_sink_failure_handler = fn
	if _pending_async_sink_failure == nil then return true end

	local pending = _pending_async_sink_failure
	local ok, handler_err = xpcall(fn, debug.traceback, pending)
	if not ok then
		_async_sink_failure_handler_error = tostring(handler_err)
		return false, _async_sink_failure_handler_error
	end
	_pending_async_sink_failure = nil
	_async_sink_failure_handler_error = nil
	return true
end

--- Classifies whether boot owns a complete launcher logger authority. All four
--- values form one trust boundary. `standalone` is a diagnostic for complete
--- absence, not permission to arm the full driver: root boot accepts only
--- `managed`, and fails visibly before input for `standalone` or `invalid`.
--- @param getenv function|nil Injectable environment reader.
--- @return string mode `managed`, `standalone`, or `invalid`.
--- @return string|nil detail Exact missing/unreadable-variable diagnosis.
function M.classify_async_sink_boot_environment(getenv)
	local reader = type(getenv) == "function" and getenv or os.getenv
	local present = 0
	local missing = {}
	for _, name in ipairs(ASYNC_SINK_MANAGED_ENV_KEYS) do
		local ok, value = pcall(reader, name)
		if not ok then
			return "invalid", "managed logger environment read failed for " .. name
		end
		if type(value) == "string" and value ~= "" then
			present = present + 1
		else
			missing[#missing + 1] = name
		end
	end
	if present == 0 then return "standalone" end
	if present == #ASYNC_SINK_MANAGED_ENV_KEYS then return "managed" end
	return "invalid", "managed logger environment is partial; missing "
		.. table.concat(missing, ", ")
end

--- Registers (or clears) a callable test sink that receives every formatted
--- log line as a plain string. Pass nil to remove. Intended for unit tests only.
--- @param fn function|nil One-arity function receiving the line string, or nil to clear.
function M.set_sink(fn)
	_test_sink = (type(fn) == "function") and fn or nil

	-- Installing a sink is a test saying "drive the logger through me", so it is
	-- also the moment this instance takes ownership of the core's single set of
	-- hooks. See claim_core_hooks() for why that is not automatic.
	M.claim_core_hooks()
end

--- Sets the active log level. Messages below this threshold are silently dropped.
--- @param level number|string Numeric constant (M.LEVELS.DEBUG) or name ("DEBUG", …).
function M.set_level(level)
	if type(level) == "number" then
		M.current_level = level
	elseif type(level) == "string" then
		M.current_level = M.LEVELS[level:upper()] or M.LEVELS.WARNING
	end
end

--- Returns true when messages at the given level would be emitted.
--- @param level number Level constant to test.
--- @return boolean
function M.is_enabled(level)
	return level >= M.current_level
end





-- ===================================
-- ===================================
-- ======= 3/ Core Logging API =======
-- ===================================
-- ===================================

-- The five-second suppression window, the streak state and the ring buffer are
-- all the core's now. What stood here was a second implementation of each, kept
-- in step with the AutoHotkey driver by a comment saying so — and the window in
-- particular was a bare literal in SECONDS facing a bare literal in MILLISECONDS,
-- which is indistinguishable from two literals that have already drifted apart.

-- Runtime error-capture state (installed by Section 7). Forward-declared here so
-- _driver_sink() routes every console write through
-- _console_out(), which the print() tee uses to tell the Logger's own output
-- (already written to the file) apart from foreign prints (Hammerspoon error
-- tracebacks, stray print()s) that must be captured into the file too.
local _emitting   = false
local _orig_print = nil

--- Writes one line to the console via the ORIGINAL print, flagging _emitting so
--- the print() tee installed by M.install_runtime_error_capture() skips it (the
--- line is already persisted by _write_to_file). Falls back to the live print
--- before capture is installed.
--- @param line string Fully-formatted console line.
local function _console_out(line)
	_emitting = true
	local p = _orig_print or print
	pcall(p, line)
	_emitting = false
end




-- ==================================
-- ===== 3.1) File Sink Helpers =====
-- ==================================

local function _matches_any(line, patterns)
	for _, p in ipairs(patterns) do
		if line:find(p, 1, true) then return true end
	end
	return false
end

--- Derives the native worker's topical fan-out outside the HID callback.
--- LogTransport calls this only from its TimerScheduler-owned pump.
--- @param line string Canonical formatted log line.
--- @return table names Validated topical filenames selected for this line.
_route_line = function(line)
	local names = {}
	for _, sub in ipairs(SUB_LOG_NAMES) do
		if _matches_any(line, sub.patterns) then names[#names + 1] = sub.name end
	end
	return names
end

--- Builds the HHhMMminSSsNNNms timestamp string matching the AHK driver format.
local function _timestamp()
	local t    = _gettime()
	local sec  = math.floor(t)
	local ms   = math.floor((t - sec) * 1000)
	return os.date("%Y-%m-%d %H:%M:%S", sec) .. string.format(":%03d", ms)
end

--- Returns an open append handle to the current daily log file, re-opening on
--- day rollover or after init_log_path() re-points UNIFIED_LOG_FILE.
local function _ensure_log_file()
	local today = os.date("%Y-%m-%d")
	local previous_date = _last_log_date
	-- Recompute the dated paths when the calendar date changes so midnight
	-- rollovers write to the new day's file rather than reopening yesterday's.
	if _log_dir and _last_log_date ~= today then
		M.UNIFIED_LOG_FILE = _log_dir .. "ErgoptiPlus_" .. today .. ".log"
		M.ERRORS_LOG_FILE  = _log_dir .. "ErgoptiPlus_errors_" .. today .. ".log"
	end
	if _file_handle and _last_log_date == today and _last_log_path == M.UNIFIED_LOG_FILE then
		return _file_handle
	end
	if _file_handle then
		pcall(function() _file_handle:close() end)
		_file_handle = nil
	end
	local ok, fh = pcall(io.open, M.UNIFIED_LOG_FILE, "a")
	if not ok or not fh then return nil end
	_file_handle   = fh
	_last_log_date = today
	_last_log_path = M.UNIFIED_LOG_FILE
	-- Session boundary marker so tailing reveals where HS restarted
	pcall(function()
		fh:write("\n===== " .. _timestamp() .. " — ErgoptiPlus session opened =====\n")
		fh:flush()
	end)
	if previous_date and previous_date ~= today and _log_retention_days then
		_schedule_log_purge(_log_dir, _log_retention_days, false)
	end
	return _file_handle
end

--- Returns the io.open mode for a topical sub-file: "a" when it already carries
--- today's lines, "w" when it must be reset for a new day. Decided once per
--- sub-file per calendar date, then cached in _sub_file_date.
---
--- Applies the same mtime-is-today predicate as the purge pass, but evaluates it
--- BEFORE the logger appends anything. Once the fan-out has written, mtime answers
--- "did this process just log?" rather than "does this file hold only today?" —
--- which is why the purge could never reset an active sub-file.
--- @param path string Absolute sub-file path.
--- @param today string Current date as YYYY-MM-DD.
--- @return string Either "a" or "w".
local function _sub_file_mode(path, today)
	if _sub_file_date[path] == today then return "a" end
	_sub_file_date[path] = today

	local hs_ref = rawget(_G, "hs")
	local fs_ref = (type(hs_ref) == "table") and hs_ref.fs or nil
	if type(fs_ref) ~= "table" or type(fs_ref.attributes) ~= "function" then
		-- Without a filesystem port the age is undecidable. Append rather than
		-- truncate: keeping a stale line is recoverable, deleting today's is not.
		return "a"
	end

	local ok_attr, attrs = pcall(fs_ref.attributes, path)
	if not ok_attr or type(attrs) ~= "table" or not attrs.modification then
		return "a"  -- File absent (nothing to reset) or unreadable — "a" creates it
	end
	return (os.date("%Y-%m-%d", attrs.modification) == today) and "a" or "w"
end

-- DEBUG lines written since the last flush.
local _unflushed_debug = 0

--- Buffered DEBUG lines allowed before the handle is flushed anyway. A COUNT
--- rather than a deadline so this needs no clock read of its own: the exposure
--- is bounded by volume, which is what actually matters — a burst of tracing is
--- exactly when losing the tail would hurt, and an idle driver writes nothing to
--- lose.
local FLUSH_EVERY_N_DEBUG = 40

--- Appends one line to the unified log.
---
--- The flush is LEVEL-AWARE. The default level is DEBUG, and DEBUG lines are
--- emitted from the keystroke path, so flushing every line meant a synchronous
--- fsync inside the eventtap on every key the user pressed — the one place in
--- the driver where blocking I/O is least affordable, since a stalled tap is
--- exactly what macOS disables for being unresponsive.
---
--- Anything at INFO or above still flushes immediately: those are the lines that
--- matter after a crash, and they are rare. DEBUG lines stay in the handle's
--- buffer and are flushed by the next important line or once
--- FLUSH_EVERY_N_DEBUG of them have accumulated, so only a bounded tail of
--- verbose tracing is ever at risk.
--- @param line string The complete formatted line, timestamp included. The core
---   composes the timestamp INTO the line, so this no longer takes the two
---   halves separately and cannot put them back together in the wrong order.
--- @param immediate boolean|nil False to defer the flush; anything else flushes now.
local function _write_to_file(line, immediate)
	local full = line .. "\n"
	local fh = _ensure_log_file()
	if fh then
		pcall(function()
			fh:write(full)
			if immediate == false then
				_unflushed_debug = _unflushed_debug + 1
				if _unflushed_debug >= FLUSH_EVERY_N_DEBUG then
					fh:flush()
					_unflushed_debug = 0
				end
			else
				fh:flush()
				_unflushed_debug = 0
			end
		end)
	end
	-- Fan-out to topical sub-files.
	--
	-- Handles are kept OPEN, exactly like the main one. Opening and closing per
	-- line looked cheap next to "the operations logged" — true of the operations,
	-- and false of a keystroke: the default level is DEBUG and DEBUG lines are
	-- emitted from the keystroke path, so every matching line paid an
	-- open+write+close inside the eventtap callback. That is the same blocking
	-- I/O the main handle's level-aware flush policy exists to avoid, arriving
	-- through the back door.
	--
	-- Lines are still flushed on the same terms as the main handle, so a crash
	-- loses at most the buffered DEBUG tail rather than leaving a stale handle
	-- holding everything.
	local today = os.date("%Y-%m-%d")
	for _, sub in ipairs(SUB_LOG_NAMES) do
		if _matches_any(line, sub.patterns) then
			pcall(function()
				local path = _log_dir .. sub.name
				local mode = _sub_file_mode(path, today)
				local entry = _sub_handles[path]
				-- Re-open when the mode changes: "w" means a new calendar day has
				-- to truncate the file, which an already-open append handle cannot do.
				if entry and entry.mode ~= mode then
					pcall(function() entry.fh:close() end)
					entry = nil
				end
				if not entry then
					local fh = io.open(path, mode)
					if not fh then return end
					entry = { fh = fh, mode = "a" }
					_sub_handles[path] = entry
				end
				entry.fh:write(full)
				if immediate ~= false then entry.fh:flush() end
			end)
		end
	end
end




-- =================================
-- ===== 3.2) Dedup & Dispatch =====
-- =================================

--- The sink the core delivers every accepted line to.
---
--- This is the whole driver half in one function, and the core calls it for
--- suppression summaries on exactly the same terms as for ordinary lines. That
--- deletes a duplicate that used to matter: _flush_dedup_summary wrote the
--- summary to the console, the ring, the file and the errors mirror itself, in
--- its own copy of this logic — and it had already drifted once, silently
--- skipping the test sink, so no assertion could observe suppression at all.
--- @param line string The complete formatted line, timestamp included.
--- @param variant string The core's lowercase variant name ("info", "warn", …).
_driver_sink = function(line, variant)
	if _async_sink_active then
		-- An explicitly installed test sink is the sole synchronous observation
		-- allowed here. Production never registers one.
		if _test_sink then pcall(_test_sink, line, variant) end

		-- The eventtap boundary ends here: enqueue() only appends one immutable
		-- in-memory record. Routing, JSON, UDP, console, notification and every
		-- filesystem operation happen after the native worker's exact ACK.
		local ok, record_or_err, enqueue_err = pcall(LogTransport.enqueue, line, variant)
		if not ok or type(record_or_err) ~= "table" then
			_async_sink_error = tostring(ok and enqueue_err or record_or_err)
			return
		end
		local pending = _pending_error_notification
		if pending then pending.record = record_or_err end
		return
	end

	local level = Core.level_of(variant) or Core.LEVELS.INFO

	-- Routed through _console_out so the print() tee (Section 7) does not
	-- re-capture the Logger's own lines — they are persisted below already.
	_console_out(line)

	-- Forward to the test sink when registered (never in production builds).
	if _test_sink then pcall(_test_sink, line, variant) end

	-- Only the DEBUG-class variants defer their flush; see _write_to_file. Those
	-- are the ones emitted per keystroke, and also the ones whose loss in a crash
	-- costs least.
	_write_to_file(line, level ~= Core.LEVELS.DEBUG)

	-- Dedicated errors-only log (WARNING + ERROR). Separate open/close per write
	-- (like the sub-files) so a crash never leaks a handle. This file stays small
	-- and is the recommended first place to look when something goes wrong,
	-- without drowning in the full daily unified log.
	if level >= Core.LEVELS.WARNING then
		local err_full = line .. "\n"
		pcall(function()
			local f = io.open(M.ERRORS_LOG_FILE, "a")
			if f then
				f:write(err_full)
				f:close()
			end
		end)
	end
end

--- Commits the authenticated native logger transport before input activation.
--- The old Lua purge timer and every open local file handle are settled first,
--- so exactly one runtime owns retention and persistence after this returns.
--- @param scheduler table TimerScheduler adapter used to own the UDP pump.
--- @param transport_overrides table|nil Narrow dependency injection for causal
---   tests (`bootstrap_socket_factory`, endpoint credentials and clock only).
--- @return boolean committed True only when the transport owns socket + timer.
--- @return string|nil error_message Exact fail-fast reason on refusal.
function M.start_async_sink(scheduler, transport_overrides)
	if _async_sink_active then return true end
	if transport_overrides ~= nil and type(transport_overrides) ~= "table" then
		return false, "transport_overrides must be a table when provided"
	end

	local purges_stopped, purge_err = _stop_pending_purge_timers()
	if not purges_stopped then return false, purge_err end

	if _file_handle then
		local ok, closed, close_err = pcall(function() return _file_handle:close() end)
		if not ok or closed ~= true then
			return false, "unified boot log handle refused close: "
				.. tostring(ok and close_err or closed)
		end
		_file_handle = nil
		_last_log_date = nil
		_last_log_path = nil
	end
	for path, entry in pairs(_sub_handles) do
		local ok, closed, close_err = pcall(function() return entry.fh:close() end)
		if not ok or closed ~= true then
			-- The refusing topical handle remains published for an exact retry.
			return false, "topical boot log handle refused close: " .. tostring(path)
				.. " — " .. tostring(ok and close_err or closed)
		end
		_sub_handles[path] = nil
		_sub_file_date[path] = nil
	end
	_unflushed_debug = 0

	local options = {
		scheduler = scheduler,
		log_dir = _log_dir,
		retention_days = _log_retention_days or DEFAULT_LOG_RETENTION_DAYS,
		route_line = _route_line,
		route_overlap_bytes = ROUTE_OVERLAP_BYTES,
		on_delivered = function(record)
			if type(record) ~= "table" or type(record.line) ~= "string" then
				return false, "delivered log record is malformed"
			end
			_console_out(record.line)
			local notification = record.notification
			if type(notification) == "table" and _error_notification_handler then
				local notified, delivered_or_err, notification_err = xpcall(
					_error_notification_handler,
					debug.traceback,
					tostring(notification.module_name),
					tostring(notification.message)
				)
				if not notified or delivered_or_err ~= true then
					local detail = notified and (notification_err or delivered_or_err)
						or delivered_or_err
					return false, "error notification delivery failed: " .. tostring(detail)
				end
			end
			return true
		end,
		on_failed = _on_async_sink_failed,
	}
	-- Production supplies none of these. Tests inject only native boundaries that
	-- cannot exist in the headless Lua process; routing and delivery stay owned by
	-- this module so the behavioural assertions still exercise the real handoff.
	for _, name in ipairs({
		"bootstrap_socket_factory", "bootstrap_timeout_sec", "port", "token",
		"getenv", "clock", "max_batch_records",
	}) do
		if transport_overrides and transport_overrides[name] ~= nil then
			options[name] = transport_overrides[name]
		end
	end
	local ok, committed_or_err, transport_err = pcall(LogTransport.start, options)
	if not ok or committed_or_err ~= true then
		return false, tostring(ok and transport_err or committed_or_err)
	end
	_async_sink_error = nil
	_async_sink_active = true
	return true
end

--- Begins an asynchronous native drain without blocking Hammerspoon's run loop.
--- LogTransport retains its queue, socket and pump until every record has an
--- exact native ACK. A bounded timeout reports failure through on_done but never
--- discards those capabilities inside this module. Root termination owns the
--- non-zero EOF policy because local consumers have already stopped and cannot
--- be rolled back into a live driver.
--- @param on_done function Callback `(drained:boolean, detail:string|nil)`.
--- @return boolean committed True only when exact callback ownership committed.
--- @return string|nil error_message Immediate refusal detail.
function M.begin_async_sink_shutdown(on_done)
	if type(on_done) ~= "function" then return false, "on_done callback is required" end
	if not _async_sink_active then
		local ok, callback_err = xpcall(function() on_done(true, "transport already inactive") end,
			debug.traceback)
		if not ok then
			_async_sink_error = "inactive shutdown callback failed: " .. tostring(callback_err)
			return false, _async_sink_error
		end
		return true
	end
	if type(LogTransport.drain) ~= "function" then
		return false, "log transport has no asynchronous shutdown capability"
	end

	local callback_fired = false
	local function complete(drained, detail)
		if callback_fired then return end
		callback_fired = true
		if drained ~= true then _async_sink_error = tostring(detail or "native log drain failed") end
		local ok, callback_err = xpcall(on_done, debug.traceback, drained == true, detail)
		if not ok then
			_on_async_sink_failed("shutdown callback failed: " .. tostring(callback_err))
		end
	end
	local ok, committed_or_err, begin_err = xpcall(function()
		return LogTransport.drain(complete, ASYNC_SINK_SHUTDOWN_TIMEOUT_SEC)
	end, debug.traceback)
	if not ok or committed_or_err ~= true then
		return false, tostring(ok and begin_err or committed_or_err)
	end
	return true
end

--- Stops the asynchronous logger's owned socket/timer resources.
--- @return boolean settled
function M.stop_async_sink()
	local ok, settled, stop_err = pcall(LogTransport.stop)
	if not ok or settled ~= true then
		_async_sink_error = tostring(ok and stop_err or settled)
		return false
	end
	_async_sink_active = false
	return true
end

--- Exposes transport health without granting callers mutable queue ownership.
function M.async_sink_status()
	local ok, status = pcall(LogTransport.status)
	if not ok or type(status) ~= "table" then
		return { active = _async_sink_active, last_error = _async_sink_error or tostring(status) }
	end
	if _async_sink_error ~= nil and status.last_error == nil then
		status.last_error = _async_sink_error
	end
	status.pending_failure = _pending_async_sink_failure
	status.failure_handler_error = _async_sink_failure_handler_error
	return status
end

--- Points the core's three single-slot hooks at THIS module instance.
---
--- The core is a process singleton and holds exactly one sink, one clock and one
--- timestamp provider, while infra.logger can be instantiated more than once in a
--- single test file — the file takes its own handle, and the module under test
--- pulls another when it loads. Whichever instance ran last owns all three slots,
--- so an instance that does not claim them would install a sink nobody calls and
--- a clock nobody reads: every line would still reach the file and the console
--- exactly as it should, and reach the assertion never.
---
--- The clock is claimed as a CLOSURE over M rather than by value, so replacing
--- Logger.clock_fn afterwards still takes effect — which is the only way a
--- five-second window can be exercised by a suite that runs in milliseconds.
--- Exposed on M rather than kept local so M.set_sink() — which is defined
--- earlier in the file — can reach it. A table field resolves at CALL time; a
--- local declared further down would not be captured at all.
function M.claim_core_hooks()
	Core.set_sink(_driver_sink)
	Core.timestamp_fn = _timestamp
	Core.clock_fn     = function() return M.clock_fn() end
end

M.claim_core_hooks()

-- The core's own severity threshold stays at its floor, permanently. This driver
-- filters in _log against M.current_level, and that field is a public contract:
-- the log-level submenu and several tests ASSIGN it directly rather than calling
-- M.set_level. A second threshold inside the core that such an assignment could
-- not reach would filter differently from the one the menu displays — so there is
-- exactly one filter, and it is the one that was already there.
Core.set_level(Core.LEVELS.DEBUG)

--- Internal dispatcher — filters by level, then hands the line to the core.
--- @param variant_key string Key into VARIANTS (this driver's UPPERCASE spelling).
--- @param module_name string Short identifier of the calling module.
--- @param msg string Message or printf-style format string.
--- @param ... any Optional arguments for string.format.
--- @return boolean emitted True when the line actually reached the sinks; false
---   when it was filtered by level or suppressed by the dedup window. Callers that
---   mirror a line elsewhere (M.error → notification handler) must follow this
---   decision, so a deduped line does not produce a side effect the log suppressed.
_log = function(variant_key, module_name, msg, ...)
	local variant = VARIANTS[variant_key]
	if not variant or variant.level < M.current_level then return false end

	local core_fn = Core[CORE_VARIANT[variant_key]]
	if not core_fn then return false end
	return core_fn(module_name, msg, ...) ~= nil
end





-- ===================================
-- ===================================
-- ======= 4/ Public Variants ========
-- ===================================
-- ===================================

--- Logs a DEBUG message — verbose detail for development and troubleshooting.
--- @param module_name string Short module identifier.
--- @param msg string Message or format string.
--- @param ... any Optional format arguments.
function M.debug(module_name, msg, ...) _log("DEBUG", module_name, msg, ...) end

--- Logs a TRACE message — start of a routine internal operation at DEBUG level.
--- Pair with Logger.done() to close the lifecycle loop.
--- @param module_name string Short module identifier.
--- @param msg string Message or format string.
--- @param ... any Optional format arguments.
function M.trace(module_name, msg, ...) _log("TRACE", module_name, msg, ...) end

--- Logs a DONE message — end of a routine internal operation at DEBUG level.
--- Pair with Logger.trace() that opened the same operation.
--- @param module_name string Short module identifier.
--- @param msg string Message or format string.
--- @param ... any Optional format arguments.
function M.done(module_name, msg, ...) _log("DONE", module_name, msg, ...) end

--- Logs an INFO message — general operational status worth knowing.
--- @param module_name string Short module identifier.
--- @param msg string Message or format string.
--- @param ... any Optional format arguments.
function M.info(module_name, msg, ...) _log("INFO", module_name, msg, ...) end

--- Logs a START message — start of a significant action at INFO level.
--- Always pair with Logger.success(); a START without SUCCESS signals a silent failure.
--- @param module_name string Short module identifier.
--- @param msg string Message or format string.
--- @param ... any Optional format arguments.
function M.start(module_name, msg, ...) _log("START", module_name, msg, ...) end

--- Logs a SUCCESS message — successful completion of a started action at INFO level.
--- Always pair with Logger.start() that opened the same action.
--- @param module_name string Short module identifier.
--- @param msg string Message or format string.
--- @param ... any Optional format arguments.
function M.success(module_name, msg, ...) _log("SUCCESS", module_name, msg, ...) end

--- Logs a WARNING message — unexpected condition; execution continues but must be investigated.
--- @param module_name string Short module identifier.
--- @param msg string Message or format string.
--- @param ... any Optional format arguments.
function M.warn(module_name, msg, ...) _log("WARNING", module_name, msg, ...) end

--- Logs an ERROR message — a failure that requires attention.
--- Also fires the registered notification handler (if any) so errors surface as
--- system notifications in addition to the console log — but ONLY when the line was
--- actually emitted. A line suppressed by the dedup window must not fire a toast the
--- log itself swallowed, otherwise a hot-path error recurring every keystroke buries
--- the user under identical notifications while the log shows a single deduped line.
--- @param module_name string Short module identifier.
--- @param msg string Message or format string.
--- @param ... any Optional format arguments.
function M.error(module_name, msg, ...)
	local ok, base = pcall(tostring, msg)
	local text = ok and base or "???"
	if select("#", ...) > 0 then
		local ok_f, formatted = pcall(string.format, text, ...)
		text = ok_f and formatted or text
	end

	local pending = {
		module_name = tostring(module_name),
		message = text,
		record = nil,
	}
	_pending_error_notification = pending
	local emitted = _log("ERROR", module_name, msg, ...)
	_pending_error_notification = nil
	if emitted and _async_sink_active and type(pending.record) == "table" then
		pending.record.notification = {
			module_name = pending.module_name,
			message = pending.message,
		}
	end
	if emitted and not _async_sink_active and _error_notification_handler then
		local notified, delivered_or_err, notification_err = xpcall(
			_error_notification_handler,
			debug.traceback,
			tostring(module_name),
			text
		)
		if not notified or delivered_or_err ~= true then
			_async_sink_error = "error notification delivery failed: "
				.. tostring(notified and notification_err or delivered_or_err)
		end
	end
end





-- ======================================
-- ======================================
-- ======= 5/ Ring Buffer & Dedup =======
-- ======================================
-- ======================================

-- Every function below delegates to the core. The ring used to be a second
-- 200-entry circular array with its own wrap arithmetic, sitting beside the
-- core's — two implementations of an off-by-one nobody wants to debug twice, and
-- the suppression streak was the same story.
--
-- Both are per PROCESS rather than per require; see the note on `Core` at the top
-- of this file. A test that needs a clean ring or a clean streak asks for one
-- here, rather than getting one as a side effect of a module reload.

--- Returns a snapshot of the ring buffer in chronological order (oldest first).
--- The most recent entry is last. Lets a "Dump recent logs" menu entry or a crash
--- report be built without reading the file back.
--- @return table Flat list of formatted log line strings.
function M.ring_buffer_snapshot() return Core.ring_buffer_snapshot() end

--- Returns how many entries the ring buffer currently holds.
--- @return number
function M.ring_buffer_size() return Core.ring_buffer_size() end

--- Empties the ring buffer.
function M.ring_buffer_clear() Core.ring_buffer_clear() end

--- Forgets the current suppression streak without emitting its summary.
--- A streak carried across a reload would suppress the first line of the new
--- session because it matched the last line of the old one, which is the least
--- useful moment to lose a line.
function M.reset_dedup() Core.reset_dedup() end

--- Reports how many identical lines the open streak has swallowed so far.
--- Exposed so a test can assert that suppression HAPPENED rather than infer it
--- from an absence, which is the shape of a vacuous assertion.
--- @return number
function M.dedup_suppressed_count() return Core.dedup_suppressed_count() end

--- Clock used to measure the dedup window, in seconds.
--- Replaceable so a test can drive the five-second window without sleeping for
--- it: a window measured in seconds cannot otherwise be exercised by a suite that
--- runs in milliseconds. The core reads this field through a closure installed in
--- Section 3.2, so replacing it here still takes effect.
M.clock_fn = _gettime





-- ==================================
-- ==================================
-- ======= 6/ Utility Helpers =======
-- ==================================
-- ==================================

--- Wraps pcall and logs any raised exception at ERROR level.
--- Identical call signature to pcall; return values are forwarded unchanged.
--- @param module_name string Short module identifier used in the error log.
--- @param fn function Function to call inside the protected block.
--- @param ... any Arguments forwarded to fn.
--- @return boolean ok True if fn completed without error.
--- @return any result_or_error Return value from fn, or the error message on failure.
function M.pcall(module_name, fn, ...)
	local results = table.pack(pcall(fn, ...))
	if not results[1] then
		_log("ERROR", module_name, "Exception: %s", tostring(results[2]))
	end
	return table.unpack(results, 1, results.n)
end

--- Wraps a builder function in a pcall and logs any failure at ERROR level.
--- Returns nil on failure so callers can use the result as a truthiness guard.
--- @param module_name string Short module identifier.
--- @param label string Human-readable name of the component being built.
--- @param fn function Builder function to call.
--- @param ctx table Context argument forwarded to fn.
--- @return any|nil The return value of fn, or nil if it threw.
function M.build(module_name, label, fn, ctx)
	local ok, result = pcall(fn, ctx)
	if not ok then
		_log("ERROR", module_name, "Build error for \"%s\": %s", label, tostring(result))
		return nil
	end
	return result
end





-- ===========================================
-- ===========================================
-- ======= 7/ Runtime Error Capture ==========
-- ===========================================
-- ===========================================

-- One-shot guard so the constructors are patched exactly once.
local _capture_installed = false

--- Wraps a timer callback so an uncaught error is logged WITH a traceback
--- instead of vanishing into the Hammerspoon Console. hs.timer ignores callback
--- return values, so discarding them here changes nothing.
---
--- The error goes to the log — including the errors-only sink, since ERROR lines
--- are mirrored there — and NOWHERE else. It deliberately does not reach the crash
--- reporter: a throw inside a timer callback is recoverable BY DEFINITION, the
--- callback is abandoned and the run loop carries on, so the driver has already
--- survived it. The reporter is reserved for genuine uncaught fatals
--- (errors-only-log-sink), and reaching it from here would run the healthcheck's
--- blocking probes and end in a modal dialog that stalls the main thread and its
--- run loop until a human dismisses it — for an error nothing was broken by.
--- Deferring that call by a run loop tick does not help: the freeze comes from the
--- nested modal loop, not from the stack frame it was started on.
--- @param fn function The user callback.
--- @param kind string Timer family label, surfaced in the error line.
--- @return function The guarded callback (or fn unchanged when not a function).
local function _guard_timer_cb(fn, kind)
	if type(fn) ~= "function" then return fn end
	return function(...)
		local ok, err = xpcall(fn, debug.traceback, ...)
		if not ok then
			_log("ERROR", "runtime", "Uncaught error in hs.timer.%s callback: %s", kind, tostring(err))
		end
	end
end

--- Installs process-wide capture so EVERY diagnostic — including errors that
--- Hammerspoon would otherwise only print to its Console — lands in the unified
--- file log. The console is too noisy to read and cannot be exported, so the
--- file must be self-sufficient.
---
--- Two complementary mechanisms:
---   1. hs.timer.{doAfter,new,delayed.new} callbacks run under xpcall; any throw
---      is logged at ERROR with a full traceback. This is the failure class that
---      silently killed predictions (the dangling ngram_predict call) and the
---      boot sequence — a throw inside a timer callback is swallowed whole by
---      Hammerspoon's runloop and never reaches lib.logger.
---   2. print() is teed into the file so foreign output (Hammerspoon's own error
---      reporter, third-party modules) is captured too. The Logger's own console
---      writes go through _console_out and are flagged via _emitting, so they are
---      never double-written.
---
--- Idempotent and best-effort: every patch is guarded so capture can never block
--- boot, and it no-ops cleanly under the headless test harness (no hs.timer).
function M.install_runtime_error_capture()
	if _capture_installed then return end
	_capture_installed = true

	-- 1) Tee print() — captures Hammerspoon's error tracebacks and stray prints.
	if type(_G.print) == "function" then
		_orig_print = _G.print
		_G.print = function(...)
			_orig_print(...)
			-- Skip the Logger's own console writes (already persisted to file).
			if _emitting then return end
			local n = select("#", ...)
			if n == 0 then return end
			local parts = {}
			for i = 1, n do parts[i] = tostring((select(i, ...))) end
			local msg = table.concat(parts, "\t")
			if msg == "" then return end
			-- Persist directly (never via _log) so a traceback is not eaten by the
			-- dedup pass and cannot recurse back through print().
			local stamp = _timestamp()
			for subline in (msg .. "\n"):gmatch("(.-)\n") do
				if subline ~= "" then
					local line = stamp .. " [CONSOLE] [console] " .. subline
					if _async_sink_active then
						local queued, record_or_err, enqueue_err = pcall(
							LogTransport.enqueue, line, "info")
						if not queued or type(record_or_err) ~= "table" then
							_async_sink_error = tostring(queued and enqueue_err or record_or_err)
						end
					else
						pcall(_write_to_file, line)
					end
				end
			end
		end
	end

	-- 2) Guard hs.timer constructors so callback throws are logged, not swallowed.
	local hs_ref = rawget(_G, "hs")
	if type(hs_ref) == "table" and type(hs_ref.timer) == "table" then
		local timer = hs_ref.timer
		if type(timer.doAfter) == "function" then
			local orig = timer.doAfter
			timer.doAfter = function(delay, fn, ...) return orig(delay, _guard_timer_cb(fn, "doAfter"), ...) end
		end
		if type(timer.new) == "function" then
			local orig = timer.new
			timer.new = function(interval, fn, ...) return orig(interval, _guard_timer_cb(fn, "new"), ...) end
		end
		if type(timer.doEvery) == "function" then
			local orig = timer.doEvery
			timer.doEvery = function(interval, fn, ...) return orig(interval, _guard_timer_cb(fn, "doEvery"), ...) end
		end
		if type(timer.delayed) == "table" and type(timer.delayed.new) == "function" then
			local orig = timer.delayed.new
			timer.delayed.new = function(delay, fn, ...) return orig(delay, _guard_timer_cb(fn, "delayed"), ...) end
		end
	end

	_log("INFO", "logger", "Runtime error capture installed (hs.timer guards + console tee).")
end

return M
