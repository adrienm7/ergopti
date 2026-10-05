--- _shared/lua/keylogger/physical_configuration_observation.lua

--- Bounded configuration receipts only; native context and capture are separate owners.
local M = {}

--- Shared numeric values must be finite and integral on both Lua54 and LuaJIT.
local function integral(value)
	return type(value) == "number" and value > -math.huge and value < math.huge and value % 1 == 0
end

--- Validates a complete ordered application array before any writer commits.
local function copy_selectors(apps)
	assert(type(apps) == "table" and getmetatable(apps) == nil, "Invalid physical disabled applications")
	local count, result = 0, {}
	for key in pairs(apps) do
		assert(integral(key) and key >= 1, "Invalid physical application array")
		count = count + 1
	end
	for index = 1, count do
		local app = apps[index]
		assert(type(app) == "table" and getmetatable(app) == nil, "Invalid physical application selector")
		local copy = {}
		for _, field in ipairs({ "bundleID", "appPath" }) do
			local value = app[field]
			assert(value == nil or type(value) == "string", "Invalid physical application selector: " .. field)
			copy[field] = value
		end
		result[index] = copy
	end
	return result
end

--- Copies policy selectors without emitting display labels, app context or input data.
---@param configuration table Native privacy filter configuration.
---@return table snapshot Detached filter values only.
function M.copy(configuration)
	assert(type(configuration) == "table" and getmetatable(configuration) == nil,
		"Invalid physical filter configuration")
	local snapshot = {}
	for _, field in ipairs({ "private_filter_enabled", "secure_field_filter_enabled", "system_auth_filter_enabled" }) do
		assert(type(configuration[field]) == "boolean", "Invalid physical filter: " .. field)
		snapshot[field] = configuration[field]
	end
	snapshot.disabled_apps = copy_selectors(configuration.disabled_apps)
	return snapshot
end

--- Copies a complete caller candidate before any foreign posture operation.
---@param candidate any Caller-owned plain configuration data.
---@return any owned Independent plain data without callable metamethods.
function M.own_data(candidate)
	local visiting = {}
	local function copy(value)
		local kind = type(value)
		if kind ~= "table" then
			assert(kind == "nil" or kind == "string" or kind == "boolean" or kind == "number",
				"Invalid physical configuration data")
			return value
		end
		assert(getmetatable(value) == nil and not visiting[value], "Physical configuration must be plain and acyclic")
		visiting[value] = true
		local result = {}
		for key, child in next, value do
			assert(type(key) == "string" or type(key) == "number", "Invalid physical configuration key")
			result[key] = copy(child)
		end
		visiting[value] = nil
		return result
	end
	return copy(candidate)
end

--- Owns and validates policy selectors before an actual bound writer assigns them.
---@param apps table Caller-owned disabled application data, including local labels.
---@return table owned Independent, validated application configuration.
function M.own_apps(apps)
	local owned = M.own_data(apps)
	copy_selectors(owned)
	return owned
end

--- Creates an explicitly owned bounded receipt channel, without permission history.
---@param capacity integer Maximum acknowledged observations before explicit replacement.
---@param clock function Raw native nanosecond reader, never a rebased or wall clock.
---@param receive function Receives one copied record; exact true acknowledges it.
---@param on_refused function Receives one terminal reason after authority is revoked.
---@return table channel publish and close ports for this exact subscription.
function M.new(capacity, clock, receive, on_refused)
	assert(integral(capacity) and capacity > 0, "Invalid physical observation budget")
	assert(type(clock) == "function" and type(receive) == "function" and type(on_refused) == "function",
		"Missing physical configuration observation ports")
	local active, publishing, revision, previous = true, false, 0, nil
	local channel = {}
	local function refuse(reason)
		if active then
			active = false
			pcall(on_refused, reason)
		end
		return false, reason
	end

	--- Revokes callbacks before the exact caller detaches the subscription.
	function channel.close() active = false; return true end

	--- Publishes a copied complete filter transaction after its writer commits.
	---@param configuration table Native filter values, without permission authority.
	---@return boolean acknowledged False retires this channel until exact detach.
	function channel.publish(configuration)
		if not active then return false, "Physical configuration subscription is retired" end
		if publishing then return refuse("Physical configuration observation reentered") end
		if revision >= capacity then return refuse("Physical configuration observation budget exhausted") end
		publishing = true
		local ok, record = pcall(function()
			local snapshot = M.copy(configuration)
			local observed_ns = clock()
			assert(integral(observed_ns) and observed_ns >= 0,
				"Invalid native observation clock representation")
			assert(not previous or observed_ns > previous, "Physical configuration observations are not ordered")
			snapshot.kind, snapshot.revision, snapshot.at = "physical_configuration", revision + 1, observed_ns
			return snapshot
		end)
		if not ok then publishing = false; return refuse(tostring(record)) end
		if not active then publishing = false; return false, "Physical configuration subscription was revoked" end
		local observed_ns = record.at
		local delivered, accepted = pcall(receive, record)
		publishing = false
		if not active then return false, "Physical configuration subscription was revoked" end
		if not delivered or accepted ~= true then return refuse("Physical configuration subscriber refused observation") end
		revision, previous = revision + 1, observed_ns
		return true
	end
	return channel
end

return M
