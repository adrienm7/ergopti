--- adapters/physical_observation_clock.lua

--- Exposes raw host samples and owns one explicit borrowed API subscription.
local M = {}
local native = hs
local Lifetime = require("keylogger.physical_subscription_lifetime")
local subscription
local getter_frames = 0

local function valid_sample(observed_ns)
	return math.type(observed_ns) == "integer" and observed_ns >= 0
end

local function legacy_sample()
	assert(native and native.timer and type(native.timer.absoluteTime) == "function",
		"Missing native observation clock")
	local observed_ns = native.timer.absoluteTime()
	assert(valid_sample(observed_ns), "Invalid native observation clock representation")
	return observed_ns
end

--- Reads strict legacy time while unbound, or the exact captured API while bound.
---@return integer observed_ns Raw nanoseconds, without clock-domain qualification.
function M.now()
	if subscription and subscription.retired() then
		subscription = nil
	end
	if subscription then
		local observed_ns, reason = subscription.read(subscription.owner, subscription.token)
		if observed_ns == nil then error(reason, 0) end
		return observed_ns
	end
	getter_frames = getter_frames + 1
	local ok, observed_ns = pcall(legacy_sample)
	getter_frames = getter_frames - 1
	if not ok then error(observed_ns, 0) end
	return observed_ns
end



--- Captures one actual host API binding without reading time or granting admission.
---@param owner table Exact subscriber owner, unrelated to native clock provenance.
---@return table|nil capability Exact binding and completed getter-frame observations.
---@return string|nil reason Typed acquisition refusal, if no subscription was bound.
function M.bind_history_scope(owner)
	assert(type(owner) == "table", "Invalid observation clock owner")
	if getter_frames > 0 then return nil, "clock_getter_inflight" end
	if subscription then
		if not subscription.retired() then
			return nil, "clock_subscription_busy"
		end
		subscription = nil
	end
	local root = rawget(_G, "hs")
	local timer = type(root) == "table" and rawget(root, "timer") or nil
	local getter = type(timer) == "table" and rawget(timer, "absoluteTime") or nil
	if type(getter) ~= "function" then return nil, "clock_binding_unavailable" end
	local token = {}
	local lifetime = Lifetime.new(owner, token)
	local authority = lifetime.capability()
	local register_hint = authority.on_retired
	local capability = {}
	local detached, reading = false, false
	local function same_binding()
		return rawequal(rawget(_G, "hs"), root)
			and rawequal(rawget(root, "timer"), timer)
			and rawequal(rawget(timer, "absoluteTime"), getter)
	end
	local function exact(candidate_owner, candidate_token)
		return rawequal(candidate_owner, owner) and rawequal(candidate_token, token)
	end
	local function refusal()
		if detached then return "clock_subscription_detached" end
		return "clock_subscription_revoked"
	end
	lifetime.bind_detach(function(candidate_owner, candidate_token)
		if not exact(candidate_owner, candidate_token) then return false end
		detached = true
		lifetime.detach()
		return true
	end)


	--- Returns only this original source binding identity, including after retirement.
	---@param candidate_owner table Exact original subscriber.
	---@return table|nil token Source-minted binding token, never a native domain descriptor.
	function capability.identity(candidate_owner) return authority.identity(candidate_owner) end

	--- Fences the actual API binding without querying or stopping its borrowed clock.
	---@param candidate_owner table Exact original subscriber.
	---@param candidate_token table Exact original binding token.
	---@return boolean current Whether this binding still admits owned reads.
	function capability.current(candidate_owner, candidate_token)
		if not authority.current(candidate_owner, candidate_token) then return false end
		if not same_binding() then lifetime.revoke(); return false end
		return true
	end

	--- Retains the real getter frame and refuses swaps, reentry or lost representation.
	---@param candidate_owner table Exact original subscriber.
	---@param candidate_token table Exact original binding token.
	---@return integer|nil observed_ns Exact native integer sample, or nil on refusal.
	---@return string|nil reason Typed read refusal; native raised objects remain errors.
	function capability.read(candidate_owner, candidate_token)
		if not exact(candidate_owner, candidate_token) then return nil, "clock_identity_refused" end
		if not authority.current(owner, token) then return nil, refusal() end
		if not same_binding() then lifetime.revoke(); return nil, "clock_binding_changed" end
		if reading then lifetime.revoke(); return nil, "clock_reentrant_read" end
		local frame = lifetime.enter()
		assert(frame, "Observation clock lost source-frame ownership")
		reading, getter_frames = true, getter_frames + 1
		local ok, observed_ns = pcall(getter)
		local reason
		if not ok then
			lifetime.revoke()
		elseif not same_binding() then
			lifetime.revoke(); reason = "clock_binding_changed"
		elseif not authority.current(owner, token) then
			reason = refusal()
		elseif not valid_sample(observed_ns) then
			lifetime.revoke(); ok = false; observed_ns = "Invalid native observation clock representation"
		end
		reading, getter_frames = false, getter_frames - 1
		assert(lifetime.leave(frame), "Observation clock source frame was already released")
		if not ok then error(observed_ns, 0) end
		if reason then return nil, reason end
		return observed_ns
	end

	--- Detaches only this subscription, never the borrowed host timer or machine clock.
	---@param candidate_owner table Exact original subscriber.
	---@param candidate_token table Exact original binding token.
	---@return boolean detached Whether the actual exact-owner detach was acknowledged.
	function capability.detach(candidate_owner, candidate_token)
		return authority.detach(candidate_owner, candidate_token)
	end

	--- Observes exact subscription detach plus completion of every held getter frame.
	---@param candidate_owner table Exact original subscriber.
	---@param candidate_token table Exact original binding token.
	---@return boolean retired Whether this subscription has no remaining getter debt.
	function capability.retired(candidate_owner, candidate_token)
		return authority.retired(candidate_owner, candidate_token)
	end
	--- Forwards only exact subscription completion, not host clock retirement.
	function capability.on_retired(candidate_owner, candidate_token, callback)
		return register_hint(candidate_owner, candidate_token, callback)
	end
	subscription = { owner = owner, token = token, read = capability.read,
		retired = function() return authority.retired(owner, token) end }
	return capability
end

return M
