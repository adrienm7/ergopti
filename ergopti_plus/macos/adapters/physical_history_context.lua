--- adapters/physical_history_context.lua

--- Borrows actual CaptureScope/CLOCK2 and freezes a native accepted calendar.
--- Default startup never loads this adapter or enables the dormant producer.
local M = {}
local Accepted = require("keylogger.physical_accepted_context")

local function native_function(value)
	return type(value) == "function" and debug.getinfo(value, "S").what == "C"
end
local function finite(value)
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end
local function information(value)
	assert(type(value) == "table" and getmetatable(value) == nil, "Missing accepted native timebase")
	local copy = { version = rawget(value, "version"), domain = rawget(value, "domain"),
		numer = rawget(value, "numer"), denom = rawget(value, "denom") }
	assert(copy.version == 1 and copy.domain == "mach_absolute_time", "Invalid accepted native clock domain")
	for _, scale in ipairs({ copy.numer, copy.denom }) do
		assert(finite(scale) and scale % 1 == 0 and scale >= 1 and scale <= 4294967295,
			"Invalid accepted native clock timebase")
	end
	assert(copy.numer and copy.denom, "Missing accepted native clock scale")
	return copy
end
local function methods(scope, names)
	assert(type(scope) == "table" and getmetatable(scope) == nil, "Missing actual accepted context scope")
	local result = {}
	for _, name in ipairs(names) do
		local method = rawget(scope, name)
		assert(type(method) == "function", "Missing accepted native scope port: " .. name)
		result[name] = method
	end
	return result
end

--- Creates only borrowed context ports; no second source bind, clock pull or start.
--- The single native History owner retains the actual scopes before clock_ready ACK.
--- Its validated clock metadata may be copied during ACK; pulls await publication.
--- Runtime/domain qualification and all native source admission remain caller-owned.
---@param owner table Exact owner of the already-retained CLOCK2 subscription.
---@param history table Actual PhysicalPermissionHistory created with these exact source tokens.
---@param scopes table Actual capture and clock capabilities already retained by that owner.
---@param clock_information table Copied native metadata from the real clock_ready callback.
---@return table|nil projection Direct PhysicalCapture context/context_interval ports.
---@return string|nil reason Refusal without native sampling or new ownership acquisition.
function M.new(owner, history, scopes, clock_information)
	assert(type(owner) == "table" and type(scopes) == "table", "Missing accepted native context owner")
	local capture = methods(rawget(scopes, "capture"), { "identity", "current", "admitted", "clock" })
	local clock = methods(rawget(scopes, "clock"), { "identity", "current", "read" })
	local policy = methods(history, { "resolve_interval", "retained_count", "stop" })
	local expected = information(clock_information)
	local root = rawget(_G, "hs")
	local timer = type(root) == "table" and rawget(root, "timer") or nil
	local absolute = type(timer) == "table" and rawget(timer, "absoluteTime") or nil
	local wall = type(timer) == "table" and rawget(timer, "secondsSinceEpoch") or nil
	local calendar = rawget(_G, "os")
	local date = type(calendar) == "table" and rawget(calendar, "date") or nil
	if not native_function(absolute) or not native_function(wall) or not native_function(date) then
		return nil, "accepted_native_calendar_unavailable"
	end
	local capture_token, clock_token = capture.identity(), clock.identity(owner)
	if type(capture_token) ~= "table" or type(clock_token) ~= "table" then
		return nil, "accepted_native_identity_unavailable"
	end
	local active, original_capture, original_convert = true, nil, nil
	local function invalidate()
		active = false
		policy.stop(capture_token)
		return false
	end
	local function same_binding()
		return rawequal(rawget(_G, "hs"), root) and rawequal(rawget(root, "timer"), timer)
			and rawequal(rawget(timer, "absoluteTime"), absolute) and rawequal(rawget(timer, "secondsSinceEpoch"), wall)
			and rawequal(rawget(_G, "os"), calendar) and rawequal(rawget(calendar, "date"), date)
	end
	local function current()
		if not active then return false end
		if not same_binding() or not rawequal(capture.identity(), capture_token)
			or not rawequal(clock.identity(owner), clock_token) then return invalidate() end
		if not active or clock.current(owner, clock_token) ~= true or capture.current(capture_token) ~= true then
			return invalidate()
		end
		local admitted = capture.admitted(capture_token)
		if not active then return false end
		if admitted == nil then
			if original_capture ~= nil then return invalidate() end
			return false
		end
		local observed, convert = capture.clock(capture_token)
		if not active then return false end
		if observed == nil then return false end
		if type(observed) ~= "table" or type(convert) ~= "function" then return invalidate() end
		for _, name in ipairs({ "version", "domain", "numer", "denom" }) do
			if rawget(observed, name) ~= expected[name] then return invalidate() end
		end
		if original_capture ~= nil and (admitted ~= original_capture or not rawequal(convert, original_convert)) then
			return invalidate()
		end
		if not same_binding() or clock.current(owner, clock_token) ~= true or capture.current(capture_token) ~= true
			or capture.admitted(capture_token) ~= admitted or not active then return invalidate() end
		original_capture, original_convert = admitted, convert
		return true
	end
	local function sample()
		assert(current(), "Accepted native context was revoked before reading")
		local at, reason = clock.read(owner, clock_token)
		assert(math.type(at) == "integer" and at >= 0, reason or "Invalid accepted native observation clock")
		assert(current(), "Accepted native context was revoked during reading")
		return at
	end
	local function accepted_calendar()
		assert(current(), "Accepted native context was revoked")
		local before = sample()
		local epoch = wall()
		assert(finite(epoch) and epoch >= 0, "Invalid accepted native wall sample")
		assert(current(), "Accepted native context was revoked during wall sampling")
		local rendered = date("%Y-%m-%d %H:%M:%S", math.floor(epoch))
		assert(type(rendered) == "string", "Invalid accepted native local calendar")
		assert(current(), "Accepted native context was revoked during local formatting")
		local timestamp = string.format("%s.%03d", rendered, math.floor((epoch % 1) * 1000))
		local after = sample()
		assert(after >= before and current(), "Accepted native calendar binding changed")
		return timestamp
	end
	return Accepted.new(owner, {
		current = current, revision = policy.retained_count,
		convert = function(ticks)
			assert(current(), "Accepted native capture is unavailable")
			local at = original_convert(ticks)
			assert(math.type(at) == "integer" and at >= 0 and current(), "Invalid accepted original native timestamp")
			return at
		end,
		resolve_interval = function(first, last)
			return policy.resolve_interval(capture_token, clock_token, first, last)
		end,
		calendar = accepted_calendar,
		on_refused = function() active = false; policy.stop(capture_token) end,
	})
end

return M
