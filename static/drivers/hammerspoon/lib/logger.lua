--- lib/logger.lua

--- ==============================================================================
--- MODULE: Logger
--- DESCRIPTION:
--- Centralized, level-aware logging system for the entire Hammerspoon runtime.
--- Provides consistent formatting, level filtering, and colored console output
--- so each log type is immediately recognizable at a glance.
---
--- FEATURES & RATIONALE:
--- 1. Level Filtering: Avoids console noise in production while preserving full
---    detail in development — just lower the level once and all modules comply.
--- 2. Module Tagging: Every call includes a short module identifier so log triage
---    never requires grepping the source.
--- 3. Colored Output: Each variant has a distinct console color — errors in red,
---    warnings in orange, successes in green, debug in gray, etc.
--- 4. Two-axis Lifecycle Logs:
---    - DEBUG axis: Logger.trace (start) / Logger.done (end) — fine-grained internal ops
---    - INFO  axis: Logger.start (start) / Logger.success (end) — important operations
---    Seeing a START without a following SUCCESS points to a silent failure.
--- 5. Deduplication: consecutive identical lines are suppressed automatically;
---    a count summary is printed when the run breaks, using the same color/level.
--- 6. Unified file sink: every log line is also appended to /tmp/ergopti.log so
---    HS, MLX server output, Ollama server output and any other subsystem land
---    in a single rotating file the user can tail. The file is truncated
---    automatically on the first log of a new day so it never grows unbounded.
--- ==============================================================================

local M = {}
local hs = hs

-- Single rotating file for the whole stack. MLX / Ollama subprocesses append
-- here too via shell redirection (see models_manager_mlx.lua / api_ollama.lua).
M.UNIFIED_LOG_FILE = "/tmp/ergopti.log"




-- ====================================
-- ====================================
-- ======= 1/ Level Definitions =======
-- ====================================
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
--   DEBUG axis (level 1): TRACE → start of a routine internal op  |  DONE → its completion
--   INFO  axis (level 2): START → start of a significant action   |  SUCCESS → its completion
--
local VARIANTS = {
	-- ── Debug axis ────────────────────────────────────────────────────────────
	DEBUG   = { level = 1, label = "DEBUG",   color = { white = 0.65, alpha = 1.0 } },
	TRACE   = { level = 1, label = "TRACE",   color = { red = 0.20, green = 0.55, blue = 0.75, alpha = 1.0 } },
	DONE    = { level = 1, label = "DONE",    color = { red = 0.10, green = 0.50, blue = 0.18, alpha = 1.0 } },
	-- ── Info axis ─────────────────────────────────────────────────────────────
	INFO    = { level = 2, label = "INFO",    color = { white = 0.20,  alpha = 1.0 } },
	START   = { level = 2, label = "START",   color = { red = 0.40, green = 0.80, blue = 1.00, alpha = 1.0 } },
	SUCCESS = { level = 2, label = "SUCCESS", color = { red = 0.15, green = 0.65, blue = 0.22, alpha = 1.0 } },
	-- ── Warning / Error ───────────────────────────────────────────────────────
	WARNING = { level = 3, label = "WARNING", color = { red = 1.00, green = 0.60, blue = 0.00, alpha = 1.0 } },
	ERROR   = { level = 4, label = "ERROR",   color = { red = 1.00, green = 0.20, blue = 0.20, alpha = 1.0 } },
}

--- Current active level — only messages at or above this level are printed.
M.current_level = M.LEVELS.WARNING

-- Optional hook set by the bootstrapper (init.lua) after all modules are loaded.
-- Called with (module_name, formatted_message) on every Logger.error invocation.
-- Kept nil by default so the logger has zero dependency on the notifications module.
local _error_notification_handler = nil




-- =======================================
-- =======================================
-- ======= 2/ Public Configuration =======
-- =======================================
-- =======================================

--- Registers a callback invoked on every Logger.error call to surface errors as
--- system notifications. Set once from init.lua after all modules are loaded so the
--- logger itself stays free of any dependency on the notifications module.
--- @param fn function|nil Callback with signature fn(module_name, message).
function M.set_error_notification_handler(fn)
	_error_notification_handler = (type(fn) == "function") and fn or nil
end

--- Sets the active log level. Messages below this threshold are silently dropped.
--- @param level number|string Numeric constant (M.LEVELS.DEBUG) or name ("DEBUG", "INFO", …).
function M.set_level(level)
	if type(level) == "number" then
		M.current_level = level
	elseif type(level) == "string" then
		M.current_level = M.LEVELS[level:upper()] or M.LEVELS.WARNING
	end
end

--- Returns true when messages at the given level would be printed.
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

-- Deduplication state: suppresses consecutive identical log lines to prevent spam.
-- Stores the variant so the summary line uses the same color/label as the suppressed messages.
local _dedup = { line = nil, count = 0, variant_key = nil }




-- ===============================================
-- ===============================================
-- ===== 3.1) Unified File Sink Helpers ==========
-- ===============================================

