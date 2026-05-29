--- static/ergopti_plus/linux/modules/keylogger/metrics_collector.lua

--- ==============================================================================
--- MODULE: Metrics Collector (Linux)
--- DESCRIPTION:
--- Collects keystroke timing metrics and derives human-readable statistics such
--- as words-per-minute, n-gram frequency, and per-session summaries. Equivalent
--- of the Hammerspoon keylogger module, rewritten as a zero-dependency pure-Lua
--- module suitable for the LuaJIT daemon.
---
--- FEATURES & RATIONALE:
--- 1. Rolling WPM: a sliding time window keeps the WPM estimate fresh without
---    storing every individual keystroke timestamp indefinitely.
--- 2. Session lifecycle: init/reset boundaries let the daemon accumulate stats
---    across the entire run or reset on a configurable inactivity timeout.
--- 3. N-gram table: a flat frequency map records consecutive character sequences
---    of the configured length — useful for optimising layout or trigger choices.
--- 4. No OS calls: the module is pure Lua and only needs the caller to provide
---    a millisecond timestamp so it can be unit-tested without a real clock.
--- ==============================================================================

local M = {}


-- =========================================
-- =========================================
-- ======= 1/ Logger Shim ==================
-- =========================================
-- =========================================

local Logger  = require("logger.shim")
local Metrics = require("keylogger.metrics")

local LOG = "modules.keylogger.metrics_collector"


-- =========================================
-- =========================================
-- ======= 2/ Constants ====================
-- =========================================
-- =========================================

-- Default inactivity gap after which the rolling WPM window is considered stale.
-- If no key is pressed for this long the WPM calculation resets to 0.
local DEFAULT_SESSION_TIMEOUT_MS = 30000   -- 30 s with no keystrokes ends the session

-- Default rolling window used for the live WPM calculation.
local DEFAULT_WPM_WINDOW_MS = 10000   -- 10 s sliding window

-- Default n-gram length (bigrams by default).
local DEFAULT_NGRAM_SIZE = 2

-- Characters per word: 5 is the accepted convention in typing tests.
local CHARS_PER_WORD = 5

-- Maximum entries stored in the rolling timestamp ring-buffer.
-- Caps memory at a fixed bound regardless of typing speed.
local WPM_RING_CAPACITY = 2000


-- =========================================
-- =========================================
-- ======= 3/ Module State =================
-- =========================================
-- =========================================

-- Populated by M.init(); nil until then.
local _state = nil


-- =========================================
-- =========================================
-- ======= 4/ Guard Helper =================
-- =========================================
-- =========================================

--- Returns false and logs an error when the module has not been initialised.
--- @param func_name string Name of the calling function (for the log message).
--- @return boolean
local function require_state(func_name)
	if not _state then
		Logger.error(LOG, "'%s' called before M.init() — shared state not initialized.", func_name)
		return false
	end
	return true
end


-- =========================================
-- =========================================
-- ======= 5/ Internal Helpers =============
-- =========================================
-- =========================================

--- Removes timestamps from the front of the ring buffer that have fallen
--- outside the WPM sliding window. Delegates to shared Metrics helper.
--- @param now_ms number Current time in milliseconds.
local function prune_wpm_ring(now_ms)
	Metrics.prune_wpm_ring(_state.wpm_ring, now_ms, _state.wpm_window_ms)
end

--- Updates the n-gram frequency table with the most recent char typed.
--- Delegates to shared Metrics helper.
--- @param ch string The character just typed.
local function record_ngram(ch)
	Metrics.record_ngram(_state.char_window, _state.ngram_size, _state.ngrams, ch)
end


-- =========================================
-- =========================================
-- ======= 6/ Public API ===================
-- =========================================
-- =========================================

