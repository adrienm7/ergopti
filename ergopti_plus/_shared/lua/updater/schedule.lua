--- _shared/lua/updater/schedule.lua

--- ==============================================================================
--- MODULE: Automatic Update-Check Schedule (Shared Lua Port)
--- DESCRIPTION:
--- Decides when an automatic update check is due for the macOS and Linux
--- drivers, from the wall clock, the persisted check record and the timing of
--- _shared/modules/updater/defaults.json.
---
--- FEATURES & RATIONALE:
--- 1. Port of the canonical JavaScript (_shared/modules/updater/schedule.js);
---    both replay _shared/modules/updater/schedule_vectors.json with the AHK
---    port, so the three drivers share one rule for catch-up after a power-off,
---    a clock moved back, failure backoff and jitter.
--- 2. PURE Lua (LuaJIT and 5.4): no driver imports, no io, no clock, no timers.
---    The jitter fold stays below 2^36, exact in LuaJIT's doubles and in 5.4's
---    integers, and uses no bitwise operator (absent from LuaJIT's syntax).
--- 3. Fail fast: validate_timing() returns nil and the exact reason for a
---    malformed timing section; the driver logs it and schedules nothing.
--- ==============================================================================

local M = {}

-- Largest prime below 2^31, the modulus of the jitter fold.
local HASH_MODULUS = 2147483647
local HASH_MULTIPLIER = 31
local NEVER_CODE = "never"

-- The persisted check record, in the order sanitize_state reports dropped fields.
local STATE_FIELDS = {
	{ "last_check_at", "time" },
	{ "last_success_at", "time" },
	{ "failures", "count" },
	{ "seed", "seed" },
	{ "last_notified_tag", "tag" },
}

-- Reported when the stored record is not an object at all.
local WHOLE_RECORD = "check_state"

--- Reports whether a value is a whole, non-negative, finite number.
--- @param value any
--- @return boolean
local function is_count(value)
	return type(value) == "number" and value >= 0 and value ~= math.huge and value == math.floor(value)
end





-- =====================================
-- =====================================
-- ======= 1/ Timing Validation ========
-- =====================================
-- =====================================

--- Validates the timing section of defaults.json.
--- @param timing table defaults.json timing.
--- @return boolean|nil ok True when valid.
--- @return string|nil err The first problem otherwise.
function M.validate_timing(timing)
	if type(timing) ~= "table" then return nil, "timing must be a table" end
	local presets = timing.check_interval_presets
	if type(presets) ~= "table" or #presets < 2 then
		return nil, "check_interval_presets needs at least two presets"
	end
	local codes = {}
	local previous = 0
	for index, preset in ipairs(presets) do
		if type(preset) ~= "table" or type(preset.code) ~= "string" or not preset.code:match("^[a-z0-9]+$") then
			return nil, "preset " .. index .. " has no valid code"
		end
		if codes[preset.code] then return nil, "preset code " .. preset.code .. " is declared twice" end
		codes[preset.code] = true
		if not is_count(preset.seconds) then
			return nil, "preset " .. preset.code .. " must be a whole number of seconds"
		end
		local last = index == #presets
		if last ~= (preset.code == NEVER_CODE) then return nil, "the " .. NEVER_CODE .. " preset must be the last one" end
		if last ~= (preset.seconds == 0) then return nil, "only the last preset may be 0 seconds" end
		if not last then
			if preset.seconds <= previous then return nil, "presets must be ordered from the shortest to the longest" end
			previous = preset.seconds
		end
	end
	local default_found = false
	for _, preset in ipairs(presets) do
		if preset.seconds == timing.default_check_interval_sec then default_found = true end
	end
	if not default_found then return nil, "default_check_interval_sec must be one of the presets" end
	if not is_count(timing.boot_check_delay_sec) then
		return nil, "boot_check_delay_sec must be a whole number of seconds"
	end
	if not is_count(timing.jitter_percent) or timing.jitter_percent > 100 then
		return nil, "jitter_percent must be 0 to 100"
	end
	if not is_count(timing.jitter_max_sec) then return nil, "jitter_max_sec must be a whole number of seconds" end
	local backoff = timing.failure_backoff_sec
	if type(backoff) ~= "table" or #backoff == 0 then return nil, "failure_backoff_sec must list positive whole seconds" end
	for _, seconds in ipairs(backoff) do
		if not is_count(seconds) or seconds == 0 then return nil, "failure_backoff_sec must list positive whole seconds" end
	end
	if not is_count(timing.reevaluate_sec) or timing.reevaluate_sec == 0 then
		return nil, "reevaluate_sec must be positive"
	end
	return true, nil
end





-- ===========================
-- ===========================
-- ======= 2/ Presets ========
-- ===========================
-- ===========================

--- Returns the preset of a saved interval, or nil when none matches exactly.
--- @param seconds number Interval in seconds (0 = never).
--- @param timing table defaults.json timing.
--- @return table|nil preset { code, seconds }
function M.preset_for(seconds, timing)
	for _, preset in ipairs(timing.check_interval_presets) do
		if preset.seconds == seconds then return preset end
	end
	return nil
end

--- Snaps a saved interval to the nearest preset by ratio (a tie takes the
--- longer preset).
--- @param seconds number Saved interval (0 = never).
--- @param timing table defaults.json timing.
--- @return number seconds The preset's seconds.
--- @return string code The preset's code.
--- @return boolean snapped Whether the value changed.
function M.snap_interval(seconds, timing)
	if not is_count(seconds) then error("an interval must be a whole number of seconds", 2) end
	local presets = timing.check_interval_presets
	if seconds == 0 then
		local never = presets[#presets]
		return 0, never.code, false
	end
	local longest = presets[#presets - 1]
	local best = presets[1]
	if seconds >= longest.seconds then
		best = longest
	elseif seconds > best.seconds then
		for index = 1, #presets - 1 do
			local preset = presets[index]
			-- ratio(p) = max(p, s) / min(p, s), compared by cross-multiplication.
			local candidate = math.max(preset.seconds, seconds) * math.min(best.seconds, seconds)
			local current = math.max(best.seconds, seconds) * math.min(preset.seconds, seconds)
			if candidate <= current then best = preset end
		end
	end
	return best.seconds, best.code, best.seconds ~= seconds
end





-- ================================
-- ================================
-- ======= 3/ State Record ========
-- ================================
-- ================================

--- Keeps the valid fields of a stored check record.
--- @param raw any The value read from the driver's Storage port.
--- @return table state The valid fields.
--- @return table dropped The names of the invalid fields.
function M.sanitize_state(raw)
	if raw == nil then return {}, {} end
	if type(raw) ~= "table" or raw[1] ~= nil then return {}, { WHOLE_RECORD } end
	local state, dropped = {}, {}
	for _, entry in ipairs(STATE_FIELDS) do
		local field, kind = entry[1], entry[2]
		local value = raw[field]
		if value ~= nil then
			local valid
			if kind == "time" or kind == "count" then
				valid = is_count(value)
			elseif kind == "seed" then
				valid = type(value) == "string" and value ~= ""
			else
				valid = type(value) == "string"
			end
			if valid then
				state[field] = value
			else
				dropped[#dropped + 1] = field
			end
		end
	end
	return state, dropped
end

--- Returns the record after one check completed; the input is not modified.
--- @param state table Sanitized record.
--- @param now number Completion time (epoch seconds).
--- @param ok boolean Whether the check reached GitHub and read the list.
--- @return table next_state
function M.record_check(state, now, ok)
	local next_state = {}
	for _, entry in ipairs(STATE_FIELDS) do
		local field = entry[1]
		if state[field] ~= nil then next_state[field] = state[field] end
	end
	next_state.last_check_at = now
	if ok then
		next_state.last_success_at = now
		next_state.failures = 0
	else
		next_state.failures = (next_state.failures or 0) + 1
	end
	return next_state
end





-- ============================
-- ============================
-- ======= 4/ Due Time ========
-- ============================
-- ============================

--- Deterministic per-install jitter for one period.
--- @param seed string Install seed.
--- @param anchor number The last check time the period starts from.
--- @param interval number Interval in seconds.
--- @param timing table defaults.json timing.
--- @return number jitter Whole seconds in [0, span].
function M.jitter_seconds(seed, anchor, interval, timing)
	local span = math.min(math.floor(interval * timing.jitter_percent / 100), timing.jitter_max_sec)
	if span <= 0 then return 0 end
	local text = tostring(seed) .. ":" .. string.format("%d", anchor)
	local hash = 0
	for index = 1, #text do
		hash = (hash * HASH_MULTIPLIER + text:byte(index)) % HASH_MODULUS
	end
	return hash % (span + 1)
end

--- When the next automatic check is due.
--- @param input table { now, started_at, interval, state, timing }: times in
---   epoch seconds; started_at is the driver start or the last wake.
--- @return number|nil due_at Epoch seconds, or nil when never due.
--- @return string reason first_check, clock_moved_back, retry_after_failure,
---   scheduled, catch_up or never.
function M.next_due(input)
	local timing, state, interval = input.timing, input.state, input.interval
	if not (type(interval) == "number" and interval > 0) then return nil, "never" end
	local earliest = input.started_at + timing.boot_check_delay_sec
	local last = state.last_check_at
	if last == nil then return earliest, "first_check" end
	if last > input.now then return earliest, "clock_moved_back" end
	local failures = state.failures or 0
	local candidate, reason
	if failures > 0 then
		local backoff = timing.failure_backoff_sec
		candidate = last + math.min(backoff[math.min(failures, #backoff)], interval)
		reason = "retry_after_failure"
	else
		candidate = last + interval + M.jitter_seconds(state.seed or "", last, interval, timing)
		reason = "scheduled"
	end
	if candidate < earliest then return earliest, "catch_up" end
	return candidate, reason
end

--- Seconds to wait before re-evaluating: never past the due time, never
--- longer than reevaluate_sec (a timer that slept through a suspend is
--- corrected then).
--- @param due_at number Due time (epoch seconds).
--- @param now number Wall clock (epoch seconds).
--- @param timing table defaults.json timing.
--- @return number seconds
function M.delay_until(due_at, now, timing)
	return math.max(0, math.min(due_at - now, timing.reevaluate_sec))
end

return M
