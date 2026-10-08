--- modules/keylogger/physical_history_session.lua

--- Explicit dormant capture wiring; installed runtime authority remains caller-owned.
local M = {}
local Coordinator = require("keylogger.physical_history_coordinator")
local Context = require("adapters.physical_history_context")
local Clock = require("adapters.physical_observation_clock")
local Capture = require("modules.keylogger.physical_capture")
local Keylogger = require("modules.keylogger")
local Tracker = require("modules.keylogger.context_tracker")
local Watchers = require("modules.keylogger.watchers")
local ScriptControl = require("modules.shortcuts.script_control")
local ShellRunner = require("adapters.shell_runner")
local Identity = require("modules.keylogger.physical_key_identity")
local LogManager = require("modules.keylogger.log_manager")
local initialized, initializing = false, false

local function port(source, name)
	assert(type(source) == "table" and type(rawget(source, name)) == "function", "Missing native history port: " .. name)
	return rawget(source, name)
end
local function scope_ports(scope, names)
	local result = {}
	for _, name in ipairs(names) do result[name] = port(scope, name) end
	result.on_retired = rawget(scope, "on_retired")
	return result
end

local function resolve_native_ports(managed)
	local native = rawget(_G, "hs")
	local json = type(native) == "table" and rawget(native, "json") or nil
	local decode, encode = port(json, "decode"), port(json, "encode")
	local capture_init, capture_bind, capture_stop = port(Capture, "init"), port(Capture, "bind_history_scope"), port(Capture, "stop")
	local clock_bind, project = port(Clock, "bind_history_scope"), port(Context, "new")
	local configuration_bind = port(Keylogger, "bind_physical_configuration_observer")
	local context_bind, may_persist = port(Tracker, "bind_physical_correlated_context_observer"), port(Keylogger, "may_persist")
	local engine_bind = port(Keylogger, "bind_physical_lifecycle_observer")
	local system_bind, pause_bind = port(Watchers, "bind_physical_lifecycle_observer"), port(ScriptControl, "bind_physical_pause_observer")
	local context_sample = managed and port(Tracker, "sample_physical_context") or nil
	return { context_sample = context_sample, decode = decode, encode = encode, capture_init = capture_init, capture_bind = capture_bind, capture_stop = capture_stop, clock_bind = clock_bind, project = project, configuration_bind = configuration_bind, context_bind = context_bind, may_persist = may_persist, engine_bind = engine_bind, system_bind = system_bind, pause_bind = pause_bind }
end

