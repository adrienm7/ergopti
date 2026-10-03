--- _shared/lua/logger/init.lua

--- ==============================================================================
--- MODULE: Logger Core (Shared)
--- DESCRIPTION:
--- Platform-neutral logger core shared by all Ergopti+ drivers. Provides the
--- canonical log-line formatter, ring buffer, severity level filter, and the
--- eight variants (debug/trace/done/info/start/success/warn/error) as specified
--- in static/ergopti_plus/_shared/modules/logger/SPEC.md.
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
--- 6. Two suppression layers (spec § 4.1 and § 4.2): a consecutive-line dedup,
---    always on, and a bounded repeat collapser that a driver arms once at boot.
---    The second is what folds a 30 s poll with other lines in between, or a
---    line whose arguments change, into its first occurrence plus one summary.
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

--- How long an identical line stays suppressed, in seconds.
--- Five seconds, matching both driver loggers byte for byte: a line that recurs
--- is de-BOUNCED, not permanently silenced, so a streak outliving the window
--- re-surfaces instead of vanishing from the log for the rest of the session.
local DEDUP_WINDOW_SEC = 5

--- The suppression state: the last accepted line, when it was accepted, how many
--- identical ones have been swallowed since, and which variant they were.
--- A streak is closed by a "N identical lines suppressed" summary carrying the
--- SAME variant, so a suppressed error storm is still reported as an error.
local _dedup = { line = nil, time = 0, count = 0, variant = nil }

--- How long a repeat streak stays open, in seconds (spec § 4.2). Ten minutes
--- folds a 30 s poll into two lines per window while a summary still lands close
--- to the events it describes.
--- Single source: _shared/modules/timings/constants.toml [logger] repeat_window_ms.
local REPEAT_WINDOW_SEC = 600

--- How many repeat streaks are tracked at once. Bounded because every distinct
--- template opens one: an unbounded table grows with every line a session ever
--- logs. The least recently used streak makes room and reports its count first.
--- Single source: _shared/modules/timings/constants.toml [logger] repeat_streak_capacity.
local REPEAT_CAPACITY = 64

--- What a collapsible variant is keyed on, beside its variant and module.
--- debug and info use the UNFORMATTED template, so a counter in the arguments
--- cannot defeat the key; warn and error use the formatted body, so every
--- distinct failure is still recorded once. trace, done, start and success are
--- absent on purpose: a collapsed half of a lifecycle pair would leave the other
--- half alone in the log, which reads as exactly the silent failure the pairing
--- rule exists to expose.
local REPEAT_KEY_BY = {
	debug = "template",
	info  = "template",
	warn  = "body",
	error = "body",
}

--- Repeat-collapsing state. Disarmed until a driver's boot calls
--- M.enable_repeat_collapsing(): the core is a process singleton shared by every
--- unit test of a driver suite, and a ten-minute window armed by default would
--- make one test's line withhold another test's.
--- `date` is the calendar day every live streak belongs to; `oldest` is the
--- earliest streak start, so the per-line due check is one comparison; `seq`
--- orders streaks by creation and `use` by recency.
local _repeat = { enabled = false, streaks = {}, size = 0, date = nil, oldest = nil, seq = 0, use = 0 }

--- Session issue counters (spec § 5.1): every WARNING and ERROR line accepted
--- since the process started, and the last ERROR line. Kept apart from the ring
--- because the ring holds every level, so a few minutes of DEBUG lines evict the
--- very problems a diagnostic is opened to show.
local _session = { warn_count = 0, err_count = 0, last_error = nil }

--- Optional sink function called with every accepted formatted line.
--- Signature: function(line: string, variant: string) → void
local _sink = nil

--- Optional observer of every accepted ERROR line, called after the sink.
--- Signature: function(module_name: string, template: string, body: string) → void,
--- template being the message before its arguments (the Linux error window keys
--- an error by it, so arguments cannot make one fault look like many).
local _error_observer = nil





-- ===================================================
-- ===================================================
-- ======= 2/ Ring Buffer (200-entry circular) =======
-- ===================================================
-- ===================================================

--- Ring buffer capacity per spec § 5.
local RING_CAPACITY = 200

local _ring      = {}   -- Array of log lines (strings)
local _ring_head = 0    -- Points to the slot to write NEXT (0-indexed)
local _ring_size = 0    -- Number of entries currently stored





