--- tests/unit/modules/keylogger/test_activation_callback_fail_closed.lua

--- ==============================================================================
--- MODULE: Regression — keylogger activation callback fails closed
--- DESCRIPTION:
--- Drives the real keylogger activation subscriber captured at the
--- ProcessLifecycle boundary. Browser-filter setup is an optional optimisation;
--- if it throws, the security/application context must already be refreshed.
--- If the context refresh itself throws, logging must fail closed instead of
--- retaining a stale non-secure state.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===========================================================
-- ===========================================================
-- ======= 1/ Real Activation Subscriber Harness =============
-- ===========================================================
-- ===========================================================

--- Loads the real keylogger with only OS and persistence boundaries stubbed.
--- @param options table|nil Lifecycle failure controls.
--- @return table context
local function load_keylogger(options)
	options = options or {}
	local ctx = {
		activation_callback = nil,
		context_calls = 0,
		context_should_throw = false,
		errors = {},
		state = nil,
		process_start_calls = 0,
		process_stop_calls = 0,
		keyboard_start_calls = 0,
		keyboard_stop_calls = 0,
		hardware_stop_calls = 0,
		log_stop_calls = 0,
		log_init_calls = 0,
		log_rearm_calls = 0,
		log_live = false,
		input_subscribe_calls = 0,
		input_unsubscribe_calls = 0,
		persist_calls = 0,
		event_callback = nil,
		caffeinate_callback = nil,
		caffeinate_stop_calls = 0,
		idle_calls = 0,
		maintenance_calls = 0,
		foreground_capture_calls = 0,
		kc_stop_calls = 0,
		kc_may_persist = nil,
		timer_handles = {},
	}

	package.loaded["modules.keylogger.init"] = nil
	package.loaded["adapters.synthetic_input"] = nil
	package.loaded["adapters.event_provenance"] = nil
	package.loaded["modules.keymap"] = {}

	local logger = helpers.make_logger_stub()
	logger.error = function(_module, fmt, ...)
		local ok, rendered = pcall(string.format, fmt, ...)
		ctx.errors[#ctx.errors + 1] = ok and rendered or tostring(fmt)
	end
	package.loaded["infra.logger"] = logger
	package.loaded["infra.manifest_reader"] = {
		default_for = function() return true end,
	}
	package.loaded["infra.config_paths"] = {
		get_config_dir = function() return "/tmp/ergopti-test" end,
	}
	package.loaded["infra.dialog_util"] = { alert = function() end }

	package.loaded["modules.keylogger.log_manager"] = {
		init = function(state)
			ctx.state = state
			ctx.log_init_calls = ctx.log_init_calls + 1
			local results = options.log_init_results or { true }
			local result = results[ctx.log_init_calls]
			if result == "throw-after-publish" then
				ctx.log_live = true
				error("log manager initialization exploded after publication")
			end
			if result == false then return false end
			ctx.log_live = true
			return true
		end,
		ensure_ingest_running = function()
			ctx.log_rearm_calls = ctx.log_rearm_calls + 1
			ctx.log_live = true
			local results = options.log_rearm_results or { true }
			return results[ctx.log_rearm_calls] ~= false
		end,
		defer_flush_buffer = function() return true end,
		flush_buffer = function() return true end,
		stop = function()
			ctx.log_stop_calls = ctx.log_stop_calls + 1
			local results = options.log_stop_results or { true }
			if results[ctx.log_stop_calls] == false then return false end
			ctx.log_live = false
			return true
		end,
		append_log = function() ctx.persist_calls = ctx.persist_calls + 1 end,
		log_keystroke = function() ctx.persist_calls = ctx.persist_calls + 1 end,
	}
	package.loaded["modules.keylogger.context_tracker"] = {
		init = function(state)
			ctx.state = state
			return options.context_init_result ~= false
		end,
		update_private_status = function() end,
		update_ax_observer = function() end,
		app_watcher_cb = function(app_name)
			ctx.context_calls = ctx.context_calls + 1
			if ctx.context_should_throw then error("context refresh exploded") end
			ctx.state.active_app_name = app_name
			ctx.state.is_secure_field = true
		end,
		capture_frontmost_app = function()
			ctx.foreground_capture_calls = ctx.foreground_capture_calls + 1
			return true
		end,
	}
	package.loaded["modules.keylogger.kc_bridge"] = {
		init = function(_state, _manager, _tap_hold, _actions, may_persist)
			ctx.kc_may_persist = may_persist
			return true
		end,
		set_log_manager = function() end,
		start = function() return true end,
		stop = function()
			ctx.kc_stop_calls = ctx.kc_stop_calls + 1
			local results = options.kc_stop_results or { true }
			if results[ctx.kc_stop_calls] ~= nil then return results[ctx.kc_stop_calls] end
			return true
		end,
	}
	package.loaded["modules.keylogger.watchers"] = {
		init = function() return options.watcher_init_result ~= false end,
		init_hardware_watchers = function()
			if options.hardware_start_throws then error("hardware watcher exploded") end
			if options.hardware_start_result ~= nil then return options.hardware_start_result end
			if options.hardware_start_returns_nil then return nil end
			return true
		end,
		stop_hardware_watchers = function()
			ctx.hardware_stop_calls = ctx.hardware_stop_calls + 1
			local results = options.hardware_stop_results or { true }
			if options.hardware_stop_returns_nil then return nil end
			if results[ctx.hardware_stop_calls] ~= nil then
				return results[ctx.hardware_stop_calls]
			end
			return true
		end,
		check_idle = function() ctx.idle_calls = ctx.idle_calls + 1 end,
		perform_maintenance = function()
			ctx.maintenance_calls = ctx.maintenance_calls + 1
		end,
		caffeinate_cb = function() ctx.caffeinate_calls = (ctx.caffeinate_calls or 0) + 1 end,
	}
	package.loaded["adapters.process_lifecycle"] = {
		onAppActivate = function(callback) ctx.activation_callback = callback end,
		start = function()
			ctx.process_start_calls = ctx.process_start_calls + 1
			local results = options.start_results or { true }
			return results[ctx.process_start_calls] ~= false
		end,
		stop = function()
			ctx.process_stop_calls = ctx.process_stop_calls + 1
			local results = options.stop_results or { true }
			return results[ctx.process_stop_calls] ~= false
		end,
	}
	package.loaded["adapters.keyboard_hook"] = {
		start = function(start_options)
			ctx.keyboard_start_calls = ctx.keyboard_start_calls + 1
			if type(start_options) == "table" then
				ctx.event_callback = start_options.onEvent
			end
			return options.keyboard_start_result ~= false
		end,
		stop = function()
			ctx.keyboard_stop_calls = ctx.keyboard_stop_calls + 1
			local results = options.keyboard_stop_results or { true }
			return results[ctx.keyboard_stop_calls] ~= false
		end,
		isRunning = function() return options.keyboard_running ~= false end,
	}
	package.loaded["adapters.input_source_broker"] = {
		subscribe = function()
			ctx.input_subscribe_calls = ctx.input_subscribe_calls + 1
			return options.input_subscribe_result ~= false
		end,
		unsubscribe = function()
			ctx.input_unsubscribe_calls = ctx.input_unsubscribe_calls + 1
			return true
		end,
	}

	local hs_overrides = {
		caffeinate = {
			watcher = {
				new = function(callback)
					ctx.caffeinate_callback = callback
					local watcher = { active = false }
					function watcher:start()
						self.active = true
						return self
					end
					function watcher:stop()
						ctx.caffeinate_stop_calls = ctx.caffeinate_stop_calls + 1
						self.active = false
						return self
					end
					return watcher
				end,
			},
		},
		window = {
			focusedWindow = function() return nil end,
			filter = {
				new = function() error("browser filter creation exploded") end,
				windowFocused = 1,
				windowTitleChanged = 2,
			},
		},
	}
	if options.timer_new_fail_at or options.timer_lifecycle then
		local timer_new_calls = 0
		local function timer_handle(delay, callback)
			local timer_index = timer_new_calls
			local handle = {
				delay = delay,
				callback = callback,
				active = false,
				start_calls = 0,
				stop_calls = 0,
			}
			function handle:start()
				self.start_calls = self.start_calls + 1
				if options.timer_start_stays_stopped_at == timer_index then return self end
				self.active = true
				if options.timer_start_throws_after_active_at == timer_index then
					error("timer start exploded after activation")
				end
				return self
			end
			function handle:stop()
				self.stop_calls = self.stop_calls + 1
				if options.timer_stop_stays_running_at == timer_index
					and self.stop_calls <= (options.timer_stop_refusals or 1) then
					return self
				end
				self.active = false
				return self
			end
			function handle:running() return self.active end
			function handle:fire() if self.active then self.callback() end end
			ctx.timer_handles[timer_index] = handle
			return handle
		end
		hs_overrides.timer = {
			absoluteTime = function() return 1000000 end,
			secondsSinceEpoch = function() return 1 end,
			new = function(delay, callback)
				timer_new_calls = timer_new_calls + 1
				if timer_new_calls == options.timer_new_fail_at then return nil end
				return timer_handle(delay, callback)
			end,
			doAfter = function(delay, callback) return timer_handle(delay, callback) end,
			delayed = {
				new = function(delay, callback) return timer_handle(delay, callback) end,
			},
		}
	end
	local keylogger = helpers.load_with_stubs("modules.keylogger.init", hs_overrides)
	ctx.keylogger = keylogger
	ctx.start_result = keylogger.start({ is_paused = function() return false end })
	if options.expect_activation_callback == false then
		helpers.assert_eq(nil, ctx.activation_callback,
			"preparation refusal must not publish the activation subscriber")
	else
		helpers.assert_true(type(ctx.activation_callback) == "function",
			"the test must capture the real production activation subscriber")
	end
	return ctx
end

helpers.describe("keylogger: activation context is fail-closed", function()
	helpers.it("commits security context before optional browser setup (keylogger-activation-context-first)", function()
		local ctx = load_keylogger()
		ctx.activation_callback("Safari", {})
		helpers.assert_eq(1, ctx.context_calls,
			"the canonical context tracker must still run exactly once")
		helpers.assert_eq("Safari", ctx.state.active_app_name,
			"the application identity must not remain stale after optional setup fails")
		helpers.assert_eq(true, ctx.state.is_secure_field,
			"the refreshed secure state must survive optional setup failure")
		helpers.assert_true(#ctx.errors >= 1,
			"the contained browser setup failure must remain visible")
	end)

	helpers.it("forces secure state when context refresh throws (keylogger-activation-fail-closed)", function()
		local ctx = load_keylogger()
		ctx.state.is_secure_field = false
		ctx.context_should_throw = true
		ctx.activation_callback("Safari", {})
		helpers.assert_eq(true, ctx.state.is_secure_field,
			"uncertain privacy context must fail closed, never retain stale false")
		helpers.assert_true(#ctx.errors >= 1
			and ctx.errors[#ctx.errors]:find("context refresh exploded", 1, true) ~= nil,
			"the file logger must preserve the context refresh failure")
	end)
end)

helpers.describe("keylogger: ProcessLifecycle commitment is transitive", function()
	helpers.it("retains broker cleanup ownership when subscription refuses after mutation", function()
		local ctx = load_keylogger({
			input_subscribe_result = false,
			expect_activation_callback = false,
		})

		helpers.assert_eq(false, ctx.start_result)
		helpers.assert_eq(1, ctx.input_subscribe_calls)
		helpers.assert_eq(1, ctx.input_unsubscribe_calls,
			"a failed broker call may already own the setter-only native slot")
		helpers.assert_eq(0, ctx.process_start_calls,
			"preparation refusal must abort before native producer acquisition")
	end)

	helpers.it("rejects an exact log-manager initialization refusal before native producers", function()
		local ctx = load_keylogger({
			log_init_results = { false },
			expect_activation_callback = false,
		})

		helpers.assert_eq(false, ctx.start_result)
		helpers.assert_eq(false, ctx.state.is_enabled)
		helpers.assert_eq(0, ctx.process_start_calls)
		helpers.assert_eq(0, ctx.keyboard_start_calls,
			"persistence refusal must abort before eventtap acquisition")
		helpers.assert_eq(1, ctx.log_stop_calls,
			"the caller must conservatively clean a potentially partial init")
	end)

	helpers.it("rejects an exact watcher initialization refusal before native producers", function()
		local ctx = load_keylogger({
			watcher_init_result = false,
			expect_activation_callback = false,
		})
		helpers.assert_eq(ctx.start_result, false,
			"keylogger startup must propagate the watcher init refusal")
		helpers.assert_eq(ctx.process_start_calls, 0,
			"watcher preparation failure must abort before hardware producers")
		helpers.assert_eq(ctx.keyboard_start_calls, 0,
			"watcher preparation failure must abort before the keyboard hook")
	end)

	helpers.it("rejects an exact context-tracker initialization refusal before native producers", function()
		local ctx = load_keylogger({
			context_init_result = false,
			expect_activation_callback = false,
		})
		helpers.assert_eq(ctx.start_result, false,
			"keylogger startup must propagate the context init refusal")
		helpers.assert_eq(ctx.process_start_calls, 0)
		helpers.assert_eq(ctx.keyboard_start_calls, 0)
	end)

	helpers.it("rolls back a post-publication log-manager throw and retries initialization", function()
		local ctx = load_keylogger({
			log_init_results = { "throw-after-publish", true },
			expect_activation_callback = false,
		})

		helpers.assert_eq(false, ctx.start_result)
		helpers.assert_eq(false, ctx.log_live,
			"rollback must revoke state published before the initializer threw")
		helpers.assert_eq(1, ctx.log_stop_calls)
		helpers.assert_eq(0, ctx.keyboard_start_calls)
		helpers.assert_eq(true,
			ctx.keylogger.start({ is_paused = function() return false end }),
			"a later start must execute initialization again and commit")
		helpers.assert_eq(2, ctx.log_init_calls,
			"retry must not inherit an idempotent-but-partial log manager")
		helpers.assert_eq(true, ctx.log_live)
		helpers.assert_eq(1, ctx.keyboard_start_calls)
	end)

	helpers.it("rolls back a throwing required producer before eventtap acquisition", function()
		local ctx = load_keylogger({ hardware_start_throws = true })

		helpers.assert_eq(false, ctx.start_result)
		helpers.assert_eq(false, ctx.state.is_enabled)
		helpers.assert_eq(0, ctx.keyboard_start_calls,
			"the eventtap must not start after an earlier required producer throws")
		helpers.assert_eq(1, ctx.process_stop_calls)
		helpers.assert_eq(1, ctx.hardware_stop_calls,
			"rollback must still invoke every sibling cleanup")
		helpers.assert_eq(1, ctx.log_stop_calls)
	end)

	helpers.it("rejects a nil hardware-watcher startup result", function()
		local ctx = load_keylogger({ hardware_start_returns_nil = true })
		helpers.assert_eq(ctx.start_result, false,
			"nil must not masquerade as a committed hardware watcher composite")
		helpers.assert_eq(ctx.keyboard_start_calls, 0)
		helpers.assert_eq(ctx.hardware_stop_calls, 1,
			"startup refusal must run exact hardware rollback")
	end)

	helpers.it("rolls back an exact ingest re-arm refusal before eventtap acquisition", function()
		local ctx = load_keylogger({ log_rearm_results = { false } })

		helpers.assert_eq(false, ctx.start_result,
			"a persistence re-arm refusal must reject keylogger startup")
		helpers.assert_eq(false, ctx.state.is_enabled)
		helpers.assert_eq(0, ctx.keyboard_start_calls,
			"the eventtap must not start without committed persistence ownership")
		helpers.assert_eq(1, ctx.process_stop_calls,
			"re-arm refusal must roll back the already-live application watcher")
		helpers.assert_eq(1, ctx.log_stop_calls,
			"re-arm refusal must release the potentially partial log-manager owner")
		helpers.assert_eq(false, ctx.log_live)
	end)

	helpers.it("rolls back every owner when a post-eventtap timer is unavailable", function()
		local ctx = load_keylogger({ timer_new_fail_at = 1 })

		helpers.assert_eq(false, ctx.start_result)
		helpers.assert_eq(false, ctx.state.is_enabled)
		helpers.assert_eq(1, ctx.keyboard_start_calls)
		helpers.assert_eq(1, ctx.keyboard_stop_calls,
			"timer allocation failure must revoke the already-live eventtap")
		helpers.assert_eq(1, ctx.process_stop_calls)
		helpers.assert_eq(1, ctx.log_stop_calls)
	end)

	helpers.it("rejects adapter start refusal even if stale native state still looks enabled", function()
		local ctx = load_keylogger({
			keyboard_start_result = false,
			keyboard_running = true,
		})

		helpers.assert_eq(false, ctx.start_result,
			"an explicit adapter refusal must reject keylogger startup")
		helpers.assert_eq(false, ctx.state.is_enabled,
			"stale native state must not publish a committed keylogger")
		helpers.assert_eq(1, ctx.process_stop_calls,
			"adapter refusal must roll back the committed application watcher")
	end)

	helpers.it("rolls back every producer when the keyboard event tap cannot commit", function()
		local ctx = load_keylogger({ keyboard_running = false })

		helpers.assert_eq(false, ctx.start_result,
			"an unavailable keyboard event tap must reject keylogger startup")
		helpers.assert_eq(false, ctx.state.is_enabled,
			"failed eventtap startup must leave the keylogger disabled")
		helpers.assert_eq(1, ctx.process_stop_calls,
			"eventtap failure must release the committed application watcher")
		helpers.assert_eq(1, ctx.keyboard_stop_calls,
			"eventtap failure must clear any partial native hook")
		helpers.assert_eq(1, ctx.log_stop_calls,
			"eventtap failure must stop the persistence producer")
	end)

	helpers.it("fails closed before installing the keyboard hook, then retries cleanly", function()
		local ctx = load_keylogger({ start_results = { false, true } })

		helpers.assert_eq(false, ctx.start_result,
			"a missing security-context watcher must reject keylogger startup")
		helpers.assert_eq(false, ctx.state.is_enabled,
			"failed lifecycle startup must leave the keylogger disabled")
		helpers.assert_eq(true, ctx.state.is_secure_field,
			"unknown application context must fail closed")
		helpers.assert_eq(0, ctx.keyboard_start_calls,
			"the eventtap must not start without secure-context tracking")

		helpers.assert_eq(true,
			ctx.keylogger.start({ is_paused = function() return false end }),
			"a later start must retry the retained lifecycle cleanup/acquisition")
		helpers.assert_eq(1, ctx.keyboard_start_calls,
			"the eventtap starts only after lifecycle commitment")
	end)

	helpers.it("rejects a physical key before the deferred initial context capture", function()
		local ctx = load_keylogger()
		helpers.assert_eq(true, ctx.state.is_secure_field,
			"cold start must default to an unloggable context until foreground capture")
		helpers.assert_true(type(ctx.event_callback) == "function",
			"the test must drive the real keylogger event callback")
		local event = {
			getType = function() return _G.hs.eventtap.event.types.keyDown end,
			getProperty = function() return 0 end,
		}
		ctx.event_callback(event)
		helpers.assert_eq(0, ctx.persist_calls,
			"no physical keystroke may persist before initial context commitment")
		helpers.assert_eq(true,
			ctx.keylogger.start({ is_paused = function() return false end }),
			"idempotent start must report the already-committed lifecycle as success")
		helpers.assert_eq(1, ctx.process_start_calls,
			"idempotent start must not acquire a second native watcher")
	end)

	helpers.it("surfaces teardown debt and lets a stopped caller retry it", function()
		local ctx = load_keylogger({ stop_results = { false, true } })

		helpers.assert_eq(false, ctx.keylogger.stop(),
			"native watcher cleanup debt must be visible to the caller")
		helpers.assert_eq(true, ctx.keylogger.stop(),
			"a second stop while disabled must retry the retained exact handle")
		helpers.assert_eq(2, ctx.process_stop_calls,
			"the disabled guard must not suppress lifecycle cleanup retry")
	end)

	helpers.it("treats a nil hardware teardown result as retained cleanup debt", function()
		local ctx = load_keylogger({ hardware_stop_returns_nil = true })
		helpers.assert_eq(ctx.keylogger.stop(), false,
			"nil must not report hardware watcher cleanup success")
		helpers.assert_true(ctx.hardware_stop_calls >= 1)
	end)

	helpers.it("surfaces keyboard-hook teardown debt and retries the exact adapter", function()
		local ctx = load_keylogger({ keyboard_stop_results = { false, true } })

		helpers.assert_eq(false, ctx.keylogger.stop(),
			"native keyboard-hook cleanup debt must be visible to the caller")
		helpers.assert_eq(true, ctx.keylogger.stop(),
			"a second stop while disabled must retry keyboard-hook cleanup")
		helpers.assert_eq(2, ctx.keyboard_stop_calls,
			"the disabled guard must not suppress retained keyboard-hook cleanup")
	end)

	helpers.it("surfaces log-manager teardown debt and retries the exact owner", function()
		local ctx = load_keylogger({ log_stop_results = { false, true } })

		helpers.assert_eq(false, ctx.keylogger.stop(),
			"log-manager cleanup refusal must be visible to the caller")
		helpers.assert_eq(true, ctx.log_live,
			"a refused cleanup must retain the live ownership obligation")
		helpers.assert_eq(true, ctx.keylogger.stop(),
			"a second stop while disabled must retry log-manager cleanup")
		helpers.assert_eq(2, ctx.log_stop_calls,
			"the disabled guard must not suppress retained persistence cleanup")
		helpers.assert_eq(false, ctx.log_live)
	end)

	helpers.it("reacquires log-manager cleanup ownership after an off-on cycle", function()
		local ctx = load_keylogger()

		helpers.assert_eq(true, ctx.keylogger.stop())
		helpers.assert_eq(1, ctx.log_stop_calls)
		helpers.assert_eq(false, ctx.log_live)
		helpers.assert_eq(true,
			ctx.keylogger.start({ is_paused = function() return false end }))
		helpers.assert_eq(2, ctx.log_rearm_calls,
			"the second start must rearm the existing log-manager state")
		helpers.assert_eq(true, ctx.log_live)
		helpers.assert_eq(true, ctx.keylogger.stop())
		helpers.assert_eq(2, ctx.log_stop_calls,
			"the second stop must release the rearmed timer/database owner")
		helpers.assert_eq(false, ctx.log_live)
	end)

	helpers.it("gives the always-on KC bridge the complete persistence gate", function()
		local ctx = load_keylogger()
		helpers.assert_eq(type(ctx.kc_may_persist), "function",
			"the ledger drain must receive the root gate, not reconstruct privacy alone")

		ctx.keylogger.set_secure_field_filter_enabled(false)
		helpers.assert_eq(ctx.kc_may_persist(), true,
			"disabling the secure-field filter must remain loggable while Metrics is on")
		helpers.assert_eq(ctx.keylogger.stop(), true)
		helpers.assert_eq(ctx.kc_may_persist(), false,
			"feature OFF must deny the retained ledger reader even when secure filtering is off")
	end)
end)

return {
	load_keylogger = load_keylogger,
}
