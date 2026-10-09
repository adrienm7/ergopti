--- ui/tooltip/dequeue.lua
---
--- Lua port of _shared/modules/tooltip/dequeue.js — stacked hotstring row expiry logic.
--- Keep in sync with the JS reference; contract tests live in
--- tests/unit/ui/test_tooltip_dequeue_contract.lua.

local M = {}

-- Sentinel 0 (not the real 0.2 / 0.05): every caller passes the decrement/floor
-- from the shared-loaded tooltip config (ui/tooltip/config.lua M.timing). These
-- defaults only apply if `opts` is missing — and a 0 there makes that omission
-- show as no decrement/floor (an obvious symptom) instead of being masked by a
-- plausible hardcoded value. MIN_TIMER_SEC is a genuine local floor, not a
-- shared value, so it keeps its real value.
local DEFAULT_TIMEOUT_DECREMENT_SEC = 0
local DEFAULT_TIMEOUT_FLOOR_SEC = 0
local MIN_TIMER_SEC = 0.05

--- @param opts table|nil
--- @return number, number decrement and floor (seconds)
local function timing_opts(opts)
	opts = opts or {}
	return opts.timeout_decrement_sec or DEFAULT_TIMEOUT_DECREMENT_SEC,
		opts.timeout_floor_sec or DEFAULT_TIMEOUT_FLOOR_SEC
end

--- Shortens a caller duration by the shared decrement, with a hard floor.
--- @param caller_duration_sec number
--- @param opts table|nil
--- @return number
function M.effective_duration_sec(caller_duration_sec, opts)
	local dec, floor = timing_opts(opts)
	if not (type(caller_duration_sec) == "number" and caller_duration_sec > 0) then
		return 0
	end
	return math.max(floor, caller_duration_sec - dec)
end

--- @param row table
--- @param field string|nil
--- @return number
local function row_duration_sec(row, field)
	field = field or "duration"
	local d = row[field]
	if type(d) == "number" and d > 0 then return d end
	return 0
end

--- @param row table
--- @param expire_field string
--- @return boolean
local function has_expiry_stamp(row, expire_field)
	local v = row[expire_field]
	return v ~= nil and v ~= 0
end

--- @param rows table
--- @param opts table|nil
--- @return boolean, boolean, boolean is_rebuild, has_any_dur, has_mixed_dur
function M.analyze_durations(rows, opts)
	opts = opts or {}
	local duration_field = opts.duration_field or "duration"
	local expire_field = opts.expire_field or "expire_at"

	local is_rebuild = false
	for _, row in ipairs(rows) do
		if has_expiry_stamp(row, expire_field) then
			is_rebuild = true
			break
		end
	end

	local first_dur, has_any_dur, has_mixed_dur = nil, false, false
	if not is_rebuild then
		for _, row in ipairs(rows) do
			local d = row_duration_sec(row, duration_field)
			if d > 0 then
				has_any_dur = true
				if first_dur == nil then
					first_dur = d
				elseif d ~= first_dur then
					has_mixed_dur = true
				end
			end
		end
	end

	return is_rebuild, has_any_dur, has_mixed_dur
end

--- @param rows table
--- @param opts table|nil
--- @return boolean
function M.should_use_dequeue_path(rows, opts)
	local is_rebuild, has_any_dur, has_mixed_dur = M.analyze_durations(rows, opts)
	return is_rebuild or (has_any_dur and has_mixed_dur)
end

--- Stamps absolute expiry timestamps (seconds since epoch) on row copies.
--- @param rows table
--- @param now_sec number
--- @param opts table|nil
--- @return table stamped_rows, number|nil next_expire_sec
function M.stamp_expiry_times(rows, now_sec, opts)
	opts = opts or {}
	local duration_field = opts.duration_field or "duration"
	local expire_field = opts.expire_field or "expire_at"
	local is_rebuild = M.analyze_durations(rows, opts)

	local stamped = {}
	local next_expire = nil

	for _, row in ipairs(rows) do
		local copy = {}
		for k, v in pairs(row) do copy[k] = v end

		local expire_at
		if is_rebuild and has_expiry_stamp(copy, expire_field) then
			expire_at = copy[expire_field]
		else
			local d = row_duration_sec(row, duration_field)
			if d > 0 then
				expire_at = now_sec + M.effective_duration_sec(d, opts)
			else
				expire_at = nil
			end
		end

		copy[expire_field] = expire_at
		table.insert(stamped, copy)

		if expire_at and (not next_expire or expire_at < next_expire) then
			next_expire = expire_at
		end
	end

	return stamped, next_expire
end

--- @param rows table
--- @param now_sec number
--- @param opts table|nil
--- @return table
function M.prune_expired(rows, now_sec, opts)
	opts = opts or {}
	local expire_field = opts.expire_field or "expire_at"
	local remaining = {}
	for _, row in ipairs(rows) do
		local exp = row[expire_field]
		-- Keep the row when: exp is nil/false (never set), exp == 0 (explicit
		-- "never expires" sentinel — consistent with has_expiry_stamp()), or
		-- the deadline has not yet passed.
		if not exp or exp == 0 or now_sec < exp then
			table.insert(remaining, row)
		end
	end
	return remaining
end

--- Seconds until the earliest not-yet-expired row deadline.
--- @param rows table
--- @param now_sec number
--- @param opts table|nil
--- @return number
function M.next_expiry_delay_sec(rows, now_sec, opts)
	opts = opts or {}
	local expire_field = opts.expire_field or "expire_at"
	local earliest = nil
	for _, row in ipairs(rows) do
		local exp = row[expire_field]
		if exp and now_sec < exp then
			if not earliest or exp < earliest then earliest = exp end
		end
	end
	if not earliest then return 0 end
	return math.max(MIN_TIMER_SEC, earliest - now_sec)
end

return M