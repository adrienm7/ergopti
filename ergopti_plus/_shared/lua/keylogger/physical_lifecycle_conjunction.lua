--- _shared/lua/keylogger/physical_lifecycle_conjunction.lua

--- Combines exact engine/system writer facts without granting history permission.
local M = {}
local MAX_RECEIPTS, MAX_EXACT_DOUBLE = 4096, 9007199254740991
local number_type = math.type
local DOMAINS = { "engine", "system" }
local POSTURE = { "system_awake", "screen_awake", "unlocked" }
local EVENT_FACTS = {
	system_sleep = { "system_awake", false }, system_wake = { "system_awake", true },
	screens_sleep = { "screen_awake", false }, screens_wake = { "screen_awake", true },
	lock = { "unlocked", false }, unlock = { "unlocked", true },
}
local SOURCES = {
	engine = { binding = true, initial_snapshot = true, start = true, stop = true, shutdown = true, resync = true },
	system = { binding = true, initial_snapshot = true, initialization = true, hardware_start = true, hardware_stop = true,
		system_sleep = true, system_wake = true, screens_sleep = true, screens_wake = true,
		lock = true, unlock = true, unknown_event = true },
}
local function integer(value)
	if type(value) ~= "number" or value < 0 or value ~= value or value == math.huge then return false end
	if type(number_type) == "function" then return number_type(value) == "integer" end
	return value <= MAX_EXACT_DOUBLE and value % 1 == 0
end
local function plain(value) return type(value) == "table" and getmetatable(value) == nil end
local function copy_scalars(value)
	local result = {}
	for key, field in next, value do result[key] = field end
	return result
end
local function unknown_posture()
	local result = {}
	for _, component in ipairs(POSTURE) do result[component] = { qualification = "unknown" } end
	return result
end
local function copy_posture(value)
	local result = {}
	for _, component in ipairs(POSTURE) do result[component] = copy_scalars(value[component]) end
	return result
end