--- Initialises the metrics collector with the given configuration.
--- Must be called once before any other function in this module.
--- @param config table {session_timeout_ms?, wpm_window_ms?, ngram_size?}
function M.init(config)
	Logger.start(LOG, "Initializing…")

	if _state then
		Logger.warn(LOG, "M.init() called more than once — ignoring duplicate call.")
		return
	end

	local cfg = type(config) == "table" and config or {}

	_state = {
		session_timeout_ms = cfg.session_timeout_ms or DEFAULT_SESSION_TIMEOUT_MS,
		wpm_window_ms      = cfg.wpm_window_ms      or DEFAULT_WPM_WINDOW_MS,
		ngram_size         = cfg.ngram_size          or DEFAULT_NGRAM_SIZE,

		-- Session accumulators.
		keystroke_count = 0,
		session_start   = nil,   -- set on first keypress

		-- Rolling ring-buffer of keypress timestamps (ms) for WPM calculation.
		wpm_ring = {},

		-- Sliding character window for n-gram collection.
		char_window = {},

		-- Frequency map: gram_string → integer count.
		ngrams = {},
	}

	Logger.success(LOG, "Initialized (timeout=%dms wpm_window=%dms ngram=%d).",
		_state.session_timeout_ms, _state.wpm_window_ms, _state.ngram_size)
end

--- Records a single keypress event.
--- Should be called from the input reader's on_char callback with the current
--- wall-clock time in milliseconds.
--- @param ch           string  The character typed (UTF-8, one codepoint).
--- @param timestamp_ms number  Wall-clock time of the keypress in milliseconds.
function M.on_keydown(ch, timestamp_ms)
	if not require_state("on_keydown") then return end

	if type(ch) ~= "string" or ch == "" then return end
	if type(timestamp_ms) ~= "number" then return end

	-- Initialise the session on the very first keypress.
	if not _state.session_start then
		_state.session_start = timestamp_ms
		Logger.debug(LOG, "Session started at t=%d.", timestamp_ms)
	end

	_state.keystroke_count = _state.keystroke_count + 1

	-- Update rolling WPM ring.
	_state.wpm_ring[#_state.wpm_ring + 1] = timestamp_ms
	-- Trim the ring to its capacity bound.
	while #_state.wpm_ring > WPM_RING_CAPACITY do
		table.remove(_state.wpm_ring, 1)
	end
	-- Prune stale entries immediately so get_wpm() is O(1) most of the time.
	prune_wpm_ring(timestamp_ms)

	-- Update n-gram table.
	record_ngram(ch)

	Logger.debug(LOG, "on_keydown('%s') t=%d ks=%d.", ch, timestamp_ms, _state.keystroke_count)
end

--- Returns the rolling words-per-minute estimate based on the sliding window.
--- Returns 0.0 when there is insufficient data.
--- @return number  WPM as a floating-point value.
function M.get_wpm()
	if not require_state("get_wpm") then return 0.0 end

	local wpm = Metrics.compute_wpm_from_ring(_state.wpm_ring, CHARS_PER_WORD)
	Logger.debug(LOG, "get_wpm(): %.1f WPM from %d ring entries.", wpm, #_state.wpm_ring)
	return wpm
end

--- Returns a snapshot of the current session statistics.
--- @return table {keystrokes, words, start_time, duration_ms}
function M.get_session_stats()
	if not require_state("get_session_stats") then
		return { keystrokes = 0, words = 0, start_time = 0, duration_ms = 0 }
	end

	local now_ms     = _state.wpm_ring[#_state.wpm_ring] or (_state.session_start or 0)
	local start_ms   = _state.session_start or now_ms
	local duration   = now_ms - start_ms
	local words      = math.floor(_state.keystroke_count / CHARS_PER_WORD)

	return {
		keystrokes   = _state.keystroke_count,
		words        = words,
		start_time   = start_ms,
		duration_ms  = duration,
	}
end

--- Returns the top N n-grams from the current session sorted by frequency.
--- Delegates ranking to the shared Metrics helper.
--- @param n integer  Maximum number of n-gram entries to return.
--- @return table  Array of {gram, count} tables in descending frequency order.
function M.get_ngrams(n)
	if not require_state("get_ngrams") then return {} end

	if type(n) ~= "number" or n < 1 then n = 10 end

	local result = Metrics.get_top_ngrams(_state.ngrams, n)
	Logger.debug(LOG, "get_ngrams(%d): returning %d entry(ies).", n, #result)
	return result
end

--- Clears all session data and resets the module to its post-init state.
--- Useful when starting a new typing session or after a long idle gap.
function M.reset_session()
	if not require_state("reset_session") then return end

	_state.keystroke_count = 0
	_state.session_start   = nil
	_state.wpm_ring        = {}
	_state.char_window     = {}
	_state.ngrams          = {}

	Logger.info(LOG, "Session reset.")
end

return M
