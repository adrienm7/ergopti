--- _shared/lua/keylogger/physical_lease_policy.lua

--- Normalizes bounded lease decisions; actual sources and event timers stay native-owned.
local M = {}
local Lifetime = require("keylogger.physical_subscription_lifetime")

function M.new(owner, ports)
	assert(type(owner) == "table" and type(ports) == "table", "Missing physical lease policy owner")
	local source_current, lease_identity, source_retired = rawget(ports, "current"), rawget(ports, "lease_identity"), rawget(ports, "retired")
	assert(type(source_current) == "function" and type(lease_identity) == "function"
		and type(source_retired) == "function", "Missing physical lease policy ports")
	local token, policy = {}, {}
	local life = Lifetime.new(owner, token)
	local authority = life.capability()
	local actual_current = authority.current
	local state, request, native, retries, pending, busy = "prepared", nil, nil, 0, nil, false
	life.bind_detach(function(candidate_owner, candidate_token)
		if not rawequal(candidate_owner, owner) or not rawequal(candidate_token, token) then return false end
		state = "stopped"; life.detach(); return true
	end)
	local function revoke()
		state = "terminal"; life.revoke()
	end
	local function owned()
		return actual_current(owner, token) and state ~= "terminal" and state ~= "stopped"
	end
	local function fence()
		if not owned() then return false end
		local ok, current = pcall(source_current)
		if not ok or current ~= true or not owned() then revoke(); return false end
		return true
	end
	local function exact(candidate_owner, candidate_request)
		return rawequal(candidate_owner, owner) and rawequal(candidate_request, request)
	end
	local function operate(operation)
		if busy or not owned() then revoke(); return nil, "policy_source_refused" end
		busy = true
		local results = { life.run(function()
			if not fence() then return nil, "policy_source_refused" end
			return operation()
		end) }
		busy = false
		return results[1], results[2]
	end
	local function captured_identity(candidate_native)
		if type(candidate_native) ~= "table" then return false end
		if native ~= nil and not rawequal(native, candidate_native) then return false end
		if not fence() then return false end
		local ok, actual = pcall(lease_identity)
		if not ok or not fence() then revoke(); return false end
		return rawequal(actual, candidate_native)
	end
	local function event(candidate_owner, candidate_request, expected, operation)
		if not rawequal(candidate_owner, owner) then return nil, "policy_identity_refused" end
		if not exact(candidate_owner, candidate_request) or state ~= expected then return nil, "policy_event_refused" end
		return operate(operation)
	end

	function policy.begin(candidate_owner)
		if not rawequal(candidate_owner, owner) then return nil, "policy_identity_refused" end
		if state ~= "prepared" then return nil, "policy_not_prepared" end
		return operate(function()
			request, native, pending, state = {}, nil, nil, "starting"
			return request
		end)
	end
	function policy.captured(candidate_owner, candidate_request, candidate_native)
		if not exact(candidate_owner, candidate_request) or (state ~= "starting" and state ~= "admitted") then return false end
		local accepted = operate(function()
			if not captured_identity(candidate_native) then return false end
			native = candidate_native
			return true
		end)
		return accepted == true
	end
	function policy.admitted(candidate_owner, candidate_request, candidate_native)
		return event(candidate_owner, candidate_request, "starting", function()
			if native == nil or not captured_identity(candidate_native) then return nil, "policy_event_refused" end
			state = "admitted"
			return { action = "arm_rotation", delay = 600 }
		end)
	end
	function policy.verdict(candidate_owner, candidate_request, record)
		if not rawequal(candidate_owner, owner) then return nil, "policy_identity_refused" end
		if not exact(candidate_owner, candidate_request) or (state ~= "starting" and state ~= "admitted")
			or type(record) ~= "table" or getmetatable(record) ~= nil then return nil, "policy_event_refused" end
		local fields = { state = true, reason = true, retryable = true, lease_token = true }
		for key in pairs(record) do if not fields[key] then return nil, "policy_event_refused" end end
		local verdict_state, reason, retryable, lease_token = record.state, record.reason, record.retryable, record.lease_token
		local recognized = retryable == true and ((verdict_state == "lost" and
			(reason == "overflow" or reason == "sequence_exhausted")) or
			(verdict_state == "interrupted" and reason == "interrupted"))
		local terminal = retryable == false and (verdict_state == "unavailable" or verdict_state == "failed")
			and type(reason) == "string" and reason ~= ""
		if not recognized and not terminal then return nil, "policy_event_refused" end
		return operate(function()
			if native == nil or not captured_identity(lease_token) then return nil, "policy_event_refused" end
			local retry = recognized and retries < 3
			if retry then retries = retries + 1; pending = { delay = ({ 1, 2, 4 })[retries] }
			else pending = { terminal = true } end
			state = "retiring"
			return { action = "retire", retryable = retry }
		end)
	end
	function policy.rotate(candidate_owner, candidate_request)
		return event(candidate_owner, candidate_request, "admitted", function()
			pending, state = { rotation = true }, "retiring"
			return { action = "retire", retryable = false, rotation = true }
		end)
	end
	function policy.continue(candidate_owner, candidate_request)
		return event(candidate_owner, candidate_request, "retiring", function()
			local ok, retired = pcall(source_retired, request)
			if not ok or not fence() then revoke(); return nil, "policy_source_refused" end
			if retired ~= true then return nil, "policy_retirement_pending" end
			if pending.rotation then state = "prepared"; return { action = "start" } end
			if pending.terminal then state = "terminal"; life.revoke(); return { action = "deny" } end
			state = "waiting"
			return { action = "retry", delay = pending.delay }
		end)
	end
	function policy.retry_ready(candidate_owner, candidate_request)
		return event(candidate_owner, candidate_request, "waiting", function()
			state = "prepared"; return { action = "start" }
		end)
	end
	function policy.stop(candidate_owner)
		if not rawequal(candidate_owner, owner) then return false end
		state = "stopped"; life.revoke(); return true
	end
	function policy.subscription() return authority end
	function policy.status() return { state = state, retries = retries } end
	return policy
end

return M