local function new_session(capacity, on_refused, native_ports)
	local decode, encode, capture_init, capture_bind, capture_stop, clock_bind, project, configuration_bind, context_bind, may_persist, engine_bind, system_bind, pause_bind =
		native_ports.decode, native_ports.encode, native_ports.capture_init, native_ports.capture_bind, native_ports.capture_stop, native_ports.clock_bind, native_ports.project, native_ports.configuration_bind, native_ports.context_bind, native_ports.may_persist, native_ports.engine_bind, native_ports.system_bind, native_ports.pause_bind
	local context_sample, context_token = native_ports.context_sample, nil
	local subscriber, session = {}, {}
	local active, binding, frames, retired = true, false, 0, false
	local coordinator, capture_scope, clock_scope, capture_token, clock_token
	local reason, stop_requested, stop_issued = nil, false, false
	local retirement_reentered, capture_released = false, false
	local notification_frames = 0
	local function refuse(message)
		local first = active
		active, stop_requested = false, true
		reason = reason or message
		if coordinator then coordinator.stop() end
		if first then pcall(on_refused, reason) end
	end
	local function stop_capture()
		if not stop_requested or binding or frames > 0 or capture_scope == nil or capture_released or retired then return end
		-- The retained exact scope prevents a replacement capture until release.
		frames = frames + 1
		local ok = pcall(function()
			if stop_issued and capture_scope.settled(capture_token) == true then return end
			stop_issued = true
			capture_stop()
		end)
		frames = frames - 1
		if not ok then reason = reason or "physical_history_capture_stop_failed" end
	end
	local function native_binder(operation, boolean_result, correlation, initial_snapshot)
		return function(owner, budget, receive, refused)
			if correlation then
				local ok, token, scope = operation(owner, budget, receive, refused, may_persist)
				if ok == true then context_token = token; return token, nil, scope end
				return nil, token, scope
			end
			if boolean_result then
				local ok, token, scope = operation(owner, budget, receive, refused)
				if ok == true then return token, nil, scope end
				return nil, token, scope
			end
			if initial_snapshot then return operation(owner, budget, receive, refused, true) end
			return operation(owner, budget, receive, refused)
		end
	end
	local function clock_ready(information)
		if not active or binding or capture_scope ~= nil then return false end
		binding, frames = true, frames + 1
		local ok, accepted = pcall(function()
			local bound, scope = capture_bind(subscriber)
			assert(active and bound == true and type(scope) == "table", "physical_history_capture_scope_unavailable")
			capture_scope = scope_ports(scope, { "identity", "current", "admitted", "clock", "settled", "release" })
			capture_token = capture_scope.identity()
			local cap, failure = clock_bind(subscriber)
			if cap ~= nil then
				clock_scope = scope_ports(cap, { "identity", "current", "read", "detach", "retired" })
				clock_token = clock_scope.identity(subscriber)
			end
			assert(active and clock_scope, failure or "physical_history_clock_scope_unavailable")
			-- The actual factory copies native timebase fields before any wall sample.
			coordinator = Coordinator.new(subscriber, capacity, {
				capture = capture_scope, clock = clock_scope,
				binders = {
					configuration = native_binder(configuration_bind, true),
					context = native_binder(context_bind, true, true),
					engine = native_binder(engine_bind, nil, nil, true), system = native_binder(system_bind, nil, nil, true),
					pause = native_binder(pause_bind, nil, nil, true),
				},
				projection = function(history)
					return project(subscriber, history, { capture = capture_scope, clock = clock_scope }, information)
				end,
				on_refused = refuse,
			})
			assert(active and coordinator.status().state == "bound", "physical_history_source_binding_refused")
			return true
		end)
		if not ok or accepted ~= true then refuse("physical_history_clock_ready_refused") end
		binding, frames = false, frames - 1
		stop_capture()
		return active and ok and accepted == true
	end
	local function baseline_ready()
		if not active or coordinator == nil or binding then return false end
		frames = frames + 1
		local ok, accepted = pcall(function()
			if coordinator.capture_ready() ~= true or not active then return false end
			if context_sample then
				local function current()
					return active and capture_scope.current(capture_token) == true
						and active and clock_scope.current(subscriber, clock_token) == true and active
				end
				if not current() then return false end
				local acknowledged = context_sample(subscriber, context_token)
				if not current() or acknowledged ~= true then return false end
			end
			return active
		end)
		if not ok or accepted ~= true then refuse("physical_history_baseline_ready_refused") end
		frames = frames - 1
		stop_capture()
		return active and ok and accepted == true
	end
	local function context(method, ...)
		if not active or coordinator == nil then return { allowed = false } end
		frames = frames + 1
		local ok, decision = pcall(coordinator[method], ...)
		if not ok then refuse("physical_history_context_failed") end
		frames = frames - 1
		stop_capture()
		if not active or not ok then return { allowed = false } end
		return decision
	end

	--- Revokes first, then requests stop only while this exact capture remains retained.
	function session.stop()
		active, stop_requested = false, true
		if coordinator then coordinator.stop() end
		stop_capture()
		return true
	end
	--- Releases CaptureScope only after real tasks, six sources and all frames retire.
	--- Callers retry while shutdown callbacks or source writers remain in flight.
	function session.retired()
		if notification_frames > 0 then return false end
		if retired then return true end
		if frames > 0 then retirement_reentered = true; return false end
		if active or binding then return false end
		retirement_reentered = false
		stop_capture()
		if retirement_reentered then return false end
		frames = frames + 1
		local ok, acknowledged = pcall(function()
			if coordinator then
				if coordinator.retired() ~= true then return false end
			elseif clock_scope then
				if clock_scope.detach(subscriber, clock_token) ~= true or clock_scope.retired(subscriber, clock_token) ~= true then return false end
			end
			if capture_scope and not capture_released then
				if capture_scope.settled(capture_token) ~= true or retirement_reentered then return false end
				if capture_scope.release(subscriber, capture_token) ~= true then return false end
				-- A true exact release ACK is monotonic, even when frame retirement is vetoed.
				capture_released = true
			end
			return true
		end)
		frames = frames - 1
		if not ok or acknowledged ~= true or retirement_reentered then return false end
		retired = true
		return true
	end
	--- Reports composition state; it establishes no installation or runtime authority.
	function session.status()
		local status = coordinator and coordinator.status() or {}
		status.state = retired and "retired" or not active and "stopping" or coordinator and status.state or "prepared"
		status.reason = reason or status.reason
		return status
	end
	local handlers = {
		notification = function(callback, ...)
			notification_frames = notification_frames + 1
			local ok = pcall(callback, ...)
			notification_frames = notification_frames - 1
			return ok
		end,
		clock_ready = clock_ready, baseline_ready = baseline_ready,
		context = function(ticks) return context("context", ticks) end,
		context_interval = function(first, last) return context("context_interval", first, last) end,
		retirement_hint = function(callback)
			if coordinator then return coordinator.on_retirement_hint(callback) end
			if clock_scope then
				local register = clock_scope.on_retired
				return type(register) == "function" and register(subscriber, clock_token, callback) == true
			end
			return true
		end,
	}
	return session, handlers
