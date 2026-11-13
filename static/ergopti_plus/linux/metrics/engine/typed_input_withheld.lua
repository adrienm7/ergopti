--- metrics/engine/typed_input_withheld.lua

--- ==============================================================================
--- MODULE: Typed Input Withheld Counters
--- DESCRIPTION:
--- Counts the typed characters Main's text callback keeps from the hotstring
--- engine and the AI, by closed reason, with the last reason and its monotonic
--- stamp. No character, application or field is ever recorded.
---
--- FEATURES & RATIONALE:
--- 1. Those paths returned without a trace: a live run lost a whole sentence
---    between two scenarios and the log could not say where. The counts name
---    the path; the daemon logs a one-line summary at shutdown.
--- 2. No logger dependency: the test harnesses compile Main's text callback
---    alone, without the central logger, and must keep doing so.
--- 3. A refused prediction keeps the error's type only, since its message can
---    quote typed text.
--- ==============================================================================

local M = {}

-- The closed reasons, in the summary's order.
M.REASONS = { "queued_during_injection", "press_not_admitted", "field_not_admitted", "prediction_refused" }

local KNOWN = {}
for _, reason in ipairs(M.REASONS) do KNOWN[reason] = true end

local _counts, _last_reason, _last_ms, _last_error_type = {}, nil, nil, nil

--- The monotonic stamp of a record, from the daemon's clock owner.
--- @return number|nil
local function now_ms()
	local ok, Monotonic = pcall(require, "core.logger.engine.monotonic")
	if not ok or type(Monotonic) ~= "table" or type(Monotonic.now_ms) ~= "function" then return nil end
	local read, value = pcall(Monotonic.now_ms)
	return read and type(value) == "number" and math.floor(value) or nil
end

--- Records one withheld character.
--- @param reason string One of M.REASONS.
--- @param error_value any The refused prediction's error, for "prediction_refused" only.
function M.record(reason, error_value)
	if not KNOWN[reason] then error("typed_input_withheld: unknown reason " .. tostring(reason), 2) end
	_counts[reason] = (_counts[reason] or 0) + 1
	_last_reason, _last_ms = reason, now_ms()
	if reason == "prediction_refused" then _last_error_type = type(error_value) end
end

--- A copy of the counts and the last record.
--- @return table { counts = { [reason] = n }, last_reason, last_ms, last_error_type }
function M.snapshot()
	local counts = {}
	for _, reason in ipairs(M.REASONS) do counts[reason] = _counts[reason] or 0 end
	return { counts = counts, last_reason = _last_reason, last_ms = _last_ms, last_error_type = _last_error_type }
end

--- The one-line summary the daemon logs, every reason named.
--- @return string
function M.summary()
	local snapshot, parts = M.snapshot(), {}
	for _, reason in ipairs(M.REASONS) do parts[#parts + 1] = reason .. "=" .. snapshot.counts[reason] end
	local line = "Typed input withheld from the engines: " .. table.concat(parts, " ")
	if snapshot.last_reason then
		line = line .. " (last " .. snapshot.last_reason .. " at " .. tostring(snapshot.last_ms) .. " ms"
		if snapshot.last_error_type then line = line .. ", prediction error type " .. snapshot.last_error_type end
		line = line .. ")"
	end
	return line .. "."
end

--- Forgets every record. Test seam.
function M._reset_for_test()
	_counts, _last_reason, _last_ms, _last_error_type = {}, nil, nil, nil
end

return M
