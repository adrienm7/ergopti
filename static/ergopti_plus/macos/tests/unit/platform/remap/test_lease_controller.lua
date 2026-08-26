--- tests/unit/platform/remap/test_lease_controller.lua

--- ==============================================================================
--- MODULE: Karabiner Lease Controller Regression Tests
--- DESCRIPTION:
--- Exercises the fail-closed protocol that makes Ergopti rules inert whenever
--- their owning Hammerspoon generation disappears. The tests drive task output,
--- completion and ACK timeouts directly so callback ordering is proven rather
--- than inferred from source spelling.
---
--- FEATURES & RATIONALE:
--- 1. Readiness: a launched helper is not active until its explicit READY ACK.
--- 2. Fail-closed commands: pause, resume and stop require protocol ACKs, while
---    malformed output and timeouts revoke the exact generation lease.
--- 3. Generation isolation: a late completion from an old helper cannot mutate
---    or revoke a newer generation because every fallback carries captured names.
--- 4. Helper replacement: worker generations and fallback retries re-resolve
---    exact launcher path/device/inode identity before constructing each task.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ========================================
-- ========================================
-- ======= 1/ Deterministic Harness =======
-- ========================================
-- ========================================

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





-- ==========================================
-- ==========================================
-- ======= 2/ Activation and Identity =======
-- ==========================================
-- ==========================================

