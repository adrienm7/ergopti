--- _shared/lua/updater/transfer_budget.lua

--- Pure updater transfer admission. Captured phase caps cannot be extended by
--- changing defaults, redirecting, selecting another relay or retiring a child.
local M = {}
local records = setmetatable({}, { __mode = "k" })
local names = { "checksum", "archive", "hash" }
local MAX_INTEGER = 9007199254740991

local function time(value)
	return type(value) == "number" and value == value and value >= 0
		and value <= MAX_INTEGER
end

local function integer(value)
	return time(value) and value % 1 == 0
end

local function observation(record, now)
	if record.retired or not time(now) or now < record.last_now then return false end
	record.last_now = now
	return now < record.deadline
end

--- Captures canonical caps and the original admission time without OS ports.
--- @param defaults table Decoded canonical updater defaults.
--- @param now number Original native monotonic milliseconds.
--- @return table|nil token Private immutable transfer identity.
function M.capture(defaults, now)
	if type(defaults) ~= "table" or not time(now) then return nil end
	local policy = rawget(defaults, "archive_transfer")
	if type(policy) ~= "table" or rawget(policy, "schema_version") ~= 1 then return nil end
	local phases = rawget(policy, "phase_timeout_ms")
	if type(phases) ~= "table" then return nil end
	local caps, total = {}, 0
	for _, name in ipairs(names) do
		local cap = rawget(phases, name)
		if not integer(cap) or cap == 0 or total > MAX_INTEGER - cap then return nil end
		caps[name], total = cap, total + cap
	end
	if now > MAX_INTEGER - total then return nil end
	local token = {}
	records[token] = { caps = caps, deadline = now + total, last_now = now,
		phase = 0, phase_deadline = nil, retired = false }
	return token
end

--- Starts each ordered phase once. Reentering the same phase retains its bound.
--- @param token table
--- @param name string checksum, archive or hash.
--- @param now number Fresh native monotonic milliseconds.
--- @return number|nil deadline Original total bound capped by first phase start.
function M.enter(token, name, now)
	local record = records[token]
	if not record or not observation(record, now) then return nil end
	local index
	for i, candidate in ipairs(names) do if name == candidate then index = i end end
	if not index then return nil end
	if index == record.phase then
		return now < record.phase_deadline and record.phase_deadline or nil
	end
	if index ~= record.phase + 1 or (record.phase_deadline and now >= record.phase_deadline) then return nil end
	local cap = record.caps[name]
	-- Total admission already bounds the addition; avoid an overflowing phase
	-- sum even when the canonical cap exceeds the remaining total budget.
	local remaining = record.deadline - now
	record.phase, record.phase_deadline = index, now + math.min(cap, remaining)
	return record.phase_deadline
end

--- Rechecks the exact active phase; never starts or extends it.
--- @param token table
--- @param name string
--- @param now number
--- @return boolean
function M.admit(token, name, now)
	local record = records[token]
	if not record or not observation(record, now) then return false end
	return record.phase > 0 and name ~= nil and names[record.phase] == name
		and now < record.phase_deadline
end

--- Reads the captured total lifetime for owned native resource retirement.
--- @param token table
--- @return number|nil
function M.deadline(token)
	local record = records[token]
	return record and not record.retired and record.deadline or nil
end

--- Revokes publication/dispatch consent without claiming native settlement.
--- @param token table
--- @return boolean
function M.retire(token)
	local record = records[token]
	if not record then return false end
	record.retired = true
	return true
end

return M
