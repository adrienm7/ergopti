--- infra/logger.lua

--- ==============================================================================
--- MODULE: Logger
--- DESCRIPTION:
--- Centralized, level-aware logging system for the entire Hammerspoon runtime.
--- Provides consistent formatting, level filtering, colored console output, and
--- a unified rotating file sink so every subsystem's output lands in one place.
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
--- 6. Unified rotating file sink: one file per calendar day under <config>/logs/,
---    named ErgoptiPlus_YYYY-MM-DD.log (mirrors the AHK driver naming convention).
---    Files older than max_age_days are purged automatically on init.
--- 7. Topical sub-files: lines are fan-out to per-subsystem logs (llm, karabiner…)
---    based on module tag matching, giving focused tail targets per feature area.
--- 8. Timestamp format: HHhMMminSSsNNNms — matches the AHK driver exactly so both
---    log files look identical when tailed side by side.
--- 9. Errors-only sink: WARNING and ERROR lines are also written to
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

--- Numeric severity levels used for filtering.
--- The spacing is spec § 4's, shared with the AutoHotkey driver's LOGGER_SEVERITY
--- and the shared Lua core. It used to be 1/2/3/4 here, which meant a level
--- NUMBER meant two different things depending on which driver read it — and
--- made the shared core impossible to adopt without silently changing what every
--- threshold filtered. The gaps also leave room for a level between two existing
--- ones without renumbering anything.
M.LEVELS = {
	DEBUG   = 10,
	INFO    = 20,
	WARNING = 30,
	ERROR   = 40,
}

-- Full variant table: each entry drives its label, color, and severity level.
--
-- Two lifecycle axes. Each axis shares ONE level so a threshold can never emit
-- half a pair: a TRACE with no DONE, or a START with no SUCCESS, is how a silent
-- failure looks in the log, and splitting an axis would manufacture one on every
-- run.
--   DEBUG axis (level 10): TRACE → start of a routine internal op  |  DONE → end
--   INFO  axis (level 20): START → start of a significant action   |  SUCCESS → end
--
local VARIANTS = {
	-- ── Debug axis ──────────────────────────────────────────────────────────
	DEBUG   = { level = M.LEVELS.DEBUG,   label = "DEBUG"   },
	TRACE   = { level = M.LEVELS.DEBUG,   label = "TRACE"   },
	DONE    = { level = M.LEVELS.DEBUG,   label = "DONE"    },
	-- ── Info axis ───────────────────────────────────────────────────────────
	INFO    = { level = M.LEVELS.INFO,    label = "INFO"    },
	START   = { level = M.LEVELS.INFO,    label = "START"   },
	SUCCESS = { level = M.LEVELS.INFO,    label = "SUCCESS" },
	-- ── Warning / Error ─────────────────────────────────────────────────────
	WARNING = { level = M.LEVELS.WARNING, label = "WARNING" },
	ERROR   = { level = M.LEVELS.ERROR,   label = "ERROR"   },
}

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

-- Forward declaration — implementation is in Section 3.2. Declared here for the
-- same reason as the handles above: init_log_path() and _purge_old_logs() are
-- defined before it and must reach the real dispatcher, not a nil global.
local _log

--- Configures the log file path under <config_dir>/hammerspoon/logs/ with
--- daily rotation (ErgoptiPlus_YYYY-MM-DD.log) and purges files older than
--- max_age_days. Best-effort: any I/O error is swallowed so a permission
--- issue cannot block init.
--- @param config_dir string Absolute path to the user config directory (trailing slash optional).
--- @param max_age_days integer Days to keep before purging (default 14).
function M.init_log_path(config_dir, max_age_days)
	max_age_days = max_age_days or 14
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
	local hs_ref = rawget(_G, "hs")
	if hs_ref and hs_ref.timer and type(hs_ref.timer.doAfter) == "function" then
		hs_ref.timer.doAfter(LOG_PURGE_DELAY_SEC, function()
			pcall(M._purge_old_logs, log_dir, max_age_days)
		end)
	else
		-- Headless / no timer (unit tests): run inline so behaviour is unchanged.
		pcall(M._purge_old_logs, log_dir, max_age_days)
	end
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
				os.remove(log_dir .. name)
				removed = removed + 1
			end
		elseif is_sub_file[name] then
			local ok_attr, attrs = pcall(fs_ref.attributes, log_dir .. name)
			if ok_attr and type(attrs) == "table" and attrs.modification
				and os.date("%Y-%m-%d", attrs.modification) ~= today then
				os.remove(log_dir .. name)
				removed = removed + 1
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