-- ==============================================
-- ==============================================
-- ======= 3/ Timestamp Helper (pure Lua) =======
-- ==============================================
-- ==============================================

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

--- Monotonic-ish seconds provider, used only to measure the dedup and repeat windows.
--- os.time() has one-second resolution, which is coarse but never runs backwards
--- within a session; a driver with a better clock replaces this.
--- @return number
function M.default_clock()
	return os.time()
end

--- Clock provider for the suppression windows. Replace with a higher-resolution one.
M.clock_fn = M.default_clock





-- =============================================
-- =============================================
-- ======= 4/ Public API — Configuration =======
-- =============================================
-- =============================================

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

--- The four thresholds, by name. Exposed so a driver can express its own policy
--- ("flush anything above DEBUG immediately") in the core's vocabulary instead of
--- keeping a private copy of the numbers — which is exactly how the macOS driver
--- came to use 1/2/3/4 while everything else used 10/20/30/40.
M.LEVELS = {
	DEBUG   = 10,
	INFO    = 20,
	WARNING = 30,
	ERROR   = 40,
}

--- The severity of one variant.
--- A driver sink receives the variant name and often needs its level — to decide
--- whether to flush now, or to mirror the line into an errors-only file. Deriving
--- it here keeps the variant→level mapping in one place.
--- @param variant string
--- @return number|nil
function M.level_of(variant)
	return LEVELS[variant]
end

--- The label a variant renders as, e.g. "warn" → "WARNING".
--- @param variant string
--- @return string|nil
function M.label_of(variant)
	return LABELS[variant]
end

--- Installs the output sink. Every accepted, formatted line is passed to fn.
--- Call with nil to remove the sink (useful in tests).
--- @param fn function|nil  function(line: string, variant: string) → void
function M.set_sink(fn)
	_sink = (type(fn) == "function") and fn or nil
end

--- Installs the ERROR observer. Call with nil to remove it (tests).
--- A line swallowed by the dedup window is not observed, as it is not logged.
--- @param fn function|nil  function(module_name, template, body) → void
function M.set_error_observer(fn)
	_error_observer = (type(fn) == "function") and fn or nil
end




-- =====================================================
-- =====================================================
-- ======= 5/ Core Line Formatter & Ring Push ==========
-- =====================================================
-- =====================================================

--- Pushes one finished line to the ring buffer and the sink.
--- Suppressed duplicates never reach here, which is what keeps the ring — the
--- buffer a crash report is built from — free of a thousand copies of one line.
--- @param line string The complete formatted line.
--- @param variant string The variant that produced it.
local function deliver(line, variant)
	local slot = (_ring_head % RING_CAPACITY) + 1
	_ring[slot] = line
	_ring_head  = _ring_head + 1
	if _ring_size < RING_CAPACITY then _ring_size = _ring_size + 1 end

	if _sink then
		local ok = pcall(_sink, line, variant)
		-- Sink errors are deliberately swallowed — a broken sink must never
		-- prevent the calling code from completing its own work
		if not ok then end
	end
end

--- Closes an open suppression streak with a summary line, if one is open.
--- The summary takes the same path as a normal line and carries the suppressed
--- variant, so a swallowed error storm is still reported at ERROR level.
local function flush_dedup_summary()
	if _dedup.count == 0 then return end
	local variant = _dedup.variant or "info"
	local label   = LABELS[variant] or variant:upper()
	local word    = _dedup.count == 1 and "line" or "lines"
	local summary = string.format("%s [%s] [logger] \u{2191} %d identical %s suppressed",
		M.timestamp_fn(), label, _dedup.count, word)
	_dedup.count   = 0
	_dedup.variant = nil
	deliver(summary, variant)
end




-- ==================================
-- ===== 5.1) Repeat Collapsing =====
-- ==================================

--- Emits the summary that closes one repeat streak, at the streak's variant and
--- under its module, so a collapsed warning still reaches the errors-only file
--- and a topical file still receives its own module's summary.
--- An open dedup streak is closed first: its suppressed lines are the most
--- recent ones, and a summary written after this one would read out of order.
--- @param streak table The closed streak.
--- @param ts string Timestamp the summary line is stamped with.
local function emit_repeat_summary(streak, ts)
	flush_dedup_summary()
	local times = streak.count == 1 and "time" or "times"
	local last = ""
	if streak.last_body ~= streak.text then last = " (last: " .. streak.last_body .. ")" end
	deliver(string.format("%s [%s] [%s] \u{2191} \"%s\" repeated %d more %s between %s and %s%s.",
		ts, LABELS[streak.variant], streak.module, streak.text, streak.count, times,
		streak.first_ts, streak.last_ts, last), streak.variant)