-- File sink state — opened lazily on first write, kept open for the life of
-- the Hammerspoon process to avoid open/close overhead on every log line.
-- _last_log_date carries the YYYY-MM-DD of the last write so we can detect a
-- day rollover and truncate the file to keep it bounded to one day at a time.
local _file_handle    = nil
local _last_log_date  = nil

--- Returns an open file handle to the unified log file, ready for append. On
--- the very first call of a new calendar day, the file is truncated so daily
--- rotation happens transparently without any external rotation daemon. Also
--- handles the cold-start case: if Hammerspoon starts up and finds an
--- existing log file from a previous day, it gets truncated before the first
--- new line is written.
--- @return file*|nil The open handle, or nil if the file could not be opened.
local function _ensure_log_file()
	local today = os.date("%Y-%m-%d")

	-- Hot path: handle still valid for the same calendar day
	if _file_handle and _last_log_date == today then
		return _file_handle
	end

	-- Either first call of the session or the day just rolled over
	if _file_handle then
		pcall(function() _file_handle:close() end)
		_file_handle = nil
	end

	local should_truncate = true
	if _last_log_date == nil then
		-- First write this session: keep yesterday's log only if its mtime
		-- is from today (e.g. Hammerspoon was reloaded mid-day)
		local attrs = (hs and hs.fs and hs.fs.attributes) and hs.fs.attributes(M.UNIFIED_LOG_FILE) or nil
		if attrs and attrs.modification then
			local file_date = os.date("%Y-%m-%d", attrs.modification)
			if file_date == today then should_truncate = false end
		else
			-- File does not exist — open in append mode (which creates it)
			should_truncate = false
		end
	end

	local mode = should_truncate and "w" or "a"
	local ok, fh = pcall(io.open, M.UNIFIED_LOG_FILE, mode)
	if not ok or not fh then return nil end
	_file_handle   = fh
	_last_log_date = today

	-- Stamp every truncation / fresh open with a session header so the user
	-- can tell where one Hammerspoon session ends and the next one begins
	pcall(function()
		fh:write("\n", "===== ", os.date("%Y-%m-%d %H:%M:%S"),
			" — Ergopti unified log opened (mode=", mode, ") =====", "\n")
		fh:flush()
	end)
	return _file_handle
end

--- Appends a single already-formatted log line to the unified file with a
--- compact HH:MM:SS prefix. Each call is line-flushed so a tail -f sees output
--- in real time and an unexpected Hammerspoon crash does not lose buffered
--- entries. Failures are silent on purpose: we never want logging to abort the
--- caller's work, e.g. when /tmp is full.
--- @param line string The fully-formatted line to append.
--- Routes a formatted log line into one or more topical sub-files in addition
--- to the main /tmp/ergopti.log sink. The classification is purely based on
--- substring matches in the rendered line (which always contains the module
--- tag, e.g. "[menu_llm.mlx]") so a module never has to know which file it
--- writes to. A line can land in multiple sub-files (e.g. "[mlx_deps]" lines
--- in both ergopti_mlx.log and ergopti_llm.log).
local SUB_LOG_FILES = {
	{ path = "/tmp/ergopti_mlx.log",        patterns = { "[mlx", "MLX-", "[menu_llm.mlx]", "[llm.api_mlx]" } },
	{ path = "/tmp/ergopti_ollama.log",     patterns = { "[ollama", "[menu_llm.ollama]", "[llm.api_ollama]" } },
	{ path = "/tmp/ergopti_llm.log",        patterns = { "[llm.", "[menu_llm", "[mlx_deps]", "[ollama_deps]", "WARMUP", "[TOGGLE]" } },
	{ path = "/tmp/ergopti_hotstrings.log", patterns = { "[keymap.registry]", "[dynamic_hotstrings", "[personal_info]", "hotstring", "[toml_reader]" } },
	{ path = "/tmp/ergopti_keylogger.log",  patterns = { "[keylogger" } },
	{ path = "/tmp/ergopti_karabiner.log",  patterns = { "[karabiner" } },
	{ path = "/tmp/ergopti_gestures.log",   patterns = { "[gestures" } },
	{ path = "/tmp/ergopti_menu.log",       patterns = { "[menu]", "[menu_", "[builder]", "[ui_builder]", "[app_picker]" } },
}

local function _matches_any(line, patterns)
	for _, p in ipairs(patterns) do
		if line:find(p, 1, true) then return true end
	end
	return false
end

local function _write_to_file(line)
	local fh = _ensure_log_file()
	local stamped = os.date("%H:%M:%S ") .. line .. "\n"
	if fh then
		pcall(function()
			fh:write(stamped)
			fh:flush()
		end)
	end
	-- Fan out to topical sub-files. Each sub-file is opened/closed per write
	-- so a crash never leaves a stale handle, and the file count is bounded
	-- (one open at a time). Cost is negligible vs. the network/MLX work
	-- already happening on every interesting log line.
	for _, sub in ipairs(SUB_LOG_FILES) do
		if _matches_any(line, sub.patterns) then
			pcall(function()
				local f = io.open(sub.path, "a")
				if f then
					f:write(stamped)
					f:close()
				end
			end)
		end
	end
