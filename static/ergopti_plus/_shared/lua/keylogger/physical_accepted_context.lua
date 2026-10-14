--- _shared/lua/keylogger/physical_accepted_context.lua

--- Projects retained event permission and freezes the accepted press calendar.
local M = {}
local Lifetime = require("keylogger.physical_subscription_lifetime")

local function integral(value)
	return type(value) == "number" and value == value and value >= 0
		and value < math.huge and value % 1 == 0
end

--- Borrows the single history owner; this projection collects no new history.
---@param owner table Exact projection subscriber.
---@param dependencies table Captured convert, resolve_interval, calendar, current, revision and on_refused ports.
---@return table projection Capture context/context_interval and exact subscription retirement.
function M.new(owner, dependencies)
	assert(type(owner) == "table" and type(dependencies) == "table", "Missing accepted context owner")
	local ports = {}
	for _, name in ipairs({ "convert", "resolve_interval", "calendar", "current", "revision", "on_refused" }) do
		assert(type(dependencies[name]) == "function", "Missing accepted context port: " .. name)
		ports[name] = dependencies[name]
	end
	local token = {}
	local lifetime = Lifetime.new(owner, token)
	local authority = lifetime.capability()
	-- Public capability observations are mutable; admission keeps the original closure.
	local authority_current = authority.current
	local projection, busy, notified = {}, false, false
	lifetime.bind_detach(function() lifetime.detach(); return true end)
	local function current()
		return ports.current() == true and authority_current(owner, token)
	end
	local function refuse(reason)
		lifetime.revoke()
		if not notified then
			notified = true
			lifetime.run(function() pcall(ports.on_refused, reason) end)
		end
	end
	local function revision()
		local count = ports.revision()
		assert(integral(count), "Invalid accepted context history revision")
		return count
	end
	local function convert(ticks)
		local at = ports.convert(ticks)
		assert(integral(at), "Invalid accepted context original timestamp")
		return at
	end
	local function run(operation, ...)
		if not authority_current(owner, token) then return { allowed = false } end
		if busy then refuse("Accepted context reentered"); return { allowed = false } end
		local frame = lifetime.enter()
		assert(frame, "Accepted context lost source-frame ownership")
		busy = true
		local ok, result = pcall(operation, ...)
		if not ok then refuse(result) end
		busy = false
		assert(lifetime.leave(frame), "Accepted context frame already released")
		if not ok then error(result, 0) end
		if not authority_current(owner, token) then return { allowed = false } end
		return result
	end

	--- Selects original app/privacy before sampling the genuine acceptance calendar.
	--- Denied events never call calendar; accepted dates never extrapolate old ticks.
	---@param ticks string Original native ticks, unchanged by delivery time.
	---@return table context Copied original app and accepted date, or allowed=false.
	function projection.context(ticks)
		return run(function()
			if not current() then return { allowed = false } end
			local before = revision()
			if not current() then return { allowed = false } end
			local at = convert(ticks)
			if not current() then return { allowed = false } end
			local decision = ports.resolve_interval(at, at)
			if not current() or decision.allowed ~= true then return { allowed = false } end
			assert(type(decision.app) == "table" and type(decision.app.name) == "string"
				and decision.app.name ~= "", "Missing original accepted context application")
			local app = decision.app.name
			local accepted = ports.calendar()
			if not current() or revision() ~= before or not current() then return { allowed = false } end
			local confirmed = ports.resolve_interval(at, at)
			if not current() or revision() ~= before or not current() or confirmed.allowed ~= true or confirmed.app.name ~= app then
				return { allowed = false }
			end
			assert(type(accepted) == "string" and accepted:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d%.%d%d%d$"),
				"Invalid accepted context calendar")
			return { allowed = true, app = app, timestamp = accepted }
		end)
	end

	--- Resolves the entire original hold; Delivery owns its frozen initial date.
	---@return table decision Permission only; no release-time calendar query.
	function projection.context_interval(first_ticks, last_ticks)
		return run(function()
			if not current() then return { allowed = false } end
			local before = revision()
			if not current() then return { allowed = false } end
			local first = convert(first_ticks)
			if not current() then return { allowed = false } end
			local last = convert(last_ticks)
			if not current() then return { allowed = false } end
			local decision = ports.resolve_interval(first, last)
			if not current() or revision() ~= before or not current() then return { allowed = false } end
			return { allowed = decision.allowed == true }
		end)
	end

	--- Revokes projection only; borrowed history/native owners retain their debt.
	function projection.stop() lifetime.revoke() end

	--- This token names projection frames, never a native clock/capture domain.
	function projection.subscription() return authority end
	return projection
end

return M