end

--- Recomputes the earliest live streak start after streaks were removed.
local function recompute_oldest_streak()
	local oldest = nil
	for _, streak in pairs(_repeat.streaks) do
		if oldest == nil or streak.start < oldest then oldest = streak.start end
	end
	_repeat.oldest = oldest
end

--- Closes every streak whose window has elapsed at `now`, or all of them, and
--- emits their summaries in the order the streaks were opened. Streaks are
--- unpublished BEFORE any summary is delivered, so a sink that logs cannot
--- observe a half-closed table.
--- @param now number Current clock reading, in seconds.
--- @param everything boolean True to close every streak regardless of age.
--- @param ts string Timestamp the summaries are stamped with.
local function close_repeat_streaks(now, everything, ts)
	local closing = {}
	for _, streak in pairs(_repeat.streaks) do
		if everything or (now - streak.start) >= REPEAT_WINDOW_SEC then
			closing[#closing + 1] = streak
		end
	end
	if #closing == 0 then return end
	table.sort(closing, function(a, b) return a.seq < b.seq end)
	for _, streak in ipairs(closing) do
		_repeat.streaks[streak.key] = nil
		_repeat.size = _repeat.size - 1
	end
	recompute_oldest_streak()
	for _, streak in ipairs(closing) do
		if streak.count > 0 then emit_repeat_summary(streak, ts) end
	end
end

--- Closes what is due: every streak when the calendar date changed (a streak
--- never spans two days), otherwise the streaks whose window has elapsed. The
--- common case — nothing due — is one comparison.
--- @param now number Current clock reading, in seconds.
--- @param ts string Current timestamp; its first ten characters are the date.
local function expire_repeat_streaks(now, ts)
	local date = ts:sub(1, 10)
	if _repeat.size == 0 then
		_repeat.date = date
		return
	end
	if date ~= _repeat.date then
		close_repeat_streaks(now, true, ts)
		_repeat.date = date
	elseif _repeat.oldest ~= nil and (now - _repeat.oldest) >= REPEAT_WINDOW_SEC then
		close_repeat_streaks(now, false, ts)
	end
end

--- Detaches the least recently used streak. The caller publishes its replacement
--- before emitting the summary, because a sink may synchronously reenter.
--- @return table victim Detached streak whose summary the caller owns.
local function evict_least_recent_streak()
	local victim = nil
	for _, streak in pairs(_repeat.streaks) do
		if victim == nil or streak.used < victim.used then victim = streak end
	end
	_repeat.streaks[victim.key] = nil
	_repeat.size = _repeat.size - 1
	if victim.start == _repeat.oldest then recompute_oldest_streak() end
	return victim
end

--- Decides whether one line is a repeat to withhold, recording it when it is and
--- opening a new streak when it is the first occurrence.
--- @param variant string Core variant name.
--- @param module_text string Module tag, already stringified.
--- @param msg any The unformatted template the caller passed.
--- @param body string The formatted body.
--- @param ts string The line's timestamp.
--- @param now number Current clock reading, in seconds.
--- @return boolean withheld True when the line must not be delivered.
local function withhold_repeat(variant, module_text, msg, body, ts, now)
	local key_by = REPEAT_KEY_BY[variant]
	if key_by == nil then return false end
	local text = (key_by == "template") and tostring(msg) or body
	local key = variant .. "\31" .. module_text .. "\31" .. text
	_repeat.use = _repeat.use + 1

	local streak = _repeat.streaks[key]
	if streak then
		streak.count = streak.count + 1
		if streak.count == 1 then streak.first_ts = ts end
		streak.last_ts   = ts
		streak.last_body = body
		streak.used      = _repeat.use
		return true
	end

	local evicted = nil
	if _repeat.size >= REPEAT_CAPACITY then evicted = evict_least_recent_streak() end
	_repeat.seq = _repeat.seq + 1
	_repeat.streaks[key] = {
		key = key, variant = variant, module = module_text, text = text,
		start = now, seq = _repeat.seq, used = _repeat.use, count = 0,
	}
	_repeat.size = _repeat.size + 1
	if _repeat.oldest == nil or now < _repeat.oldest then _repeat.oldest = now end
	if evicted and evicted.count > 0 then emit_repeat_summary(evicted, ts) end
	return false
end




-- =========================
-- ===== 5.2) Emission =====
-- =========================

