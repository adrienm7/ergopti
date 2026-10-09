--- tests/unit/modules/llm/test_stream_watchdog_timer_ownership.lua

local helpers = require("tests.helpers")

local function load_fixture()
	local fixture = {
		start_mode = "success",
		stop_mode = "success",
		timers = {},
		renders = 0,
		stop_on_render = false,
	}
	local timer_stub = {
		secondsSinceEpoch = function() return 1 end,
	}
	function timer_stub.doAfter(_, callback)
		-- Negative control for the former production path: raw doAfter may invoke
		-- before publishing its returned owner.
		callback()
		return { stop = function() return true end }
	end
	function timer_stub.new(delay, callback)
		local timer = {
			delay = delay,
			callback = callback,
			live = false,
			starts = 0,
			stops = 0,
		}
		function timer:start()
			self.starts = self.starts + 1
			self.live = true
			if fixture.start_mode == "sync" then self.callback() end
			if fixture.start_mode == "throw" then error("watchdog start mutation") end
			if fixture.start_mode == "false" then return false end
			if fixture.start_mode == "nil" then return nil end
			return self
		end
		function timer:stop()
			self.stops = self.stops + 1
			if fixture.stop_mode == "throw" then error("watchdog stop refusal") end
			if fixture.stop_mode == "false" then return false end
			if fixture.stop_mode == "nil" then return nil end
			self.live = false
			return self
		end
		function timer:running()
			if fixture.reenter_on_running == true then
				fixture.reenter_on_running = false
				fixture.reentrant_arm_result =
					fixture.handler.arm_watchdog(fixture.context)
			end
			return self.live
		end
		function timer:deliver()
			self.callback()
		end
		fixture.timers[#fixture.timers + 1] = timer
		return timer
	end

	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["modules.llm.parser"] = {
		strip_thinking = function(value) return value end,
		process_prediction = function() return nil end,
	}
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["modules.llm.streaming_handler"] = nil
	local Handler = helpers.load_with_stubs("modules.llm.streaming_handler", {
		timer = timer_stub,
		application = {
			frontmostApplication = function()
				return { title = function() return "WatchdogFixture" end }
			end,
		},
	})
	Handler.init({
		core_llm = {
			get_active_profile = function() return nil end,
			get_backend = function() return "mlx" end,
			get_current_model = function() return "fixture-model" end,
		},
		tooltip = {
			show_predictions = function()
				if fixture.stop_on_render == true then
					fixture.stop_on_render = false
					fixture.reentrant_stop_result = fixture.handler.stop_watchdog()
				end
				if fixture.render_mode == "throw" then
					error("watchdog render failure")
				end
				fixture.renders = fixture.renders + 1
				return true
			end,
			tint = function() return nil end,
		},
		keylogger = {},
	})
	local pending = { value = { { to_type = " partial" } } }
	local visible = { value = true }
	fixture.context = {
		my_fetch_id = 7,
		get_fetch_id = function() return 7 end,
		runtime_available = function() return true end,
		pending_predictions_ref = pending,
		predictions_visible_ref = visible,
		validation_mods = {},
		navigation_mods = {},
		prediction_indent = 0,
		is_ai_preview_enabled = true,
		show_info_bar = false,
		build_info_bar_text = function() return nil end,
		llm_display_name = "Fixture",
		resolve_backend_label = function() return "MLX" end,
		on_ui_unavailable = function()
			fixture.ui_failures = (fixture.ui_failures or 0) + 1
			if fixture.stop_on_ui_unavailable == true then
				fixture.reentrant_failure_stop = fixture.handler.stop_watchdog()
			end
			return true
		end,
	}
	fixture.handler = Handler
	return fixture
end

helpers.describe("stream watchdog exact TimerScheduler ownership", function()
	helpers.it("paints once only after native self-stop settlement", function()
		local fixture = load_fixture()
		helpers.assert_true(fixture.handler.arm_watchdog(fixture.context))
		helpers.assert_eq(fixture.renders, 0,
			"arming must not paint before scheduler commit and settlement")
		local timer = fixture.timers[1]
		timer:deliver()
		helpers.assert_eq(fixture.renders, 1)
		timer:deliver()
		timer:deliver()
		helpers.assert_eq(fixture.renders, 1,
			"late and duplicate native deliveries must stay inert")
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("withholds paint while self-stop returns " .. mode, function()
			local fixture = load_fixture()
			helpers.assert_true(fixture.handler.arm_watchdog(fixture.context))
			local timer = fixture.timers[1]
			fixture.stop_mode = mode
			timer:deliver()
			helpers.assert_eq(fixture.renders, 0)
			helpers.assert_true(timer.live,
				"a refused self-stop must retain the exact native timer")
			fixture.stop_mode = "success"
			timer:deliver()
			helpers.assert_eq(fixture.renders, 1,
				"pending business may run only after a later exact settlement")
			timer:deliver()
			helpers.assert_eq(fixture.renders, 1)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains a mutating " .. mode .. " start and refuses a sibling", function()
			local fixture = load_fixture()
			fixture.start_mode = mode
			fixture.stop_mode = "false"
			helpers.assert_eq(fixture.handler.arm_watchdog(fixture.context), false)
			helpers.assert_eq(#fixture.timers, 1)
			helpers.assert_eq(fixture.renders, 0)
			fixture.start_mode = "success"
			helpers.assert_eq(fixture.handler.arm_watchdog(fixture.context), false)
			helpers.assert_eq(#fixture.timers, 1,
				"cleanup debt must block every sibling watchdog")
			fixture.stop_mode = "success"
			helpers.assert_true(fixture.handler.stop_watchdog())
			helpers.assert_true(fixture.handler.arm_watchdog(fixture.context))
			helpers.assert_eq(#fixture.timers, 2)
		end)
	end

	helpers.it("buffers a synchronous native delivery without painting", function()
		local fixture = load_fixture()
		fixture.start_mode = "sync"
		helpers.assert_eq(fixture.handler.arm_watchdog(fixture.context), false)
		helpers.assert_eq(fixture.renders, 0,
			"a pre-commit delivery must never escape into tooltip paint")
	end)

	helpers.it("retains a logical owner until a reentrant render returns", function()
		local fixture = load_fixture()
		helpers.assert_true(fixture.handler.arm_watchdog(fixture.context))
		fixture.stop_on_render = true
		fixture.timers[1]:deliver()

		helpers.assert_eq(fixture.reentrant_stop_result, false,
			"PAUSE-facing cleanup cannot settle while tooltip rendering is on stack")
		helpers.assert_eq(fixture.renders, 1)
		helpers.assert_true(fixture.handler.stop_watchdog(),
			"cleanup retry after callback return must observe exact settlement")
	end)

	helpers.it("retains the owner through the throwing-render failure callback", function()
		local fixture = load_fixture()
		helpers.assert_true(fixture.handler.arm_watchdog(fixture.context))
		fixture.render_mode = "throw"
		fixture.stop_on_ui_unavailable = true
		fixture.timers[1]:deliver()

		helpers.assert_eq(fixture.ui_failures, 1)
		helpers.assert_eq(fixture.reentrant_failure_stop, false,
			"failure compensation remains part of the owned watchdog callback")
		helpers.assert_true(fixture.handler.stop_watchdog())
	end)

	helpers.it("preserves a successor installed during native stop proof", function()
		local fixture = load_fixture()
		helpers.assert_true(fixture.handler.arm_watchdog(fixture.context))
		fixture.reenter_on_running = true

		helpers.assert_eq(fixture.handler.arm_watchdog(fixture.context), false,
			"the stale outer arm must refuse after a nested successor commits")
		helpers.assert_true(fixture.reentrant_arm_result)
		helpers.assert_eq(#fixture.timers, 2,
			"the outer arm must not publish a third watchdog over the successor")
		helpers.assert_eq(fixture.timers[1].live, false)
		helpers.assert_true(fixture.timers[2].live)
		helpers.assert_true(fixture.handler.stop_watchdog())
		helpers.assert_eq(fixture.timers[2].live, false)
	end)
end)