--- Registers (or clears) a callable test sink that receives every formatted
--- log line as a plain string. Pass nil to remove. Intended for unit tests only.
--- @param fn function|nil One-arity function receiving the line string, or nil to clear.
function M.set_sink(fn)
	_test_sink = (type(fn) == "function") and fn or nil
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

-- Window during which a repeated identical line is suppressed. Named rather than
-- inlined because the AHK driver holds the same duration in MILLISECONDS, and two
-- bare literals in two units, each with a comment claiming to match the other,
-- are indistinguishable from two literals that have drifted apart.
-- Single source: _shared/modules/timings/constants.toml [logger] dedup_window_ms.
local DEDUP_WINDOW_SEC = 5

-- Deduplication state: suppresses consecutive identical log lines to prevent spam.
-- `time` stamps the start of the current streak so a recurring line re-surfaces
-- after the window instead of being silenced forever (matches the AHK driver).
local _dedup = { line = nil, count = 0, variant_key = nil, time = 0 }

-- Forward declaration — implementation is in Section 5 (ring buffer).
-- Must be declared here so _log() captures the variable by reference.
local _push_ring

-- Runtime error-capture state (installed by Section 7). Forward-declared here so
-- _log() and _flush_dedup_summary() route their console writes through
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
	return _file_handle
end

--- Appends a fully-formatted line to the main log and any matching sub-files.
--- All writes are line-flushed so `tail -f` sees output in real time and an
--- unexpected HS crash does not lose buffered entries. Failures are silent.
--- @param stamp string Pre-built timestamp string.
--- @param line string The line to write (without timestamp).
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
--- @param stamp string Formatted timestamp.
--- @param line string The already-composed log line.
--- @param immediate boolean|nil False to defer the flush; anything else flushes now.
local function _write_to_file(stamp, line, immediate)
	local full = stamp .. " " .. line .. "\n"
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

--- Emits a count summary using the same variant as the suppressed messages, then resets.
local function _flush_dedup_summary()
	if _dedup.count == 0 then return end
	local variant = VARIANTS[_dedup.variant_key] or VARIANTS["INFO"]
	local word    = _dedup.count == 1 and "line" or "lines"
	local summary = string.format("[%s] [logger] \u{2191} %d identical %s suppressed",
		variant.label, _dedup.count, word)
	_console_out(summary)
	local stamp = _timestamp()
	-- Push to ring buffer before writing so the snapshot reflects dedup summaries
	_push_ring(stamp .. " " .. summary)

	-- The summary must take the SAME sinks as a normal line. It did not reach the
	-- test sink, which meant no test could observe suppression at all: the count
	-- was written to console, ring and file and was invisible to every assertion.
	-- The shared core delivers its summary through the sink, so this was also a
	-- difference that would have surfaced as a behaviour change on adoption.
	local sink_variant = _dedup.variant_key == "WARNING" and "warn"
		or string.lower(_dedup.variant_key or "info")
	if _test_sink then pcall(_test_sink, stamp .. " " .. summary, sink_variant) end

	_write_to_file(stamp, summary)
	-- Mirror suppression summary to the errors-only log when the suppressed
	-- messages were WARNING or ERROR; without this the errors-only file only
	-- shows the first occurrence and silently omits the repeat count.
	if variant.level >= M.LEVELS.WARNING then
		local err_full = stamp .. " " .. summary .. "\n"
		pcall(function()
			local f = io.open(M.ERRORS_LOG_FILE, "a")
			if f then
				f:write(err_full)
				f:close()
			end
		end)
	end
	_dedup.count       = 0
	_dedup.line        = nil
	_dedup.variant_key = nil