--- Formats a log line per spec § 3, suppresses it per spec § 4.1 and § 4.2,
--- and delivers it.
--- @param variant string  One of: debug/trace/done/info/start/success/warn/error
--- @param module_name string  Caller-supplied tag (e.g. "menu_llm")
--- @param msg string  Format string (Lua string.format syntax)
--- @param ... any  Variadic arguments for msg
--- @return string|nil  The formatted line, or nil when filtered or suppressed
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

	local label       = LABELS[variant] or variant:upper()
	local module_text = tostring(module_name)
	local ts          = M.timestamp_fn()
	local line        = string.format("%s [%s] [%s] %s", ts, label, module_text, body)

	-- Deduplication is keyed on everything AFTER the timestamp: two emissions of
	-- one message a second apart differ only in their timestamp, so keying on the
	-- whole line would suppress nothing at all.
	local body_key = string.format("[%s] [%s] %s", label, module_text, body)
	local now = M.clock_fn()

	-- Due repeat streaks are closed on every emission, not only on a driver's
	-- tick: that keeps the rule identical on a driver whose tick is slow or
	-- stopped, and puts each summary before the line that found it due.
	if _repeat.enabled then expire_repeat_streaks(now, ts) end

	if body_key == _dedup.line and (now - _dedup.time) < DEDUP_WINDOW_SEC then
		_dedup.count   = _dedup.count + 1
		_dedup.variant = variant
		return nil
	end

	-- The repeat layer only sees what the consecutive dedup let through, so a
	-- burst is reported once, promptly, by the dedup summary and never twice.
	if _repeat.enabled and withhold_repeat(variant, module_text, msg, body, ts, now) then
		return nil
	end

	flush_dedup_summary()
	_dedup.line    = body_key
	_dedup.time    = now
	_dedup.variant = nil

	-- Counted before delivery and never logged about: the sink may be a driver
	-- callback, and a counter update must not depend on it returning
	if variant == "warn" then
		_session.warn_count = _session.warn_count + 1
	elseif variant == "error" then
		_session.err_count = _session.err_count + 1
		_session.last_error = line
	end

	deliver(line, variant)
	if variant == "error" and _error_observer then
		-- Swallowed like a sink failure: the logging call cannot log about itself,
		-- and must complete whatever a driver callback does
		local ok = pcall(_error_observer, tostring(module_name), tostring(msg), body)
		if not ok then end
	end
	return line
end





-- ==================================================
-- ==================================================
-- ======= 6/ Public API — Eight Log Variants =======
-- ==================================================
-- ==================================================

-- Each variant RETURNS the formatted line, or nil when the line was filtered by
-- level or swallowed by the dedup window. A driver that mirrors a line elsewhere
-- — the macOS logger raises a system notification on every error — has to follow
-- the log's own decision: firing a toast for a line the log suppressed buries the
-- user under identical notifications while the log shows a single deduped entry.

--- DEBUG misc — verbose detail, per-keystroke events, setter calls.
--- @param module_name string  @param msg string  @param ... any
function M.debug(module_name, msg, ...)   return emit("debug",   module_name, msg, ...) end

--- DEBUG start — start of a routine internal operation. Pair with M.done().
--- @param module_name string  @param msg string  @param ... any
function M.trace(module_name, msg, ...)   return emit("trace",   module_name, msg, ...) end

--- DEBUG end — successful end of a routine internal operation. Pair with M.trace().
--- @param module_name string  @param msg string  @param ... any
function M.done(module_name, msg, ...)    return emit("done",    module_name, msg, ...) end

--- INFO misc — general status, config loaded, feature toggled.
--- @param module_name string  @param msg string  @param ... any
function M.info(module_name, msg, ...)    return emit("info",    module_name, msg, ...) end

--- INFO start — start of a significant action. Pair with M.success().
--- @param module_name string  @param msg string  @param ... any
function M.start(module_name, msg, ...)   return emit("start",   module_name, msg, ...) end

