--- _shared/lua/keylogger/physical_lifecycle_observation.lua

--- Emits dormant writer facts; no receipt grants retained history or capture.
local M = {}
local unpack_values = table.unpack or unpack

local function pack(...) return { n = select("#", ...), ... } end
local function integral(value)
	return type(value) == "number" and value == value and value >= 0
		and value < math.huge and value == math.floor(value)
end
local EVENT_FACTS = {
	{ "systemWillSleep", "system_sleep", "system_awake", false },
	{ "screensDidSleep", "screens_sleep", "screen_awake", false },
	{ "systemDidWake", "system_wake", "system_awake", true },
	{ "screensDidWake", "screens_wake", "screen_awake", true },
	{ "screensDidLock", "lock", "unlocked", false },
	{ "screensDidUnlock", "unlock", "unlocked", true },
}

--- Normalizes only existing native event constants, without guessing other facts.
---@param constants table Native caffeinate constants already present in the runtime.
---@param event any Actual callback event.
---@return table source Independent event fact or an explicit unknown event.
function M.system_event(constants, event)
	if type(constants) == "table" and integral(event) then
		for _, fact in ipairs(EVENT_FACTS) do
			if rawequal(rawget(constants, fact[1]), event) then
				return { source = fact[2], event = event, component = fact[3], value = fact[4] }
			end
		end
	end
	return { source = "unknown_event" }
end