end

--- Internal dispatcher — formats and outputs one log entry.
--- @param variant_key string Key into VARIANTS.
--- @param module_name string Short identifier of the calling module.
--- @param msg string Message or printf-style format string.
--- @param ... any Optional arguments for string.format.
--- @return boolean emitted True when the line was actually written to the sinks;
---   false when it was filtered by level or suppressed by the dedup window. Callers
---   that mirror a line elsewhere (M.error → notification handler) must follow this
---   decision so a deduped line does not produce a side effect the log itself suppressed.
_log = function(variant_key, module_name, msg, ...)
	local variant = VARIANTS[variant_key]
	if not variant or variant.level < M.current_level then return false end

	local ok, base = pcall(tostring, msg)
	local text = ok and base or "???"
	if select("#", ...) > 0 then
		local ok_f, formatted = pcall(string.format, text, ...)
		text = ok_f and formatted or (text .. " [format error]")
	end

	-- Canonical line format (no indent) shared with the AHK driver, the shared
	-- logger core, and the Linux daemon: "[LEVEL] [module] body". The timestamp
	-- prefix is added by the console/file sinks below.
	local line = string.format("[%s] [%s] %s", variant.label, tostring(module_name), text)

	-- Deduplication: suppress repeated identical lines within a 5 s window so a
	-- recurring line is de-bounced rather than permanently silenced — a streak that
	-- outlives the window re-surfaces. The window matches the AHK driver so both
	-- drivers dedup identically.
	local _now = M.clock_fn()
	if line == _dedup.line and (_now - _dedup.time) < DEDUP_WINDOW_SEC then
		_dedup.count = _dedup.count + 1
		return false
	end
	_flush_dedup_summary()
	_dedup.line        = line
	_dedup.variant_key = variant_key
	_dedup.time        = _now

	local stamp = _timestamp()

	-- Console output: plain print (colors removed — hs.styledtext/console no longer a dependency).
	-- Routed through _console_out so the print() tee (Section 7) does not re-capture
	-- the Logger's own lines — they are already persisted by _write_to_file below.
	local console_line = stamp .. " " .. line
	_console_out(console_line)

	-- Push to the in-memory ring buffer so ring_buffer_snapshot() is always
	-- current without requiring a file read.
	_push_ring(console_line)

	-- Forward to the test sink when registered (never in production builds).
	-- Map "WARNING" to "warn" to match the lowercase short-name convention used
	-- by the shared logger, so test assertions like `if variant == "warn"` work.
	local sink_variant = variant_key == "WARNING" and "warn" or string.lower(variant_key)
	if _test_sink then pcall(_test_sink, console_line, sink_variant) end

	-- Only the DEBUG-class variants defer their flush; see _write_to_file. These
	-- are the ones emitted per keystroke, and they are also the ones whose loss
	-- in a crash costs least.
	_write_to_file(stamp, line, variant.level ~= M.LEVELS.DEBUG)

	-- Dedicated errors-only log (WARNING + ERROR). Separate open/close per
	-- write (like sub-files) so a crash never leaks a handle. This file stays
	-- small and is the recommended first place to look when something goes
	-- wrong without drowning in the full daily unified log.
	if variant.level >= M.LEVELS.WARNING then
		local err_full = stamp .. " " .. line .. "\n"
		pcall(function()
			local f = io.open(M.ERRORS_LOG_FILE, "a")
			if f then
				f:write(err_full)
				f:close()
			end
		end)
	end

	return true
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
	local emitted = _log("ERROR", module_name, msg, ...)
	if emitted and _error_notification_handler then
		local ok, base = pcall(tostring, msg)
		local text = ok and base or "???"
		if select("#", ...) > 0 then
			local ok_f, formatted = pcall(string.format, text, ...)
			text = ok_f and formatted or text
		end
		pcall(_error_notification_handler, tostring(module_name), text)
	end
