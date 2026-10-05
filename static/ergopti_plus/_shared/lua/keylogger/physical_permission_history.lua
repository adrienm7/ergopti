--- _shared/lua/keylogger/physical_permission_history.lua

--- Dormant permission composition over exact bound receipts, never native admission.
local M = {}
local Interval = require("keylogger.physical_interval")
local Configuration = require("keylogger.physical_configuration_observation")
local permits, copy_configuration = Interval.permits, Configuration.copy
local COMPONENTS = { "configuration", "context", "lifecycle", "pause", "capture" }
local RETIREMENT_OWNERS = { "configuration", "context", "lifecycle", "pause", "capture", "clock" }
local MAX_HISTORY, MAX_SELECTORS, MAX_TEXT_BYTES = 4096, 256, 4096
M.MAX_HISTORY, M.MAX_SELECTORS, M.MAX_TEXT_BYTES = MAX_HISTORY, MAX_SELECTORS, MAX_TEXT_BYTES
local MAX_EXACT_DOUBLE = 9007199254740991
local number_type = math.type

local function integer(value)
	if type(value) ~= "number" or value < 0 or value ~= value or value == math.huge then return false end
	if type(number_type) == "function" then return number_type(value) == "integer" end
	return value <= MAX_EXACT_DOUBLE and value % 1 == 0
end

local function plain(value) return type(value) == "table" and getmetatable(value) == nil end
local function text(value) return type(value) == "string" and #value > 0 and #value <= MAX_TEXT_BYTES end

local function copy_app(app)
	assert(plain(app) and text(app.name) and text(app.bundle_id) and text(app.path)
		and integer(app.pid) and app.pid > 0, "Invalid retained physical application")
	return { name = app.name, bundle_id = app.bundle_id, path = app.path, pid = app.pid }
end

local function copy_observation(observation)
	local result = { at = observation.at, allowed = observation.allowed }
	if observation.allowed then result.app = copy_app(observation.app) end
	return result
end

