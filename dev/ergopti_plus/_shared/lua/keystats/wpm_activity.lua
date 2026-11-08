--- _shared/lua/keystats/wpm_activity.lua

--- ==============================================================================
--- MODULE: WPM Input and Source Activity (Shared)
--- DESCRIPTION:
--- Physical input owns pointer visibility; independent producer holds own colour.
--- Synthetic output never advances the real keyboard clock.
--- ==============================================================================

local M = {}

--- Creates activity owned by one keystats collection session.
--- @param hold_ms number Shared source colour duration in milliseconds.
--- @return table
function M.new(hold_ms)
	assert(type(hold_ms) == "number" and hold_ms > 0, "WPM activity requires its hold duration")
	return { hold_ms = hold_ms, holds = {}, last_input_ms = nil }
end

--- Records an admitted physical key, including a correction.
--- @param state table
--- @param now_ms number Monotonic input time.
function M.record_input(state, now_ms)
	-- Character telemetry may carry integer milliseconds after a precise raw key.
	state.last_input_ms = math.max(state.last_input_ms or now_ms, now_ms)
end

--- Discards expired holds even when no readout is enabled.
local function prune(state, now_ms)
	for key, hold in pairs(state.holds) do
		if now_ms - hold.time_ms >= state.hold_ms then state.holds[key] = nil end
	end
end

--- Holds each source independently; later neutral output cannot erase it.
--- @param state table
--- @param source string Producer name.
--- @param variant string|nil Hotstring group.
--- @param now_ms number Monotonic output time.
function M.mark_source(state, source, variant, now_ms)
	prune(state, now_ms)
	variant = type(variant) == "string" and variant ~= "" and variant or source
	state.holds[source .. "\0" .. variant] = { source = source, variant = variant, time_ms = now_ms }
end

--- Copies the activity into a readout snapshot without lending mutable state.
--- @param state table
--- @param stats table Destination stats.
--- @param now_ms number Monotonic read time.
--- @return table Destination stats.
function M.snapshot(state, stats, now_ms)
	prune(state, now_ms)
	stats.last_input_time = state.last_input_ms and state.last_input_ms / 1000 or nil
	stats.source_holds = {}
	for _, hold in pairs(state.holds) do
		stats.source_holds[#stats.source_holds + 1] = {
			source = hold.source, variant = hold.variant, time = hold.time_ms / 1000,
		}
	end
	return stats
end

return M