--- Creates a two-prefix transducer over actual independently owned subscriptions.
--- Construction captures methods but makes no native query or permission claim.
---@param sources table Engine/system exact owner, token and actual subscription scope.
---@param capacity number Maximum accepted receipts per source without rebuilding state.
---@param receive function Copied aggregate facts consumer, accepting literal true.
---@param on_refused function Once-only notification after authority is revoked.
---@return table owner Exact receipts and joint subscription retirement ports.
function M.new(sources, capacity, receive, on_refused)
	assert(plain(sources) and integer(capacity) and capacity > 0 and capacity <= MAX_RECEIPTS,
		"Invalid lifecycle conjunction sources or capacity")
	assert(type(receive) == "function" and type(on_refused) == "function", "Missing lifecycle conjunction ports")
	local bindings, state, pending = {}, {}, {}
	for _, domain in ipairs(DOMAINS) do
		local source = rawget(sources, domain)
		assert(plain(source) and plain(source.owner) and plain(source.token) and plain(source.scope),
			"Missing exact lifecycle subscription: " .. domain)
		local binding = { owner = source.owner, token = source.token }
		for _, method in ipairs({ "identity", "current", "detach", "retired" }) do
			local port = rawget(source.scope, method)
			assert(type(port) == "function", "Missing lifecycle subscription port: " .. method)
			binding[method] = port
		end
		bindings[domain], state[domain] = binding, { revision = 0, writer_complete = false }
	end
	local owner, posture = {}, unknown_posture()
	local system_generation
	local active, busy, retired, retirement_reentered = true, false, false, false
	local function refuse(reason)
		if active then
			active = false
			local was_busy = busy
			busy = true
			pcall(on_refused, reason)
			busy = was_busy
		end
		return false
	end
	local function current()
		for _, domain in ipairs(DOMAINS) do
			local binding = bindings[domain]
			local known, identity = pcall(binding.identity, binding.owner)
			if not active or not known or not rawequal(identity, binding.token) then return refuse("Lifecycle source identity changed") end
			local ok, accepted = pcall(binding.current, binding.owner, binding.token)
			if not active or not ok or accepted ~= true then return refuse("Lifecycle source authority is unavailable") end
		end
		return true
	end
	local function snapshot(next_domain, next_state, next_posture)
		return { kind = "physical_lifecycle_facts",
			engine = copy_scalars(next_domain == "engine" and next_state or state.engine),
			system = copy_scalars(next_domain == "system" and next_state or state.system),
			posture = copy_posture(next_posture) }
	end

	--- Accepts copied actual actor fields under exact independent source revisions.
	--- Notification facts remain observed-only and provide no OS transition timestamp.
	---@param domain string Engine or system.
	---@param source_owner table Exact source subscriber owner.
	---@param token table Exact source-minted subscription token.
	---@param record table Actual copied physical_lifecycle receipt.
	---@return boolean accepted Literal true after exact current ownership and facts ACK.
	function owner.accept(domain, source_owner, token, record)
		if not active or retired then return false end
		if busy then return refuse("Lifecycle conjunction reentered") end
		local binding = bindings[domain]
		if not binding or not rawequal(source_owner, binding.owner) or not rawequal(token, binding.token) then
			return refuse("Lifecycle conjunction source owner changed")
		end
		busy = true
		local ok, failure = pcall(function()
			assert(plain(record), "Invalid lifecycle source receipt")
			-- Copy only strict scalar fields before crossing foreign current ports.
			local next_state = { revision = rawget(record, "revision"), observed_at = rawget(record, "at"),
				source = rawget(record, "source"), stage = rawget(record, "stage"),
				fields_complete = rawget(record, "fields_complete"), writer_complete = rawget(record, "complete") }
			assert(rawget(record, "kind") == "physical_lifecycle" and rawget(record, "domain") == domain
				and rawget(record, "allowed") == false, "Unexpected lifecycle source kind or authority")
			assert(integer(next_state.revision) and next_state.revision == state[domain].revision + 1
				and next_state.revision <= capacity, "Lifecycle conjunction revision gap or exhaustion")
			assert(integer(next_state.observed_at) and (state[domain].observed_at == nil
				or next_state.observed_at > state[domain].observed_at), "Unordered lifecycle source clock")
			assert(SOURCES[domain][next_state.source], "Unknown lifecycle writer source")
			assert(type(next_state.fields_complete) == "boolean" and type(next_state.writer_complete) == "boolean",
				"Unknown lifecycle writer completeness")
			local fields = domain == "engine" and { "enabled", "paused", "runtime_generation" }
				or { "enabled", "paused", "hardware_committed", "hardware_generation", "context_refresh_generation" }
			for _, name in ipairs(fields) do
				local value = rawget(record, name)
				if value ~= nil then
					assert(name:find("generation", 1, true) and integer(value)
						or not name:find("generation", 1, true) and type(value) == "boolean", "Invalid lifecycle writer field")
					next_state[name] = value
				end
				assert(not next_state.fields_complete or value ~= nil, "Incomplete lifecycle writer fields")
			end
			if next_state.stage == "observed" then
				next_state.settled = rawget(record, "settled")
				next_state.observation_complete = rawget(record, "observation_complete")
				next_state.qualification = rawget(record, "qualification")
				assert(next_state.settled == nil or type(next_state.settled) == "boolean", "Invalid lifecycle settlement field")
				assert(not next_state.fields_complete or next_state.settled ~= nil, "Missing observed settlement")
				assert(type(next_state.observation_complete) == "boolean"
					and next_state.observation_complete == (next_state.fields_complete and next_state.settled == true)
					and next_state.qualification == (next_state.observation_complete and "observed" or "unknown"),
					"Invalid lifecycle observation qualification")
			end
			local source = { source = next_state.source, event = rawget(record, "event"),
				component = rawget(record, "component"), value = rawget(record, "value") }
			local event = EVENT_FACTS[source.source]
			if event then
				assert(domain == "system" and integer(source.event) and source.component == event[1]
					and source.value == event[2], "Invalid lifecycle notification fields")
			else assert(source.event == nil and source.component == nil and source.value == nil,
				"Unexpected lifecycle notification fields") end
			local next_pending = pending[domain]
			if next_state.stage == "observed" then
				assert(source.source == "initial_snapshot" and next_state.revision == 2
					and state[domain].revision == 1 and state[domain].source == "binding"
					and next_pending == nil and not next_state.writer_complete, "Invalid initial lifecycle observation")
			elseif next_state.stage == "boundary" then
				assert(source.source ~= "initial_snapshot", "Snapshot cannot declare a writer boundary")
				assert(not next_state.writer_complete and not next_state.fields_complete, "Boundary claims writer completion")
				assert(next_pending == nil, "Lifecycle boundary reentered")
				if source.source == "binding" then assert(next_state.revision == 1, "Repeated lifecycle bootstrap")
				else next_pending = source; next_pending.revision = next_state.revision end
			else
				assert(source.source ~= "initial_snapshot" and (next_state.stage == "complete" or next_state.stage == "incomplete"), "Invalid lifecycle writer stage")
				assert(next_pending and next_pending.revision + 1 == next_state.revision, "Missing lifecycle writer boundary")
				for _, name in ipairs({ "source", "event", "component", "value" }) do
					assert(rawequal(next_pending[name], source[name]), "Lifecycle completion source changed")
				end
				assert(next_state.stage == "complete" and next_state.writer_complete and next_state.fields_complete
					or next_state.stage == "incomplete" and not next_state.writer_complete, "Invalid lifecycle completion verdict")
				next_pending = nil
			end
			local next_posture = copy_posture(posture)
			local next_generation = system_generation
			if domain == "system" then
				if next_state.hardware_generation ~= nil then
					if system_generation ~= nil and system_generation ~= next_state.hardware_generation then
						next_posture = unknown_posture()
					end
					next_generation = next_state.hardware_generation
				end
				if source.source == "binding" or source.source == "initial_snapshot" or source.source == "initialization" or source.source == "hardware_start"
					or source.source == "hardware_stop" or source.source == "unknown_event" then next_posture = unknown_posture()
				elseif event then
					next_posture[source.component] = { qualification = "unknown" }
					if next_state.writer_complete then
						next_posture[source.component] = { qualification = "observed_only", value = source.value,
							observed_at = next_state.observed_at, revision = next_state.revision, source = source.source, event = source.event }
					end
				end
			end
			assert(current(), "Lifecycle authority changed before facts publication")
			local delivered, accepted = pcall(receive, snapshot(domain, next_state, next_posture))
			assert(active and delivered and accepted == true, "Lifecycle facts subscriber refused or revoked")
			assert(current(), "Lifecycle authority changed after facts publication")
			state[domain], pending[domain], posture = next_state, next_pending, next_posture
			system_generation = next_generation
		end)
		if not ok then refuse(tostring(failure)) end
		busy = false
		return active and ok
	end

	--- Revokes first and retains scalar facts until both exact sources retire.
	function owner.stop() if retired then return false end; active = false; return true end

	--- Detaches only captured subscriptions; native global watchers remain borrowed.
	--- A caller retries after contained callbacks unwind when this owner is busy.
	function owner.detach()
		active = false
		if busy or retired then return false end
		busy, retirement_reentered = true, false
		local all = true
		for _, domain in ipairs(DOMAINS) do
			local binding = bindings[domain]
			local ok, detached = pcall(binding.detach, binding.owner, binding.token)
			if not ok or detached ~= true then all = false end
		end
		busy = false
		return all and not retirement_reentered
	end

	--- Completes joint lane retirement only after actual detach and all source frames.
	function owner.retired()
		if retired then return true end
		if active then return false end
		if busy then retirement_reentered = true; return false end
		busy, retirement_reentered = true, false
		local all = true
		for _, domain in ipairs(DOMAINS) do
			local binding = bindings[domain]
			local ok, settled = pcall(binding.retired, binding.owner, binding.token)
			if not ok or settled ~= true then all = false end
		end
		busy = false
		if not all or retirement_reentered then return false end
		retired, state, pending, posture = true, {}, {}, {}
		return true
	end
	return owner
end

return M