--- Creates one bounded history under independently qualified adapter identities.
--- Tokens identify already-owned subscriptions, not native process incarnations.
--- A separate pause source is mandatory; lifecycle phase alone grants nothing.
---@param capacity integer Maximum retained composites, without silent eviction.
---@param dependencies table Exact capture/clock/observer tokens; current, receive, on_refused and native retirement ports.
---@return table owner Dormant receipt composition, retained interval and retirement ports.
function M.new(capacity, dependencies)
	assert(integer(capacity) and capacity > 0 and capacity <= MAX_HISTORY, "Invalid permission history capacity")
	assert(plain(dependencies) and plain(dependencies.capture) and plain(dependencies.clock)
		and plain(dependencies.observers), "Missing exact physical history identities")
	local capture, clock, observers = dependencies.capture, dependencies.clock, {}
	local current, receive, on_refused = dependencies.current, dependencies.receive, dependencies.on_refused
	assert(type(current) == "function" and type(receive) == "function" and type(on_refused) == "function",
		"Missing physical permission history ports")
	local revisions, state = {}, {}
	for _, component in ipairs(COMPONENTS) do
		assert(plain(dependencies.observers[component]), "Missing physical observer: " .. component)
		observers[component], revisions[component] = dependencies.observers[component], 0
	end
	assert(plain(dependencies.retirement), "Missing native permission-history retirement owners")
	local retirement = {}
	for _, component in ipairs(RETIREMENT_OWNERS) do
		local native = dependencies.retirement[component]
		assert(plain(native) and plain(native.token) and type(native.settled) == "function",
			"Missing native retirement owner: " .. component)
		retirement[component] = { token = native.token, settled = native.settled }
	end
	local active, busy, retired = true, false, false
	local retirement_reentered = false
	local observations, previous, context_transaction = {}, nil, nil
	local owner = {}

	local function refuse(reason)
		if active then active = false; pcall(on_refused, reason) end
		return false, reason
	end

	local function owned(candidate, clock_token)
		return rawequal(candidate, capture) and rawequal(clock_token, clock)
	end

	local function current_authority()
		local ok, accepted = pcall(current, capture)
		if not active then return false end
		if not ok or accepted ~= true then return refuse("Physical capture authority is unavailable") end
		return true
	end

	local function enter(candidate, clock_token)
		if not active then return false end
		if busy then return refuse("Physical permission history reentered") end
		if not owned(candidate, clock_token) then return refuse("Physical history identity changed") end
		busy = true
		if not current_authority() then busy = false; return false end
		return true
	end

	local function composite(at)
		local allowed = state.configuration ~= nil and state.context ~= nil
			and state.context.allowed == true and state.context.configuration == revisions.configuration
		for _, component in ipairs({ "lifecycle", "pause", "capture" }) do
			allowed = allowed and state[component] ~= nil and state[component].complete == true
				and state[component].allowed == true
		end
		local record = { at = at, allowed = allowed == true }
		if record.allowed then record.app = copy_app(state.context.app) end
		return record
	end

	local function configuration(record)
		assert(plain(record.disabled_apps), "Invalid retained physical selectors")
		local count = 0
		for _ in next, record.disabled_apps do
			count = count + 1
			assert(count <= MAX_SELECTORS, "Retained physical selector budget exhausted")
		end
		local snapshot = copy_configuration(record)
		for _, selector in ipairs(snapshot.disabled_apps) do
			for _, field in ipairs({ "bundleID", "appPath" }) do
				assert(selector[field] == nil or #selector[field] <= MAX_TEXT_BYTES,
					"Retained physical selector text budget exhausted")
			end
		end
		state.configuration, state.context = snapshot, nil
	end

	local function context(record)
		assert(text(record.source), "Missing physical context writer source")
		assert(type(record.complete) == "boolean" and type(record.allowed) == "boolean", "Invalid context verdict")
		if record.stage == "boundary" then
			state.context = nil
			if record.source == "binding" then context_transaction = nil; return end
			assert(context_transaction == nil, "Physical context transaction reentered")
			context_transaction = { source = record.source, revision = record.revision,
				configuration = state.configuration and revisions.configuration or nil }
			return
		end
		assert(record.stage == "complete" or record.stage == "incomplete", "Invalid physical context stage")
		assert(context_transaction and context_transaction.source == record.source
			and context_transaction.revision + 1 == record.revision, "Physical context completion has no exact boundary")
		local transaction = context_transaction
		context_transaction, state.context = nil, nil
		if record.stage ~= "complete" or record.complete ~= true or record.fields_complete ~= true
			or record.correlated ~= true or record.allowed ~= true
			or transaction.configuration == nil or transaction.configuration ~= revisions.configuration then return end
		assert(type(record.private) == "boolean" and type(record.secure) == "boolean", "Incomplete context privacy fields")
		state.context = { allowed = true, app = copy_app(record.app), configuration = transaction.configuration }
	end

	--- Copies each source receipt, then acknowledges one strictly ordered composite.
	--- Configuration linkage is captured at the actual context boundary; completion
	--- cannot replace it with an arbitrary revision or the latest cached permission.
	--- Lifecycle/pause/capture complete=true and allowed=true must be supplied by
	--- their actual owned admission adapters; observed phase fields cannot prove it.
	---@param candidate table Exact capture identity.
	---@param clock_token table Independently qualified native clock identity.
	---@param component string Configuration, context, lifecycle, pause or capture.
	---@param observer table Exact retained native subscription identity.
	---@param record table Plain source receipt; no caller fields are retained by alias.
	---@return boolean accepted Literal true only after current owner and subscriber ACK.
	function owner.observe(candidate, clock_token, component, observer, record)
		if not enter(candidate, clock_token) then return false end
		local ok, failure = pcall(function()
			assert(observers[component] and rawequal(observers[component], observer), "Physical observer identity changed")
			assert(plain(record) and record.kind == "physical_" .. component, "Invalid physical source receipt")
			assert(integer(record.revision) and record.revision == revisions[component] + 1,
				"Physical receipt revision gap or replay")
			assert(integer(record.at) and (not previous or record.at > previous), "Unordered native permission clock")
			assert(#observations < capacity, "Physical permission history exhausted")
			if component == "configuration" then configuration(record)
			elseif component == "context" then context(record)
			else
				assert(type(record.complete) == "boolean" and type(record.allowed) == "boolean", "Invalid authority verdict")
				state[component] = { complete = record.complete, allowed = record.allowed }
			end
			revisions[component] = record.revision
			local snapshot = composite(record.at)
			assert(current_authority(), "Physical capture authority was revoked before publication")
			local delivered, accepted = pcall(receive, copy_observation(snapshot))
			assert(active and delivered and accepted == true, "Physical permission subscriber refused or revoked")
			assert(current_authority(), "Physical capture authority was revoked after publication")
			observations[#observations + 1], previous = snapshot, snapshot.at
		end)
		busy = false
		if not active then return false end
		if not ok then return refuse(tostring(failure)) end
		return true
	end

	--- Resolves a whole original hold through existing interval policy and press context.
	--- Missing coverage, unknown authority and every denied crossing cancel it entirely.
	---@return table decision Detached permission and initial app, or only allowed=false.
	function owner.resolve_interval(candidate, clock_token, first_ns, last_ns)
		if not enter(candidate, clock_token) then return { allowed = false } end
		last_ns = last_ns == nil and first_ns or last_ns
		local result = { allowed = false }
		if integer(first_ns) and integer(last_ns) and first_ns <= last_ns
			and permits(observations, first_ns, last_ns) then
			local selected
			for _, observation in ipairs(observations) do
				if observation.at > first_ns then break end
				selected = observation
			end
			result = copy_observation(selected)
		end
		if not current_authority() then result = { allowed = false } end
		busy = false
		return result
	end

	--- Revokes delivery while retaining this capture's history until actual retirement.
	function owner.stop(candidate)
		if not rawequal(candidate, capture) or retired then return false end
		active = false
		return true
	end

	--- A source gap is terminal for this capture; cached permission never repairs it.
	function owner.gap(candidate) return owner.stop(candidate) end

	--- Retires a detached or failed exact source before notifying foreign observers.
	--- Source channels must route their terminal refusal here; no retry repairs it.
	function owner.detach(candidate, component, observer)
		if not active then return false end
		if not rawequal(candidate, capture) or not observers[component]
			or not rawequal(observer, observers[component]) then return refuse("Physical source retirement identity changed") end
		return refuse("Physical observer detached or refused receipts")
	end

	--- Records terminal refusal from the exact bound source, including its budget.
	function owner.refused(candidate, component, observer) return owner.detach(candidate, component, observer) end

	--- Clears history only after every exact bound native owner acknowledges shutdown.
	--- Each settled port must be a conclusive, monotonic retirement observation.
	--- Merely returning a caller boolean cannot satisfy the missing native bindings;
	--- this policy cannot independently prove those bindings or process retirement.
	function owner.retired(candidate)
		if not rawequal(candidate, capture) or active or retired then return false end
		if busy then retirement_reentered = true; return false end
		busy, retirement_reentered = true, false
		local all_settled = true
		for _, component in ipairs(RETIREMENT_OWNERS) do
			local native = retirement[component]
			local ok, acknowledged = pcall(native.settled, capture, native.token)
			if not ok or acknowledged ~= true or retirement_reentered then all_settled = false; break end
		end
		busy = false
		if not all_settled then return false end
		retired, observations, state, context_transaction = true, {}, {}, nil
		return true
	end

	--- Exposes only the bounded retained count, including after authority is revoked.
	function owner.retained_count() return #observations end
	return owner
end

return M
