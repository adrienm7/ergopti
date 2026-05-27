--- drivers/_shared/lua/logger/init.lua

--- ==============================================================================
--- MODULE: Logger Core (Shared)
--- DESCRIPTION:
--- Platform-neutral logger core shared by all Ergopti+ drivers. Provides the
--- canonical log-line formatter, ring buffer, severity level filter, and the
--- eight variants (debug/trace/done/info/start/success/warn/error) as specified
--- in static/ergopti_plus/shared/logger/SPEC.md.
---
--- FEATURES & RATIONALE:
--- 1. Pure Lua 5.3+: no driver-specific APIs — no hs.console, no file I/O, no
---    AHK-specific calls. Drivers extend this module by injecting a sink function
---    via M.set_sink() to route formatted lines to their output channel.
--- 2. Ring Buffer: 200-entry circular buffer (spec § 5) for in-process log
---    inspection without touching the filesystem.
--- 3. Severity Filtering: minimum level configurable at runtime (spec § 4).
---    Default level 10 (all variants active).
--- 4. Canonical line format: "TIMESTAMP [LEVEL] [MODULE] message_body"
---    where TIMESTAMP is "YYYY-MM-DD HH:MM:SS:mmm" (spec § 3.1).
--- 5. Lifecycle pairs: trace/done and start/success are paired at DEBUG and
---    INFO level respectively. A start/trace without a following success/done
---    in the ring buffer indicates a silent failure.
--- ==============================================================================

local M = {}




-- =============================================
-- =============================================
-- ======= 1/ Severity Level Definitions =======
-- =============================================
-- =============================================

--- Numeric severity levels per spec § 4.
local LEVELS = {
	debug   = 10,
	trace   = 10,
	done    = 10,
	info    = 20,
	start   = 20,
	success = 20,
	warn    = 30,
	error   = 40,
}

--- Level labels as they appear in formatted lines (spec § 3.2).
local LABELS = {
	debug   = "DEBUG",
	trace   = "TRACE",
	done    = "DONE",
	info    = "INFO",
	start   = "START",
	success = "SUCCESS",
	warn    = "WARNING",
	error   = "ERROR",
}

--- Minimum severity level. Lines below this threshold are discarded.
local _min_level = 10

--- Optional sink function called with every accepted formatted line.
--- Signature: function(line: string, variant: string) → void
local _sink = nil




-- ================================================
-- ================================================
-- ======= 2/ Ring Buffer (200-entry circular) =====
-- ================================================
-- ================================================

--- Ring buffer capacity per spec § 5.
local RING_CAPACITY = 200

local _ring      = {}   -- Array of log lines (strings)
local _ring_head = 0    -- Points to the slot to write NEXT (0-indexed)
local _ring_size = 0    -- Number of entries currently stored




-- ============================================
-- ============================================
-- ======= 3/ Timestamp Helper (pure Lua) =====
-- ============================================
-- ============================================

--- Returns the current timestamp in "YYYY-MM-DD HH:MM:SS:mmm" format.
--- Uses os.time() for the calendar fields and os.clock() for fractional
--- seconds when the platform does not provide sub-second precision.
--- Drivers that have access to a high-resolution clock (e.g. socket.gettime
--- on HS, A_Now + A_MSec on AHK) should override M.timestamp_fn to use it.
--- @return string Formatted timestamp.
function M.default_timestamp()
	local t = os.time()
	local d = os.date("*t", t)
	return string.format(
		"%04d-%02d-%02d %02d:%02d:%02d:000",
		d.year, d.month, d.day,
		d.hour, d.min,   d.sec
	)
end

--- Timestamp provider. Replace with a higher-resolution function if available.
--- Signature: function() → string in "YYYY-MM-DD HH:MM:SS:mmm" format.
M.timestamp_fn = M.default_timestamp




-- ====================================================
-- ====================================================
-- ======= 4/ Public API — Configuration =======
-- ====================================================
-- ====================================================

--- Sets the minimum severity level. Lines below this level are silently dropped.
--- @param level number|string  Numeric (10/20/30/40) or string alias
---   ("debug"|"info"|"warning"|"error").
function M.set_level(level)
	if type(level) == "string" then
		local aliases = { debug = 10, info = 20, warning = 30, error = 40 }
		level = aliases[level:lower()] or 10
	end
	_min_level = tonumber(level) or 10
end

--- Returns the current minimum severity level.
--- @return number
function M.get_level()
	return _min_level
end

--- Installs the output sink. Every accepted, formatted line is passed to fn.
--- Call with nil to remove the sink (useful in tests).
--- @param fn function|nil  function(line: string, variant: string) → void
function M.set_sink(fn)
	_sink = (type(fn) == "function") and fn or nil
