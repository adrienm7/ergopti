--- _shared/lua/keylogger/live_wpm.lua

--- ==============================================================================
--- MODULE: Live Typing Speed (Shared)
--- DESCRIPTION:
--- The number the WPM readouts show, and where the last text came from.
---
--- FEATURES & RATIONALE:
--- 1. Effective speed. Every character that reaches the page counts — typed,
---    expanded or generated — because the readout answers "how fast is text
---    appearing", which is what a hotstring or a completion speeds up.
--- 2. Zero after a pause. A burst's speed is not the user's speed ten seconds
---    later; after timings [keylogger] wpm_idle_reset_ms without a character
---    the readout reads 0.
--- 3. One clock, the caller's. Every function takes `now_ms` rather than reading
---    a clock, so a driver passes its own monotonic time and a test moves time
---    by hand.
--- ==============================================================================

local M = {}

local Metrics = require("keylogger.metrics")




-- =========================================
-- =========================================
-- ======= 1/ State ========================
-- =========================================
-- =========================================

--- A fresh tracker.
--- @param opts table { window_ms, min_duration_ms, idle_reset_ms } from the shared timings.
--- @return table
function M.new(opts)
	if type(opts) ~= "table" then error("live_wpm.new requires its timings", 2) end
	for _, key in ipairs({ "window_ms", "min_duration_ms", "idle_reset_ms" }) do
		if type(opts[key]) ~= "number" or opts[key] <= 0 then
			error("live_wpm.new: " .. key .. " must be a positive number", 2)
		end
	end
	return {
		window_ms = opts.window_ms,
		min_duration_ms = opts.min_duration_ms,
		idle_reset_ms = opts.idle_reset_ms,
		stamps = {},
		last_active_ms = nil,
		source = "none",
		source_variant = "none",
		source_ms = nil,
	}
end

--- Drops the stamps that left the window.
local function prune(tracker, now_ms)
	local stamps = tracker.stamps
	local keep_from = 1
	while stamps[keep_from] and (now_ms - stamps[keep_from]) > tracker.window_ms do
		keep_from = keep_from + 1
	end
	if keep_from > 1 then
		local kept = {}
		for index = keep_from, #stamps do kept[#kept + 1] = stamps[index] end
		tracker.stamps = kept
	end
end




-- =========================================
-- =========================================
-- ======= 2/ Recording ====================
-- =========================================
-- =========================================

--- Counts `count` characters that reached the page at `now_ms`.
--- @param tracker table
--- @param count integer
--- @param now_ms number
function M.record(tracker, count, now_ms)
	count = math.floor(tonumber(count) or 0)
	if count <= 0 then return end
	for _ = 1, count do tracker.stamps[#tracker.stamps + 1] = now_ms end
	tracker.last_active_ms = now_ms
	prune(tracker, now_ms)
end

--- Names where the last text came from: "hotstring" (with its group as the
--- variant), "llm", or any other producer's name.
--- @param tracker table
--- @param source string
--- @param variant string|nil The hotstring group, when there is one.
--- @param now_ms number
function M.mark_source(tracker, source, variant, now_ms)
	if type(source) ~= "string" or source == "" then return end
	tracker.source = source
	tracker.source_variant = (type(variant) == "string" and variant ~= "") and variant or source
	tracker.source_ms = now_ms
end




-- =========================================
-- =========================================
-- ======= 3/ Reading ======================
-- =========================================
-- =========================================

--- The readout's numbers, in the shape the macOS keylogger has always returned.
--- @param tracker table
--- @param now_ms number
--- @return table { wpm, source, source_variant, source_time } — source_time in seconds.
function M.stats(tracker, now_ms)
	prune(tracker, now_ms)
	local wpm = 0
	local idle = tracker.last_active_ms == nil or (now_ms - tracker.last_active_ms) > tracker.idle_reset_ms
	local count = #tracker.stamps
	if not idle and count > 1 then
		local window = math.max(now_ms - tracker.stamps[1], tracker.min_duration_ms)
		wpm = math.floor(Metrics.compute_wpm_from_events(count, window) + 0.5)
	end
	return {
		wpm = wpm,
		source = tracker.source,
		source_variant = tracker.source_variant,
		source_time = tracker.source_ms and tracker.source_ms / 1000 or 0,
	}
end

return M
