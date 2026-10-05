--- _shared/lua/dynamic_hotstrings/user_scope.lua

--- ==============================================================================
--- MODULE: Programmable Hotstring Configuration Inverse
--- DESCRIPTION:
--- Retains publication closures and native lifecycle identity while configuration
--- transactions adopt scalar controls. An operation returns its own revision even
--- on refusal; a nested foreign mutation cannot become a scope's accepted inverse.
--- ==============================================================================

local M = {}

--- Constructs one native facade's configuration revision and inverse owner.
--- @param ports table Native identity, source, policy, scalar and restoration ports.
--- @return table scope Configuration token, capture, adopt and restore operations.
function M.new(ports)
	local scope, revision = {}, {}
	function scope.begin() revision = {}; return revision end
	function scope.current(token) return token == revision end
	function scope.revision() return revision end
	function scope.capture()
		local token = revision
		local identity, native = ports.identity()
		if identity == nil then return nil end
		local policy = ports.policy()
		local source = ports.read_source()
		local snapshot = { identity = identity, native = native, source = source, policy = policy,
			seconds = ports.seconds(), enabled = ports.enabled(), desired = ports.desired(), expected = token }
		if source == nil or source.present ~= true then
			if policy.ready ~= false or policy.enabled ~= false
				or snapshot.enabled ~= false or ports.quiescent() ~= true then return nil end
			if source == nil then snapshot.source = { unavailable = true } end
			snapshot.closed_only = true
			snapshot.policy.ready, snapshot.policy.enabled = false, false
		end
		if policy.ready == true and (policy.source == nil or source == nil
			or policy.source.path ~= source.path or policy.source.present ~= source.present
			or policy.source.content ~= source.content or ports.source_current(policy.source) ~= true) then return nil end
		if snapshot.closed_only and (ports.enabled() ~= false or ports.quiescent() ~= true
			or ports.policy().ready ~= false) then return nil end
		local latest, latest_native = ports.identity()
		if not scope.current(token) or latest ~= identity or latest_native ~= native then return nil end
		return snapshot
	end
	local function owns(snapshot)
		local identity, native = ports.identity()
		if type(snapshot) ~= "table" or snapshot.identity ~= identity or snapshot.native ~= native
			or snapshot.expected ~= revision then return false end
		if snapshot.closed_only then
			local policy = ports.policy()
			if snapshot.enabled ~= false or ports.enabled() ~= false or policy.enabled ~= false
				or policy.ready ~= false or ports.quiescent() ~= true then return false end
		end
		if snapshot.source.unavailable then
			if snapshot.closed_only ~= true then return false end
		elseif ports.source_current(snapshot.source) ~= true then return false end
		local latest, latest_native = ports.identity()
		return snapshot.expected == revision and latest == identity and latest_native == native
	end
	local function mutate(snapshot, operation, value)
		local acknowledged, token = operation(value)
		if type(token) ~= "table" then return false end
		snapshot.expected = token
		return acknowledged == true and scope.current(token)
	end
	function scope.adopt(snapshot, seconds, enabled)
		if not owns(snapshot) then return false end
		if snapshot.closed_only and enabled ~= false then return false end
		if not mutate(snapshot, ports.set_seconds, seconds) then return false end
		if not owns(snapshot) then return false end
		return mutate(snapshot, ports.set_enabled, enabled)
	end
	function scope.current_snapshot(snapshot) return owns(snapshot) end
	function scope.restore(snapshot)
		if not owns(snapshot) then return false end
		local token = scope.begin()
		snapshot.expected = token
		return ports.restore(snapshot, token) == true and scope.current(token)
	end
	return scope
end

return M