end

-- Managed owner implementation follows the preserved per-lease factory.
--- Owns only retained native scheduler handles; completion callbacks are hints.
local function event_owner(scheduler, receive, signal, refuse)
	local after, cancel, on_settled = port(scheduler, "after"), port(scheduler, "cancel"), port(scheduler, "onSettled")
	local records, uncertain = {}, false
	local events = {}
	function events.cancel(record)
		if record == nil or record.settled then return true end
		record.canceled = true
		if record.arming then return false end
		if record.handle == nil then uncertain = true; return false end
		local ok, settled = pcall(cancel, record.handle)
		if ok and settled == true then record.settled = true; records[record] = nil; return true end
		if not record.observing then
			record.observing = true
			local registered, accepted = pcall(on_settled, record.handle, signal)
			if not registered or accepted ~= true then uncertain = true; refuse("physical_history_scheduler_refused") end
		end
		return false
	end
	function events.arm(kind, delay, request)
		local record = { kind = kind, request = request, arming = true }
		records[record] = true
		local ok, handle, committed = pcall(after, delay, function()
			if record.arming then record.early = true; return end
			if not record.committed or record.canceled or record.delivered then return end
			record.delivered = true
			receive(record)
		end)
		record.arming, record.handle = false, ok and handle or nil
		record.committed = ok and type(handle) == "table" and committed == true and not record.early
		if not record.committed then events.cancel(record); refuse("physical_history_scheduler_refused") end
		return record, record.committed
	end
	function events.cancel_all()
		local snapshot, complete = {}, not uncertain
		for record in pairs(records) do snapshot[#snapshot + 1] = record end
		for _, record in ipairs(snapshot) do complete = events.cancel(record) and complete end
		return complete
	end
	function events.retired()
		return not uncertain and next(records) == nil
	end
	return events
end

--- Copies explicit existing start arguments without adding runtime authority.
local function start_options(value)
	assert(type(value) == "table" and getmetatable(value) == nil, "Missing physical capture options")
	local result = {}
	for _, name in ipairs({ "executable", "requirement", "batch_limit", "frame_limit" }) do result[name] = rawget(value, name) end
	local arguments = rawget(value, "arguments")
	assert(type(arguments) == "table" and getmetatable(arguments) == nil, "Missing physical capture arguments")
	result.arguments = {}
	for index, argument in next, arguments do result.arguments[index] = argument end
	return result
end

--- Creates a dormant once-init manager; all successor leases use fresh closures.
local function new_manager(capacity, on_refused, native_ports)
	local Policy = require("keylogger.physical_lease_policy")
	local policy_new = port(Policy, "new")
	local Scheduler = require("adapters.timer_scheduler")
	local managed_bind = rawget(Capture, "bind_managed_source")
	if type(managed_bind) ~= "function" then return nil, "physical_history_managed_unavailable" end
	local owner, manager = {}, {}
	local source, source_token, policy, policy_scope, policy_token
	local lease, retained_options, events, deferred
	local frames, pumping, hint_due = 0, false, false
	local terminal, finished, notified, reason, observer = false, false, false, nil, nil
	local unavailable_reason
	local observer_identity, observer_delivered
	local starting = false
	local held = false
	local pump, signal, stop, begin, manager_shutdown, schedule
	local function source_current() return source.current(owner, source_token) == true end
	local function source_identity() return source.lease_identity(owner, source_token) end
	local function wrapped(operation, ...)
		frames = frames + 1
		local result = table.pack(pcall(operation, ...))
		frames = frames - 1
		if not result[1] then stop("physical_history_policy_refused") end
		if frames == 0 and not pumping then pump() end
		if not result[1] then return nil end
		return table.unpack(result, 2, result.n)
	end
	local function foreign(operation, ...)
		frames = frames + 1
		local result = table.pack(pcall(operation, ...))
		frames = frames - 1
		if not result[1] then stop("physical_history_policy_refused") end
		if frames == 0 and not pumping then schedule() end
		if not result[1] then return nil end
		return table.unpack(result, 2, result.n)
	end
	local function refuse(message)
		if reason == nil then reason = message end
		terminal = true
		if lease then
			lease.stopped = true
			if not pcall(lease.facade_stop) then lease.stop_failed = true end
		end
		if policy then pcall(policy.stop, owner) end
		if not notified then
			notified = true
			frames = frames + 1
			pcall(on_refused, reason)
			frames = frames - 1
		end
	end
	local function lease_retired(candidate)
		if candidate == nil then return true end
		if candidate.complete then return true end
		if not candidate.stopped or candidate.binding or candidate.stop_failed or not candidate.native_stopped then return false end
		if candidate.facade_retired() ~= true then return false end
		candidate.complete = true
		return true
	end
	local function notify()
		if not finished or frames ~= 0 or observer == nil or observer_delivered then return end
		local callback = observer; observer = nil; observer_delivered = true
		frames = frames + 1
		pcall(callback, true)
		frames = frames - 1
	end
	signal = function()
		if finished then return end
		hint_due = true
		if frames == 0 and not pumping then schedule() end
	end
	local function retire(candidate)
		if candidate == nil or candidate.complete then return end
		if not candidate.stopped then hint_due = true end
		candidate.stopped = true
		candidate.facade_stop()
		if candidate.rotation then events.cancel(candidate.rotation) end
		if not candidate.native_stopped then
			local accepted = source.stop_lease(owner, source_token, candidate.native_observer)
			if accepted == true then candidate.native_stopped = true end
		end
	end
	local function consume_action(action, candidate)
		if type(action) ~= "table" then refuse("physical_history_policy_refused"); return end
		if action.action == "retire" then
			retire(candidate)
		elseif action.action == "retry" then
			candidate.retry = events.arm("retry", action.delay, candidate)
		elseif action.action == "start" then begin()
		elseif action.action == "hold" or action.action == "ready" then return
		elseif action.action == "deny" then stop(reason or "physical_history_manager_stopped")
		else refuse("physical_history_policy_refused") end
	end
	local function capture_identity(candidate)
		if terminal or held or not rawequal(lease, candidate) or candidate.stopped then return false end
		local native = source_identity()
		if type(native) ~= "table" or not source_current() then return false end
		if candidate.native_token ~= nil and not rawequal(candidate.native_token, native) then return false end
		if policy.captured(owner, candidate.request, native) ~= true then return false end
		candidate.native_token = native
		return true
	end
	local function routes(method, ...)
		return foreign(function(...)
			local candidate = lease
			if candidate == nil or not capture_identity(candidate) then
				if method == "context" or method == "context_interval" then return { allowed = false } end
				return false
			end
			if method == "clock_ready" then
				candidate.binding = true
				local accepted = candidate.handlers.clock_ready(...)
				candidate.binding = false
				if not candidate.hints then
					candidate.hints = true
					if candidate.handlers.retirement_hint(function() if rawequal(lease, candidate) then signal() end end) ~= true then
						refuse("physical_history_retirement_signal_refused")
					end
				end
				return not terminal and not held and not candidate.stopped and accepted == true
			elseif method == "baseline_ready" then
				if candidate.handlers.baseline_ready() ~= true or terminal or held or candidate.stopped then return false end
				local action = policy.admitted(owner, candidate.request, candidate.native_token)
				if type(action) ~= "table" or action.action ~= "arm_rotation" then refuse("physical_history_policy_refused"); return false end
				local record, committed = events.arm("rotation", action.delay, candidate)
				candidate.rotation = record
				return committed == true and not terminal and not held and not candidate.stopped
			end
			local decision = candidate.handlers[method](...)
			if terminal or held or candidate.stopped or not rawequal(lease, candidate) then return { allowed = false } end
			return decision
		end, ...)
	end
	local function verdict(record)
		return foreign(function()
			local candidate = lease
			if candidate == nil or type(record) ~= "table" or not rawequal(record.lease_token, source_identity()) then
				refuse("physical_history_verdict_refused"); return false
			end
			if candidate.native_token == nil then
				if not capture_identity(candidate) then refuse("physical_history_verdict_refused"); return false end
			end
			if not rawequal(candidate.native_token, record.lease_token) then refuse("physical_history_verdict_refused"); return false end
			if terminal then return true end
			local action = policy.verdict(owner, candidate.request, record)
			if action == nil then refuse("physical_history_verdict_refused"); return false end
			reason = record.reason
			consume_action(action, candidate)
			return true
		end) == true
	end
	begin = function()
		if terminal or held or starting then return false, "physical_history_manager_stopped" end
		local request = policy.begin(owner)
		if terminal or held then return false, "physical_history_manager_stopped" end
		if request == nil then return false, "physical_history_manager_not_prepared" end
		local candidate = { request = request }
		lease = candidate
		unavailable_reason = nil
		local lease_ports = {}
		for key, value in pairs(native_ports) do lease_ports[key] = value end
		candidate.native_observer = function(value)
			foreign(function()
				if value == true and rawequal(lease, candidate) then candidate.native_stopped = true; signal() end
			end)
		end
		lease_ports.capture_stop = function() return source.stop_lease(owner, source_token, candidate.native_observer) end
		local facade, handlers = new_session(capacity, function(message) refuse(message) end, lease_ports)
		candidate.facade_stop, candidate.facade_retired, candidate.facade_status = facade.stop, facade.retired, facade.status
		candidate.handlers = handlers
		candidate.view = {
			stop = function()
				if rawequal(lease, candidate) and not candidate.stopped then return manager_shutdown() end
				return true
			end,
			retired = function()
				if frames > 0 or pumping then return false end
				if not rawequal(lease, candidate) then return candidate.complete == true end
				return wrapped(function() return lease_retired(candidate) end) == true
			end,
			status = function()
				local status = candidate.facade_status()
				if candidate.complete then status.state = "retired" elseif candidate.stopped then status.state = "stopping" end
				return status
			end,
		}
		starting = true
		local accepted, actual = source.start(owner, source_token, retained_options)
		starting = false
		if actual ~= nil and candidate.native_token == nil and not candidate.stopped and not terminal then
			if not capture_identity(candidate) then refuse("physical_history_managed_start_refused") end
		end
		if accepted ~= true and not candidate.stopped and not terminal then refuse("physical_history_managed_start_refused") end
		if accepted == true then return true end
		return false, reason or "physical_history_managed_start_refused"
	end
	stop = function(message)
		if message then refuse(message) else terminal = true; if policy then policy.stop(owner) end end
		if lease then retire(lease) end
		events.cancel_all()
		return true
	end
	local function event(record)
		wrapped(function()
			if events.cancel(record) ~= true then stop("physical_history_scheduler_refused"); return end
			if record.kind == "continuation" then
				if rawequal(deferred, record) then deferred = nil end
			elseif not terminal and not held and rawequal(lease, record.request) then
				local candidate = record.request
				if record.kind == "rotation" then consume_action(policy.rotate(owner, candidate.request), candidate)
				elseif record.kind == "retry" then consume_action(policy.retry_ready(owner, candidate.request), candidate) end
			end
		end)
	end
	events = event_owner(Scheduler, event, signal, refuse)
	local final_observer = function() signal() end
	schedule = function()
		if deferred and deferred.settled then deferred = nil end
		if hint_due and not finished and deferred == nil and (terminal or lease and lease.stopped) then
			hint_due = false
			frames = frames + 1
			local record = events.arm("continuation", 0, lease)
			deferred = record
			frames = frames - 1
		end
	end
	pump = function()
		if frames > 0 or pumping or finished or source == nil then return end
		pumping, frames = true, frames + 1
		local ok = pcall(function()
			if deferred and deferred.delivered and events.cancel(deferred) == true then deferred = nil end
			if terminal then
				if lease then retire(lease) end
				if not events.cancel_all() or not lease_retired(lease) then return end
				if policy_scope then
					if policy_scope.detach(owner, policy_token) ~= true or policy_scope.retired(owner, policy_token) ~= true then return end
				end
				source.shutdown(owner, source_token, final_observer)
				if source.retired(owner, source_token) == true then finished, hint_due = true, false end
			elseif held or policy.status().state == "suspending" then
				if lease then retire(lease) end
				if not events.cancel_all() or not lease_retired(lease) then return end
				if policy.status().state == "suspending" then
					local action, refusal = policy.continue(owner, lease.request)
					if action then consume_action(action, lease)
					elseif refusal ~= "policy_retirement_pending" then refuse("physical_history_policy_refused") end
				end
			elseif lease and lease.stopped then
				retire(lease)
				if lease.rotation and events.cancel(lease.rotation) ~= true then return end
				if policy.status().state == "retiring" then
					local action, refusal = policy.continue(owner, lease.request)
					if action then consume_action(action, lease)
					elseif refusal ~= "policy_retirement_pending" then refuse("physical_history_policy_refused") end
				end
			end
		end)
		frames, pumping = frames - 1, false
		if not ok then refuse("physical_history_policy_refused") end
		if not terminal and lease and lease.complete and policy.status().state == "waiting" then hint_due = false end
		if not terminal and held and policy.status().state == "suspended" and events.retired() then hint_due = false end
		schedule()
		notify()
	end
	local capture_ports = {
		spawn = port(ShellRunner, "spawn"), decode = native_ports.decode, encode = native_ports.encode,
		clock_ready = function(info) return routes("clock_ready", info) end,
		baseline_ready = function() return routes("baseline_ready") end,
		context = function(ticks) return routes("context", ticks) end,
		context_interval = function(first, last) return routes("context_interval", first, last) end,
		-- Explicit managed metrics preserve platform IDs and add only the shared HID whitelist.
		keycode = require("keylogger.hid_metric_identity").with_virtual_keycodes(port(Identity, "resolve")),
		emit = port(LogManager, "log_physical_press"),
		emit_release = port(LogManager, "log_physical_release"), on_verdict = verdict,
	}
	initializing = true
	local initialized_ok, accepted = pcall(native_ports.capture_init, capture_ports)
	initializing = false
	if not initialized_ok or accepted ~= true then
		initialized = not initialized_ok
		return nil, initialized_ok and "physical_history_capture_already_initialized" or "physical_history_capture_initialization_failed"
	end
	initialized = true
	local bound_ok, actual, failure = pcall(managed_bind, owner)
	if not bound_ok or type(actual) ~= "table" then return nil, "physical_history_managed_binding_refused" end
	source = scope_ports(actual, { "identity", "current", "start", "stop_lease", "shutdown", "retired", "lease_identity", "select_unavailable" })
	source_token = source.identity(owner)
	assert(type(source_token) == "table", "Missing managed physical source identity")
	local actual_policy = policy_new(owner, { current = source_current, lease_identity = source_identity,
		retired = function(request) return lease and rawequal(lease.request, request) and lease_retired(lease) end })
	policy = scope_ports(actual_policy, { "begin", "captured", "admitted", "verdict", "rotate", "continue", "retry_ready", "stop", "status", "subscription", "suspend", "resume" })
	policy_scope = scope_ports(policy.subscription(), { "identity", "detach", "retired" }); policy_token = policy_scope.identity(owner)
	--- Delegates unavailable intent without beginning a lease or native work.
	--- Successful selection stays nonterminal; on_refused still owns terminal
	--- failures alone. The original source retains GAP and its first reason.
	---@param message string Explicit unavailable diagnostic, never runtime authority.
	---@return boolean selected Whether the captured source retained unavailable intent.
	---@return string|nil refusal Original source or manager refusal.
	function manager.select_unavailable(message)
		if terminal or finished then return false, "physical_history_manager_stopped" end
		if held then return false, "physical_history_manager_suspended" end
		if frames > 0 or pumping or policy.status().state ~= "prepared" then return false, "physical_history_manager_not_prepared" end
		local accepted, failure = wrapped(function()
			if not events.retired() or lease and not lease_retired(lease) then return false, "physical_history_manager_not_prepared" end
			local selected, refusal = source.select_unavailable(owner, source_token, message)
			if selected ~= true then return false, refusal end
			-- Settlement can synchronously latch shutdown or suspension. Keep
			-- the acquired source custody without publishing stale success.
			if terminal or finished then return false, "physical_history_manager_stopped" end
			if held then return false, "physical_history_manager_suspended" end
			if not source_current() then return false, "physical_history_managed_binding_refused" end
			unavailable_reason = unavailable_reason or message
			return true
		end)
		return accepted == true, failure
	end
	function manager.start(options)
		if terminal or finished then return false, "physical_history_manager_stopped" end
		if held then return false, "physical_history_manager_suspended" end
		if frames > 0 or pumping or policy.status().state ~= "prepared" then return false, "physical_history_manager_not_prepared" end
		local accepted, failure = wrapped(function() retained_options = start_options(options); return begin() end)
		return accepted == true, failure
	end
	--- Accepts a nonterminal off intent; actual retirement is observed separately.
	--- @return boolean accepted Selected owner retained, never a native retirement acknowledgement.
	function manager.suspend()
		if terminal or finished then return false end
		held = true
		return wrapped(function()
			local action = policy.suspend(owner)
			if action == nil then refuse("physical_history_policy_refused"); return false end
			consume_action(action, lease)
			if lease then retire(lease) end
			events.cancel_all()
			return not terminal
		end) == true
	end
	--- Retains one on intent without bypassing old source, callback or timer debt.
	--- @return boolean accepted Resume requested; an admitted successor is not implied.
	function manager.resume()
		if terminal or finished then return false end
		held = false
		return wrapped(function()
			local action = policy.resume(owner)
			if action == nil then refuse("physical_history_policy_refused"); return false end
			consume_action(action, lease)
			return not terminal
		end) == true
	end
	--- Observes a fully parked lease while preserving the selected accounting GAP.
	--- @return boolean quiescent No retained lease, callback or timer debt; not final retirement.
	function manager.quiescent()
		if frames > 0 or pumping or terminal or not held then return false end
		pump()
		return held and not terminal and frames == 0 and not pumping
			and policy.status().state == "suspended" and events.retired()
			and (lease == nil or lease.complete == true)
	end
	manager_shutdown = function(callback)
		assert(callback == nil or type(callback) == "function", "Invalid physical history stop observer")
		if callback then
			if observer_identity ~= nil and not rawequal(observer_identity, callback) then return false end
			observer_identity = callback
			if not observer_delivered then observer = callback end
		end
		wrapped(function() stop() end)
		notify()
		return true
	end
	manager.stop, manager.shutdown = manager_shutdown, manager_shutdown
	function manager.retired()
		if frames > 0 or pumping then return false end
		pump()
		return finished and events.retired()
	end
	function manager.status()
		local state = policy.status()
		local explanation = reason
		if state.state == "suspended" and (frames > 0 or pumping or not events.retired()) then state.state = "suspending" end
		if state.state == "prepared" and unavailable_reason then state.state, explanation = "unavailable", unavailable_reason end
		return { state = finished and "retired" or terminal and "stopped" or state.state,
			reason = explanation, retries_used = state.retries }
	end
	function manager.lease() return lease and lease.view or nil end
	return manager, nil, manager_shutdown
end

--- Dormant module shutdown forwarding does not add queries to legacy callers.
local function legacy_forwarder(session, handlers, native_ports, on_refused)
	local exact_stop, exact_retired = session.stop, session.retired
	local requested, observing, finished, frames = false, false, false, 0
	local callback, callback_identity, delivered, events, deferred
	local continuation, signal
	local function refuse() pcall(on_refused, "physical_history_retirement_signal_refused") end
	local function notify()
		if not finished or callback == nil or delivered or frames > 0 then return end
		delivered = true
		frames = frames + 1
		handlers.notification(callback, true)
		frames = frames - 1
	end
	local function check()
		if not requested or frames > 0 then return false end
		frames = frames + 1
		local ok, retired = pcall(exact_retired)
		frames = frames - 1
		if ok and retired == true and (events == nil or events.retired()) then finished = true end
		notify()
		return finished
	end
	signal = function()
		if finished or deferred ~= nil then return end
		local record = events.arm("legacy_continuation", 0)
		deferred = record
	end
	continuation = function(record)
		if events.cancel(record) ~= true then return end
		if rawequal(deferred, record) then deferred = nil end
		check()
	end
	local native_observer = function(value) if value == true then signal() end end
	local function shutdown(observer)
		assert(observer == nil or type(observer) == "function", "Invalid physical history stop observer")
		if observer and callback_identity and not rawequal(observer, callback_identity) then return false end
		if observer then callback, callback_identity = observer, observer end
		requested = true
		if observer and not observing then
			observing = true
			events = event_owner(require("adapters.timer_scheduler"), continuation, signal, refuse)
			frames = frames + 1
			local ok, accepted = pcall(handlers.retirement_hint, signal)
			frames = frames - 1
			if not ok or accepted ~= true then refuse(); return false end
		end
		frames = frames + 1
		local ok, accepted = pcall(exact_stop)
		if observer then pcall(native_ports.capture_stop, native_observer) end
		frames = frames - 1
		if not ok or accepted ~= true then return false end
		check()
		return true
	end
	return shutdown, function()
		if frames > 0 then return false end
		if not requested then return exact_retired() == true end
		return check()
	end
end

local current_owner, current_stop, current_retired
local module_frames = 0
local module_observer, module_callback

local function validate_options(options)
	if options == nil then return false end
	assert(type(options) == "table" and getmetatable(options) == nil and rawget(options, "managed") == true,
		"Invalid physical history session options")
	for name in next, options do assert(name == "managed", "Invalid physical history session options") end
	return true
end

--- Installs captured ports once; neither form starts or installs a native runtime.
function M.init(capacity, on_refused, options)
	local managed = validate_options(options)
	assert(math.type(capacity) == "integer" and capacity > 0 and capacity <= Coordinator.MAX_HISTORY,
		"Invalid native history session budget")
	assert(type(on_refused) == "function", "Missing native history session refusal observer")
	if initialized or initializing then return nil, "physical_history_session_already_initialized" end
	local native_ports = resolve_native_ports(managed)
	if managed then
		local manager, reason, stop = new_manager(capacity, on_refused, native_ports)
		if manager then current_owner, current_stop, current_retired = manager, stop, manager.retired end
		return manager, reason
	end
	local session, handlers = new_session(capacity, on_refused, native_ports)
	initializing = true
	local ok, accepted = pcall(native_ports.capture_init, {
		spawn = port(ShellRunner, "spawn"), decode = native_ports.decode, encode = native_ports.encode,
		clock_ready = handlers.clock_ready, baseline_ready = handlers.baseline_ready,
		context = handlers.context, context_interval = handlers.context_interval,
		keycode = port(Identity, "resolve"), emit = port(LogManager, "log_physical_press"),
		emit_release = port(LogManager, "log_physical_release"),
	})
	initializing = false
	if not ok or accepted ~= true then
		initialized = not ok
		return nil, ok and "physical_history_capture_already_initialized" or "physical_history_capture_initialization_failed"
	end
	initialized = true
	current_owner = session
	current_stop, current_retired = legacy_forwarder(session, handlers, native_ports, on_refused)
	return session
end

--- Forwards only to this module's privately captured, already initialized owner.
function M.stop(on_stopped)
	assert(on_stopped == nil or type(on_stopped) == "function", "Invalid physical history stop observer")
	if current_owner == nil then return true end
	if on_stopped and module_observer and not rawequal(on_stopped, module_observer) then return false end
	if on_stopped and module_callback == nil then
		module_observer = on_stopped
		module_callback = function(value)
			module_frames = module_frames + 1
			pcall(module_observer, value)
			module_frames = module_frames - 1
		end
	end
	local callback = on_stopped and module_callback or nil
	return current_stop(callback)
end
function M.retired()
	if module_frames > 0 then return false end
	if current_owner == nil then return true end
	return current_retired() == true
end
return M
