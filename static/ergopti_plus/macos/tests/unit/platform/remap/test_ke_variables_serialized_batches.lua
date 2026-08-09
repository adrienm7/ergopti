--- tests/unit/platform/remap/test_ke_variables_serialized_batches.lua

--- ==============================================================================
--- MODULE: Regression — Karabiner variable writes are serialized latest-wins
--- DESCRIPTION:
--- Drives the Karabiner variable bridge through a controllable asynchronous CLI
--- fake. Independent CLI children can finish out of order and restore stale
--- navigation state. The harness therefore holds the first writer open while
--- newer states arrive, then releases completions explicitly.
---
--- ROOT CAUSE ENCODED HERE:
--- 1. Only one child runs at a time, and pending values coalesce latest-wins
---    without dropping unrelated variables.
--- 2. The gesture bridge cannot write the generation-scoped atomic-mode or
---    revocation namespaces owned by the native worker protocol.
--- 3. A live watchdog is validated before child start; timeout and exhausted
---    recovery poison/fence the exact token before any successor can overlap.
--- 4. Accepted nonzero/refused launches retry twice without new user input, and
---    optional settlement callbacks cannot break serializer progress.
--- 5. CapsWord probes use monotonic revisions and inspect pending intent before
---    active intent, so stale asynchronous observations cannot clear activation.
--- ==============================================================================

local helpers = require("tests.helpers")

local LAYER_VARIABLE = "layer_active"
local LAYER_ON       = 1
local LAYER_OFF      = 0
local TOKEN           = "0123456789abcdef0123456789abcdef"
local TOKEN_B         = "fedcba9876543210fedcba9876543210"
local TOKEN_C         = "11111111111111111111111111111111"

local function scoped_name(logical_name, token)
	return "ergopti_" .. logical_name .. "_" .. (token or TOKEN)
end





-- =============================================
-- =============================================
-- ======= 1/ Controllable Async Harness =======
-- =============================================
-- =============================================

--- Copies a flat variable map so later coalescence cannot mutate test evidence.
--- @param values table Variable map passed to the JSON adapter.
--- @return table snapshot Independent copy of the encoded state.
local function copy_values(values)
	local snapshot = {}
	for name, value in pairs(values) do snapshot[name] = value end
	return snapshot
end