helpers.describe("karabiner lease controller: activation identity", function()
	helpers.it("reports initialization without logging or allocating a lease", function()
		local controller, ctx = load_controller()
		helpers.assert_true(controller.is_initialized() == false)
		helpers.assert_eq(ctx.helper_resolve_calls, 0,
			"the state probe must not resolve or launch the native helper")

		controller.init()
		helpers.assert_true(controller.is_initialized() == true)
		helpers.assert_eq(#ctx.spawns, 0,
			"initialization status must remain side-effect-free")
	end)

	helpers.it("parses only one canonical side-effect-free guardian status line", function()
		local controller, ctx = load_controller()
		controller.init()
		local observed = {}
		local last_cached_status = nil

		for _, fixture in ipairs({
			{ stdout = "ready\n", expected = "ready" },
			{ stdout = "requires_approval\n", expected = "requires_approval" },
			{ stdout = "unavailable\n", expected = "unavailable" },
			{ stdout = "ready\nready\n", expected = nil },
			{ stdout = "unknown\n", expected = nil },
			{ stdout = string.rep("x", 33), expected = nil },
			{ stdout = "ready\n", exit_code = 9, expected = nil },
		}) do
			local handle, reason = controller.probe_guardian_status(function(status)
				observed[#observed + 1] = status or false
			end)
			helpers.assert_true(type(handle) == "table")
			helpers.assert_eq(reason, nil)
			local spawn = ctx.spawns[#ctx.spawns]
			helpers.assert_true(helpers.deep_equal(spawn.args, { "--remap-guardian-status" }))
			ctx.complete(#ctx.spawns, fixture.exit_code or 0, fixture.stdout)
			helpers.assert_eq(observed[#observed], fixture.expected or false)
			if fixture.expected then last_cached_status = fixture.expected end
			local _, snapshot = controller.status()
			helpers.assert_eq(snapshot.guardian_status, last_cached_status,
				"only a canonical successful native probe may replace the cached status")
		end
	end)

	helpers.it("rejects a guardian probe whose exact helper cannot start", function()
		local controller, ctx = load_controller()
		controller.init()
		ctx.next_start_result = false
		local callback_count = 0
		local handle, reason = controller.probe_guardian_status(function()
			callback_count = callback_count + 1
		end)

		helpers.assert_eq(handle, nil)
		helpers.assert_eq(reason, "helper-start-failed")
		helpers.assert_eq(callback_count, 0)
	end)

	helpers.it("invalidates a cancelled guardian observation before retrying exact termination", function()
		local controller, ctx = load_controller({ terminate_results = { false, true } })
		controller.init()
		controller.probe_guardian_status(function() end)
		ctx.complete(1, 0, "requires_approval\n")

		local callback_count = 0
		local handle = controller.probe_guardian_status(function()
			callback_count = callback_count + 1
		end)
		helpers.assert_type(handle, "table")
		helpers.assert_true(handle.terminate() == false,
			"logical cancellation must survive a failed native terminate")
		helpers.assert_eq(ctx.spawns[2].terminate_calls, 1)

		ctx.complete(2, 0, "ready\n")
		local _, snapshot = controller.status()
		helpers.assert_eq(callback_count, 0,
			"a cancelled native completion must not reach its consumer")
		helpers.assert_eq(snapshot.guardian_status, "requires_approval",
			"a cancelled native completion must not replace cached authorization")

		helpers.assert_true(handle.terminate(),
			"the wrapper must retry termination through the same raw handle")
		helpers.assert_eq(ctx.spawns[2].terminate_calls, 2)
		helpers.assert_true(ctx.spawns[2].terminated)
	end)

	helpers.it("keeps a newer guardian ready probe over an older settings result", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.probe_guardian_status(function() end)
		ctx.complete(1, 0, "requires_approval\n")

		helpers.assert_true(controller.open_guardian_settings(function() end))
		local observed = nil
		controller.probe_guardian_status(function(status) observed = status end)
		ctx.complete(3, 0, "ready\n")
		helpers.assert_eq(observed, "ready")

		ctx.complete(2, 0, "not_required\n")
		local _, snapshot = controller.status()
		helpers.assert_eq(snapshot.guardian_status, "ready",
			"an older settings completion must not clear a newer status observation")
	end)

	helpers.it("keeps a newer guardian settings recheck over an older status completion", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.probe_guardian_status(function() end)
		ctx.complete(1, 0, "requires_approval\n")

		local stale_callback_count = 0
		controller.probe_guardian_status(function()
			stale_callback_count = stale_callback_count + 1
		end)
		helpers.assert_true(controller.open_guardian_settings(function() end))
		ctx.complete(3, 0, "not_required\n")
		ctx.complete(2, 0, "requires_approval\n")

		local _, snapshot = controller.status()
		helpers.assert_eq(stale_callback_count, 0,
			"a superseded status observation must not reach its consumer")
		helpers.assert_nil(snapshot.guardian_status,
			"an older status completion must not overwrite the newer settings recheck")
	end)

	helpers.it("returns routine guardian probe failures without per-poll controller logs", function()
		local controller, ctx = load_controller()
		controller.init()
		local baseline_warns = #ctx.logs.warn
		local baseline_errors = #ctx.logs.error
		local callback_count = 0

		ctx.helper_path = nil
		ctx.helper_error = "runtime helper identity unavailable"
		for _ = 1, 3 do
			local handle, reason = controller.probe_guardian_status(function()
				callback_count = callback_count + 1
			end)
			helpers.assert_nil(handle)
			helpers.assert_eq(reason, "runtime helper identity unavailable")
		end
		ctx.helper_path = "/test/ErgoptiPlus"
		ctx.helper_error = nil
		for _ = 1, 3 do
			ctx.next_start_result = false
			local handle, reason = controller.probe_guardian_status(function()
				callback_count = callback_count + 1
			end)
			helpers.assert_nil(handle)
			helpers.assert_eq(reason, "helper-start-failed")
		end
		for _ = 1, 3 do
			local handle = controller.probe_guardian_status(function(status, reason)
				callback_count = callback_count + 1
				helpers.assert_nil(status)
				helpers.assert_type(reason, "string")
			end)
			helpers.assert_type(handle, "table")
			ctx.complete(#ctx.spawns, 9, "malformed\n")
		end

		helpers.assert_eq(callback_count, 3,
			"only started probes may deliver routine failure callbacks")
		helpers.assert_eq(#ctx.logs.warn, baseline_warns)
		helpers.assert_eq(#ctx.logs.error, baseline_errors,
			"the polling owner, not the controller, must rate-limit external failures")
	end)

	helpers.it("accepts only one canonical guardian settings result from exact argv", function()
		for _, fixture in ipairs({
			{ stdout = "opened\n", expected_ok = true, expected_reason = "opened" },
			{ stdout = "not_required\n", expected_ok = true, expected_reason = "not_required" },
			{ stdout = "opened\nopened\n", expected_ok = false },
			{ stdout = "unknown\n", expected_ok = false },
			{ stdout = string.rep("x", 33), expected_ok = false },
			{ stdout = "opened\n", exit_code = 9, expected_ok = false },
		}) do
			local controller, ctx = load_controller()
			controller.init()
			local probe_handle = controller.probe_guardian_status(function() end)
			helpers.assert_type(probe_handle, "table")
			ctx.complete(1, 0, "requires_approval\n")

			local callback_count = 0
			local callback_ok, callback_reason = nil, nil
			local accepted = controller.open_guardian_settings(function(ok, reason)
				callback_count = callback_count + 1
				callback_ok, callback_reason = ok, reason
			end)
			helpers.assert_true(accepted,
				"a cached approval requirement must permit the explicit settings request")
			local settings_task = ctx.spawns[2]
			helpers.assert_not_nil(settings_task)
			helpers.assert_true(helpers.deep_equal(settings_task.args,
				{ "--open-remap-guardian-settings" }),
				"the explicit action must pass exactly one native launcher flag")

			ctx.complete(2, fixture.exit_code or 0, fixture.stdout)
			helpers.assert_eq(callback_count, 1,
				"every accepted settings process must settle its callback exactly once")
			helpers.assert_eq(callback_ok, fixture.expected_ok)
			if fixture.expected_ok then
				helpers.assert_eq(callback_reason, fixture.expected_reason)
			else
				helpers.assert_type(callback_reason, "string")
			end
			local _, snapshot = controller.status()
			if fixture.expected_reason == "not_required" then
				helpers.assert_nil(snapshot.guardian_status,
					"a native not-required result must retire the stale approval hint")
			else
				helpers.assert_eq(snapshot.guardian_status, "requires_approval",
					"opening or rejecting Settings must not manufacture guardian readiness")
			end
		end
	end)

	helpers.it("rejects a guardian settings request whose exact helper cannot start", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.probe_guardian_status(function() end)
		ctx.complete(1, 0, "requires_approval\n")
		ctx.next_start_result = false
		local callback_count = 0
		local callback_ok, callback_reason = nil, nil

		local accepted = controller.open_guardian_settings(function(ok, reason)
			callback_count = callback_count + 1
			callback_ok, callback_reason = ok, reason
		end)

		helpers.assert_true(accepted == false)
		helpers.assert_eq(callback_count, 1)
		helpers.assert_true(callback_ok == false)
		helpers.assert_eq(callback_reason, "helper-start-failed")
		helpers.assert_true(helpers.deep_equal(ctx.spawns[2].args,
			{ "--open-remap-guardian-settings" }))
	end)

	helpers.it("joins repeated guardian settings clicks into one native request", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.probe_guardian_status(function() end)
		ctx.complete(1, 0, "requires_approval\n")
		local results = {}

		helpers.assert_true(controller.open_guardian_settings(function(ok, reason)
			results[#results + 1] = { ok = ok, reason = reason }
		end))
		helpers.assert_true(controller.open_guardian_settings(function(ok, reason)
			results[#results + 1] = { ok = ok, reason = reason }
		end))
		helpers.assert_eq(#ctx.spawns, 2,
			"repeated menu clicks must join the retained request instead of opening twice")

		ctx.complete(2, 0, "opened\n")
		helpers.assert_eq(#results, 2)
		for _, result in ipairs(results) do
			helpers.assert_true(result.ok == true)
			helpers.assert_eq(result.reason, "opened")
		end
	end)

	helpers.it("revalidates helper identity before each generation spawn", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.start()
		ctx.chunk(1, "READY\n")
		controller.stop("replace helper identity")
		ctx.chunk(1, "STOPPED\n")
		ctx.helper_path = nil
		ctx.helper_error = "helper inode changed"
		local callback_ok = nil

		helpers.assert_true(not controller.start(function(ok) callback_ok = ok end))
		helpers.assert_true(callback_ok == false)
		helpers.assert_eq(#ctx.spawns, 1,
			"a helper replaced between generations must never cross ShellRunner.spawn again")
		helpers.assert_eq(ctx.helper_resolve_calls, 3,
			"each generation must re-resolve identity instead of trusting a cached path")
	end)

	helpers.it("revalidates helper identity before a fallback attempt", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.start()
		ctx.chunk(1, "READY\n")
		ctx.helper_path = nil
		ctx.helper_error = "helper inode changed"

		ctx.complete(1, 9, "")

		helpers.assert_eq(#ctx.spawns, 1,
			"a changed helper must not become a detached revoker from the cached path")
		helpers.assert_eq(ctx.helper_resolve_calls, 3,
			"worker and fallback boundaries must each observe current helper identity")
		local retry = ctx.timers[#ctx.timers]
		helpers.assert_true(retry and retry.delay == 1 and not retry.cancelled,
			"failed identity revalidation must keep exact fencing pending for retry")
	end)

	helpers.it("revalidates helper identity between fallback retries", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.start()
		ctx.chunk(1, "READY\n")
		ctx.complete(1, 9, "")
		helpers.assert_eq(#ctx.spawns, 2,
			"the first fallback attempt must use the still-valid helper identity")

		ctx.helper_path = nil
		ctx.helper_error = "helper inode changed between retries"
		ctx.complete(2, 1, "")
		ctx.fire_latest_timer()

		helpers.assert_eq(#ctx.spawns, 2,
			"a replacement helper must not execute on a later fallback retry")
		helpers.assert_eq(ctx.helper_resolve_calls, 4,
			"each fallback retry must independently re-resolve the helper identity")
		local retry = ctx.timers[#ctx.timers]
		helpers.assert_true(retry and retry.delay == 1 and not retry.cancelled,
			"identity rejection must preserve the unresolved exact fence obligation")
	end)

	helpers.it("exhausts a permanently missing fallback helper and settles joined stops loudly", function()
		local controller, ctx = load_controller()
		controller.init()
		local start_results = {}
		local stop_results = {}
		controller.start(function(ok, reason)
			start_results[#start_results + 1] = { ok = ok, reason = reason }
		end)
		ctx.helper_path = nil
		ctx.helper_error = "helper identity permanently unavailable"

		ctx.complete(1, 9, "")
		helpers.assert_true(controller.stop("join exhausted fence", function(ok, reason)
			stop_results[#stop_results + 1] = { ok = ok, reason = reason }
		end))
		helpers.assert_eq(#stop_results, 0,
			"joined Stop must wait while bounded fallback attempts remain")
		ctx.fire_latest_timer()
		ctx.fire_latest_timer()

		helpers.assert_eq(#ctx.spawns, 1,
			"an unresolvable helper identity must never cross ShellRunner.spawn")
		helpers.assert_eq(ctx.helper_resolve_calls, 5,
			"init, worker, and exactly three fallback identity checks are expected")
		helpers.assert_eq(#start_results, 1,
			"the failed start must settle once when bounded fencing gives up")
		helpers.assert_true(start_results[1].ok == false)
		helpers.assert_eq(#stop_results, 1)
		helpers.assert_true(stop_results[1].ok == false)
		helpers.assert_eq(stop_results[1].reason, "fallback-retry-exhausted")
		local phase, snapshot = controller.status()
		helpers.assert_eq(phase, "fencing",
			"exhaustion must never fabricate proof that the exact variables were revoked")
		helpers.assert_true(snapshot.fallback_exhausted == true)
		helpers.assert_eq(snapshot.fallback_attempts, 3)
		helpers.assert_eq(snapshot.fallback_exhausted_reason, "fallback-retry-exhausted")
		local live_fallback_timers = 0
		for _, timer in ipairs(ctx.timers) do
			if timer.delay == 1 and not timer.cancelled and not timer.fired then
				live_fallback_timers = live_fallback_timers + 1
			end
		end
		helpers.assert_eq(live_fallback_timers, 0,
			"exhaustion must not leave a fourth fallback attempt armed")
		local terminal_error = nil
		for _, event in ipairs(ctx.logs.error) do
			if type(event[2]) == "string"
				and event[2]:find("variables remain fenced", 1, true) then
				terminal_error = event
			end
		end
		helpers.assert_not_nil(terminal_error,
			"permanent fallback failure must be visible at ERROR severity")
		helpers.assert_eq(terminal_error[4], 3,
			"the terminal diagnostic must report the exact bounded attempt count")
		helpers.assert_nil(controller.token(),
			"unproven variables must still block replacement generation allocation")

		local joined_again = {}
		helpers.assert_true(controller.stop("join exhausted fence again", function(ok, reason)
			joined_again[#joined_again + 1] = { ok = ok, reason = reason }
		end))
		helpers.assert_eq(#joined_again, 1,
			"later Stop callers must receive the retained degraded terminal immediately")
		helpers.assert_true(joined_again[1].ok == false)
		helpers.assert_eq(joined_again[1].reason, "fallback-retry-exhausted")
	end)

	helpers.it("publishes guarded lifecycle phases to dependent resource owners", function()
		local controller, ctx = load_controller()
		local phases = {}
		controller.init(function(phase) phases[#phases + 1] = phase end)
		controller.token()
		controller.start()
		ctx.chunk(1, "READY\n")
		ctx.complete(1, 9, "")
		helpers.assert_eq(controller.status(), "fencing")
		ctx.complete(2, 0, "")

		helpers.assert_true(helpers.deep_equal(phases, {
			"idle", "prepared", "starting", "active", "fencing", "failed",
		}), "dependents must be able to release resources after an unexpected watchdog death")
	end)

	helpers.it("stays starting until READY and uses one exact 32-hex token", function()
		local controller, ctx = load_controller()
		helpers.assert_true(controller.init(), "init must succeed without external side effects")

		local token = controller.token()
		helpers.assert_eq(token, "00112233445566778899aabbccddeeff",
			"the RFC 4122 UUID must be normalized to exactly 32 lowercase hex digits")
		local vars = controller.variables()
		local contract = require("platform.remap.lease_contract")
		helpers.assert_true(helpers.deep_equal(vars, contract.variables(token)),
			"controller names must exactly equal the generator's pure mode contract")
		helpers.assert_eq(vars.mode, "ergopti_mode_" .. token, "mode name must be token-scoped")

		local ready_ok = nil
		helpers.assert_true(controller.start(function(ok) ready_ok = ok end),
			"start must report that the watchdog task launched")
		helpers.assert_eq(controller.status(), "starting", "launch alone must never imply activation")
		helpers.assert_nil(ready_ok, "the readiness callback must wait for READY")

		local watchdog = ctx.spawns[1]
		helpers.assert_eq(watchdog.executable, "/test/ErgoptiPlus",
			"watchdog must use the packaged native launcher executable")
		helpers.assert_eq(watchdog.args[1], "--karabiner-lease-worker",
			"the native worker mode must be an explicit argv entry")
		helpers.assert_eq(watchdog.args[2], "/test/karabiner_cli", "CLI path must be an argv entry")
		helpers.assert_eq(watchdog.args[3], vars.mode, "watchdog must receive only this atomic mode name")
		helpers.assert_eq(watchdog.args[4], vars.revoked,
			"watchdog must receive the exact same-generation revocation fence")
		helpers.assert_eq(watchdog.args[5], "1",
			"normal cold start must explicitly request the non-paused activation mode")
		helpers.assert_eq(watchdog.args[6], "5",
			"production heartbeat must use the bounded five-second recovery interval")

		ctx.chunk(1, "READY\n")
		helpers.assert_eq(controller.status(), "active",
			"READY follows the clean HS-originated ACTIVATE transport")
		helpers.assert_true(ready_ok == true, "start callback must succeed after READY")
		local heartbeat = ctx.timers[#ctx.timers]
		helpers.assert_true(heartbeat.repeating and heartbeat.delay == 5,
			"the recurring timer must be retained before the live phase is published")
		helpers.assert_eq(#watchdog.inputs, 0,
			"ACTIVATE is the bootstrap pulse; startup must not add a redundant CLI PING")
	end)

	helpers.it("starts a recovery generation atomically paused before READY", function()
		local controller, ctx = load_controller()
		controller.init()
		local ready_ok, ready_reason = nil, nil

		helpers.assert_true(controller.start_paused(function(ok, reason)
			ready_ok, ready_reason = ok, reason
		end), "the dedicated rollback path must accept a fresh paused generation")
		helpers.assert_eq(ctx.spawns[1].args[5], "2",
			"paused recovery must select atomic mode=2 before READY")
		helpers.assert_eq(controller.status(), "starting")
		helpers.assert_nil(ready_ok)

		ctx.chunk(1, "READY\n")
		helpers.assert_eq(controller.status(), "paused",
			"READY for an initially paused watchdog must never publish active")
		helpers.assert_true(ready_ok == true)
		helpers.assert_eq(ready_reason, "ready-paused")
		helpers.assert_eq(#ctx.spawns[1].inputs, 0,
			"atomic paused activation must not rely on a racy post-READY PAUSE write")
	end)

	helpers.it("does not let prepared activation overtake a PAUSE queued before READY", function()
		local controller, ctx = load_controller()
		controller.init()
		local token = controller.token()
		local prepared_ok, prepared_reason, prepared_accepted = nil, nil, nil
		local pause_ok, pause_reason = nil, nil

		helpers.assert_true(controller.start_paused(function(ok)
			helpers.assert_true(ok, "paused READY must reach the preparation callback")
			prepared_accepted = controller.resume_prepared(token, function(resumed, reason)
				prepared_ok, prepared_reason = resumed, reason
			end)
		end))
		helpers.assert_true(controller.pause(function(ok, reason)
			pause_ok, pause_reason = ok, reason
		end), "PAUSE while STARTING must be serialized, not dropped")

		ctx.chunk(1, "READY\n")
		helpers.assert_true(prepared_accepted == false,
			"internal activation must be refused while the older PAUSE owns intent")
		helpers.assert_true(prepared_ok == false)
		helpers.assert_eq(prepared_reason, "pause-intent-pending")
		helpers.assert_true(pause_ok == true)
		helpers.assert_eq(pause_reason, "already-paused")
		helpers.assert_eq(controller.status(), "paused")
		helpers.assert_eq(#ctx.spawns[1].inputs, 0,
			"the worker must receive no RESUME after an older PAUSE request")
	end)

	helpers.it("never becomes active when the helper exits before READY", function()
		local controller, ctx = load_controller()
		controller.init()
		local vars = controller.variables()
		local ready_ok = nil
		controller.start(function(ok) ready_ok = ok end)

		ctx.complete(1, 70, "")
		helpers.assert_eq(controller.status(), "fencing",
			"a pre-READY exit remains ambiguous until native revocation finishes")
		helpers.assert_nil(ready_ok, "start callback must not permit retry before the fence")
		helpers.assert_not_nil(find_native_revoke(ctx, vars),
			"completion fallback must revoke exactly the failed generation variables")
		ctx.complete(2, 0, "")
		helpers.assert_eq(controller.status(), "failed", "safe failure publishes only after the fence")
		helpers.assert_true(ready_ok == false, "start callback must expose activation failure after fencing")
	end)

	helpers.it("does not fence variables when the primary worker never launched", function()
		local controller, ctx = load_controller()
		controller.init()
		local first_token = controller.token()
		ctx.next_start_result = false
		local callback_calls = 0
		local callback_ok = nil

		local started = controller.start(function(ok)
			callback_calls = callback_calls + 1
			callback_ok = ok
		end)

		helpers.assert_eq(started, false)
		helpers.assert_eq(callback_calls, 1,
			"a proven prelaunch refusal must settle immediately rather than await a needless fence")
		helpers.assert_true(callback_ok == false)
		helpers.assert_eq(#ctx.spawns, 1,
			"no fallback revoker is needed when start() proves the worker never ran")
		helpers.assert_eq(controller.status(), "failed")

		local replacement = controller.variables()
		helpers.assert_not_nil(replacement)
		helpers.assert_true(replacement.token ~= first_token)
		helpers.assert_true(controller.start(), "a later executable helper may start a fresh generation")
	end)

	helpers.it("rejects a final READY chunk from an unexpectedly failed watchdog", function()
		local controller, ctx = load_controller()
		local phases = {}
		local callback_calls = 0
		local callback_result = nil
		controller.init(function(phase) phases[#phases + 1] = phase end)
		controller.start(function(ok)
			callback_calls = callback_calls + 1
			callback_result = ok
		end)

		ctx.complete(1, 9, "READY\n")

		helpers.assert_eq(callback_calls, 0, "start callback must wait for the exact fallback fence")
		ctx.complete(2, 0, "")
		helpers.assert_eq(callback_calls, 1, "start callback must settle exactly once after fencing")
		helpers.assert_true(callback_result == false,
			"non-zero completion must outrank buffered protocol output")
		helpers.assert_eq(controller.status(), "failed")
		for _, phase in ipairs(phases) do
			helpers.assert_true(phase ~= "active" and phase ~= "paused",
				"final completion output must never publish a live phase")
		end
	end)

	helpers.it("retries duplicate UUIDs without ever publishing a reused token", function()
		local controller, ctx = load_controller({
			uuid_values = {
				UUIDS[1],
				UUIDS[1],
				UUIDS[2],
			},
		})
		controller.init()
		local first = controller.token()
		controller.stop("discard prepared token")
		local second = controller.token()

		helpers.assert_eq(first, "00112233445566778899aabbccddeeff")
		helpers.assert_eq(second, "ffeeddccbbaa99887766554433221100")
		helpers.assert_eq(ctx.uuid_index, 3,
			"the duplicate must be consumed and retried before publication")
		helpers.assert_eq(#ctx.spawns, 0, "token allocation retries must have no task side effects")
	end)

	helpers.it("fails closed when the UUID source can only repeat a used token", function()
		local controller, ctx = load_controller({ uuid_values = { UUIDS[1] } })
		controller.init()
		local first = controller.token()
		controller.stop("discard prepared token")
		local duplicate = controller.token()

		helpers.assert_not_nil(first)
		helpers.assert_nil(duplicate, "a reused capability must never be returned to the generator")
		helpers.assert_eq(ctx.uuid_index, 9,
			"one initial allocation plus eight bounded duplicate attempts are expected")
		helpers.assert_eq(#ctx.spawns, 0, "always-duplicate failure must not launch a watchdog")
		helpers.assert_eq(controller.status(), "failed")
	end)

	helpers.it("accepts READY delivered synchronously by the task adapter", function()
		local controller, ctx = load_controller()
		controller.init()
		ctx.ready_on_start = true
		local ready_ok = nil

		helpers.assert_true(controller.start(function(ok) ready_ok = ok end),
			"start must survive immediate streaming output")
		helpers.assert_true(ready_ok == true, "immediate READY must settle the callback")
		helpers.assert_eq(controller.status(), "active", "immediate READY must activate the lease")
	end)

	helpers.it("revokes in the completion callback when an active watchdog dies", function()
		local controller, ctx = load_controller()
		controller.init()
		local vars = controller.variables()
		controller.start()
		ctx.chunk(1, "READY\n")

		ctx.complete(1, 9, "")
		helpers.assert_eq(controller.status(), "fencing", "a dead helper cannot be declared safe prematurely")
		helpers.assert_not_nil(find_native_revoke(ctx, vars),
			"Hammerspoon completion must revoke when an untrappable watchdog death occurs")
		ctx.complete(2, 0, "")
		helpers.assert_eq(controller.status(), "failed", "dead-helper failure settles after exact fencing")
	end)

	helpers.it("retries a refused detached revoker launch until the exact helper runs", function()
		local controller, ctx = load_controller()
		controller.init()
		local vars = controller.variables()
		controller.start()
		ctx.chunk(1, "READY\n")
		ctx.next_start_result = false

		ctx.complete(1, 9, "")
		helpers.assert_eq(#ctx.spawns, 2, "watchdog death must immediately attempt detached cleanup")
		helpers.assert_eq(ctx.spawns[2].executable, "/test/ErgoptiPlus")
		helpers.assert_eq(ctx.spawns[2].args[1], "--karabiner-lease-revoke")
		helpers.assert_eq(ctx.spawns[2].args[2], "/test/karabiner_cli")
		helpers.assert_eq(ctx.spawns[2].args[3], vars.mode)
		helpers.assert_eq(ctx.spawns[2].args[4], vars.revoked)

		ctx.fire_latest_timer()
		helpers.assert_eq(#ctx.spawns, 3,
			"a refused helper launch must retry asynchronously instead of abandoning mode=1")
		helpers.assert_eq(ctx.spawns[3].args[1], "--karabiner-lease-revoke")
		helpers.assert_eq(ctx.spawns[3].args[3], vars.mode)
		helpers.assert_eq(ctx.spawns[3].args[4], vars.revoked)
		ctx.complete(3, 0, "")
	end)

	helpers.it("rejects a synchronously firing fallback retry without recursive revocation", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.start()
		ctx.chunk(1, "READY\n")
		ctx.next_start_result = false
		ctx.next_after_callback_sync = true
		local timers_before_failure = #ctx.timers

		ctx.complete(1, 9, "")

		helpers.assert_eq(controller.status(), "fencing",
			"an unretained retry must leave the generation fenced")
		helpers.assert_eq(#ctx.spawns, 2,
			"a callback fired before handle retention must not recursively launch another revoker")
		helpers.assert_eq(#ctx.timers, timers_before_failure + 1,
			"the scheduler must be attempted once without a synchronous retry spin")
		local _, snapshot = controller.status()
		helpers.assert_true(snapshot.fallback_exhausted == true,
			"a synchronously fired candidate must terminalize the logical obligation")
		helpers.assert_eq(snapshot.fallback_exhausted_reason, "fallback-retry-unavailable")
	end)

	helpers.it("contains a fallback retry scheduler exception without publishing safety", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.start()
		ctx.chunk(1, "READY\n")
		ctx.next_start_result = false
		ctx.next_after_error = "injected fallback timer failure"

		local ok, err = pcall(function() ctx.complete(1, 9, "") end)

		helpers.assert_true(ok, "timer adapter errors must not escape a task completion callback: " .. tostring(err))
		helpers.assert_eq(controller.status(), "fencing",
			"timer failure cannot certify the exact generation as revoked")
		helpers.assert_eq(#ctx.spawns, 2,
			"scheduler failure must not recursively launch an unbounded revoker loop")
		local phase, snapshot = controller.status()
		helpers.assert_eq(phase, "fencing")
		helpers.assert_true(snapshot.fallback_exhausted == true)
		helpers.assert_eq(snapshot.fallback_attempts, 1)
		helpers.assert_eq(snapshot.fallback_exhausted_reason, "fallback-retry-unavailable")
		local stopped_ok, stopped_reason = nil, nil
		helpers.assert_true(controller.stop("join unavailable fallback", function(result, reason)
			stopped_ok = result
			stopped_reason = reason
		end))
		helpers.assert_true(stopped_ok == false,
			"a scheduler failure must settle later Stop callers instead of hanging")
		helpers.assert_eq(stopped_reason, "fallback-retry-unavailable")
	end)

	helpers.it("never reuses a published token across a controller reload", function()
		local settings_store = {}
		local first_controller = load_controller({
			settings_store = settings_store,
			uuid_values = { UUIDS[1] },
		})
		first_controller.init()
		helpers.assert_eq(first_controller.token(), "00112233445566778899aabbccddeeff")

		local second_controller, second_ctx = load_controller({
			settings_store = settings_store,
			uuid_values = { UUIDS[1], UUIDS[2] },
		})
		second_controller.init()
		helpers.assert_eq(second_controller.token(), "ffeeddccbbaa99887766554433221100",
			"reload must reject a token whose old Karabiner variables can still exist")
		helpers.assert_eq(second_ctx.uuid_index, 2, "the persisted collision must be retried")

		local duplicate_controller, duplicate_ctx = load_controller({
			settings_store = settings_store,
			uuid_values = { UUIDS[1] },
		})
		duplicate_controller.init()
		helpers.assert_nil(duplicate_controller.token(),
			"an always-repeating UUID source must fail closed after reload")
		helpers.assert_eq(duplicate_ctx.uuid_index, 8)
		helpers.assert_eq(#duplicate_ctx.spawns, 0)
	end)

	helpers.it("fails closed when reload cannot read the one-shot token ledger", function()
		local settings_store = {}
		local first_controller = load_controller({
			settings_store = settings_store,
			uuid_values = { UUIDS[1] },
		})
		first_controller.init()
		helpers.assert_eq(first_controller.token(), "00112233445566778899aabbccddeeff")

		local reloaded, ctx = load_controller({
			settings_store = settings_store,
			settings_get_failures = 1,
			uuid_values = { UUIDS[1] },
		})
		local initialized = reloaded.init()

		helpers.assert_eq(initialized, false,
			"a reload that cannot recover token history must expose failed initialization")
		helpers.assert_nil(reloaded.token(),
			"the repeated UUID must never be republished after an ambiguous ledger read")
		helpers.assert_eq(#ctx.spawns, 0)
	end)

	helpers.it("rejects malformed persisted token history instead of filtering it", function()
		local ledger_key = "ergopti.karabiner.used_tokens.v1"
		local malformed_ledgers = {
			"not-a-table",
			{ UUIDS[1] },
			{ [1] = "00112233445566778899aabbccddeeff", [3] = "ffeeddccbbaa99887766554433221100" },
		}

		for index, ledger in ipairs(malformed_ledgers) do
			local controller, ctx = load_controller({
				settings_store = { [ledger_key] = ledger },
				uuid_values = { UUIDS[1] },
			})
			helpers.assert_eq(controller.init(), false,
				"malformed ledger case " .. index .. " must fail initialization")
			helpers.assert_nil(controller.token(),
				"malformed ledger case " .. index .. " must block capability allocation")
			helpers.assert_eq(#ctx.spawns, 0)
		end
	end)

	helpers.it("keeps every managed rule inert when the packaged native helper is unavailable", function()
		local controller, ctx = load_controller({ helper_unavailable = true })
		controller.init()
		local variables = controller.variables()
		local started_ok = nil

		helpers.assert_not_nil(variables, "generator may still publish a fresh default-zero gate")
		helpers.assert_true(not controller.start(function(ok) started_ok = ok end))
		helpers.assert_true(started_ok == false)
		helpers.assert_eq(controller.status(), "failed")
		helpers.assert_eq(#ctx.spawns, 0, "missing helper must never fall back to a shell or direct CLI")
	end)
end)





-- ==============================================
-- ==============================================
-- ======= 3/ Acknowledged State Commands =======
-- ==============================================
-- ==============================================

helpers.describe("karabiner lease controller: acknowledged commands", function()
	helpers.it("serializes timer PING behind exact PONG before a queued pause", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.start()
		ctx.chunk(1, "READY\n")
		local heartbeat = ctx.fire_heartbeat_timer()

		helpers.assert_eq(ctx.spawns[1].inputs[1], "PING 1\n",
			"the retained HS timer must be the sole public heartbeat origin")
		ctx.fire_heartbeat_timer()
		helpers.assert_eq(#ctx.spawns[1].inputs, 1,
			"a second timer firing must not overwrite undrained hs.task input")
		local paused_ok = nil
		helpers.assert_true(controller.pause(function(ok) paused_ok = ok end))
		helpers.assert_eq(#ctx.spawns[1].inputs, 1,
			"pause must queue while the PING transport is unacknowledged")

		ctx.chunk(1, "PONG 1\n")
		helpers.assert_eq(ctx.spawns[1].inputs[2], "PAUSE\n",
			"the latest queued mode may write only after its exact PONG")
		ctx.chunk(1, "PAUSED\n")
		helpers.assert_true(paused_ok == true)
		helpers.assert_true(not heartbeat.cancelled,
			"the recurring heartbeat must remain retained in paused mode")
	end)

	helpers.it("lets the latest settled-state intent cancel an opposite command queued by PING", function()
		for _, case in ipairs({
			{
				start = "active",
				queue = "pause",
				latest = "resume",
				phase = "active",
			},
			{
				start = "paused",
				queue = "resume",
				latest = "pause",
				phase = "paused",
			},
		}) do
			local controller, ctx = load_controller()
			controller.init()
			if case.start == "paused" then
				controller.start_paused()
			else
				controller.start()
			end
			ctx.chunk(1, "READY\n")
			ctx.fire_heartbeat_timer()

			local queued_result, latest_result
			controller[case.queue](function(ok) queued_result = ok end)
			controller[case.latest](function(ok) latest_result = ok end)

			helpers.assert_true(queued_result == false,
				"the older opposite intent must settle as superseded immediately")
			helpers.assert_true(latest_result == true,
				"the latest request for the already-settled state must succeed")
			ctx.chunk(1, "PONG 1\n")
			helpers.assert_eq(#ctx.spawns[1].inputs, 1,
				"PONG must not dispatch the superseded opposite transition")
			helpers.assert_eq(controller.status(), case.phase,
				"the final public phase must match the latest user intent")
		end
	end)

	helpers.it("heartbeats an initially paused lease and cancels the timer before STOP", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.start_paused()
		ctx.chunk(1, "READY\n")
		local heartbeat = ctx.fire_heartbeat_timer()
		helpers.assert_eq(ctx.spawns[1].inputs[1], "PING 1\n",
			"pause is a live lease mode and must still detect Hammerspoon loss")

		controller.stop("cancel heartbeat")
		helpers.assert_true(heartbeat.cancelled,
			"STOP must cancel recurring liveness before writing terminal input")
		local input_count = #ctx.spawns[1].inputs
		ctx.chunk(1, "PONG 1\n")
		helpers.assert_eq(controller.status(), "stopping",
			"a late PONG batched behind STOP must not restore the live generation")
		heartbeat.fn()
		helpers.assert_eq(#ctx.spawns[1].inputs, input_count,
			"a stale timer callback must never write after STOP")
	end)

	helpers.it("retains a failed timer cancellation and retries the same inert handle", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.start()
		ctx.chunk(1, "READY\n")
		local heartbeat = ctx.fire_heartbeat_timer()
		local input_count = #ctx.spawns[1].inputs
		ctx.cancel_target = heartbeat
		ctx.cancel_failures = 3

		controller.stop("retry failed timer cancellation")
		helpers.assert_eq(heartbeat.cancel_attempts, 3,
			"sibling lifecycle work must retry retained cancellation debt")
		helpers.assert_true(not heartbeat.cancelled)
		heartbeat.fn()
		helpers.assert_eq(#ctx.spawns[1].inputs, input_count + 1,
			"the failed-stop timer must be logically inert before native cleanup settles")

		ctx.chunk(1, "STOPPED\n")
		helpers.assert_eq(heartbeat.cancel_attempts, 4,
			"final fence settlement must retry the exact retained timer")
		helpers.assert_true(heartbeat.cancelled)
	end)

	helpers.it("fails closed on missing or stale PONG without accepting another input", function()
		for _, stale_line in ipairs({ false, "PONG 2\n" }) do
			local controller, ctx = load_controller()
			controller.init()
			local variables = controller.variables()
			controller.start()
			ctx.chunk(1, "READY\n")
			ctx.fire_heartbeat_timer()
			if stale_line then
				ctx.chunk(1, stale_line)
			else
				ctx.fire_latest_timer()
			end

			helpers.assert_eq(controller.status(), "fencing",
				"a heartbeat without its exact PONG must revoke the live generation")
			helpers.assert_not_nil(find_native_revoke(ctx, variables),
				"missing or stale PONG must launch only exact-token fallback fencing")
		end
	end)

	helpers.it("treats PING_FAILED as negative transport and releases queued mode input", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.start()
		ctx.chunk(1, "READY\n")
		ctx.fire_heartbeat_timer()
		local paused_ok = nil
		controller.pause(function(ok) paused_ok = ok end)

		ctx.chunk(1, "PING_FAILED 1\n")
		helpers.assert_eq(ctx.spawns[1].inputs[2], "PAUSE\n",
			"negative heartbeat transport must clear hs.task input serialization")
		helpers.assert_nil(paused_ok)
		ctx.chunk(1, "PAUSED\n")
		helpers.assert_true(paused_ok == true)
		helpers.assert_eq(controller.status(), "paused",
			"a clean queued mode transport must reset heartbeat recovery")
	end)

	helpers.it("retries one negative heartbeat after a bounded quiet interval", function()
		local controller, ctx = load_controller()
		local phases = {}
		controller.init(function(phase) phases[#phases + 1] = phase end)
		controller.start()
		ctx.chunk(1, "READY\n")
		local heartbeat = ctx.fire_heartbeat_timer()
		ctx.chunk(1, "PING_FAILED 1\n")

		helpers.assert_eq(controller.status(), "recovering",
			"negative transport must not leave the public phase claiming active")
		local retry = ctx.timers[#ctx.timers]
		helpers.assert_true(not retry.repeating and retry.delay == 1.0,
			"the first failure must retain exactly one bounded retry timer")
		helpers.assert_eq(#ctx.spawns[1].inputs, 1,
			"the failure callback must not spin a replacement CLI immediately")

		heartbeat.fn()
		helpers.assert_true(controller.refresh_liveness(),
			"wake joins the retained retry instead of bypassing its backoff")
		helpers.assert_eq(#ctx.spawns[1].inputs, 1,
			"recurring and wake origins must remain suppressed before the retry")
		retry.fn()
		helpers.assert_eq(ctx.spawns[1].inputs[2], "PING 2\n")
		ctx.chunk(1, "PONG 2\n")

		helpers.assert_eq(controller.status(), "active",
			"one clean retry must restore the exact prior settled phase")
		helpers.assert_eq(phases[#phases - 1], "recovering")
		helpers.assert_eq(phases[#phases], "active")
		helpers.assert_true(not heartbeat.cancelled,
			"recovery must keep the five-second liveness source retained")
	end)

	helpers.it("fences after the one bounded heartbeat retry also fails", function()
		local controller, ctx = load_controller()
		controller.init()
		local variables = controller.variables()
		controller.start()
		ctx.chunk(1, "READY\n")
		ctx.fire_heartbeat_timer()
		ctx.chunk(1, "PING_FAILED 1\n")
		local retry = ctx.timers[#ctx.timers]
		retry.fn()
		ctx.chunk(1, "PING_FAILED 2\n")

		helpers.assert_eq(controller.status(), "fencing",
			"a second negative transport must not remain in an endless retry state")
		helpers.assert_not_nil(find_native_revoke(ctx, variables),
			"the repeated failure must launch exact-token fallback fencing")
	end)

	helpers.it("cancels the bounded heartbeat retry before STOP", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.start()
		ctx.chunk(1, "READY\n")
		ctx.fire_heartbeat_timer()
		ctx.chunk(1, "PING_FAILED 1\n")
		local retry = ctx.timers[#ctx.timers]

		controller.stop("retry cancellation")
		helpers.assert_true(retry.cancelled,
			"STOP must make the one-shot recovery callback stale before terminal input")
		local input_count = #ctx.spawns[1].inputs
		retry.fn()
		helpers.assert_eq(#ctx.spawns[1].inputs, input_count,
			"a stale retry callback must never write after STOP")
	end)

	helpers.it("fails closed when the bounded heartbeat retry cannot be retained", function()
		local controller, ctx = load_controller()
		controller.init()
		local variables = controller.variables()
		controller.start()
		ctx.chunk(1, "READY\n")
		ctx.fire_heartbeat_timer()
		ctx.next_timer_fired = true
		ctx.chunk(1, "PING_FAILED 1\n")

		helpers.assert_eq(controller.status(), "fencing")
		helpers.assert_not_nil(find_native_revoke(ctx, variables),
			"an unretained retry must never leave an ambiguous live generation")
	end)

	helpers.it("pings immediately on wake without duplicating an in-flight transport", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.start()
		ctx.chunk(1, "READY\n")

		helpers.assert_true(controller.refresh_liveness())
		helpers.assert_true(controller.refresh_liveness(),
			"a duplicate wake may join the exact outstanding ping")
		helpers.assert_eq(#ctx.spawns[1].inputs, 1,
			"wake and unlock callbacks must not overwrite the same undrained PING")
		helpers.assert_eq(ctx.spawns[1].inputs[1], "PING 1\n")
		ctx.chunk(1, "PONG 1\n")
	end)

	helpers.it("refuses READY when the retained heartbeat timer cannot be armed", function()
		local controller, ctx = load_controller()
		controller.init()
		local variables = controller.variables()
		local started_ok = nil
		controller.start(function(ok) started_ok = ok end)
		ctx.next_timer_fired = true
		ctx.chunk(1, "READY\n")

		helpers.assert_eq(controller.status(), "fencing")
		helpers.assert_nil(started_ok,
			"READY cannot publish a live phase without its retained liveness source")
		helpers.assert_not_nil(find_native_revoke(ctx, variables))
	end)

	helpers.it("rolls back an uncommitted heartbeat timer before refusing READY", function()
		local controller, ctx = load_controller()
		controller.init()
		local variables = controller.variables()
		local started_ok = nil
		controller.start(function(ok) started_ok = ok end)
		ctx.next_every_committed = false
		ctx.chunk(1, "READY\n")
		local candidate = ctx.timers[#ctx.timers]

		helpers.assert_eq(controller.status(), "fencing",
			"an explicit uncommitted result must never publish an active lease")
		helpers.assert_nil(started_ok,
			"READY remains unsettled until the exact failed generation is fenced")
		helpers.assert_true(candidate.cancelled,
			"the uncommitted candidate must be rolled back through its exact handle")
		helpers.assert_not_nil(find_native_revoke(ctx, variables),
			"missing heartbeat ownership must fail the generation closed")
	end)

	helpers.it("rolls back an uncommitted ACK timer and rejects worker activation", function()
		local controller, ctx = load_controller()
		controller.init()
		local variables = controller.variables()
		ctx.next_after_committed = false
		local started = controller.start()
		local candidate = ctx.timers[#ctx.timers]

		helpers.assert_eq(started, false,
			"a worker without its committed READY timeout cannot be accepted")
		helpers.assert_eq(controller.status(), "fencing")
		helpers.assert_true(candidate.cancelled,
			"the uncommitted ACK candidate must be rolled back exactly")
		helpers.assert_not_nil(find_native_revoke(ctx, variables))
	end)

	helpers.it("uses ACK budgets that cover the native write sequences without sharing one magic timeout", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.start()
		helpers.assert_eq(ctx.timers[#ctx.timers].delay, 4.0,
			"READY covers native worker startup plus one atomic mode write")
		ctx.chunk(1, "READY\n")

		controller.pause()
		helpers.assert_eq(ctx.timers[#ctx.timers].delay, 2.0,
			"PAUSED/RESUMED cover one native CLI write")
		ctx.chunk(1, "PAUSED\n")

		controller.stop("budget proof")
		helpers.assert_eq(ctx.timers[#ctx.timers].delay, 7.0,
			"STOPPED covers the repeated fence cleanup sequence")
		ctx.chunk(1, "STOPPED\n")
	end)

	helpers.it("queues pause until READY instead of replacing the activation ACK", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.start()

		local paused_ok = nil
		helpers.assert_true(controller.pause(function(ok) paused_ok = ok end),
			"pause during activation must be accepted and queued")
		helpers.assert_eq(controller.status(), "starting", "READY must remain the awaited activation ACK")
		helpers.assert_eq(#ctx.spawns[1].inputs, 0,
			"no state command may overwrite task input before READY")

		ctx.chunk(1, "READY\n")
		helpers.assert_eq(ctx.spawns[1].inputs[1], "PAUSE\n", "queued pause must send after READY")
		helpers.assert_eq(controller.status(), "pausing", "PAUSED must now be awaited")
		ctx.chunk(1, "PAUSED\n")
		helpers.assert_true(paused_ok == true, "queued pause must complete only after PAUSED")
		helpers.assert_eq(controller.status(), "paused", "the lease must finish paused")
	end)

	helpers.it("lets re-entrant READY callbacks supersede an older queued mode", function()
		local controller, ctx = load_controller()
		controller.init()

		local started = nil
		local latest_resume = nil
		local stale_pause = nil
		controller.start(function(ok)
			started = ok
			controller.resume(function(resumed_ok) latest_resume = resumed_ok end)
		end)
		controller.pause(function(paused_ok) stale_pause = paused_ok end)

		ctx.chunk(1, "READY\n")

		helpers.assert_true(started == true and latest_resume == true,
			"READY and the re-entrant latest active intent must both settle true")
		helpers.assert_true(stale_pause == false,
			"a pause queued before READY must not overtake a newer start-callback resume")
		helpers.assert_eq(#ctx.spawns[1].inputs, 0,
			"the superseded PAUSE must never be written after READY")
		helpers.assert_eq(controller.status(), "active")
	end)

	helpers.it("serializes pause then resume and waits for each ACK", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.start()
		ctx.chunk(1, "READY\n")

		local paused_ok = nil
		local resumed_ok = nil
		helpers.assert_true(controller.pause(function(ok) paused_ok = ok end), "pause must be accepted")
		helpers.assert_eq(controller.status(), "pausing", "pause must stay pending before PAUSED")
		helpers.assert_eq(ctx.spawns[1].inputs[1], "PAUSE\n", "pause command must be one framed line")
		helpers.assert_true(controller.resume(function(ok) resumed_ok = ok end),
			"resume requested during pause must queue rather than overwrite stdin")
		helpers.assert_eq(#ctx.spawns[1].inputs, 1,
			"setInput must not be called twice before the first ACK because it discards unwritten input")

		ctx.chunk(1, "PAU")
		helpers.assert_eq(controller.status(), "pausing",
			"a partial protocol line must not be treated as an acknowledgement")
		ctx.chunk(1, "SED\nRESUMED\n")
		helpers.assert_true(paused_ok == true, "pause callback must wait for PAUSED")
		helpers.assert_eq(ctx.spawns[1].inputs[2], "RESUME\n", "queued resume must send after PAUSED")
		helpers.assert_true(resumed_ok == true, "resume callback must succeed after RESUMED")
		helpers.assert_eq(controller.status(), "active",
			"multiple complete lines in one chunk must be processed in order")
	end)

	helpers.it("ignores a cancelled same-ACK timeout queued behind a newer transition", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.start()
		ctx.chunk(1, "READY\n")

		controller.pause()
		local stale_pause_timer = ctx.timers[#ctx.timers]
		ctx.chunk(1, "PAUSED\n")
		helpers.assert_true(stale_pause_timer.cancelled)
		controller.resume()
		ctx.chunk(1, "RESUMED\n")
		controller.pause()
		helpers.assert_eq(controller.status(), "pausing")

		-- Hammerspoon may already have queued the old callback when :stop() runs.
		-- The repeated PAUSED text cannot identify which transition owns it.
		stale_pause_timer.fn()
		helpers.assert_eq(controller.status(), "pausing",
			"a cancelled earlier PAUSED timer must not fence the newer PAUSE")
		helpers.assert_eq(#ctx.spawns, 1,
			"the stale callback must not launch an exact-generation revoker")

		ctx.chunk(1, "PAUSED\n")
		helpers.assert_eq(controller.status(), "paused",
			"the current transition must still accept its own PAUSED acknowledgement")
	end)

	helpers.it("coalesces pause-resume-pause to the last requested state", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.start()
		ctx.chunk(1, "READY\n")

		local first_pause = nil
		local superseded_resume = nil
		local last_pause = nil
		controller.pause(function(ok) first_pause = ok end)
		controller.resume(function(ok) superseded_resume = ok end)
		controller.pause(function(ok) last_pause = ok end)

		helpers.assert_true(superseded_resume == false,
			"the queued intermediate resume must be explicitly rejected as superseded")
		ctx.chunk(1, "PAUSED\n")
		helpers.assert_true(first_pause == true and last_pause == true,
			"both callers requesting the final paused state must observe PAUSED")
		helpers.assert_eq(#ctx.spawns[1].inputs, 1,
			"superseded resume must never be written after PAUSED")
		helpers.assert_eq(controller.status(), "paused", "last user intent must win")
	end)

	helpers.it("does not let a detached queued command overtake re-entrant latest intent", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.start()
		ctx.chunk(1, "READY\n")

		local first_pause = nil
		local latest_pause = nil
		local stale_resume = nil
		controller.pause(function(ok)
			first_pause = ok
			-- Public callbacks are allowed to re-enter the controller. At this point
			-- PAUSED is proven, but the older queued RESUME has not been dispatched
			-- yet. This newer pause intent must cancel that stale queued command.
			controller.pause(function(latest_ok) latest_pause = latest_ok end)
		end)
		controller.resume(function(ok) stale_resume = ok end)

		ctx.chunk(1, "PAUSED\n")

		helpers.assert_true(first_pause == true and latest_pause == true,
			"both the acknowledged pause and the re-entrant latest pause must settle true")
		helpers.assert_true(stale_resume == false,
			"the older queued resume must settle false once a callback publishes newer pause intent")
		helpers.assert_eq(#ctx.spawns[1].inputs, 1,
			"the stale queued RESUME must never reach the native input stream")
		helpers.assert_eq(controller.status(), "paused",
			"callback re-entrance must preserve the latest requested state")
	end)

	helpers.it("retains an intent re-entered from a superseded queued callback", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.start()
		ctx.chunk(1, "READY\n")
		local stale_resume, latest_resume = nil, nil
		controller.pause()
		controller.resume(function(ok)
			stale_resume = ok
			controller.resume(function(latest_ok) latest_resume = latest_ok end)
		end)

		controller.pause()
		helpers.assert_true(stale_resume == false,
			"the older queued RESUME must settle before the latest callback re-enters")
		ctx.chunk(1, "PAUSED\n")
		helpers.assert_eq(ctx.spawns[1].inputs[2], "RESUME\n",
			"the re-entered RESUME must survive detachment of the superseded queue")
		ctx.chunk(1, "RESUMED\n")
		helpers.assert_true(latest_resume == true,
			"the callback attached by re-entrance must settle exactly from RESUMED")
		helpers.assert_eq(controller.status(), "active")
	end)

	helpers.it("retains STARTING intent re-entered from a superseded callback", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.start()
		local stale_pause, latest_pause = nil, nil
		controller.pause(function(ok)
			stale_pause = ok
			controller.pause(function(latest_ok) latest_pause = latest_ok end)
		end)

		controller.resume()
		helpers.assert_true(stale_pause == false,
			"the pre-READY PAUSE must be rejected before its callback re-enters")
		ctx.chunk(1, "READY\n")
		helpers.assert_eq(ctx.spawns[1].inputs[1], "PAUSE\n",
			"the re-entered PAUSE must replace the outer RESUME before READY reconciliation")
		ctx.chunk(1, "PAUSED\n")
		helpers.assert_true(latest_pause == true,
			"the re-entered pre-READY callback must not be orphaned")
		helpers.assert_eq(controller.status(), "paused")
	end)

	helpers.it("revokes the lease when a command ACK times out", function()
		local controller, ctx = load_controller()
		controller.init()
		local vars = controller.variables()
		controller.start()
		ctx.chunk(1, "READY\n")

		local paused_ok = nil
		controller.pause(function(ok) paused_ok = ok end)
		ctx.fire_latest_timer()

		helpers.assert_eq(controller.status(), "fencing", "an ambiguous pause outcome must fence first")
		helpers.assert_nil(paused_ok, "pause callback must not permit retry before fencing")
		helpers.assert_not_nil(find_native_revoke(ctx, vars), "timeout must launch exact fallback revocation")
		helpers.assert_true(not ctx.spawns[1].terminated,
			"controller must close native stdin and let the worker fence; it must not signal any process")
		ctx.complete(2, 0, "")
		helpers.assert_true(paused_ok == false, "pause callback must expose the missing ACK after fencing")
		helpers.assert_eq(controller.status(), "failed")
	end)

	helpers.it("fails closed on an unknown protocol line", function()
		local controller, ctx = load_controller()
		controller.init()
		local vars = controller.variables()
		controller.start()
		ctx.chunk(1, "READY\n")

		ctx.chunk(1, "NOT_A_PROTOCOL_ACK\n")
		helpers.assert_eq(controller.status(), "fencing", "unknown helper output must enter exact fencing")
		helpers.assert_not_nil(find_native_revoke(ctx, vars),
			"malformed protocol output must revoke only the current token")
		ctx.complete(2, 0, "")
		helpers.assert_eq(controller.status(), "failed")
	end)

	helpers.it("bounds a helper protocol line that never terminates", function()
		local controller, ctx = load_controller()
		controller.init()
		local variables = controller.variables()
		controller.start()
		ctx.chunk(1, "READY\n")

		ctx.chunk(1, string.rep("X", 40))
		helpers.assert_eq(controller.status(), "active",
			"one partial chunk below the protocol ceiling may await its newline")
		ctx.chunk(1, string.rep("Y", 25))

		helpers.assert_eq(controller.status(), "fencing",
			"a newline-free protocol stream must be bounded and fail closed")
		local revoke = find_native_revoke(ctx, variables)
		helpers.assert_not_nil(revoke, "overflow must launch exact token revocation")
	end)

	helpers.it("accepts a command acknowledgement delivered before set_input returns", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.start()
		ctx.chunk(1, "READY\n")
		local timer_count = #ctx.timers
		local callback_calls = 0
		local callback_ok = nil
		ctx.next_input_chunk = "PAUSED\n"

		local accepted = controller.pause(function(ok)
			callback_calls = callback_calls + 1
			callback_ok = ok
		end)

		helpers.assert_true(accepted,
			"a synchronously observable ACK must still be ordered after the pending command")
		helpers.assert_eq(callback_calls, 1, "the immediate ACK must settle exactly once")
		helpers.assert_true(callback_ok == true)
		helpers.assert_eq(controller.status(), "paused")
		helpers.assert_eq(#ctx.timers, timer_count,
			"an ACK already consumed during set_input must not leave a phantom timeout")
	end)

	helpers.it("keeps a pause request accepted while timer failure fences asynchronously", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.start()
		ctx.chunk(1, "READY\n")
		ctx.next_timer_fired = true
		local callback_calls = 0
		local callback_ok = nil

		local accepted = controller.pause(function(ok)
			callback_calls = callback_calls + 1
			callback_ok = ok
		end)

		helpers.assert_true(accepted,
			"timer setup failure must not trigger an eager request-rejected callback upstream")
		helpers.assert_eq(callback_calls, 0, "the callback must wait for the exact fallback fence")
		helpers.assert_eq(controller.status(), "fencing")
		ctx.complete(2, 0, "")
		helpers.assert_eq(callback_calls, 1, "the failed pause must settle exactly once after fencing")
		helpers.assert_true(callback_ok == false)
	end)
end)





-- =======================================
-- =======================================
-- ======= 4/ Generation Isolation =======
-- =======================================
-- =======================================

helpers.describe("karabiner lease controller: generation isolation", function()
	helpers.it("does not release a stop barrier while an older generation still fences", function()
		local controller, ctx = load_controller()
		controller.init()
		local old_variables = controller.variables()
		controller.start()
		ctx.chunk(1, "READY\n")
		local old_stopped, new_stopped = nil, nil
		controller.stop("old generation", function(ok) old_stopped = ok end)
		local old_stop_timer = ctx.timers[#ctx.timers]

		local replacement = controller.variables()
		controller.start()
		ctx.chunk(2, "READY\n")
		controller.stop("replacement generation", function(ok) new_stopped = ok end)

		old_stop_timer.fired = true
		old_stop_timer.fn()
		helpers.assert_eq(ctx.spawns[3].args[1], "--karabiner-lease-revoke",
			"the old timeout must capture only its own generation")
		helpers.assert_eq(ctx.spawns[3].args[3], old_variables.mode)
		ctx.chunk(2, "STOPPED\n")
		helpers.assert_nil(new_stopped,
			"new STOPPED cannot outrun the older generation's still-pending fence")
		helpers.assert_nil(old_stopped)
		helpers.assert_eq(controller.status(), "fencing",
			"aggregate status must deterministically expose the unsafe retiring set")

		ctx.complete(3, 0, "")
		helpers.assert_true(old_stopped == true and new_stopped == true)
		helpers.assert_eq(controller.status(), "idle")
		helpers.assert_eq(replacement.token, "ffeeddccbbaa99887766554433221100")
	end)

	helpers.it("publishes safe status before a failure callback starts a replacement", function()
		local controller, ctx = load_controller()
		controller.init()
		local old_token = controller.token()
		local callback_status = nil
		local replacement = nil
		local replacement_started = nil
		controller.start(function(ok)
			helpers.assert_true(ok == false)
			callback_status = controller.status()
			replacement = controller.variables()
			replacement_started = controller.start()
		end)

		ctx.complete(1, 9, "")
		helpers.assert_nil(replacement, "failure callback must remain blocked before exact fencing")
		helpers.assert_nil(controller.variables(),
			"even a direct retry must not allocate while failed writers remain ambiguous")
		ctx.complete(2, 0, "")

		helpers.assert_eq(callback_status, "failed",
			"re-entrant callback must observe the post-fence phase, never stale fencing")
		helpers.assert_not_nil(replacement)
		helpers.assert_true(replacement.token ~= old_token)
		helpers.assert_true(replacement_started == true)
		helpers.assert_eq(controller.status(), "starting")
		helpers.assert_eq(ctx.spawns[3].args[1], "--karabiner-lease-worker")
	end)

	helpers.it("publishes IDLE before stopping an already-safe FAILED controller", function()
		local controller, ctx = load_controller()
		local phases = {}
		controller.init(function(phase, token)
			phases[#phases + 1] = { phase = phase, token = token }
		end)
		local failed_variables = controller.variables()
		ctx.next_start_result = false
		helpers.assert_true(controller.start() == false)
		helpers.assert_eq(controller.status(), "failed")
		local spawn_count = #ctx.spawns
		local timer_count = #ctx.timers
		local callback_calls = 0
		local callback_ok, callback_reason, callback_phase = nil, nil, nil

		helpers.assert_true(controller.stop("shutdown safe failure", function(ok, reason)
			callback_calls = callback_calls + 1
			callback_ok = ok
			callback_reason = reason
			callback_phase = controller.status()
		end))

		helpers.assert_eq(callback_calls, 1,
			"an empty aggregate barrier must settle synchronously exactly once")
		helpers.assert_true(callback_ok == true)
		helpers.assert_eq(callback_reason, "already-stopped")
		helpers.assert_eq(callback_phase, "idle",
			"successful STOP proof must be public before a teardown callback re-enters")
		helpers.assert_eq(controller.status(), "idle")
		helpers.assert_eq(phases[#phases].phase, "idle")
		helpers.assert_nil(phases[#phases].token)
		helpers.assert_eq(#ctx.spawns, spawn_count)
		helpers.assert_eq(#ctx.timers, timer_count)
		helpers.assert_eq(#ctx.spawns[1].inputs, 0)
		helpers.assert_nil(find_native_revoke(ctx, failed_variables),
			"normalizing a proven-safe failure must not launch another helper")
	end)

	helpers.it("publishes IDLE before a stop joined to an in-flight failure fence", function()
		local controller, ctx = load_controller()
		local phases = {}
		controller.init(function(phase, token)
			phases[#phases + 1] = { phase = phase, token = token }
		end)
		local failed_variables = controller.variables()
		controller.start()
		ctx.chunk(1, "READY\n")
		ctx.chunk(1, "UNKNOWN_AFTER_READY\n")
		helpers.assert_eq(controller.status(), "fencing")
		local exact_revoke = find_native_revoke(ctx, failed_variables)
		helpers.assert_eq(exact_revoke, ctx.spawns[2])
		helpers.assert_eq(exact_revoke.args[3], failed_variables.mode)
		helpers.assert_eq(exact_revoke.args[4], failed_variables.revoked)
		local spawn_count = #ctx.spawns
		local callback_calls = 0
		local callback_ok, callback_reason, callback_phase = nil, nil, nil
		local callback_publication = nil

		helpers.assert_true(controller.stop("shutdown during failure fence", function(ok, reason)
			callback_calls = callback_calls + 1
			callback_ok = ok
			callback_reason = reason
			callback_phase = controller.status()
			callback_publication = phases[#phases]
		end))
		helpers.assert_eq(callback_calls, 0,
			"accepted FENCING is not yet proof that teardown is safe")
		helpers.assert_eq(#ctx.spawns, spawn_count,
			"joining an exact fence must not launch or signal a generic Karabiner process")
		helpers.assert_eq(#ctx.spawns[1].inputs, 0,
			"joining FENCING must not send a second transport command")

		ctx.complete(2, 0, "")
		helpers.assert_eq(callback_calls, 1)
		helpers.assert_true(callback_ok == true)
		helpers.assert_eq(callback_reason, "fallback-revoked")
		helpers.assert_eq(callback_phase, "idle",
			"the aggregate fence must publish the explicit Stop intent before its callback")
		helpers.assert_eq(callback_publication.phase, "idle",
			"lease consumers must receive IDLE before the teardown callback re-enters")
		helpers.assert_eq(controller.status(), "idle")
		ctx.complete(2, 0, "")
		helpers.assert_eq(callback_calls, 1,
			"a duplicate native completion must not re-settle the Stop callback")
		helpers.assert_eq(#ctx.spawns, spawn_count,
			"late completions must remain confined to the captured exact revoker")
	end)

	helpers.it("applies aggregate Stop intent to every simultaneous retiring generation", function()
		local controller, ctx = load_controller()
		local phases = {}
		controller.init(function(phase, token)
			phases[#phases + 1] = { phase = phase, token = token }
		end)

		local first = controller.variables()
		controller.start()
		ctx.chunk(1, "READY\n")
		controller.stop("retire first generation")
		local second = controller.variables()
		controller.start()
		ctx.chunk(2, "READY\n")
		ctx.chunk(2, "BROKEN_REPLACEMENT\n")
		helpers.assert_eq(controller.status(), "fencing")
		helpers.assert_true(first.token ~= second.token)
		helpers.assert_eq(find_native_revoke(ctx, second), ctx.spawns[3])
		local spawn_count = #ctx.spawns
		local callback_calls = 0
		local callback_phase = nil

		helpers.assert_true(controller.stop("aggregate shutdown", function(ok)
			callback_calls = callback_calls + 1
			helpers.assert_true(ok == true)
			callback_phase = controller.status()
		end))
		helpers.assert_eq(callback_calls, 0)
		helpers.assert_eq(#ctx.spawns, spawn_count)
		helpers.assert_eq(ctx.spawns[1].inputs[#ctx.spawns[1].inputs], "STOP\n")
		helpers.assert_eq(#ctx.spawns[2].inputs, 0,
			"joining the failed replacement must not send an unfenced generic STOP")

		ctx.chunk(1, "STOPPED\n")
		helpers.assert_eq(callback_calls, 0,
			"the first retiree cannot outrun the replacement's exact fallback")
		ctx.complete(3, 0, "")
		helpers.assert_eq(callback_calls, 1)
		helpers.assert_eq(callback_phase, "idle",
			"the final failed retiree must inherit the aggregate Stop intent")
		helpers.assert_eq(phases[#phases].phase, "idle")
		helpers.assert_eq(controller.status(), "idle")
		helpers.assert_eq(#ctx.spawns, spawn_count,
			"aggregate settlement must stay exact-token-only across both retirees")
	end)

	helpers.it("clears the retired token from an IDLE publication after STOPPED", function()
		local controller, ctx = load_controller()
		local phases = {}
		controller.init(function(phase, token)
			phases[#phases + 1] = { phase = phase, token = token }
		end)
		local retired = controller.variables()
		controller.start()
		ctx.chunk(1, "READY\n")

		controller.stop("normal token cleanup")
		ctx.chunk(1, "STOPPED\n")

		local phase, snapshot = controller.status()
		helpers.assert_eq(phase, "idle")
		helpers.assert_nil(snapshot.token)
		helpers.assert_eq(phases[#phases].phase, "idle")
		helpers.assert_nil(phases[#phases].token,
			"IDLE must not publish the retired exact-generation identity")
		helpers.assert_true(retired.token ~= nil)
	end)

	helpers.it("clears the retired token from an IDLE publication after fallback", function()
		local controller, ctx = load_controller()
		local phases = {}
		controller.init(function(phase, token)
			phases[#phases + 1] = { phase = phase, token = token }
		end)
		local retired = controller.variables()
		controller.start()
		ctx.chunk(1, "READY\n")
		ctx.next_input_result = false

		controller.stop("fallback token cleanup")
		helpers.assert_eq(find_native_revoke(ctx, retired), ctx.spawns[2])
		ctx.complete(2, 0, "")

		local phase, snapshot = controller.status()
		helpers.assert_eq(phase, "idle")
		helpers.assert_nil(snapshot.token)
		helpers.assert_eq(phases[#phases].phase, "idle")
		helpers.assert_nil(phases[#phases].token,
			"fallback IDLE must not leak the revoked generation identity")
	end)

	helpers.it("accepts a broken STOP channel but settles only after fallback fencing", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.start()
		ctx.chunk(1, "READY\n")
		ctx.next_input_result = false
		local stopped_ok, stopped_reason = nil, nil

		helpers.assert_true(controller.stop("broken channel", function(ok, reason)
			stopped_ok, stopped_reason = ok, reason
		end), "accepted fallback cleanup must not trigger an eager caller rollback")
		helpers.assert_nil(stopped_ok)
		helpers.assert_eq(controller.status(), "fencing")
		ctx.complete(2, 0, "")
		helpers.assert_true(stopped_ok == true)
		helpers.assert_eq(stopped_reason, "fallback-revoked")
		helpers.assert_eq(controller.status(), "idle")
	end)

	helpers.it("keeps stop accepted when its acknowledgement timer cannot be armed", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.start()
		ctx.chunk(1, "READY\n")
		ctx.next_timer_fired = true
		local callback_calls = 0
		local stopped_ok = nil

		local accepted = controller.stop("timer unavailable", function(ok)
			callback_calls = callback_calls + 1
			stopped_ok = ok
		end)

		helpers.assert_true(accepted,
			"an accepted exact fallback fence must not make disable roll back eagerly")
		helpers.assert_eq(callback_calls, 0)
		helpers.assert_eq(controller.status(), "fencing")
		ctx.complete(2, 0, "")
		helpers.assert_eq(callback_calls, 1)
		helpers.assert_true(stopped_ok == true,
			"fallback proof satisfies the requested system-wide stopped state")
		helpers.assert_eq(controller.status(), "idle")
	end)

	helpers.it("does not arm a phantom timeout after synchronous STOPPED", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.start()
		ctx.chunk(1, "READY\n")
		local timer_count = #ctx.timers
		ctx.next_input_chunk = "STOPPED\n"
		local callback_calls = 0

		helpers.assert_true(controller.stop("immediate stop", function(ok)
			callback_calls = callback_calls + 1
			helpers.assert_true(ok == true)
		end))
		helpers.assert_eq(callback_calls, 1)
		helpers.assert_eq(controller.status(), "idle")
		helpers.assert_eq(#ctx.timers, timer_count,
			"STOPPED consumed inside set_input must prevent a later stale timeout")
	end)

	helpers.it("joins two stop callers until the same STOPPED acknowledgement", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.start()
		ctx.chunk(1, "READY\n")
		local first, second = nil, nil

		helpers.assert_true(controller.stop("first", function(ok) first = ok end))
		helpers.assert_true(controller.stop("second", function(ok) second = ok end),
			"a duplicate stop must join the retiring generation")
		helpers.assert_nil(first)
		helpers.assert_nil(second, "duplicate stop must not report already-stopped early")
		helpers.assert_eq(#ctx.spawns[1].inputs, 1, "STOP must be written only once")

		ctx.chunk(1, "STOPPED\n")
		helpers.assert_true(first == true and second == true,
			"both callers must settle from the same revocation proof")
	end)

	helpers.it("fails every joined stop caller on the same STOPPED timeout", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.start()
		ctx.chunk(1, "READY\n")
		local first, second = nil, nil
		controller.stop("first timeout", function(ok) first = ok end)
		controller.stop("second timeout", function(ok) second = ok end)

		ctx.fire_latest_timer()
		helpers.assert_nil(first, "a protocol timeout is not yet a revocation proof")
		helpers.assert_nil(second, "joined callers must wait for the native fallback fence")
		ctx.complete(2, 0, "")
		helpers.assert_true(first == true and second == true,
			"fallback fencing fulfills the requested safe stop for every caller")
	end)

	helpers.it("stops safely before READY without treating late READY as corruption", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.start()

		local stopped_ok = nil
		controller.stop("stop during activation", function(ok) stopped_ok = ok end)
		ctx.chunk(1, "READY\nSTOPPED\n")

		helpers.assert_true(stopped_ok == true, "STOPPED must acknowledge a stop queued during activation")
		helpers.assert_true(ctx.spawns[1].closed, "the controller must close stdin after STOPPED")
		helpers.assert_eq(controller.status(), "idle", "late READY must never reactivate a detached generation")
	end)

	helpers.it("ignores a superseded PAUSED ACK while waiting for STOPPED", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.start()
		ctx.chunk(1, "READY\n")
		controller.pause()

		local stopped_ok = nil
		controller.stop("stop during pause", function(ok) stopped_ok = ok end)
		ctx.chunk(1, "PAUSED\nSTOPPED\n")

		helpers.assert_true(stopped_ok == true,
			"an in-flight pause ACK must not make the later STOPPED acknowledgement fail")
		helpers.assert_eq(controller.status(), "idle", "stop must remain the final user intent")
	end)

	helpers.it("waits for an exact native fence when STOPPED times out", function()
		local controller, ctx = load_controller()
		controller.init()
		local vars = controller.variables()
		controller.start()
		ctx.chunk(1, "READY\n")

		local stopped_ok = nil
		controller.stop("missing stop ack", function(ok) stopped_ok = ok end)
		ctx.fire_latest_timer()

		helpers.assert_nil(stopped_ok,
			"missing STOPPED cannot settle before the fallback has fenced the exact variables")
		helpers.assert_true(not ctx.spawns[1].terminated,
			"the controller must not signal even its native worker; stdin EOF drives cleanup")
		helpers.assert_not_nil(find_native_revoke(ctx, vars),
			"STOPPED timeout must invoke exact token fallback revocation")
		helpers.assert_eq(controller.status(), "fencing",
			"a detached generation remains visible until fallback revocation succeeds")
		ctx.complete(2, 0, "")
		helpers.assert_true(stopped_ok == true,
			"fallback proof fulfills disable even when the primary STOPPED protocol degraded")
		helpers.assert_eq(controller.status(), "idle", "a detached failed generation cannot own new status")
	end)

	helpers.it("an old STOPPED/completion cannot mutate or revoke the new token", function()
		local controller, ctx = load_controller()
		controller.init()
		local old_vars = controller.variables()
		controller.start()
		ctx.chunk(1, "READY\n")

		local stopped_ok = nil
		helpers.assert_true(controller.stop("test replacement", function(ok) stopped_ok = ok end),
			"stop must be accepted")
		helpers.assert_eq(controller.status(), "stopping",
			"a detached generation remains retiring until STOPPED proves revocation")
		helpers.assert_eq(ctx.spawns[1].inputs[#ctx.spawns[1].inputs], "STOP\n",
			"stop must request an acknowledged revocation")
		helpers.assert_true(not ctx.spawns[1].closed,
			"the helper must stay alive until STOPPED so completion cannot overtake the ACK")

		local new_vars = controller.variables()
		helpers.assert_true(new_vars.token ~= old_vars.token, "the replacement must use a distinct token")
		controller.start()
		ctx.chunk(2, "READY\n")
		helpers.assert_eq(controller.status(), "active", "new generation must activate independently")

		ctx.chunk(1, "STOPPED\n")
		helpers.assert_true(ctx.spawns[1].closed,
			"STOPPED must close stdin and let the helper observe EOF after its ACK")
		ctx.complete(1, 0, "STOPPED\n")
		helpers.assert_true(stopped_ok == true, "old stop callback may complete after replacement")
		helpers.assert_eq(controller.status(), "active", "old callbacks must not mutate the new phase")

		helpers.assert_nil(find_native_revoke(ctx, old_vars),
			"an acknowledged STOPPED fence must not launch redundant detached cleanup")
		helpers.assert_nil(find_native_revoke(ctx, new_vars),
			"old completion must never revoke the new variables")
	end)

	helpers.it("does not publish a late failure from a detached generation over its replacement", function()
		local controller, ctx = load_controller()
		local phases = {}
		controller.init(function(phase, token)
			phases[#phases + 1] = { phase = phase, token = token }
		end)
		local old_token = controller.token()
		controller.start()
		ctx.chunk(1, "READY\n")
		controller.stop("replace stale generation")

		local new_token = controller.token()
		controller.start()
		ctx.chunk(2, "READY\n")
		helpers.assert_true(new_token ~= old_token, "replacement must carry a fresh capability")
		local publications_before_late_failure = #phases

		ctx.chunk(1, "BROKEN_AFTER_DETACH\n")

		helpers.assert_eq(controller.status(), "active",
			"a stale protocol failure must not replace the live generation phase")
		helpers.assert_eq(#phases, publications_before_late_failure,
			"a detached generation must not publish failed and tear down replacement inputs")
		local saw_old_stopping = false
		for _, publication in ipairs(phases) do
			if publication.phase == "stopping" and publication.token == old_token then
				saw_old_stopping = true
			end
		end
		helpers.assert_true(saw_old_stopping,
			"the intentional detached stopping transition must remain observable")
	end)

	helpers.it("accepts the final STOPPED chunk when completion arrives first", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.start()
		ctx.chunk(1, "READY\n")

		local stopped_ok = nil
		controller.stop("completion ordering", function(ok) stopped_ok = ok end)
		ctx.complete(1, 0, "", true)
		helpers.assert_nil(stopped_ok,
			"completion must defer its verdict because the final stream callback can still follow")
		ctx.fire_zero_timers()
		helpers.assert_nil(stopped_ok,
			"one runloop turn is not a documented bound for hs.task's final stream callback")

		ctx.chunk(1, "STOPPED\n")
		helpers.assert_true(stopped_ok == true,
			"the documented final streaming callback must still satisfy STOPPED")
		helpers.assert_eq(controller.status(), "idle", "old completion ordering must preserve detached state")
	end)

	helpers.it("cancels a failed fallback retry when a late STOPPED proves safety", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.start()
		ctx.chunk(1, "READY\n")
		controller.stop("late protocol proof")

		ctx.complete(1, 0, "", true)
		helpers.assert_eq(#ctx.spawns, 2,
			"worker completion must start the redundant exact-generation revoker")
		ctx.complete(2, 1, "", true)
		local retry = ctx.timers[#ctx.timers]
		helpers.assert_true(retry and retry.delay == 1 and not retry.cancelled,
			"a failed detached revoker must retain its bounded retry before protocol proof")

		ctx.chunk(1, "STOPPED\n")
		helpers.assert_true(retry.cancelled,
			"late STOPPED must cancel the now-redundant fallback retry timer")
		local spawn_count = #ctx.spawns
		retry.fn()
		helpers.assert_eq(#ctx.spawns, spawn_count,
			"a queued callback from the cancelled retry must be generation-fenced")
	end)

	helpers.it("fails a completed stop only when the existing STOPPED deadline expires", function()
		local controller, ctx = load_controller()
		controller.init()
		controller.start()
		ctx.chunk(1, "READY\n")

		local stopped_ok = nil
		controller.stop("missing final stream", function(ok) stopped_ok = ok end)
		ctx.complete(1, 0, "", true)
		helpers.assert_nil(stopped_ok, "completion alone cannot prove the final ACK is absent")

		ctx.fire_latest_timer()
		helpers.assert_nil(stopped_ok,
			"the STOPPED deadline alone cannot certify that the fallback fence completed")
		ctx.complete(2, 0, "")
		helpers.assert_true(stopped_ok == true,
			"the callback succeeds only after exact native fallback revocation succeeds")
	end)
end)

package.loaded["platform.remap.lease_controller"] = nil
package.loaded["adapters.shell_runner"] = nil
package.loaded["adapters.timer_scheduler"] = nil
package.loaded["platform.remap.ke_paths"] = nil
package.loaded["platform.remap.lease_helper"] = nil
package.loaded["infra.logger"] = nil