--- Creates one lazily bound lifecycle actor, shared by native writer adapters.
---@param domain string Engine or system domain.
---@param clock function One exact native nanosecond sample, with no fallback.
---@param on_refused function Once-only notification after subscription retirement.
---@return table actor Exact-owner dormant lifecycle ports.
function M.new(domain, clock, on_refused)
	assert(domain == "engine" or domain == "system", "Invalid lifecycle domain")
	assert(type(clock) == "function" and type(on_refused) == "function", "Missing lifecycle ports")
	local actor, binding, frame = {}, nil, nil

	local function current(candidate)
		return candidate ~= nil and rawequal(binding, candidate) and candidate.active
	end
	local function refuse(candidate, reason)
		if current(candidate) then
			candidate.active = false; candidate.lifetime.revoke()
			if candidate.on_refused then
				candidate.lifetime.run(function() pcall(candidate.on_refused, reason, candidate.token) end)
			end
			pcall(on_refused, reason)
		end
		return false, reason
	end
	local function source_fields(source)
		if type(source) == "string" then return { source = source } end
		return { source = rawget(source, "source"), event = rawget(source, "event"),
			component = rawget(source, "component"), value = rawget(source, "value") }
	end
	local function same_source(a, b)
		return rawequal(a.source, b.source) and rawequal(a.event, b.event)
	end
	local function sample(candidate)
		candidate.dispatching = true
		local ok, at = pcall(clock)
		candidate.dispatching = false
		if not current(candidate) then return nil end
		if not ok or not integral(at) or (candidate.previous and at <= candidate.previous) then
			refuse(candidate, "Invalid or unordered native lifecycle clock"); return nil
		end
		return at
	end
	local function publish(candidate, source, fields, committed, reserved_at)
		if not current(candidate) then return false end
		if candidate.dispatching then return refuse(candidate, "Lifecycle publication reentered") end
		if candidate.revision >= candidate.capacity then return refuse(candidate, "Lifecycle receipt budget exhausted") end
		local at = reserved_at or sample(candidate)
		if at == nil or not current(candidate) then return false end
		candidate.dispatching = true
		local record = { kind = "physical_lifecycle", domain = domain, source = source.source,
			revision = candidate.revision + 1, at = at, allowed = false,
			fields_complete = false, complete = false, stage = fields and "incomplete" or "boundary",
			event = source.event, component = source.component, value = source.value }
		if fields then
			local enabled, paused = rawget(fields, "enabled"), rawget(fields, "paused")
			if type(enabled) == "boolean" then record.enabled = enabled end
			if type(paused) == "boolean" then record.paused = paused end
			local known = type(enabled) == "boolean" and type(paused) == "boolean"
			if domain == "engine" then
				local generation = rawget(fields, "runtime_generation")
				if integral(generation) then record.runtime_generation = generation else known = false end
			else
				local hardware = rawget(fields, "hardware_committed")
				if type(hardware) == "boolean" then record.hardware_committed = hardware else known = false end
				for _, name in ipairs({ "hardware_generation", "context_refresh_generation" }) do
					local generation = rawget(fields, name)
					if integral(generation) then record[name] = generation else known = false end
				end
			end
			record.fields_complete = known
			record.complete = known and committed == true and source.source ~= "unknown_event"
			if record.complete then record.stage = "complete" end
		end
		local delivered, accepted = pcall(candidate.receive, record, candidate.token)
		candidate.dispatching = false
		if not current(candidate) then return false end
		if not delivered or accepted ~= true then return refuse(candidate, "Lifecycle subscriber refused receipt") end
		candidate.previous, candidate.revision = at, candidate.revision + 1
		return true
	end

	--- Claims the single exact owner without starting or sampling runtime state.
	---@param owner table Exact owner capability.
	---@param capacity number Positive finite integral receipt budget.
	---@param receive function Receives copied records and exact binding token.
	---@param refusal_observer function|nil Exact callback receiving terminal reason and source token.
	---@return table|nil token Owned detach capability, or nil on refusal.
	---@return string|nil reason Explicit refusal reason when binding fails.
	---@return table|nil scope Exact callback ownership, detach and post-frame retirement.
	function actor.bind(owner, capacity, receive, refusal_observer)
		if type(owner) ~= "table" or not integral(capacity) or capacity < 1 or type(receive) ~= "function"
			or (refusal_observer ~= nil and type(refusal_observer) ~= "function") then
			return nil, "Invalid lifecycle subscription"
		end
		if binding ~= nil then return nil, "Lifecycle observer already owned" end
		local candidate = { owner = owner, token = {}, active = true, dispatching = false,
			capacity = capacity, receive = receive, revision = 0, on_refused = refusal_observer }
		candidate.lifetime = require("keylogger.physical_subscription_lifetime").new(owner, candidate.token)
		candidate.lifetime.bind_detach(function(exact_owner, exact_token) return actor.unbind(exact_owner, exact_token) end)
		binding = candidate
		if candidate.lifetime.run(publish, candidate, { source = "binding" }) ~= true then
			if rawequal(binding, candidate) then binding = nil end
			candidate.active = false; candidate.lifetime.detach()
			return nil, "Lifecycle bootstrap refused", candidate.lifetime.capability()
		end
		return candidate.token, nil, candidate.lifetime.capability()
	end

	--- Releases only the actual owner and token; equality hooks are never invoked.
	---@param owner table Exact owner capability.
	---@param token table Exact returned binding token.
	---@return boolean released Whether the exact subscription was detached.
	function actor.unbind(owner, token)
		if binding == nil or not rawequal(binding.owner, owner) or not rawequal(binding.token, token) then return false end
		binding.active = false; binding.lifetime.detach(); binding = nil
		return true
	end

	local function execute(source, writer, snapshot, bridge, ...)
		local candidate, args = binding, pack(...)
		if not current(candidate) then return writer(unpack_values(args, 1, args.n)) end
		source = source_fields(source)
		if frame then
			-- A successor binding cannot complete a writer begun by its old owner.
			if not rawequal(frame.binding, candidate) then return writer(unpack_values(args, 1, args.n)) end
			if not bridge and frame.expected and same_source(frame.expected, source) then
				frame.expected = nil
				local results = pack(pcall(writer, unpack_values(args, 1, args.n)))
				frame.child_committed = results[1] == true and results[2] == true
				if not results[1] then error(results[2], 0) end
				return unpack_values(results, 2, results.n)
			end
			refuse(candidate, "Lifecycle writer reentered")
			return writer(unpack_values(args, 1, args.n))
		end
		if candidate.dispatching then
			refuse(candidate, "Lifecycle writer reentered publication")
			return writer(unpack_values(args, 1, args.n))
		end
		local ticket = { binding = candidate, source = source }
		frame = ticket
		if publish(candidate, source) == true and current(candidate) and bridge then ticket.expected = source end
		local results = pack(pcall(writer, unpack_values(args, 1, args.n)))
		ticket.expected = nil
		if current(candidate) and rawequal(frame, ticket) then
			-- Every receipt reserves its budget before invoking a foreign pause predicate.
			if candidate.revision >= candidate.capacity then
				refuse(candidate, "Lifecycle receipt budget exhausted")
			else
				local at = sample(candidate)
				if at ~= nil and current(candidate) and rawequal(frame, ticket) then
					local observed, fields = pcall(snapshot)
					if current(candidate) and rawequal(frame, ticket) then
						if not observed or type(fields) ~= "table" then fields = {} end
						local committed = results[1] == true and (bridge and ticket.child_committed == true or not bridge and results[2] == true)
						publish(candidate, source, fields, committed, at)
					end
				end
			end
		end
		if rawequal(frame, ticket) then frame = nil end
		if not results[1] then error(results[2], 0) end
		return unpack_values(results, 2, results.n)
	end

	--- Observes one actual writer while preserving its unbound queries and returns.
	---@param source string|table Declared writer or normalized native event.
	---@param writer function Existing native writer body.
	---@param snapshot function Copied scalar state, read only while still owned.
	---@param ... any Original writer arguments.
	---@return any result Original writer result tuple.
	function actor.run(source, writer, snapshot, ...)
		local candidate = binding
		if candidate then return candidate.lifetime.run(execute, source, writer, snapshot, false, ...) end
		return execute(source, writer, snapshot, false, ...)
	end

	--- Denies before legacy callback admission and accepts only its actual child.
	---@param source table Normalized native event.
	---@param writer function Generation-qualified callback with its legacy admission guard.
	---@param snapshot function Copied scalar state after the actual child returns.
	---@param ... any Original callback arguments.
	---@return any result Original callback result tuple.
	function actor.bridge(source, writer, snapshot, ...)
		local candidate = binding
		if candidate then return candidate.lifetime.run(execute, source, writer, snapshot, true, ...) end
		return execute(source, writer, snapshot, true, ...)
	end
	return actor
end

return M