--- Loads a fresh bridge with a fake CLI whose completions fire only on demand.
--- @param options table|nil Controllable task, timer, lease, and engine behavior.
--- @return table bridge Loaded ke_variables module.
--- @return table ctx Task and payload recorder.
local function fresh_bridge(options)
	options = options or {}
	-- Preserve the original compact call shape used by the launch-refusal case.
	if options.start_results == nil and options[1] ~= nil then
		options = { start_results = options }
	end
	local ctx = {
		tasks = {},
		timers = {},
		payloads = {},
		logs = {},
		stop_calls = {},
		engine = {},
		start_results = options.start_results or {},
		timer_results = options.timer_results or {},
		apply_on_start = options.apply_on_start or {},
		stop_results = options.stop_results or {},
		cancel_throws = options.cancel_throws or {},
		cancel_results = options.cancel_results or {},
		cancel_handles = {},
		cancel_calls = 0,
		terminate_results = options.terminate_results or {},
		terminate_throws = options.terminate_throws or {},
		terminate_handles = {},
		terminate_calls = 0,
		lease_phase = "active",
		current_token = TOKEN,
	}
	ctx.engine["ergopti_mode_" .. TOKEN] = 1
	ctx.engine["ergopti_revoked_" .. TOKEN] = 0
	ctx.engine["ergopti_mode_" .. TOKEN_B] = 1
	ctx.engine["ergopti_revoked_" .. TOKEN_B] = 0

	package.loaded["platform.remap.ke_variables"] = nil
	package.loaded["adapters.shell_runner"] = nil
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["adapters.json_codec"] = nil
	package.loaded["platform.remap.ke_paths"] = nil
	package.loaded["platform.remap.lease_contract"] = nil
	package.loaded["platform.remap.lease_controller"] = nil
	local function log(level, format_string, ...)
		local ok, message = pcall(string.format, tostring(format_string), ...)
		ctx.logs[#ctx.logs + 1] = {
			level = level,
			message = ok and message or tostring(format_string),
		}
	end
	package.loaded["infra.logger"] = {
		debug = function(_, ...) log("debug", ...) end,
		info = function(_, ...) log("info", ...) end,
		warn = function(_, ...) log("warn", ...) end,
		error = function(_, ...) log("error", ...) end,
	}

	package.loaded["platform.remap.ke_paths"] = { CLI = "/test/karabiner_cli" }
	package.loaded["platform.remap.lease_controller"] = {
		status = function()
			if ctx.status_error then error(ctx.status_error) end
			return ctx.lease_phase, { token = ctx.current_token }
		end,
		token = function() return ctx.current_token end,
		stop = function(reason, on_done)
			local stop_index = #ctx.stop_calls + 1
			ctx.stop_calls[#ctx.stop_calls + 1] = {
				reason = reason,
				token = ctx.current_token,
			}
			local configured = ctx.stop_results[stop_index]
			if configured == false then
				if type(on_done) == "function" then on_done(false, "injected stop failure") end
				return false
			end
			ctx.engine["ergopti_mode_" .. ctx.current_token] = 0
			ctx.engine["ergopti_revoked_" .. ctx.current_token] = 1
			if type(on_done) == "function" then on_done(true, "stopped") end
			return true
		end,
	}
	package.loaded["adapters.json_codec"] = {
		encode = function(values)
			local payload = "payload-" .. tostring(#ctx.payloads + 1)
			ctx.payloads[#ctx.payloads + 1] = {
				text = payload,
				values = copy_values(values),
			}
			return payload, nil
		end,
	}
	package.loaded["adapters.shell_runner"] = {
		spawn = function(executable, args, on_done)
			local task = {
				executable = executable,
				args = args,
				on_done = on_done,
				started = false,
			}
			ctx.tasks[#ctx.tasks + 1] = task
			local task_index = #ctx.tasks
			return {
				start = function()
					task.start_calls = (task.start_calls or 0) + 1
					local configured = ctx.start_results[task_index]
					if configured == false then
						task.started = false
						return false
					end
				task.started = true
				if ctx.apply_on_start[task_index] then
					local values = {}
					for _, payload in ipairs(ctx.payloads) do
						if payload.text == task.args[2] then values = payload.values break end
					end
					for name, value in pairs(values) do ctx.engine[name] = value end
				end
					return true
				end,
				terminate = function()
					task.terminate_calls = (task.terminate_calls or 0) + 1
					ctx.terminate_calls = ctx.terminate_calls + 1
					ctx.terminate_handles[ctx.terminate_calls] = task
					if ctx.terminate_throws[ctx.terminate_calls] then
						error("injected child termination failure #" .. tostring(ctx.terminate_calls))
					end
					local configured = ctx.terminate_results[ctx.terminate_calls]
					if configured == "nil" then return nil end
					if configured == nil then return true end
					return configured
				end,
			}
		end,
	}
	package.loaded["adapters.timer_scheduler"] = {
		after = function(delay_sec, fn)
			local timer_index = #ctx.timers + 1
			local configured = ctx.timer_results[timer_index]
			if configured == "throw" then error("timer failure #" .. tostring(timer_index)) end
			local timer = {
				delay_sec = delay_sec,
				fn = fn,
				cancelled = false,
				fired = configured == "fired",
			}
			ctx.timers[#ctx.timers + 1] = timer
			return timer
		end,
		cancel = function(timer)
			ctx.cancel_calls = ctx.cancel_calls + 1
			ctx.cancel_handles[ctx.cancel_calls] = timer
			if ctx.cancel_throws[ctx.cancel_calls] then
				error("injected timer cancel failure #" .. tostring(ctx.cancel_calls))
			end
			if ctx.cancel_results[ctx.cancel_calls] == false then return false end
			if timer then timer.cancelled = true end
			return true
		end,
	}

	--- Completes one previously started fake task.
	--- @param index number One-based task index.
	--- @param exit_code number|nil Exit code, defaulting to success.
	function ctx.complete(index, exit_code)
		local task = ctx.tasks[index]
		helpers.assert_not_nil(task, "cannot complete a task that was never spawned")
		helpers.assert_true(task.started, "cannot complete a task that never started")
		task.on_done(exit_code or 0, "", "")
	end

	--- Applies one task payload to the modeled shared Karabiner engine, then exits.
	--- Terminated tasks deliberately remain applicable: terminate() is asynchronous,
	--- and the regression must prove a late same-token side effect is fenced.
	--- @param index number One-based task index.
	--- @param exit_code number|nil Exit code, defaulting to success.
	function ctx.apply(index, exit_code)
		local task = ctx.tasks[index]
		helpers.assert_not_nil(task, "cannot apply a task that was never spawned")
		helpers.assert_true(task.started, "cannot apply a task that never started")
		local payload
		for _, candidate in ipairs(ctx.payloads) do
			if candidate.text == task.args[2] then payload = candidate.values break end
		end
		helpers.assert_not_nil(payload, "task payload must exist before applying it")
		for name, value in pairs(payload) do ctx.engine[name] = value end
		task.on_done(exit_code or 0, "", "")
	end

	--- Fires one writer watchdog exactly as the timer adapter would.
	--- @param index number One-based timer index.
	function ctx.fire_timer(index)
		local timer = ctx.timers[index]
		helpers.assert_not_nil(timer, "cannot fire a watchdog that was never armed")
		helpers.assert_true(not timer.cancelled, "cannot fire a cancelled watchdog")
		timer.fired = true
		timer.fn()
	end

	--- Returns whether one exact generation can currently observe layer_active=1.
	--- @param token string Exact lease token.
	--- @return boolean active Effective managed layer state.
	function ctx.layer_is_active(token)
		return ctx.engine["ergopti_mode_" .. token] == 1
			and ctx.engine["ergopti_revoked_" .. token] == 0
			and ctx.engine[scoped_name(LAYER_VARIABLE, token)] == 1
	end

	return require("platform.remap.ke_variables"), ctx
end

--- Resolves the variable snapshot carried by one recorded CLI task.
--- @param ctx table Harness recorder.
--- @param index number One-based task index.
--- @return table values Encoded variable map.
local function task_values(ctx, index)
	local task = ctx.tasks[index]
	helpers.assert_not_nil(task, "expected a recorded CLI task")
	helpers.assert_eq(task.executable, "/test/karabiner_cli")
	helpers.assert_eq(#task.args, 2, "one writer must receive one flag plus one JSON payload")
	helpers.assert_eq(task.args[1], "--set-variables",
		"the plural CLI operation carries the latest coalesced variable map")
	for _, payload in ipairs(ctx.payloads) do
		if payload.text == task.args[2] then return payload.values end
	end
	error("recorded CLI task refers to an unknown JSON payload")
end

--- Asserts that a task writes the sole live navigation-layer authority.
--- @param ctx table Harness recorder.
--- @param index number One-based task index.
--- @param expected number Expected layer state.
local function assert_layer_state(ctx, index, expected)
	local values = task_values(ctx, index)
	helpers.assert_eq(values[scoped_name(LAYER_VARIABLE)], expected)
	helpers.assert_nil(values.layer_active,
		"the writer must never claim an untagged personal layer variable")
	helpers.assert_nil(values.layer_toggle, "the unread layer_toggle mirror must stay deleted")
	helpers.assert_nil(values.layer_hold, "the unread layer_hold mirror must stay deleted")
end





-- =========================================
-- =========================================
-- ======= 2/ Serialized Coalescence =======
-- =========================================
-- =========================================

helpers.describe("karabiner variables: serialized latest-wins writes", function()
	helpers.it("ke-variables-latest-wins keeps one writer active and finishes OFF", function()
		local bridge, ctx = fresh_bridge()

		helpers.assert_true(bridge.set(LAYER_VARIABLE, LAYER_ON))
		helpers.assert_eq(#ctx.tasks, 1, "one logical ON state must spawn one CLI writer")
		assert_layer_state(ctx, 1, LAYER_ON)

		-- The first writer stays blocked while three newer user intents arrive.
		-- No pending state may start until its completion callback releases the
		-- serialized executor, and only the final OFF state should survive.
		helpers.assert_true(bridge.set(LAYER_VARIABLE, LAYER_OFF))
		helpers.assert_true(bridge.set(LAYER_VARIABLE, LAYER_ON))
		helpers.assert_true(bridge.set(LAYER_VARIABLE, LAYER_OFF))
		helpers.assert_eq(#ctx.tasks, 1,
			"pending layer states must not race the still-running ON writer")

		ctx.complete(1)
		helpers.assert_eq(#ctx.tasks, 2,
			"one coalesced writer must start after the blocked writer completes")
		assert_layer_state(ctx, 2, LAYER_OFF)
		ctx.complete(1)
		helpers.assert_eq(#ctx.tasks, 2,
			"a duplicate stale completion must not release or duplicate the active OFF writer")

		ctx.complete(2)
		helpers.assert_eq(#ctx.tasks, 2,
			"intermediate ON/OFF requests must not leave extra stale writers queued")
	end)

	helpers.it("coalescing keeps unrelated single-variable writes", function()
		local bridge, ctx = fresh_bridge()

		bridge.set(LAYER_VARIABLE, LAYER_ON)
		bridge.set(LAYER_VARIABLE, LAYER_OFF)
		bridge.set("capsword", 1)
		helpers.assert_eq(#ctx.tasks, 1, "all writers must share the same serializer")

		ctx.complete(1)
		helpers.assert_eq(#ctx.tasks, 2)
		local values = task_values(ctx, 2)
		helpers.assert_eq(values[scoped_name(LAYER_VARIABLE)], LAYER_OFF)
		helpers.assert_eq(values[scoped_name("capsword")], 1,
			"latest-wins must merge disjoint values instead of dropping CapsWord")
		helpers.assert_nil(values.capsword,
			"the writer must never claim an untagged personal CapsWord variable")
	end)

	helpers.it("a refused launch releases the executor for the next state", function()
		local bridge, ctx = fresh_bridge({ false, true })

		helpers.assert_true(not bridge.set(LAYER_VARIABLE, LAYER_ON),
			"the caller must observe that the first writer did not start")
		helpers.assert_true(bridge.set(LAYER_VARIABLE, LAYER_OFF),
			"a refused launch must not wedge every later gesture")
		helpers.assert_eq(#ctx.tasks, 2)
		assert_layer_state(ctx, 2, LAYER_OFF)
	end)

	helpers.it("a failed completed writer still releases the final OFF state", function()
		local bridge, ctx = fresh_bridge()

		bridge.set(LAYER_VARIABLE, LAYER_ON)
		bridge.set(LAYER_VARIABLE, LAYER_OFF)
		helpers.assert_eq(#ctx.tasks, 1)

		ctx.complete(1, 9)
		helpers.assert_eq(#ctx.tasks, 1,
			"a nonzero child must wait for bounded recovery instead of spinning immediately")
		helpers.assert_eq(#ctx.timers, 2, "one retry timer must recover the accepted pending OFF")
		ctx.fire_timer(2)
		helpers.assert_eq(#ctx.tasks, 2,
			"the bounded retry must release the final state without another user action")
		assert_layer_state(ctx, 2, LAYER_OFF)
	end)

	helpers.it("a same-generation timeout fences before a terminated child can apply late", function()
		local bridge, ctx = fresh_bridge()
		local callback_results = {}

		helpers.assert_true(bridge.set(LAYER_VARIABLE, LAYER_ON, function(ok, reason)
			callback_results[#callback_results + 1] = {
				ok = ok,
				reason = reason,
				stop_count = #ctx.stop_calls,
			}
		end))
		helpers.assert_true(bridge.set(LAYER_VARIABLE, LAYER_OFF, function(ok, reason)
			callback_results[#callback_results + 1] = {
				ok = ok,
				reason = reason,
				stop_count = #ctx.stop_calls,
			}
		end))
		helpers.assert_eq(#ctx.tasks, 1, "the reproduction requires one hung active writer")
		helpers.assert_eq(#ctx.timers, 1, "every started writer must arm one watchdog")

		ctx.fire_timer(1)
		helpers.assert_eq(ctx.tasks[1].terminate_calls, 1,
			"the watchdog must terminate the exact hung CLI child")
		helpers.assert_eq(#ctx.tasks, 1,
			"no same-token successor may overlap a child whose death is unconfirmed")
		helpers.assert_eq(#ctx.stop_calls, 1,
			"timeout must request one exact lease fence instead of trusting terminate()")
		helpers.assert_eq(ctx.stop_calls[1].token, TOKEN)
		helpers.assert_eq(#callback_results, 2,
			"active and pending accepted writes must both settle on poison")
		helpers.assert_true(not callback_results[1].ok and not callback_results[2].ok)
		helpers.assert_eq(callback_results[1].reason, "superseded")
		helpers.assert_eq(callback_results[1].stop_count, 0,
			"the active callback is deliberately superseded when newer intent arrives")
		helpers.assert_eq(callback_results[2].stop_count, 1,
			"exact fence request must precede the timeout's writer-fenced callback code")

		-- The OS may still deliver the old child's side effect after terminate().
		-- Its exact token must already be inert, so stale ON cannot reactivate rules.
		ctx.apply(1)
		helpers.assert_true(not ctx.layer_is_active(TOKEN),
			"a late timed-out child must remain harmless behind mode=0 + revoked=1")
		helpers.assert_true(not bridge.set(LAYER_VARIABLE, LAYER_OFF),
			"a poisoned token must reject every same-generation successor")
		helpers.assert_eq(#ctx.tasks, 1)
	end)

	helpers.it("validates the watchdog before start so timer failure has zero side effect", function()
		local bridge, ctx = fresh_bridge({
			timer_results = { "fired" },
			apply_on_start = { true },
		})

		local accepted = bridge.set("capsword", 1)
		helpers.assert_true(not accepted, "a write without a watchdog must be rejected synchronously")
		helpers.assert_eq(#ctx.tasks, 1, "the exact CLI task may be created before timer validation")
		helpers.assert_true(not ctx.tasks[1].started,
			"the child must not start before its watchdog has been proven live")
		helpers.assert_eq(ctx.tasks[1].terminate_calls, 1,
			"the never-started ShellRunner task must release its construction-time GC pin")
		helpers.assert_nil(ctx.engine[scoped_name("capsword")],
			"watchdog failure must not leave a side effect behind a false return")
	end)

	helpers.it("still terminates and fences when watchdog cancellation throws", function()
		local bridge, ctx = fresh_bridge({ cancel_throws = { true } })
		local settlement_stop_count = nil

		helpers.assert_true(bridge.set(LAYER_VARIABLE, LAYER_ON, function()
			settlement_stop_count = #ctx.stop_calls
		end))
		ctx.fire_timer(1)
		helpers.assert_eq(ctx.tasks[1].terminate_calls, 1)
		helpers.assert_eq(#ctx.stop_calls, 1,
			"cancel failure inside timeout cleanup must not bypass exact fencing")
		helpers.assert_eq(settlement_stop_count, 1,
			"fence request must happen before timeout settlement invokes user code")
	end)

	helpers.it("retries an accepted pending launch refusal without another user action", function()
		local bridge, ctx = fresh_bridge({ start_results = { true, false, true } })
		local callback_results = {}

		helpers.assert_true(bridge.set(LAYER_VARIABLE, LAYER_ON))
		helpers.assert_true(bridge.set("capsword", 1, function(ok, reason)
			callback_results[#callback_results + 1] = { ok = ok, reason = reason }
		end))
		ctx.complete(1)
		helpers.assert_eq(#ctx.tasks, 2, "the accepted pending batch must attempt its launch")
		helpers.assert_true(not ctx.tasks[2].started, "the injected second launch must be refused")
		helpers.assert_eq(#callback_results, 0,
			"a retryable refusal must not falsely settle the accepted write")
		helpers.assert_eq(#ctx.timers, 3,
			"watchdog 1, cancelled watchdog 2, and one retry timer must be observable")

		ctx.fire_timer(3)
		helpers.assert_eq(#ctx.tasks, 3,
			"the retry timer must make progress without a new bridge.set() call")
		ctx.apply(3)
		helpers.assert_eq(ctx.engine[scoped_name("capsword")], 1)
		helpers.assert_eq(#callback_results, 1)
		helpers.assert_true(callback_results[1].ok, "the callback must settle only after the retry applies")
	end)

	helpers.it("retries a lone accepted nonzero exit and settles its callback once", function()
		local bridge, ctx = fresh_bridge()
		local callback_results = {}

		helpers.assert_true(bridge.set(LAYER_VARIABLE, LAYER_ON, function(ok, reason)
			callback_results[#callback_results + 1] = { ok = ok, reason = reason }
		end))
		ctx.complete(1, 9)
		helpers.assert_eq(#callback_results, 0, "nonzero exit must remain pending while retries exist")
		helpers.assert_eq(#ctx.timers, 2, "the failed writer must arm one bounded retry")
		ctx.fire_timer(2)
		helpers.assert_eq(#ctx.tasks, 2)
		ctx.apply(2)
		helpers.assert_eq(#callback_results, 1)
		helpers.assert_true(callback_results[1].ok)
		helpers.assert_eq(ctx.engine[scoped_name(LAYER_VARIABLE)], LAYER_ON)
	end)

	helpers.it("fences after exactly three failed attempts without an unbounded retry", function()
		local bridge, ctx = fresh_bridge()
		local callback_results = {}

		helpers.assert_true(bridge.set(LAYER_VARIABLE, LAYER_ON, function(ok, reason)
			callback_results[#callback_results + 1] = { ok = ok, reason = reason }
		end))
		ctx.complete(1, 9)
		ctx.fire_timer(2)
		ctx.complete(2, 9)
		ctx.fire_timer(4)
		ctx.complete(3, 9)

		helpers.assert_eq(#ctx.tasks, 3, "initial attempt plus two retries is the hard bound")
		helpers.assert_eq(#ctx.timers, 5,
			"three watchdogs and two retry delays must be the entire recovery schedule")
		helpers.assert_eq(#ctx.stop_calls, 1,
			"retry exhaustion must fence the exact lease instead of accepting a fourth attempt")
		helpers.assert_eq(#callback_results, 1)
		helpers.assert_true(not callback_results[1].ok)
		helpers.assert_eq(callback_results[1].reason, "writer-fenced")
		helpers.assert_true(not ctx.layer_is_active(TOKEN))
	end)

	helpers.it("fails closed when the retry timer itself is unavailable", function()
		local bridge, ctx = fresh_bridge({ timer_results = { nil, "fired" } })
		local callback_results = {}

		helpers.assert_true(bridge.set(LAYER_VARIABLE, LAYER_ON, function(ok, reason)
			callback_results[#callback_results + 1] = { ok = ok, reason = reason }
		end))
		ctx.complete(1, 9)
		helpers.assert_eq(#ctx.stop_calls, 1,
			"an unarmable recovery timer must fence instead of stranding accepted state")
		helpers.assert_eq(#callback_results, 1)
		helpers.assert_true(not callback_results[1].ok)
		helpers.assert_true(not ctx.layer_is_active(TOKEN))
	end)

	helpers.it("a new lease token preempts a hung old-generation writer immediately", function()
		local bridge, ctx = fresh_bridge()

		bridge.set(LAYER_VARIABLE, LAYER_ON)
		bridge.set("capsword", 1) -- pending generation A state must be rejected too
		helpers.assert_eq(#ctx.tasks, 1, "generation A must still own the serializer")

		ctx.current_token = TOKEN_B
		helpers.assert_true(bridge.set(LAYER_VARIABLE, LAYER_OFF))
		helpers.assert_eq(ctx.tasks[1].terminate_calls, 1,
			"generation change must terminate the exact A child")
		helpers.assert_true(ctx.timers[1].cancelled,
			"generation change must cancel A's obsolete watchdog")
		helpers.assert_eq(#ctx.tasks, 2,
			"generation B must start immediately instead of waiting for A's callback")

		local values = task_values(ctx, 2)
		helpers.assert_eq(values[scoped_name(LAYER_VARIABLE, TOKEN_B)], LAYER_OFF)
		helpers.assert_nil(values[scoped_name(LAYER_VARIABLE, TOKEN)],
			"B must not replay A's superseded layer state")
		helpers.assert_nil(values[scoped_name("capsword", TOKEN)],
			"B must discard A's pending generation-scoped state")

		ctx.complete(1)
		bridge.set("capsword", 1)
		helpers.assert_eq(#ctx.tasks, 2,
			"late completion from A must not release B's serializer slot")
		ctx.complete(2)
		helpers.assert_eq(#ctx.tasks, 3,
			"B's own completion must drain B's pending state")
		local pending_values = task_values(ctx, 3)
		helpers.assert_eq(pending_values[scoped_name("capsword", TOKEN_B)], 1)
	end)

	helpers.it("a timeout from A never stops a replacement B lease", function()
		local bridge, ctx = fresh_bridge()

		helpers.assert_true(bridge.set(LAYER_VARIABLE, LAYER_ON))
		ctx.current_token = TOKEN_B
		ctx.fire_timer(1)
		helpers.assert_eq(#ctx.stop_calls, 0,
			"timeout fencing must revalidate the token before calling LeaseController.stop")
		helpers.assert_eq(ctx.engine["ergopti_mode_" .. TOKEN_B], 1)
		helpers.assert_eq(ctx.engine["ergopti_revoked_" .. TOKEN_B], 0)

		helpers.assert_true(bridge.set(LAYER_VARIABLE, LAYER_OFF),
			"replacement B must remain writable after stale A timeout cleanup")
		helpers.assert_eq(#ctx.tasks, 2)
		local values = task_values(ctx, 2)
		helpers.assert_eq(values[scoped_name(LAYER_VARIABLE, TOKEN_B)], LAYER_OFF)
	end)

	helpers.it("retries a refused exact fence and makes a late child harmless", function()
		local bridge, ctx = fresh_bridge({ stop_results = { false, true } })
		local callback_results = {}

		helpers.assert_true(bridge.set(LAYER_VARIABLE, LAYER_ON, function(ok, reason)
			callback_results[#callback_results + 1] = { ok = ok, reason = reason }
		end))
		ctx.fire_timer(1)
		helpers.assert_eq(#ctx.stop_calls, 1)
		helpers.assert_eq(#callback_results, 0,
			"a refused fence must not enter arbitrary settlement code before its retry")
		helpers.assert_eq(#ctx.timers, 2,
			"a refused exact stop must arm one bounded fence retry")
		ctx.apply(1)
		helpers.assert_true(ctx.layer_is_active(TOKEN),
			"the adversarial model must expose the real late-child hazard before retry")

		ctx.fire_timer(2)
		helpers.assert_eq(#ctx.stop_calls, 2)
		helpers.assert_eq(#callback_results, 1)
		helpers.assert_true(not callback_results[1].ok)
		helpers.assert_eq(callback_results[1].reason, "writer-fenced")
		helpers.assert_true(not ctx.layer_is_active(TOKEN),
			"the successful exact retry must revoke the late external side effect")
		helpers.assert_eq(#ctx.timers, 2, "successful fencing must schedule no third attempt")
	end)

	helpers.it("settles an obsolete active callback as superseded even after exit zero", function()
		local bridge, ctx = fresh_bridge()
		local old_results, new_results = {}, {}

		helpers.assert_true(bridge.set("capsword", 1, function(ok, reason, revision)
			old_results[#old_results + 1] = { ok = ok, reason = reason, revision = revision }
		end))
		helpers.assert_true(bridge.set("capsword", 0, function(ok, reason, revision)
			new_results[#new_results + 1] = { ok = ok, reason = reason, revision = revision }
		end))
		helpers.assert_eq(#old_results, 1,
			"newer desired state must settle the active callback before its child exits")
		helpers.assert_true(not old_results[1].ok)
		helpers.assert_eq(old_results[1].reason, "superseded")

		ctx.complete(1)
		helpers.assert_eq(#old_results, 1,
			"exit zero from an obsolete child must never resurrect success")
		helpers.assert_eq(#ctx.tasks, 2)
		ctx.complete(2)
		helpers.assert_eq(#new_results, 1)
		helpers.assert_true(new_results[1].ok)
	end)

	helpers.it("survives a superseded callback that re-enters under a replacement token", function()
		local bridge, ctx = fresh_bridge()
		local reentrant_accepted = false
		local callback_ok, callback_reason = nil, nil

		helpers.assert_true(bridge.set(LAYER_VARIABLE, LAYER_ON, function(ok, reason)
			callback_ok = ok
			callback_reason = reason
			ctx.current_token = TOKEN_B
			reentrant_accepted = bridge.set("capsword", 1)
		end))
		helpers.assert_true(bridge.set(LAYER_VARIABLE, LAYER_OFF),
			"queuing the superseding state must contain callback re-entrance")

		helpers.assert_true(reentrant_accepted)
		helpers.assert_true(not callback_ok)
		helpers.assert_eq(callback_reason, "superseded")
		helpers.assert_eq(ctx.tasks[1].terminate_calls, 1,
			"the callback's replacement token must retire the captured old owner")
		helpers.assert_eq(#ctx.tasks, 2)
		local values = task_values(ctx, 2)
		helpers.assert_eq(values[scoped_name("capsword", TOKEN_B)], 1)
		helpers.assert_nil(values[scoped_name(LAYER_VARIABLE, TOKEN)],
			"the resumed outer enqueue must not overwrite callback-installed generation B")
	end)

	helpers.it("rejects a stale outer set when retirement callback installs a third token", function()
		local bridge, ctx = fresh_bridge()
		local callback_accepted = false

		helpers.assert_true(bridge.set(LAYER_VARIABLE, LAYER_ON, function()
			ctx.current_token = TOKEN_C
			callback_accepted = bridge.set("capsword", 1)
		end))
		ctx.current_token = TOKEN_B
		local stale_outer_accepted = bridge.set(LAYER_VARIABLE, LAYER_OFF)

		helpers.assert_true(callback_accepted,
			"the retirement callback must install its live generation C write")
		helpers.assert_true(not stale_outer_accepted,
			"the resumed B call must revalidate after callback-driven token replacement")
		helpers.assert_eq(#ctx.tasks, 2, "no stale generation B child may be spawned")
		local values = task_values(ctx, 2)
		helpers.assert_eq(values[scoped_name("capsword", TOKEN_C)], 1)
		helpers.assert_nil(values[scoped_name(LAYER_VARIABLE, TOKEN_B)])
	end)

	helpers.it("contains a throwing optional callback and still drains pending state", function()
		local bridge, ctx = fresh_bridge()

		helpers.assert_true(bridge.set(LAYER_VARIABLE, LAYER_ON, function()
			error("injected callback failure")
		end))
		helpers.assert_true(bridge.set("capsword", 1))
		ctx.complete(1)
		helpers.assert_eq(#ctx.tasks, 2,
			"serializer progress must continue after the callback failure is logged")
		local saw_callback_error = false
		for _, entry in ipairs(ctx.logs) do
			if entry.message:find("injected callback failure", 1, true) then
				saw_callback_error = true
				break
			end
		end
		helpers.assert_true(saw_callback_error, "caught callback failure must remain visible in the file logger")
	end)

	helpers.it("contains a throwing timer cancellation and still settles then drains", function()
		local bridge, ctx = fresh_bridge({ cancel_throws = { true } })
		local settled = nil

		helpers.assert_true(bridge.set(LAYER_VARIABLE, LAYER_ON, function(ok)
			settled = ok
		end))
		helpers.assert_true(bridge.set("capsword", 1))
		ctx.complete(1)

		helpers.assert_true(settled, "watchdog cancel failure must not skip successful settlement")
		helpers.assert_eq(#ctx.tasks, 2,
			"watchdog cancel failure must not strand accepted pending output")
		local visible = false
		for _, entry in ipairs(ctx.logs) do
			if entry.message:find("injected timer cancel failure", 1, true) then
				visible = true
				break
			end
		end
		helpers.assert_true(visible, "timer cancellation failure must remain visible in the file logger")
	end)

	helpers.it("retains an explicitly refused timer cancellation and retries the exact handle", function()
		local bridge, ctx = fresh_bridge({ cancel_results = { false, true } })

		helpers.assert_true(bridge.set(LAYER_VARIABLE, LAYER_ON))
		local refused_timer = ctx.timers[1]
		ctx.complete(1)

		helpers.assert_eq(ctx.cancel_calls, 1)
		helpers.assert_true(ctx.cancel_handles[1] == refused_timer,
			"the first cancellation must target the completed writer's exact watchdog")
		helpers.assert_true(not refused_timer.cancelled,
			"an adapter false result must not be fabricated into successful cancellation")

		helpers.assert_true(bridge.set("capsword", 1))
		helpers.assert_eq(ctx.cancel_calls, 1,
			"starting unrelated work must not duplicate cleanup before a cancellation boundary")
		ctx.complete(2)

		helpers.assert_true(ctx.cancel_handles[2] == refused_timer,
			"the next cleanup boundary must retry the retained timer object by identity")
		helpers.assert_true(refused_timer.cancelled,
			"the retained native timer must become settled after the retry succeeds")
		helpers.assert_true(ctx.cancel_handles[3] == ctx.timers[2],
			"after draining the backlog, cleanup must still cancel the current exact watchdog")
	end)

	helpers.it("retains every unsettled child termination and retries the same exact handle", function()
		for _, case in ipairs({
			{ label = "false", options = { terminate_results = { false, true } } },
			{ label = "nil", options = { terminate_results = { "nil", true } } },
			{ label = "throw", options = { terminate_throws = { true, false } } },
		}) do
			local bridge, ctx = fresh_bridge(case.options)

			helpers.assert_true(bridge.set(LAYER_VARIABLE, LAYER_ON))
			local retired_child = ctx.tasks[1]
			ctx.current_token = TOKEN_B
			helpers.assert_true(bridge.set("capsword", 1),
				case.label .. ": a newer exact generation must remain usable after retiring the old writer")

			helpers.assert_eq(ctx.terminate_calls, 2,
				case.label .. ": an unsettled native termination must be retried before a successor starts")
			helpers.assert_true(ctx.terminate_handles[1] == retired_child)
			helpers.assert_true(ctx.terminate_handles[2] == retired_child,
				case.label .. ": cleanup must retain the original capability instead of discovering by name")
			helpers.assert_eq(retired_child.terminate_calls, 2)
			helpers.assert_nil(ctx.tasks[2].terminate_calls,
				case.label .. ": retrying the retired child must not touch the newer exact writer")
		end
	end)

	helpers.it("supersedes a local in-flight CapsWord activation through the shared writer", function()
		local bridge, ctx = fresh_bridge()

		local accepted, activation_revision = bridge.set("capsword", 1)
		helpers.assert_true(accepted)
		helpers.assert_eq(bridge.capsword_revision(), activation_revision)
		local superseded, clear_revision = bridge.supersede_capsword_activation()
		helpers.assert_true(superseded,
			"the watcher helper must detect the latest local in-flight value 1")
		helpers.assert_true(clear_revision > activation_revision)
		helpers.assert_eq(#ctx.tasks, 1, "the clear must serialize behind the active activation")
		local no_op, same_revision = bridge.supersede_capsword_activation()
		helpers.assert_true(not no_op,
			"pending clear must outrank active activation and prevent a duplicate write")
		helpers.assert_eq(same_revision, clear_revision)
		helpers.assert_eq(#ctx.tasks, 1)

		ctx.complete(1)
		helpers.assert_eq(#ctx.tasks, 2)
		local values = task_values(ctx, 2)
		helpers.assert_eq(values[scoped_name("capsword")], 0,
			"the shared serializer must make the watcher clear latest-wins")
	end)

	helpers.it("set_if_revision rejects a stale probe after a newer CapsWord activation", function()
		local bridge, ctx = fresh_bridge()

		local probe_revision = bridge.capsword_revision()
		local accepted, activation_revision = bridge.set("capsword", 1)
		helpers.assert_true(accepted)
		helpers.assert_true(activation_revision > probe_revision)
		local stale_accepted, current_revision = bridge.set_if_revision(
			"capsword",
			0,
			probe_revision
		)
		helpers.assert_true(not stale_accepted,
			"an old probe must not clear the activation that happened while it was in flight")
		helpers.assert_eq(current_revision, activation_revision)
		helpers.assert_eq(#ctx.tasks, 1)
		ctx.apply(1)
		helpers.assert_eq(ctx.engine[scoped_name("capsword")], 1)

		local clear_accepted, clear_revision = bridge.set_if_revision(
			"capsword",
			0,
			activation_revision
		)
		helpers.assert_true(clear_accepted)
		helpers.assert_true(clear_revision > activation_revision)
	end)

	helpers.it("keeps accepting the settled active state until PAUSED acknowledges", function()
		local bridge, ctx = fresh_bridge()
		ctx.lease_phase = "pausing"
		helpers.assert_true(bridge.set(LAYER_VARIABLE, LAYER_OFF),
			"the UI remains active until the pause transaction acknowledges")
		ctx.complete(1)

		ctx.lease_phase = "paused"
		helpers.assert_true(not bridge.set(LAYER_VARIABLE, LAYER_ON),
			"a settled paused generation must reject normal gesture writes")
		helpers.assert_eq(#ctx.tasks, 1)
	end)

	helpers.it("logs the actual LeaseController.status exception", function()
		local bridge, ctx = fresh_bridge()
		ctx.status_error = "status exploded"

		helpers.assert_true(not bridge.set("capsword", 1))
		helpers.assert_eq(#ctx.tasks, 0)
		local visible = false
		for _, entry in ipairs(ctx.logs) do
			if entry.message:find("status exploded", 1, true) then
				visible = true
				break
			end
		end
		helpers.assert_true(visible, "status pcall error must not be replaced by a nil snapshot")
	end)

end)





-- ==============================================
-- ==============================================
-- ======= 3/ Reserved Variable Isolation =======
-- ==============================================
-- ==============================================

helpers.describe("karabiner variables: generation namespaces are reserved", function()
	helpers.it("rejects current and legacy generation names before any CLI side effect", function()
		local bridge, ctx = fresh_bridge()
		local reserved_names = {
			"ergopti_mode_user_supplied",
			"ergopti_lease_user_supplied",
			"ergopti_pause_user_supplied",
			"ergopti_revoked_user_supplied",
			scoped_name("layer_active"),
			scoped_name("capsword"),
		}

		for _, name in ipairs(reserved_names) do
			helpers.assert_true(not bridge.set(name, 1), name .. " must be rejected")
		end
		helpers.assert_nil(bridge.set_all,
			"no public multi-variable API may imply an upstream transaction guarantee")

		helpers.assert_eq(#ctx.tasks, 0,
			"gesture writes must never reach watchdog-owned variable namespaces")
		helpers.assert_eq(#ctx.payloads, 0,
			"reserved-name validation must happen before serialization or subprocess work")
	end)

	helpers.it("rejects unknown bare names instead of overwriting personal variables", function()
		local bridge, ctx = fresh_bridge()
		for _, name in ipairs({ "personal_layer", "system.use_fkeys_as_standard_function_keys" }) do
			helpers.assert_true(not bridge.set(name, 1), name .. " must remain outside driver ownership")
		end
		helpers.assert_eq(#ctx.tasks, 0)
		helpers.assert_eq(#ctx.payloads, 0)
	end)
end)





package.loaded["platform.remap.ke_variables"] = nil
package.loaded["adapters.shell_runner"] = nil
package.loaded["adapters.timer_scheduler"] = nil
package.loaded["adapters.json_codec"] = nil
package.loaded["platform.remap.ke_paths"] = nil
package.loaded["platform.remap.lease_contract"] = nil
package.loaded["platform.remap.lease_controller"] = nil
package.loaded["infra.logger"] = nil