end

--- Emits a count summary using the same variant as the suppressed messages, then resets state.
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
	_write_to_file(summary)
	_dedup.count       = 0
	_dedup.line        = nil
	_dedup.variant_key = nil
end

--- Internal dispatcher — formats and outputs one log entry.
--- Uses hs.console.printStyledtext for colored output; falls back to print if unavailable.
--- Consecutive identical lines are suppressed; a count summary is shown when the run breaks.
--- @param variant_key string Key into VARIANTS ("DEBUG", "TRACE", "DONE", "SUCCESS", …).
--- @param module_name string Short identifier of the calling module.
--- @param msg string Message or printf-style format string.
--- @param ... any Optional arguments for string.format.
local function _log(variant_key, module_name, msg, ...)
	local variant = VARIANTS[variant_key]
	if not variant or variant.level < M.current_level then return end

	-- Format the message; guard against malformed format strings
	local text
	local ok, fmt = pcall(tostring, msg)
	text = ok and fmt or "???"

	if select("#", ...) > 0 then
		local ok_f, formatted = pcall(string.format, text, ...)
		text = ok_f and formatted or (text .. " [format error]")
	end

	-- DEBUG-axis variants (level 1) are indented so they visually nest under surrounding
	-- INFO-axis events — e.g., per-item scan logs nest under the surrounding START/SUCCESS pair
	local indent = (variant.level == 1) and string.rep(" ", 10) or ""
	local line   = string.format("%s [%s] [%s] %s", indent, variant.label, tostring(module_name), text)

	-- Deduplication: suppress repeated identical lines, emit a count summary on change
	if line == _dedup.line then
		_dedup.count = _dedup.count + 1
		return
	end
	_flush_dedup_summary()
	_dedup.line        = line
	_dedup.variant_key = variant_key

	-- Prefer styled output (colors); plain print is the fallback for headless contexts
	if hs and hs.styledtext and hs.console and hs.console.printStyledtext then
		local styled = hs.styledtext.new(line, { color = variant.color })
		pcall(hs.console.printStyledtext, styled)
	else
		print(line)
	end

	-- Mirror to the unified rotating file so the user has a single tail target
	_write_to_file(line)
end

--- Logs a DEBUG message — verbose detail for development and troubleshooting.
--- Only visible when the active level is set to DEBUG.
--- @param module_name string Short module identifier.
--- @param msg string Message or format string.
--- @param ... any Optional format arguments.
function M.debug(module_name, msg, ...) _log("DEBUG", module_name, msg, ...) end

--- Logs a TRACE message — marks the start of a routine internal operation at DEBUG level.
--- Pair with Logger.done() to close the lifecycle loop at debug granularity.
--- @param module_name string Short module identifier.
--- @param msg string Message or format string.
--- @param ... any Optional format arguments.
function M.trace(module_name, msg, ...) _log("TRACE", module_name, msg, ...) end

--- Logs a DONE message — marks the successful end of a routine internal operation (DEBUG level).
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

--- Logs a START message — marks the beginning of a significant action (INFO level).
--- Always pair with Logger.success() to close the lifecycle loop.
--- If you see a START in logs without a following SUCCESS, something failed silently.
--- @param module_name string Short module identifier.
--- @param msg string Message or format string.
--- @param ... any Optional format arguments.
function M.start(module_name, msg, ...) _log("START", module_name, msg, ...) end

--- Logs a SUCCESS message — marks the successful completion of a started action (INFO level).
--- Always pair with Logger.start() that opened the same action.
--- @param module_name string Short module identifier.
--- @param msg string Message or format string.
--- @param ... any Optional format arguments.
function M.success(module_name, msg, ...) _log("SUCCESS", module_name, msg, ...) end

--- Logs a WARNING message — unexpected condition; execution continues but investigate.
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
		-- Build the formatted message independently from _log so the handler
		-- receives a clean string without the console prefix/indentation.
		local ok, base = pcall(tostring, msg)
		local text = ok and base or "???"
		if select("#", ...) > 0 then
			local ok_f, formatted = pcall(string.format, text, ...)
			text = ok_f and formatted or text
		end
		pcall(_error_notification_handler, tostring(module_name), text)
	end
end




-- ==================================
-- ==================================
-- ======= 4/ Utility Helpers =======
-- ==================================
-- ==================================

--- Wraps pcall and logs any raised exception at the ERROR level.
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

--- Wraps a builder function in a pcall and logs any failure at the ERROR level.
--- Returns nil on failure so callers can use the result as a truthiness guard.
--- @param module_name string Short module identifier.
--- @param label string Human-readable name of the component being built (for the error message).
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