end




-- ====================================
--- ====================================
-- ======= 5/ In-memory Ring Buffer ===
--- ====================================
-- ====================================

-- Fixed-capacity circular array — 200 entries matching the AHK driver and the
-- shared SPEC §5. Each slot stores the complete formatted line (post-substitution,
-- with timestamp). On overflow the oldest slot is silently overwritten (O(1)).
local RING_BUFFER_SIZE = 200
local _ring_buffer     = {}
local _ring_cursor     = 0

--- Appends a fully-formatted line to the in-memory ring buffer.
--- Called from _log() after every emitted line so the buffer always mirrors
--- the most recent RING_BUFFER_SIZE entries of the main log file.
--- @param line string The complete formatted log line (timestamp + level + tag + body).
_push_ring = function(line)
	if #_ring_buffer < RING_BUFFER_SIZE then
		_ring_buffer[#_ring_buffer + 1] = line
		_ring_cursor = #_ring_buffer
	else
		_ring_cursor = (_ring_cursor % RING_BUFFER_SIZE) + 1
		_ring_buffer[_ring_cursor] = line
	end
end

--- Returns a snapshot of the ring buffer in chronological order (oldest first).
--- The most recent entry is last. Useful for a "Dump recent logs" menu entry
--- without requiring a file read.
--- @return table Flat list of formatted log line strings.
function M.ring_buffer_snapshot()
	if #_ring_buffer == 0 then return {} end
	local snapshot = {}
	if #_ring_buffer < RING_BUFFER_SIZE then
		-- Buffer not yet full — entries are already in chronological order.
		for i = 1, #_ring_buffer do
			snapshot[#snapshot + 1] = _ring_buffer[i]
		end
		return snapshot
	end
	-- Buffer is full and wrapped — read from cursor+1 (oldest) to cursor (newest).
	for i = 1, RING_BUFFER_SIZE do
		local idx = (_ring_cursor + i - 1) % RING_BUFFER_SIZE + 1
		snapshot[#snapshot + 1] = _ring_buffer[idx]
	end
	return snapshot
end

--- Returns how many entries the ring buffer currently holds.
--- @return number
function M.ring_buffer_size()
	return #_ring_buffer
end

--- Empties the ring buffer.
--- Resets the cursor as well as the contents: leaving the cursor where it was
--- would make the next snapshot after a wrap read from a slot that no longer
--- corresponds to the oldest entry, so the buffer would come back shuffled.
function M.ring_buffer_clear()
	_ring_buffer = {}
	_ring_cursor = 0
end

--- Forgets the current suppression streak without emitting its summary.
--- Mirrors the shared core, which is what this driver is being migrated onto.
--- A streak carried across a reload would suppress the first line of the new
--- session because it matched the last line of the old one — the least useful
--- moment to lose a line.
function M.reset_dedup()
	_dedup.line        = nil
	_dedup.count       = 0
	_dedup.variant_key = nil
	_dedup.time        = 0
end

--- Reports how many identical lines the open streak has swallowed so far.
--- Exposed so a test can assert that suppression HAPPENED rather than infer it
--- from an absence, which is the shape of a vacuous assertion.
--- @return number
function M.dedup_suppressed_count()
	return _dedup.count
end

--- Clock used to measure the dedup window, in seconds.
--- Replaceable so a test can drive the five-second window without sleeping for
--- it: a window measured in seconds cannot otherwise be exercised by a suite
--- that runs in milliseconds.
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
					pcall(_write_to_file, stamp, "[CONSOLE] [console] " .. subline)
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
