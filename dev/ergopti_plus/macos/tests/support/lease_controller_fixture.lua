--- tests/support/lease_controller_fixture.lua

--- ==============================================================================
--- MODULE: Lease Controller Fixture
--- DESCRIPTION:
--- Scopes native and dependency ownership without hiding task receipt boundaries.
--- ==============================================================================

local helpers = require("tests.helpers")

local UUIDS = {
	"00112233-4455-6677-8899-aabbccddeeff",
	"ffeeddcc-bbaa-9988-7766-554433221100",
}

--- Loads a fresh controller with controllable task and timer adapters.
--- @return table controller The freshly loaded controller module.
--- @return table ctx Controls and observations for spawned tasks and timers.
local function load_controller(options)
	options = options or {}
	package.loaded["platform.remap.lease_controller"] = nil
	package.loaded["adapters.shell_runner"] = nil
	package.loaded["adapters.storage"] = nil
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["platform.remap.ke_paths"] = nil
	package.loaded["platform.remap.lease_helper"] = nil
	local log_events = { warn = {}, error = {} }
	local logger = helpers.make_logger_stub()
	for _, level in ipairs({ "warn", "error" }) do
		logger[level] = function(...)
			log_events[level][#log_events[level] + 1] = { ... }
		end
	end
	package.loaded["infra.logger"] = logger

	local ctx = {
		spawns = {},
		timers = {},
		uuid_index = 0,
		ready_on_start = false,
		next_start_result = nil,
		next_input_result = nil,
		next_input_chunk = nil,
		next_timer_fired = false,
		next_after_callback_sync = false,
		next_after_error = nil,
		next_after_committed = nil,
		next_every_committed = nil,
		uuid_values = options.uuid_values or UUIDS,
		settings_store = options.settings_store or {},
		settings_get_failures = options.settings_get_failures or 0,
		settings_get_calls = 0,
		cancel_failures = options.cancel_failures or 0,
		cancel_attempts = 0,
		terminate_results = options.terminate_results or {},
		logs = log_events,
		helper_path = "/test/ErgoptiPlus",
		helper_error = nil,
		helper_resolve_calls = 0,
	}
	if options.helper_unavailable then
		ctx.helper_path = nil
		ctx.helper_error = "test helper unavailable"
	end

	package.loaded["adapters.shell_runner"] = {
		_active_tasks = {},
		spawn = function(executable, args, on_done, on_chunk)
			local start_result = ctx.next_start_result
			if start_result == nil then start_result = true end
			local task = {
				executable = executable,
				args = args,
				on_done = on_done,
				on_chunk = on_chunk,
				inputs = {},
				closed = false,
				terminated = false,
				terminate_calls = 0,
				start_result = start_result,
			}
			ctx.next_start_result = nil
			ctx.spawns[#ctx.spawns + 1] = task
			return {
				start = function()
					if ctx.ready_on_start and task.on_chunk then task.on_chunk(task, "READY\n", "") end
					return task.start_result
				end,
				set_input = function(data)
					local result = ctx.next_input_result
					if result == nil then result = true end
					ctx.next_input_result = nil
					if result then task.inputs[#task.inputs + 1] = data end
					local immediate_chunk = ctx.next_input_chunk
					ctx.next_input_chunk = nil
					if result and immediate_chunk and task.on_chunk then
						task.on_chunk(task, immediate_chunk, "")
					end
					return result
				end,
				close_input = function()
					task.closed = true
					return true
				end,
				terminate = function()
					task.terminate_calls = task.terminate_calls + 1
					local result = table.remove(ctx.terminate_results, 1)
					if result == nil then result = true end
					if result == "raise" then error("injected terminate failure") end
					if result == true then task.terminated = true end
					return result
				end,
			}
		end,
	}

	package.loaded["adapters.timer_scheduler"] = {
		after = function(_delay, fn)
			if ctx.next_after_error then
				local err = ctx.next_after_error
				ctx.next_after_error = nil
				error(err)
			end
			local handle = {
				delay = _delay,
				fn = fn,
				cancelled = false,
				fired = ctx.next_timer_fired,
			}
			ctx.next_timer_fired = false
			ctx.timers[#ctx.timers + 1] = handle
			if ctx.next_after_callback_sync then
				ctx.next_after_callback_sync = false
				fn()
			end
			local committed = ctx.next_after_committed
			if committed == nil then committed = true end
			ctx.next_after_committed = nil
			return handle, committed
		end,
		every = function(_delay, fn)
			local handle = {
				delay = _delay,
				fn = fn,
				cancelled = false,
				fired = ctx.next_timer_fired,
				repeating = true,
			}
			ctx.next_timer_fired = false
			ctx.timers[#ctx.timers + 1] = handle
			local committed = ctx.next_every_committed
			if committed == nil then committed = true end
			ctx.next_every_committed = nil
			return handle, committed
		end,
		cancel = function(handle)
			ctx.cancel_attempts = ctx.cancel_attempts + 1
			handle.cancel_attempts = (handle.cancel_attempts or 0) + 1
			if ctx.cancel_failures > 0
				and (ctx.cancel_target == nil or ctx.cancel_target == handle) then
				ctx.cancel_failures = ctx.cancel_failures - 1
				return false
			end
			if handle then handle.cancelled = true end
			return true
		end,
	}

	package.loaded["platform.remap.ke_paths"] = {
		CLI = "/test/karabiner_cli",
	}
	package.loaded["platform.remap.lease_helper"] = {
		resolve = function()
			ctx.helper_resolve_calls = ctx.helper_resolve_calls + 1
			return ctx.helper_path, ctx.helper_error
		end,
	}

	local controller = helpers.load_with_stubs("platform.remap.lease_controller", {
		host = {
			uuid = function()
				ctx.uuid_index = ctx.uuid_index + 1
				return ctx.uuid_values[ctx.uuid_index]
					or ctx.uuid_values[#ctx.uuid_values]
			end,
		},
		settings = {
			get = function(key)
				ctx.settings_get_calls = ctx.settings_get_calls + 1
				if ctx.settings_get_failures > 0 then
					ctx.settings_get_failures = ctx.settings_get_failures - 1
					error("injected settings read failure")
				end
				return ctx.settings_store[key]
			end,
			set = function(key, value)
				ctx.settings_store[key] = value
				return true
			end,
		},
	})

	--- Feeds one stdout protocol chunk to a spawned task.
	--- @param index integer Spawn index.
	--- @param stdout string Protocol bytes.
	function ctx.chunk(index, stdout)
		local task = ctx.spawns[index]
		helpers.assert_true(task ~= nil and type(task.on_chunk) == "function",
			"the selected spawn must have a streaming callback")
		task.on_chunk(task, stdout, "")
	end

	--- Completes one spawned task.
	--- @param index integer Spawn index.
	--- @param exit_code integer Process exit code.
	--- @param stdout string|nil Final stdout delivered by the task API.
	function ctx.complete(index, exit_code, stdout, keep_deferred)
		local task = ctx.spawns[index]
		helpers.assert_true(task ~= nil and type(task.on_done) == "function",
			"the selected spawn must have a completion callback")
		task.on_done(exit_code, stdout or "", "")
		if not keep_deferred then
			for _, timer in ipairs(ctx.timers) do
				if timer.delay == 0 and not timer.cancelled and not timer.fired then
					timer.fired = true
					timer.fn()
				end
			end
		end
	end

	--- Fires every live zero-delay completion finalizer.
	function ctx.fire_zero_timers()
		for _, timer in ipairs(ctx.timers) do
			if timer.delay == 0 and not timer.cancelled and not timer.fired then
				timer.fired = true
				timer.fn()
			end
		end
	end

	--- Fires the most recent live ACK timeout.
	function ctx.fire_latest_timer()
		for index = #ctx.timers, 1, -1 do
			local timer = ctx.timers[index]
			if not timer.cancelled and not timer.fired then
				timer.fired = true
				timer.fn()
				return
			end
		end
		error("no live timer to fire")
	end

	--- Fires the retained heartbeat timer without consuming its recurring handle.
	function ctx.fire_heartbeat_timer()
		for index = #ctx.timers, 1, -1 do
			local timer = ctx.timers[index]
			if timer.repeating and not timer.cancelled and not timer.fired then
				timer.fn()
				return timer
			end
		end
		error("no live heartbeat timer to fire")
	end

	return controller, ctx
end

--- Finds a native detached revoker for the exact generation variables.
--- @param ctx table Harness context.
--- @param variables table Generation identity returned by controller.variables().
--- @return table|nil task Matching spawn.
local function find_native_revoke(ctx, variables)
	for _, task in ipairs(ctx.spawns) do
		if task.executable == "/test/ErgoptiPlus"
			and task.args[1] == "--karabiner-lease-revoke"
			and task.args[2] == "/test/karabiner_cli"
			and task.args[3] == variables.mode
			and task.args[4] == variables.revoked then
			return task
		end
	end
	return nil
end

local function with_fixture(callback)
	return helpers.with_stub_scope({
		"platform.remap.lease_controller", "adapters.shell_runner", "adapters.storage",
		"adapters.timer_scheduler", "platform.remap.ke_paths", "platform.remap.lease_helper",
		"infra.logger",
	}, function()
		return callback(load_controller)
	end)
end

return {
	with_fixture = with_fixture,
	find_native_revoke = find_native_revoke,
	UUIDS = UUIDS,
}
