--- lib/logger.lua

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
--- 3. Colored Output: Each variant has a distinct console color — errors in red,
---    warnings in orange, successes in green, debug in gray, etc.
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
--- ==============================================================================

local M = {}
local hs = hs

-- socket.gettime() gives sub-second precision for the millisecond component.
-- Loaded via pcall so headless unit tests that lack the hs sandbox still work.
local _ok_socket, _socket = pcall(require, "socket")
local _gettime = (_ok_socket and _socket and _socket.gettime) or os.time

-- Main unified log file. Set to a safe early-boot fallback; overridden by
-- M.init_log_path() once the user config directory is known.
M.UNIFIED_LOG_FILE = "/tmp/ErgoptiPlus_boot.log"

-- Log directory resolved after M.init_log_path(); used by sub-file fan-out.
local _log_dir = "/tmp/"

-- Topical sub-files: lines whose rendered "[tag]" matches any pattern are
-- fan-out here in addition to the main unified file. Sub-files are ephemeral
-- (today only) — they are a filtered view of the main log, not an archive.
-- Paths are resolved at runtime relative to _log_dir (set by init_log_path).
-- Declared up here (rather than alongside the file-sink state further down)
-- because init_log_path iterates this list to purge stale sub-files, and a
-- forward reference would resolve to nil at call time.
local SUB_LOG_NAMES = {
	-- MLX inference server: startup, model loads, per-token latency
	{ name = "ErgoptiPlus_mlx.log",        patterns = { "[mlx",        "[llm.api_mlx]",     "MLX-",        "[mlx_deps]"    } },
	-- Ollama daemon: startup, model pulls, inference calls
	{ name = "ErgoptiPlus_ollama.log",      patterns = { "[ollama",     "[llm.api_ollama]",  "[ollama_deps]"                } },
	-- LLM bridge: prompt dispatch, temperature, model switching, warmup
	{ name = "ErgoptiPlus_llm.log",         patterns = { "[llm.",       "[menu_llm",         "[keymap.llm", "WARMUP",  "[TOGGLE]" } },
	-- Hotstrings & keymap: registry, dynamic expansions, personal shortcuts
	{ name = "ErgoptiPlus_hotstrings.log",  patterns = { "[keymap.",    "[dynamic_hotstring", "[personal_info]", "[toml_reader]", "hotstring" } },
	-- Raw keystroke capture and n-gram analysis
	{ name = "ErgoptiPlus_keylogger.log",   patterns = { "[keylogger"                                                       } },
	-- Karabiner-Elements config generation and deployment
	{ name = "ErgoptiPlus_karabiner.log",   patterns = { "[karabiner"                                                       } },
	-- Touchpad & mouse gesture recognition
	{ name = "ErgoptiPlus_gestures.log",    patterns = { "[gestures"                                                        } },
	-- Menubar, tray, modal dialogs, app picker, UI builders
	{ name = "ErgoptiPlus_menu.log",        patterns = { "[menu]",      "[menu_",            "[builder]",   "[ui_builder]", "[app_picker]", "[download_window]" } },
	-- Notification routing and system alerts
	{ name = "ErgoptiPlus_notify.log",      patterns = { "[notify",     "[notifications"                                    } },
	-- Boot sequence, path resolution, config loading
	{ name = "ErgoptiPlus_boot.log",        patterns = { "[init]",      "[menu_paths]",      "[paths]",     "[config"       } },
}




-- ====================================
--- ====================================
-- ======= 1/ Level Definitions =======
--- ====================================
-- ====================================

--- Numeric severity levels used for filtering.
M.LEVELS = {
	DEBUG   = 1,
	INFO    = 2,
	WARNING = 3,
	ERROR   = 4,
}