--- INFO end — successful completion of a significant action. Pair with M.start().
--- @param module_name string  @param msg string  @param ... any
function M.success(module_name, msg, ...) return emit("success", module_name, msg, ...) end

--- WARNING — unexpected but recoverable condition; must be investigated.
--- @param module_name string  @param msg string  @param ... any
function M.warn(module_name, msg, ...)    return emit("warn",    module_name, msg, ...) end

--- ERROR — unrecoverable failure; execution should stop or degrade gracefully.
--- @param module_name string  @param msg string  @param ... any
function M.error(module_name, msg, ...)   return emit("error",   module_name, msg, ...) end





-- =================================================
-- =================================================
-- ======= 7/ Ring Buffer Inspection & Reset =======
-- =================================================
-- =================================================

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

--- Forgets the current suppression streak without emitting its summary.
--- For tests and for a driver reload: a streak carried across a reload would
--- suppress the first line of the new session because it matched the last line
--- of the old one, which is the least useful moment to lose a line.
function M.reset_dedup()
	_dedup.line    = nil
	_dedup.time    = 0
	_dedup.count   = 0
	_dedup.variant = nil
end

--- Reports how many identical lines the open streak has swallowed so far.
--- Exposed so a test can assert suppression happened rather than infer it from
--- an absence, which is the shape of a vacuous assertion.
--- @return number
function M.dedup_suppressed_count()
	return _dedup.count
end

--- Returns the number of entries currently in the ring buffer.
--- @return number
function M.ring_buffer_size()
	return _ring_size
end





-- =================================================
-- =================================================
-- ======= 8/ Public API — Repeat Collapsing =======
-- =================================================
-- =================================================

--- Arms repeat collapsing (spec § 4.2). Called exactly once by a driver's boot;
--- a second call raises instead of silently discarding every live streak and
--- the counts they carry.
function M.enable_repeat_collapsing()
	if _repeat.enabled then
		error("logger: repeat collapsing is already enabled", 2)
	end
	_repeat.enabled = true
	_repeat.streaks = {}
	_repeat.size    = 0
	_repeat.date    = nil
	_repeat.oldest  = nil
end

--- Disarms repeat collapsing and forgets every streak without a summary. For
--- test teardown and for an owner that is being torn down; a live driver closes
--- its streaks with M.flush_repeats(true) first.
function M.disable_repeat_collapsing()
	_repeat.enabled = false
	_repeat.streaks = {}
	_repeat.size    = 0
	_repeat.date    = nil
	_repeat.oldest  = nil
end

--- Reports whether repeat collapsing is armed.
--- @return boolean
function M.repeat_collapsing_enabled()
	return _repeat.enabled
end

--- Emits the summaries that are due.
--- The periodic form (force false) closes the streaks whose window has elapsed,
--- or all of them when the calendar date changed — the same rule every emission
--- applies, run from a driver's timer so a source that fell silent is still
--- summarised. The terminal form (force true) is for exit and reload, after which
--- nothing would ever close a streak again: it closes the open consecutive-dedup
--- streak first, then every repeat streak.
--- @param force boolean True at a terminal boundary.
function M.flush_repeats(force)
	if force then
		flush_dedup_summary()
		if _repeat.enabled then close_repeat_streaks(M.clock_fn(), true, M.timestamp_fn()) end
		return
	end
	if _repeat.enabled and _repeat.size > 0 then
		expire_repeat_streaks(M.clock_fn(), M.timestamp_fn())
	end
end





-- ================================================
-- ================================================
-- ======= 9/ Session Issue Counters ==============
-- ================================================
-- ================================================

--- Returns the session's issue counters as a fresh table, so a caller can
--- never mutate the core's own state.
--- A line swallowed by the dedup window is not counted: the counters describe
--- the log a user can open, where the streak appears once plus its summary.
--- @return table { warn_count = number, err_count = number, last_error = string|nil }
function M.session_issues()
	return {
		warn_count = _session.warn_count,
		err_count  = _session.err_count,
		last_error = _session.last_error,
	}
end

--- Zeroes the session counters. For tests and for a driver that restarts its
--- session inside one process; the running drivers never call it.
function M.reset_session_issues()
	_session.warn_count = 0
	_session.err_count  = 0
	_session.last_error = nil
end


return M
