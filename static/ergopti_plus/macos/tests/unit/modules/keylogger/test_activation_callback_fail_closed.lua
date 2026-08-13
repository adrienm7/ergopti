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
		log_stop_calls = 0,
		persist_calls = 0,
		event_callback = nil,
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
		init = function(state) ctx.state = state end,
		ensure_ingest_running = function() end,
		defer_flush_buffer = function() return true end,
		flush_buffer = function() return true end,
		stop = function() ctx.log_stop_calls = ctx.log_stop_calls + 1; return true end,
		append_log = function() ctx.persist_calls = ctx.persist_calls + 1 end,
		log_keystroke = function() ctx.persist_calls = ctx.persist_calls + 1 end,
	}
	package.loaded["modules.keylogger.context_tracker"] = {
		init = function(state) ctx.state = state end,
		update_private_status = function() end,
		update_ax_observer = function() end,
		app_watcher_cb = function(app_name)
			ctx.context_calls = ctx.context_calls + 1
			if ctx.context_should_throw then error("context refresh exploded") end
			ctx.state.active_app_name = app_name
			ctx.state.is_secure_field = true
		end,
	}
	package.loaded["modules.keylogger.kc_bridge"] = {
		init = function() end,
		set_log_manager = function() end,
		start = function() end,
		stop = function() end,
	}
	package.loaded["modules.keylogger.watchers"] = {
		init = function() end,
		init_hardware_watchers = function() end,
		stop_hardware_watchers = function() end,
		check_idle = function() end,
		perform_maintenance = function() end,
		caffeinate_cb = function() end,
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
		start = function(options)
			ctx.keyboard_start_calls = ctx.keyboard_start_calls + 1
			if type(options) == "table" then ctx.event_callback = options.onEvent end
			return true
		end,
		stop = function() return true end,
		isRunning = function() return true end,
	}

	local keylogger = helpers.load_with_stubs("modules.keylogger.init", {
		caffeinate = {
			watcher = {
				new = function()
					return {
						start = function(self) return self end,
						stop = function(self) return self end,
					}
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
	})
	ctx.keylogger = keylogger
	ctx.start_result = keylogger.start({ is_paused = function() return false end })
	helpers.assert_true(type(ctx.activation_callback) == "function",
		"the test must capture the real production activation subscriber")
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
end)
