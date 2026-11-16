--- _shared/metrics/engine/wpm/activity.lua

--- ==============================================================================
--- MODULE: WPM Input and Source Activity (Shared)
--- DESCRIPTION:
--- Physical input owns pointer visibility; independent producer holds own colour.
--- Synthetic output never advances the real keyboard clock. A typing burst starts
--- with a text key and ends at a shortcut, an ending key, a modifier tapped alone
--- or a focus change (TWD-2, decided by the maintainer on 2026-11-16).
--- ==============================================================================

local M = {}

--- Creates activity owned by one keystats collection session.
--- @param hold_ms number Shared source colour duration in milliseconds.
--- @return table
function M.new(hold_ms)
	assert(type(hold_ms) == "number" and hold_ms > 0, "WPM activity requires its hold duration")
	return { hold_ms = hold_ms, holds = {}, last_input_ms = nil, last_break_ms = nil, lone_modifier = nil }
end

--- Records an admitted text key: it starts or continues a typing burst.
--- @param state table
--- @param now_ms number Monotonic input time.
function M.record_input(state, now_ms)
	-- Character telemetry may carry integer milliseconds after a precise raw key:
	-- the text takes the raw key's time, so it never sorts before a pointer event
	-- of the same millisecond.
	local stamp = math.max(now_ms, state.pending_text_ms or now_ms)
	state.last_input_ms = math.max(state.last_input_ms or stamp, stamp)
	state.lone_modifier = nil
	state.pending_text_ms = nil
end

--- Ends the typing burst: the widget hides until the next text key.
--- @param state table
--- @param now_ms number Monotonic time.
function M.record_break(state, now_ms)
	state.last_break_ms = math.max(state.last_break_ms or now_ms, now_ms)
	state.lone_modifier = nil
end

--- Observes a physical key press that is not text by itself.
--- @param state table
--- @param role string|nil From typing_keys: "ends", "modifier", "neutral", "level", or nil.
--- @param code any The native key code.
--- @param shortcut boolean A Ctrl, Alt, Cmd or Win chord.
--- @param now_ms number Monotonic time.
function M.observe_key(state, role, code, shortcut, now_ms)
	if role == "modifier" then
		state.lone_modifier = code
		return
	end
	-- Shift and AltGr type text: they never end a burst, and one pressed after a
	-- Ctrl (the LCtrl Windows sends with AltGr) means that Ctrl was no lone tap.
	state.lone_modifier = nil
	if role == "level" then return end
	if shortcut == true or role == "ends" then
		M.record_break(state, now_ms)
		state.pending_text_ms = nil
	elseif role == "neutral" then
		-- A correction, a new line or a Tab keeps a live burst going, never starts one.
		local input, stop = state.last_input_ms, state.last_break_ms
		if input ~= nil and (stop == nil or stop < input) then state.last_input_ms = math.max(input, now_ms) end
	elseif role == nil then
		-- A key that may type text: its character will follow (record_input).
		state.pending_text_ms = now_ms
	end
end

--- Observes a modifier release: tapped alone, it ends the burst.
--- @param state table
--- @param code any The native key code.
--- @param now_ms number Monotonic time.
function M.observe_release(state, code, now_ms)
	if state.lone_modifier ~= nil and state.lone_modifier == code then M.record_break(state, now_ms) end
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
	stats.last_break_time = state.last_break_ms and state.last_break_ms / 1000 or nil
	stats.source_holds = {}
	for _, hold in pairs(state.holds) do
		stats.source_holds[#stats.source_holds + 1] = {
			source = hold.source, variant = hold.variant, time = hold.time_ms / 1000,
		}
	end
	return stats
end

return M
