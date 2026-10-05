--- _shared/lua/keylogger/physical_history_coordinator.lua

--- Binds actual writer subscriptions to one retained history and accepted context.
local M = {}
local History = require("keylogger.physical_permission_history")
local Conjunction = require("keylogger.physical_lifecycle_conjunction")
M.MAX_HISTORY = History.MAX_HISTORY
local Lifetime = require("keylogger.physical_subscription_lifetime")
local SOURCES = { "configuration", "context", "engine", "system", "pause" }
local number_type = math.type
local function plain(value) return type(value) == "table" and getmetatable(value) == nil end
local function integer(value)
	if type(value) ~= "number" or value < 0 or value ~= value or value == math.huge then return false end
	if type(number_type) == "function" then return number_type(value) == "integer" end
	return value <= 9007199254740991 and value % 1 == 0
end
local function methods(scope, names)
	assert(plain(scope), "Missing exact history subscription")
	local captured = {}
	for _, name in ipairs(names) do
		captured[name] = rawget(scope, name)
		assert(type(captured[name]) == "function", "Missing history subscription port: " .. name)
	end
	return captured
end
local function copy(value, budget, depth)
	assert(depth <= 4, "History bootstrap nesting exhausted")
	if type(value) ~= "table" then
		assert(type(value) == "number" or type(value) == "boolean" or type(value) == "string", "Invalid history receipt scalar")
		if type(value) == "string" then assert(#value <= History.MAX_TEXT_BYTES, "History bootstrap text exhausted") end
		return value
	end
	assert(plain(value), "Invalid history bootstrap alias")
	local result = {}
	for key, field in next, value do
		budget.remaining = budget.remaining - 1
		assert(budget.remaining >= 0 and (type(key) == "string" and #key <= History.MAX_TEXT_BYTES or integer(key)), "History bootstrap copy exhausted")
		result[key] = copy(field, budget, depth + 1)
	end
	return result
end

--- Acquires source subscriptions in order, preserving synchronous bootstrap frames.
--- Native capture/clock scopes are borrowed and already bound inside clock_ready.
--- Lifecycle posture remains observed-only; unknown posture never grants permission.
---@param owner table Exact subscriber shared by these actual owned capabilities.
---@param capacity integer Bounded receipts, without eviction or timestamp rewriting.
---@param dependencies table Capture/clock scopes, source binders, projection factory and terminal observer.
---@return table coordinator Retained context, stop and exact post-frame retirement ports, including on acquisition refusal.
function M.new(owner, capacity, dependencies)
	assert(plain(owner) and integer(capacity) and capacity > 0 and capacity <= History.MAX_HISTORY,
		"Invalid physical history coordinator ownership or budget")
	assert(plain(dependencies) and plain(dependencies.binders), "Missing physical history coordinator ports")
	local capture = methods(dependencies.capture, { "identity", "current", "settled" })
	capture.admitted = rawget(dependencies.capture, "admitted")
	local clock = methods(dependencies.clock, { "identity", "current", "read", "detach", "retired" })
	local project, notify, binders = dependencies.projection, dependencies.on_refused, {}
	assert(type(project) == "function" and type(notify) == "function", "Missing history projection or refusal observer")
	for _, name in ipairs(SOURCES) do
		binders[name] = rawget(dependencies.binders, name)
		assert(type(binders[name]) == "function", "Missing history writer binder: " .. name)
	end
	local coordinator, life_token = {}, {}
	local life = Lifetime.new(owner, life_token)
	local capability = life.capability()
	local own_current, own_retired = capability.current, capability.retired
	life.bind_detach(function() life.detach(); return true end)
	local active, building, busy, finished = true, true, false, false
	local retirement_reentered = false
	local bindings, queue, failure = {}, {}, nil
	local binding_name, history, conjunction, projection, projection_scope
	local capture_token, clock_token, capture_observer, lifecycle_observer = nil, nil, {}, {}
	local capture_revision, lifecycle_revision, admission = 1, 0, nil
	local lifecycle_at, lifecycle_qualification = nil, "unknown"

	local function revoke(reason)
		local first = active
		active = false
		life.revoke()
		if failure == nil and reason ~= nil then failure = reason end
		if history then history.stop(capture_token) end
		if conjunction then conjunction.stop() end
		if projection then pcall(projection.stop) end
		if first and reason ~= nil then life.run(function() pcall(notify, reason) end) end
		return false
	end
	local function current()
		if not active or not own_current(owner, life_token) then return false end
		local function foreign(operation, ...)
			local ok, result = pcall(operation, ...)
			if not active or not ok then return false end
			return result
		end
		if not rawequal(foreign(capture.identity), capture_token)
			or not rawequal(foreign(clock.identity, owner), clock_token)
			or foreign(capture.current, capture_token) ~= true
			or foreign(clock.current, owner, clock_token) ~= true then return revoke("History capture or clock was revoked") end
		if admission ~= nil and foreign(capture.admitted, capture_token) ~= admission then
			return revoke("History capture admission was lost or changed")
		end
		for _, name in ipairs(SOURCES) do
			local source = bindings[name]
			if source and (not rawequal(foreign(source.identity, owner), source.token)
				or foreign(source.current, owner, source.token) ~= true) then return revoke("History writer was revoked") end
		end
		return active
	end
	local function sample()
		assert(current(), "History clock owner unavailable")
		local at, reason = clock.read(owner, clock_token)
		assert(active and integer(at) and current(), reason or "History observation clock unavailable")
		return at
	end
	local function observe(component, observer, record)
		return history.observe(capture_token, clock_token, component, observer, record)
	end
	local function facts(record)
		local function scalar_ready(state)
			-- Readonly startup state qualifies only at its actual observed callback.
			-- Its source still reports writer_complete=false, without a fake start.
			return state.writer_complete == true or state.source == "initial_snapshot" and state.stage == "observed"
				and state.writer_complete == false and state.fields_complete == true
				and state.observation_complete == true and state.qualification == "observed" and state.settled == true
		end
		local engine_ready, system_ready = scalar_ready(record.engine), scalar_ready(record.system)
		local allowed = engine_ready and system_ready
			and record.engine.enabled == true and record.engine.paused == false
			and record.system.enabled == true and record.system.paused == false
			and record.system.hardware_committed == true
		local known = true
		for _, name in ipairs({ "system_awake", "screen_awake", "unlocked" }) do
			local posture = record.posture[name]
			known = known and posture.qualification == "observed_only"
			allowed = allowed and posture.qualification == "observed_only" and posture.value == true
		end
		lifecycle_qualification = known and "observed_only" or "unknown"
		lifecycle_revision = lifecycle_revision + 1
		return observe("lifecycle", lifecycle_observer, { kind = "physical_lifecycle", revision = lifecycle_revision,
			at = lifecycle_at, complete = known and engine_ready and system_ready,
			allowed = allowed == true })
	end
	local function pause(record)
		assert(record.kind == "physical_lifecycle" and record.domain == "pause" and record.allowed == false,
			"Invalid actual pause writer receipt")
		assert(type(record.complete) == "boolean" and type(record.fields_complete) == "boolean", "Unknown pause writer completion")
		local complete = record.stage == "complete" and record.complete and record.fields_complete
		local allowed = false
		local observed = record.source == "initial_snapshot" and record.stage == "observed" and record.revision == 2 and record.complete == false
			and record.fields_complete == true and record.observation_complete == true
			and record.qualification == "observed" and record.settled == true
		complete = complete or observed
		if complete then
			assert(type(record.paused) == "boolean" and type(record.admission_released) == "boolean"
				and type(record.settled) == "boolean" and integer(record.transition_generation), "Invalid actual pause release fields")
			allowed = (record.source == "resume" or observed) and record.paused == false and record.admission_released and record.settled
		end
		return observe("pause", bindings.pause.token, { kind = "physical_pause", revision = record.revision,
			at = record.at, complete = complete == true, allowed = allowed == true })
	end
	local function dispatch(name, record, token)
		local source = bindings[name]
		assert(source and rawequal(source.token, token), "History source receipt identity changed")
		assert(current(), "History source owner unavailable before receipt")
		local accepted
		if name == "engine" or name == "system" then
			lifecycle_at = record.at
			accepted = conjunction.accept(name, owner, token, record)
		elseif name == "pause" then accepted = pause(record)
		else accepted = observe(name, token, record) end
		assert(active and accepted == true and current(), "History source refused or revoked receipt")
		return true
	end
	local function receive(name, record, token)
		return life.run(function()
			if not active then return false end
			local ok, result = pcall(function()
				local snapshot = copy(record, { remaining = History.MAX_SELECTORS * 4 }, 0)
				assert(plain(token), "Missing source-minted history token")
				if building then
					assert(binding_name == name and #queue < capacity, "History bootstrap reentry or exhaustion")
					queue[#queue + 1] = { source = name, record = snapshot, token = token }
					return true
				end
				assert(not busy, "History coordinator reentered")
				busy = true
				return dispatch(name, snapshot, token)
			end)
			if not ok then revoke("History source receipt failed") end
			if not building then busy = false end
			return active and ok and result == true
		end)
	end
	local function refused(name, reason, token)
		return life.run(function()
			if not active then return false end
			if history then
				local component = (name == "engine" or name == "system") and "lifecycle" or name
				local expected = component == "lifecycle" and lifecycle_observer or bindings[name].token
				if token ~= nil and not rawequal(token, bindings[name].token) then revoke("History refusal token changed")
				else history.refused(capture_token, component, expected) end
			end
			return revoke("History writer refused: " .. name)
		end)
	end
	local function retain(name, token, scope)
		if scope == nil then return end
		local ports = methods(scope, { "identity", "current", "detach", "retired" })
		bindings[name] = ports
		ports.token = token or ports.identity(owner)
		assert(plain(ports.token) and rawequal(ports.identity(owner), ports.token), "History binding identity changed")
	end
	local function scoped_retirement(source)
		return { token = source.token, settled = function(candidate, token)
			return rawequal(candidate, capture_token) and rawequal(token, source.token)
				and source.retired(owner, source.token) == true and not retirement_reentered
		end }
	end
	local function initialize()
		capture_token, clock_token = capture.identity(), clock.identity(owner)
		assert(plain(capture_token) and plain(clock_token) and current(), "History borrowed identities unavailable")
		local first = sample()
		for _, name in ipairs(SOURCES) do
			assert(current(), "History revoked before source acquisition")
			binding_name = name
			local token, reason, scope = binders[name](owner, capacity,
				function(record, identity) return receive(name, record, identity) end,
				function(reason, identity) return refused(name, reason, identity) end)
			retain(name, token, scope)
			assert(active and plain(token) and bindings[name] and current(), reason or "History source acquisition failed")
		end
		binding_name = nil
		conjunction = Conjunction.new({ engine = { owner = owner, token = bindings.engine.token, scope = bindings.engine },
			system = { owner = owner, token = bindings.system.token, scope = bindings.system } }, capacity, facts,
			function() revoke("History lifecycle conjunction refused") end)
		local retirement = {
			configuration = scoped_retirement(bindings.configuration), context = scoped_retirement(bindings.context),
			pause = scoped_retirement(bindings.pause),
			lifecycle = { token = lifecycle_observer, settled = function(candidate, token)
				return rawequal(candidate, capture_token) and rawequal(token, lifecycle_observer) and conjunction.retired() == true and not retirement_reentered
			end },
			capture = { token = capture_token, settled = function(candidate, token)
				return rawequal(candidate, capture_token) and rawequal(token, capture_token) and capture.settled(token) == true and not retirement_reentered
			end },
			clock = { token = clock_token, settled = function(candidate, token)
				return rawequal(candidate, capture_token) and rawequal(token, clock_token) and clock.retired(owner, token) == true and not retirement_reentered
			end },
		}
		history = History.new(capacity, { capture = capture_token, clock = clock_token,
			observers = { configuration = bindings.configuration.token, context = bindings.context.token,
				lifecycle = lifecycle_observer, pause = bindings.pause.token, capture = capture_observer },
			current = function(candidate) return rawequal(candidate, capture_token) and current() end,
			receive = function() return current() end,
			on_refused = function() revoke("History permission composition refused") end, retirement = retirement })
		assert(observe("capture", capture_observer, { kind = "physical_capture", revision = 1,
			at = first, complete = false, allowed = false }), "Initial capture denial refused")
		building, busy = false, true
		for _, receipt in ipairs(queue) do dispatch(receipt.source, receipt.record, receipt.token) end
		queue = {}
		assert(current(), "History revoked before context projection")
		local candidate, reason = project(history)
		assert(active and candidate, reason or "History accepted context unavailable")
		projection = methods(candidate, { "context", "context_interval", "stop", "subscription" })
		projection_scope = methods(projection.subscription(), { "identity", "detach", "retired" })
		projection_scope.token = projection_scope.identity(owner)
		assert(plain(projection_scope.token) and current(), "History projection identity unavailable")
	end
	local function admission_observed()
		assert(type(capture.admitted) == "function", "Missing actual baseline admission adapter")
		local observed = capture.admitted(capture_token)
		assert(active and current(), "History capture changed during admission observation")
		assert(observed ~= nil, "Actual baseline admission is incomplete")
		assert(type(observed) == "string" and #observed > 0, "Invalid actual capture admission")
		assert(admission == nil, "Actual baseline admission replayed")
		local at = sample()
		assert(capture.admitted(capture_token) == observed and active and current(), "History baseline changed during observation")
		capture_revision = capture_revision + 1
		assert(observe("capture", capture_observer, { kind = "physical_capture", revision = capture_revision,
			at = at, complete = true, allowed = true }), "Observed capture admission refused")
		admission = observed
		return true
	end
	local function context(method, ...)
		if not active then return { allowed = false } end
		return life.run(function(...)
			if busy then revoke("History coordinator reentered"); return { allowed = false } end
			busy = true
			local ok, result = pcall(function(...)
				assert(current(), "History context owner unavailable")
				local decision = projection[method](...)
				assert(plain(decision) and current(), "History projection refused or revoked")
				return decision
			end, ...)
			if not ok then revoke("History context failed") end
			busy = false
			if not active or not ok then return { allowed = false } end
			return result
		end, ...)
	end

	--- Acknowledges only the actual completed baseline event before further delivery.
	--- The native owner supplies this no-argument port; context never publishes it.
	---@return boolean accepted Literal true after exact scope/clock/history ACK.
	function coordinator.capture_ready()
		if not active then return false end
		return life.run(function()
			if busy then return revoke("History readiness reentered") end
			busy = true
			local ok, accepted = pcall(function()
				assert(current(), "History baseline owner unavailable")
				return admission_observed()
			end)
			if not ok then revoke("History baseline readiness failed") end
			busy = false
			return active and ok and accepted == true
		end)
	end

	--- Resolves original ticks; newly observed admission cannot backdate permission.
	function coordinator.context(ticks) return context("context", ticks) end
	--- Uses the same retained whole-hold interval policy and frozen press date owner.
	function coordinator.context_interval(first, last) return context("context_interval", first, last) end
	--- Revokes before foreign cleanup; borrowed capture task shutdown stays native-owned.
	function coordinator.stop()
		if not active then return true end
		return life.run(function()
			local previous_busy = busy
			busy = true
			revoke()
			busy = previous_busy
			return true
		end)
	end
	--- Detaches captured sources and waits for all six owners plus projection frames.
	--- CaptureScope.release remains caller-owned until this literal-true acknowledgement.
	function coordinator.retired()
		if finished then return true end
		if busy then retirement_reentered = true; return false end
		if active or building then return false end
		busy, retirement_reentered = true, false
		local ok, acknowledged = pcall(function()
			capability.detach(owner, life_token)
			if not own_retired(owner, life_token) then return false end
			local all = true
			if projection_scope then
				all = projection_scope.detach(owner, projection_scope.token) == true and all
				all = projection_scope.retired(owner, projection_scope.token) == true and all
			end
			if conjunction then all = conjunction.detach() == true and all end
			for _, name in ipairs(SOURCES) do
				local source = bindings[name]
				if source then
					all = source.detach(owner, source.token) == true and all
					all = source.retired(owner, source.token) == true and all
				end
			end
			all = clock.detach(owner, clock_token) == true and all
			all = clock.retired(owner, clock_token) == true and all
			all = capture.settled(capture_token) == true and all
			if not all or retirement_reentered then return false end
			if history then return history.retired(capture_token) == true end
			return true
		end)
		busy = false
		if not ok or acknowledged ~= true or retirement_reentered then return false end
		finished, queue = true, {}
		return true
	end
	--- Returns detached operational status without retained application/private data.
	function coordinator.status()
		return { state = finished and "retired" or active and "bound" or failure and "refused" or "stopped",
			reason = failure, retained_count = history and history.retained_count() or 0,
			lifecycle_admission = lifecycle_qualification == "unknown" and "unqualified" or lifecycle_qualification,
			capture_admission = admission and "observed" or "unqualified" }
	end
	life.run(function()
		busy = true
		local ok = pcall(initialize)
		if not ok then revoke("History binding preparation failed") end
		building, binding_name, busy = false, nil, false
	end)
	return coordinator
end

return M
