--- shared/lua/keylogger/metrics.lua

--- ==============================================================================
--- MODULE: Keylogger Metrics — Shared Pure Functions
--- DESCRIPTION:
--- Platform-neutral, stateless helper functions for computing typing-speed
--- metrics and n-gram frequencies. Shared between the Hammerspoon (macOS) and
--- LuaJIT (Linux) keylogger drivers.
---
--- All functions are pure: no I/O, no timers, no OS calls, no upvalue state.
--- Each driver owns its own ring buffer / n-gram table and calls these helpers
--- to perform the math.
---
--- FEATURES & RATIONALE:
--- 1. Ring-buffer WPM: compute_wpm_from_ring() implements the sliding-window
---    algorithm used by Linux metrics_collector — two timestamp endpoints
---    define the window, keycount-1 / elapsed_s gives CPS, scaled to WPM.
--- 2. Event-batch WPM: compute_wpm_from_events() implements the batch formula
---    used by macOS log_manager/aggregator — (chars/5)/(total_ms/60000).
--- 3. N-gram recording: record_ngram() updates a char-window and frequency map
---    in place; the caller owns both tables.
--- 4. Top-N n-grams: get_top_ngrams() sorts a frequency map and returns the
---    top N entries as { gram, count } pairs.
--- ==============================================================================

local M = {}


-- Default constant: 5 characters = 1 word (industry standard for WPM).
local DEFAULT_CHARS_PER_WORD = 5




-- =======================================
-- =======================================
-- ======= 1/ WPM Computation ============
-- =======================================
-- =======================================

--- Computes WPM from a ring buffer of keypress timestamps.
--- Implements the sliding-window algorithm: the window is defined by the
--- oldest and newest timestamp still inside [now_ms - window_ms, now_ms].
---
--- @param ring table  Array of keypress timestamps in milliseconds (sorted asc).
--- @param chars_per_word number|nil Characters per word (default 5).
--- @return number WPM as a floating-point value, or 0.0 when insufficient data.
function M.compute_wpm_from_ring(ring, chars_per_word)
	if type(ring) ~= "table" or #ring < 2 then return 0.0 end

	local n         = #ring
	local elapsed_s = (ring[n] - ring[1]) / 1000.0
	if elapsed_s <= 0 then return 0.0 end

	local cpw = tonumber(chars_per_word) or DEFAULT_CHARS_PER_WORD
	if cpw <= 0 then cpw = DEFAULT_CHARS_PER_WORD end

	-- Characters per second → words per minute.
	local cps = (n - 1) / elapsed_s
	return (cps / cpw) * 60.0
end

--- Computes WPM from a total character count and elapsed time.
--- Implements the batch formula used by macOS log_manager:
---   wpm = (total_chars / 5) / (total_time_ms / 60000)
---
--- @param total_chars  number Total characters typed in the interval.
--- @param total_time_ms number Total elapsed time in milliseconds.
--- @param chars_per_word number|nil Characters per word (default 5).
--- @return number WPM as a floating-point value, or 0.0 when total_time_ms <= 0.
function M.compute_wpm_from_events(total_chars, total_time_ms, chars_per_word)
	if type(total_time_ms) ~= "number" or total_time_ms <= 0 then return 0.0 end
	if type(total_chars)   ~= "number" or total_chars  <= 0 then return 0.0 end

	local cpw = tonumber(chars_per_word) or DEFAULT_CHARS_PER_WORD
	if cpw <= 0 then cpw = DEFAULT_CHARS_PER_WORD end

	return (total_chars / cpw) / (total_time_ms / 60000.0)
end




-- ===========================================
-- ===========================================
-- ======= 2/ N-gram Recording ===============
-- ===========================================
-- ===========================================

--- Updates the n-gram frequency table with the most recent character typed.
--- Mutates both char_window (the rolling char buffer) and ngrams (the freq map)
--- in place — the caller owns both tables.
---
--- @param char_window table Mutable array of recent characters (state owned by caller).
--- @param ngram_size  number Number of characters per gram (e.g. 2 = bigram, 3 = trigram).
--- @param ngrams      table Mutable map of gram_string -> integer count.
--- @param ch          string The character just typed (UTF-8, one codepoint).
function M.record_ngram(char_window, ngram_size, ngrams, ch)
	if type(ch) ~= "string" or ch == "" then return end
	if type(char_window) ~= "table" then return end
	if type(ngrams)       ~= "table" then return end

	local size = tonumber(ngram_size) or 3
	if size < 1 then size = 1 end

	char_window[#char_window + 1] = ch

	-- Keep the window at exactly size characters.
	while #char_window > size do
		table.remove(char_window, 1)
	end

	-- Only record when the window is fully populated.
	if #char_window == size then
		local gram = table.concat(char_window)
		ngrams[gram] = (ngrams[gram] or 0) + 1
	end
end




-- ==========================================
-- ==========================================
-- ======= 3/ N-gram Ranking =================
-- ==========================================
-- ==========================================

--- Returns the top N n-grams from a frequency map sorted by descending count.
---
--- @param ngrams table Frequency map: gram_string -> integer count.
--- @param n      number Maximum number of entries to return.
--- @return table Array of { gram: string, count: number } in descending order.
function M.get_top_ngrams(ngrams, n)
	if type(ngrams) ~= "table" then return {} end

	local limit = math.max(1, math.floor(tonumber(n) or 10))

	local list = {}
	for gram, count in pairs(ngrams) do
		list[#list + 1] = { gram = gram, count = count }
	end

	table.sort(list, function(a, b) return a.count > b.count end)

	local top = {}
	for i = 1, math.min(limit, #list) do
		top[i] = list[i]
	end
	return top
end




-- ============================================
-- ============================================
-- ======= 4/ WPM Ring Pruning Helper =========
-- ============================================
-- ============================================

--- Removes timestamps older than the sliding window from the front of a ring.
--- Mutates ring in place. Returns the number of entries removed.
---
--- @param ring     table  Sorted ascending array of keypress timestamps (ms).
--- @param now_ms   number Current time in milliseconds.
--- @param window_ms number Window duration in milliseconds.
--- @return number  Count of entries removed.
function M.prune_wpm_ring(ring, now_ms, window_ms)
	if type(ring) ~= "table" then return 0 end

	local cutoff = (tonumber(now_ms) or 0) - (tonumber(window_ms) or 0)
	local removed = 0
	while ring[1] and ring[1] < cutoff do
		table.remove(ring, 1)
		removed = removed + 1
	end
	return removed
end

return M