-- Full variant table: each entry drives its label, color, and severity level.
--
-- Two lifecycle axes:
--   DEBUG axis (level 1): TRACE → start of a routine internal op  |  DONE → end
--   INFO  axis (level 2): START → start of a significant action   |  SUCCESS → end
--
local VARIANTS = {
	-- ── Debug axis ──────────────────────────────────────────────────────────
	DEBUG   = { level = 1, label = "DEBUG",   color = { white = 0.65, alpha = 1.0 } },
	TRACE   = { level = 1, label = "TRACE",   color = { red = 0.20, green = 0.55, blue = 0.75, alpha = 1.0 } },
	DONE    = { level = 1, label = "DONE",    color = { red = 0.10, green = 0.50, blue = 0.18, alpha = 1.0 } },
	-- ── Info axis ───────────────────────────────────────────────────────────
	INFO    = { level = 2, label = "INFO",    color = { white = 0.20, alpha = 1.0 } },
	START   = { level = 2, label = "START",   color = { red = 0.40, green = 0.80, blue = 1.00, alpha = 1.0 } },
	SUCCESS = { level = 2, label = "SUCCESS", color = { red = 0.15, green = 0.65, blue = 0.22, alpha = 1.0 } },
	-- ── Warning / Error ─────────────────────────────────────────────────────
	WARNING = { level = 3, label = "WARNING", color = { red = 1.00, green = 0.60, blue = 0.00, alpha = 1.0 } },
	ERROR   = { level = 4, label = "ERROR",   color = { red = 1.00, green = 0.20, blue = 0.20, alpha = 1.0 } },
}

--- Current active level — only messages at or above this level are emitted.
M.current_level = M.LEVELS.WARNING

-- Optional hook set by the bootstrapper after all modules are loaded.
-- Called with (module_name, formatted_message) on every Logger.error call.
local _error_notification_handler = nil




-- =======================================
--- =======================================
-- ======= 2/ Public Configuration =======
--- =======================================
-- =======================================

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
	pcall(hs.execute, string.format("mkdir -p %q", log_dir))
	_log_dir = log_dir

	-- Close any handle open on the old path so the next write re-opens cleanly
	if _file_handle then
		pcall(function() _file_handle:close() end)
		_file_handle   = nil
		_last_log_date = nil
		_last_log_path = nil
	end

	M.UNIFIED_LOG_FILE = log_dir .. "ErgoptiPlus_" .. os.date("%Y-%m-%d") .. ".log"

	-- Purge main log files older than max_age_days by comparing the date in the
	-- filename (YYYY-MM-DD) rather than mtime, so moved/copied files age correctly.
	pcall(hs.execute, string.format(
		"find %q -name 'ErgoptiPlus_*.log' -type f | while read f; do"
		.. " d=$(basename \"$f\" .log | sed 's/ErgoptiPlus_//'); "
		.. " [ \"$(date -j -f '%%Y-%%m-%%d' \"$d\" '+%%s' 2>/dev/null)\" -lt"
		.. " \"$(date -j -v-%dd '+%%s' 2>/dev/null)\" ] && rm -f \"$f\"; "
		.. "done 2>/dev/null",
		log_dir, max_age_days))

	-- Sub-files are ephemeral (today only). Delete any that belong to a previous
	-- day — they are a filtered view of the main log, not an independent archive.
	local today = os.date("%Y-%m-%d")
	for _, sub in ipairs(SUB_LOG_NAMES) do
		local sub_path = log_dir .. sub.name
		-- Read the file's last-modified date via stat; delete if it differs from today
		pcall(function()
			local stat_out = hs.execute(string.format(
				"stat -f '%%Sm' -t '%%Y-%%m-%%d' %q 2>/dev/null", sub_path))
			if stat_out then
				local file_date = stat_out:match("^(%d%d%d%d%-%d%d%-%d%d)")
				if file_date and file_date ~= today then
					os.remove(sub_path)
				end
			end
		end)
	end
end

--- Registers a callback invoked on every Logger.error call to surface errors as
--- system notifications. Set once from init.lua after all modules are loaded.
--- @param fn function|nil Callback with signature fn(module_name, message).
function M.set_error_notification_handler(fn)
	_error_notification_handler = (type(fn) == "function") and fn or nil
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
--- ===================================
-- ======= 3/ Core Logging API =======
--- ===================================
-- ===================================

-- Deduplication state: suppresses consecutive identical log lines to prevent spam.
local _dedup = { line = nil, count = 0, variant_key = nil }


