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
	return result
end

--- Installs actual native producer ports once without launching or enabling capture.
--- A qualified runtime owner must later start Capture; this adapter selects no path,
--- signing authority or runtime artifact, and never changes the default source.
---@param capacity integer Exact bounded writer/history receipt budget.
---@param on_refused function Terminal native composition notification after denial.
---@return table|nil session Context ownership and exact shutdown/retirement ports.
---@return string|nil reason Explicit duplicate/native acquisition refusal.
function M.init(capacity, on_refused)
	assert(math.type(capacity) == "integer" and capacity > 0 and capacity <= Coordinator.MAX_HISTORY,
		"Invalid native history session budget")
	assert(type(on_refused) == "function", "Missing native history session refusal observer")
	if initialized or initializing then return nil, "physical_history_session_already_initialized" end
	local native = rawget(_G, "hs")
	local json = type(native) == "table" and rawget(native, "json") or nil
	local decode, encode = port(json, "decode"), port(json, "encode")
	local capture_init, capture_bind, capture_stop = port(Capture, "init"), port(Capture, "bind_history_scope"), port(Capture, "stop")
	local clock_bind, project = port(Clock, "bind_history_scope"), port(Context, "new")
	local configuration_bind = port(Keylogger, "bind_physical_configuration_observer")
	local context_bind, may_persist = port(Tracker, "bind_physical_correlated_context_observer"), port(Keylogger, "may_persist")
	local engine_bind = port(Keylogger, "bind_physical_lifecycle_observer")
	local system_bind, pause_bind = port(Watchers, "bind_physical_lifecycle_observer"), port(ScriptControl, "bind_physical_pause_observer")
	local subscriber, session = {}, {}
	local active, binding, frames, retired = true, false, 0, false
	local coordinator, capture_scope, clock_scope, capture_token, clock_token
	local reason, stop_requested, stop_issued = nil, false, false
	local retirement_reentered, capture_released = false, false
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
	local function native_binder(operation, boolean_result, correlation)
		return function(owner, budget, receive, refused)
			if correlation then
				local ok, token, scope = operation(owner, budget, receive, refused, may_persist)
				if ok == true then return token, nil, scope end
				return nil, token, scope
			end
			if boolean_result then
				local ok, token, scope = operation(owner, budget, receive, refused)
				if ok == true then return token, nil, scope end
				return nil, token, scope
			end
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
					engine = native_binder(engine_bind), system = native_binder(system_bind), pause = native_binder(pause_bind),
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
		local ok, accepted = pcall(coordinator.capture_ready)
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
	initializing = true
	local ok, accepted = pcall(capture_init, {
		spawn = port(ShellRunner, "spawn"), decode = decode, encode = encode, clock_ready = clock_ready,
		baseline_ready = baseline_ready,
		context = function(ticks) return context("context", ticks) end,
		context_interval = function(first, last) return context("context_interval", first, last) end,
		keycode = port(Identity, "resolve"), emit = port(LogManager, "log_physical_press"),
		emit_release = port(LogManager, "log_physical_release"),
	})
	initializing = false
	if not ok or accepted ~= true then
		active = false
		-- A thrown initializer may have installed the captured ports; never reopen them.
		initialized = not ok
		return nil, ok and "physical_history_capture_already_initialized" or "physical_history_capture_initialization_failed"
	end
	initialized = true

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
	return session
end

return M