end




-- =====================================================
-- =====================================================
-- ======= 5/ Core Line Formatter & Ring Push ==========
-- =====================================================
-- =====================================================

--- Formats a log line per spec § 3 and pushes it to the ring buffer and sink.
--- @param variant string  One of: debug/trace/done/info/start/success/warn/error
--- @param module  string  Caller-supplied tag (e.g. "menu_llm")
--- @param msg     string  Format string (Lua string.format syntax)
--- @param ...            Variadic arguments for msg
--- @return string|nil    The formatted line, or nil if filtered out
local function emit(variant, module_name, msg, ...)
	local level = LEVELS[variant]
	if not level or level < _min_level then return nil end

	-- Build message body, guarding against format errors
	local body
	if select("#", ...) > 0 then
		local ok, result = pcall(string.format, msg, ...)
		body = ok and result or tostring(msg)
	else
		body = tostring(msg)
	end

	local label = LABELS[variant] or variant:upper()
	local ts    = M.timestamp_fn()
	local line  = string.format("%s [%s] [%s] %s", ts, label, tostring(module_name), body)

	-- Push to ring buffer (circular, O(1))
	local slot = (_ring_head % RING_CAPACITY) + 1
	_ring[slot] = line
	_ring_head  = _ring_head + 1
	if _ring_size < RING_CAPACITY then _ring_size = _ring_size + 1 end

	-- Forward to sink (driver-specific output)
	if _sink then
		local ok = pcall(_sink, line, variant)
		-- Sink errors are deliberately swallowed — a broken sink must never
		-- prevent the calling code from completing its own work
		if not ok then end
	end

	return line
end




-- ===================================================
-- ===================================================
-- ======= 6/ Public API — Eight Log Variants =======
-- ===================================================
-- ===================================================

--- DEBUG misc — verbose detail, per-keystroke events, setter calls.
--- @param module_name string  @param msg string  @param ... any
function M.debug(module_name, msg, ...)   emit("debug",   module_name, msg, ...) end

--- DEBUG start — start of a routine internal operation. Pair with M.done().
--- @param module_name string  @param msg string  @param ... any
function M.trace(module_name, msg, ...)   emit("trace",   module_name, msg, ...) end

--- DEBUG end — successful end of a routine internal operation. Pair with M.trace().
--- @param module_name string  @param msg string  @param ... any
function M.done(module_name, msg, ...)    emit("done",    module_name, msg, ...) end

--- INFO misc — general status, config loaded, feature toggled.
--- @param module_name string  @param msg string  @param ... any
function M.info(module_name, msg, ...)    emit("info",    module_name, msg, ...) end

--- INFO start — start of a significant action. Pair with M.success().
--- @param module_name string  @param msg string  @param ... any
function M.start(module_name, msg, ...)   emit("start",   module_name, msg, ...) end

--- INFO end — successful completion of a significant action. Pair with M.start().
--- @param module_name string  @param msg string  @param ... any
function M.success(module_name, msg, ...) emit("success", module_name, msg, ...) end

--- WARNING — unexpected but recoverable condition; must be investigated.
--- @param module_name string  @param msg string  @param ... any
function M.warn(module_name, msg, ...)    emit("warn",    module_name, msg, ...) end

--- ERROR — unrecoverable failure; execution should stop or degrade gracefully.
--- @param module_name string  @param msg string  @param ... any
function M.error(module_name, msg, ...)   emit("error",   module_name, msg, ...) end




-- =======================================================
-- =======================================================
-- ======= 7/ Ring Buffer Inspection & Reset =======
-- =======================================================
-- =======================================================

--- Returns a chronologically ordered snapshot of all buffered lines.
--- @return table  Array of strings, oldest-first.
function M.ring_buffer_snapshot()
	if _ring_size == 0 then return {} end

	local out = {}
	if _ring_size < RING_CAPACITY then
		-- Buffer not yet wrapped — elements are in slots 1.._ring_size in order
		for i = 1, _ring_size do
			out[i] = _ring[i]
		end
	else
		-- Buffer has wrapped — oldest element is at (head % capacity) + 1
		local start = (_ring_head % RING_CAPACITY) + 1
		for i = 0, RING_CAPACITY - 1 do
			local slot = ((start - 1 + i) % RING_CAPACITY) + 1
			out[i + 1] = _ring[slot]
		end
	end
	return out
end

--- Clears the ring buffer. Useful in test teardown to avoid cross-test pollution.
function M.ring_buffer_clear()
	_ring      = {}
	_ring_head = 0
	_ring_size = 0
end

--- Returns the number of entries currently in the ring buffer.
--- @return number
function M.ring_buffer_size()
	return _ring_size
end


return M