--- ==================================
-- ===== 3.1) File Sink Helpers =====
--- ==================================

-- File sink state — handle kept open for the life of the HS process to avoid
-- open/close overhead. _last_log_date detects day rollovers; _last_log_path
-- detects init_log_path() re-points after early-boot.
local _file_handle    = nil
local _last_log_date  = nil
local _last_log_path  = nil

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
local function _write_to_file(stamp, line)
	local full = stamp .. " " .. line .. "\n"
	local fh = _ensure_log_file()
	if fh then
		pcall(function()
			fh:write(full)
			fh:flush()
		end)
	end
	-- Fan-out to topical sub-files. Each is opened/closed per write so a crash
	-- never leaves a stale handle. Cost is negligible vs. the operations logged.
	for _, sub in ipairs(SUB_LOG_NAMES) do
		if _matches_any(line, sub.patterns) then
			pcall(function()
				local f = io.open(_log_dir .. sub.name, "a")
				if f then
					f:write(full)
					f:close()
				end
			end)
		end
	end
end


--- =================================
-- ===== 3.2) Dedup & Dispatch =====
--- =================================

--- Emits a count summary using the same variant as the suppressed messages, then resets.
local function _flush_dedup_summary()
	if _dedup.count == 0 then return end
	local variant = VARIANTS[_dedup.variant_key] or VARIANTS["INFO"]
	local word    = _dedup.count == 1 and "line" or "lines"
	local indent  = (variant.level == 1) and string.rep(" ", 10) or ""
	local summary = string.format("[%s] [logger] %s\u{2191} %d identical %s suppressed",
		variant.label, indent, _dedup.count, word)
	if hs and hs.styledtext and hs.console and hs.console.printStyledtext then
		pcall(hs.console.printStyledtext, hs.styledtext.new(summary, { color = variant.color }))
	else
		print(summary)
	end
	local stamp = _timestamp()
	_write_to_file(stamp, summary)
	_dedup.count       = 0
	_dedup.line        = nil
	_dedup.variant_key = nil
end

--- Internal dispatcher — formats and outputs one log entry.
--- @param variant_key string Key into VARIANTS.
--- @param module_name string Short identifier of the calling module.
--- @param msg string Message or printf-style format string.
--- @param ... any Optional arguments for string.format.
local function _log(variant_key, module_name, msg, ...)
	local variant = VARIANTS[variant_key]
	if not variant or variant.level < M.current_level then return end

	local ok, base = pcall(tostring, msg)
	local text = ok and base or "???"
	if select("#", ...) > 0 then
		local ok_f, formatted = pcall(string.format, text, ...)
		text = ok_f and formatted or (text .. " [format error]")
	end

	-- DEBUG-axis variants are indented so they visually nest under INFO-axis events
	local indent = (variant.level == 1) and string.rep(" ", 10) or ""
	local line   = string.format("%s[%s] [%s] %s", indent, variant.label, tostring(module_name), text)

	-- Deduplication: suppress repeated identical lines
	if line == _dedup.line then
		_dedup.count = _dedup.count + 1
		return
	end
	_flush_dedup_summary()
	_dedup.line        = line
	_dedup.variant_key = variant_key

	local stamp = _timestamp()

	-- Console output: styled (colors) when hs is available, plain print otherwise
	local console_line = stamp .. " " .. line
	if hs and hs.styledtext and hs.console and hs.console.printStyledtext then
		pcall(hs.console.printStyledtext, hs.styledtext.new(console_line, { color = variant.color }))
	else
		print(console_line)
	end

	-- Push to the in-memory ring buffer so ring_buffer_snapshot() is always
	-- current without requiring a file read.
	_push_ring(console_line)

	_write_to_file(stamp, line)
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
--- system notifications in addition to the console log.
--- @param module_name string Short module identifier.
--- @param msg string Message or format string.
--- @param ... any Optional format arguments.
function M.error(module_name, msg, ...)
	_log("ERROR", module_name, msg, ...)
	if _error_notification_handler then
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
local function _push_ring(line)
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




-- ==================================
--- ==================================
-- ======= 6/ Utility Helpers =======
--- ==================================
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

return M
