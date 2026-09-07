--- tests/unit/modules/shortcuts/pause_owners/test_startup.lua

--- ==============================================================================
--- MODULE: Pause Owner startup Regressions
--- DESCRIPTION:
--- Preserves the behavioral pause-owner regression scenarios with a focused
--- fixture boundary. Shared fixtures create fresh runtime state per invocation.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixtures = require("tests.unit.modules.shortcuts.pause_owners.fixtures")
local reset_module = fixtures.reset_module
local load_inventory_context = fixtures.load_inventory_context
local startup_fixture = require("tests.unit.modules.shortcuts.pause_owners.startup_fixture")
local load_real_startup_owner = startup_fixture.load_real_startup_owner
local fire_timer_delay = startup_fixture.fire_timer_delay

helpers.describe("HS-012 real startup timer and manager ownership", function()
	for _, delay in ipairs({ 1, 3 }) do
		for _, mode in ipairs({ "false", "nil", "throw", "sync" }) do
			helpers.it("compensates startup timer " .. tostring(delay)
				.. " acquisition " .. mode, function()
				local ctx = load_real_startup_owner(nil, {
					arm_mode = mode,
					arm_fail_delay = delay,
					arm_failures = 1,
				})
				helpers.assert_eq(ctx.startup_result, false)
				helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false, true }),
					"timer acquisition refusal must restore the startup lease")
				for _, timer in ipairs(ctx.timers) do timer.fn() end
				helpers.assert_eq(#ctx.probes, 0,
					"failed and synchronous timer acquisitions must leave late work fenced")
			end)
		end
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("compensates startup probe dispatch " .. mode .. " exactly once", function()
			local ctx = load_real_startup_owner(nil, { dispatch_mode = mode })
			helpers.assert_true(ctx.startup_result)
			fire_timer_delay(ctx, 1)
			helpers.assert_eq(#ctx.probes, 1)
			helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false, true }))
			local probe = ctx.probes[1]
			probe.on_ok()
			probe.on_fail("late")
			helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false, true }),
				"late or duplicate manager terminals may not restore twice")
			helpers.assert_eq(ctx.state.llm_enabled, true)
		end)

		helpers.it("discards synchronous startup failure before " .. mode
			.. " dispatch refusal", function()
			local ctx = load_real_startup_owner(nil, {
				dispatch_mode = mode,
				sync_terminal = "fail",
			})
			local saves_before = ctx.get_saves()
			local menu_before = ctx.get_menu_updates()
			fire_timer_delay(ctx, 1)
			helpers.assert_eq(ctx.state.llm_enabled, true,
				"a pre-commit terminal may not disable the live preference")
			helpers.assert_eq(ctx.get_saves(), saves_before)
			helpers.assert_eq(ctx.get_menu_updates(), menu_before)
			helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false, true }))
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("fences mutate-then-" .. mode .. " download reattachment", function()
			local active = false
			local parked = false
			local reattach_opts = nil
			local ctx = load_real_startup_owner(nil, {
				reattach_download = function(_, opts)
					active = true
					reattach_opts = opts
					if mode == "false" then return false end
					if mode == "nil" then return nil end
					error("reattach dispatch exploded")
				end,
				has_reattached_download = function() return active end,
				pause_reattached_download = function() parked = true; return true end,
				resume_reattached_download = function(opts)
					parked = false
					reattach_opts = opts
					return true
				end,
			})
			local original_open = io.open
			local original_decode = hs.json.decode
			io.open = function(path, access)
				if path == "/tmp/hs_mlx_active_download.json" then
					return {
						read = function() return "fixture" end,
						close = function() return true end,
					}
				end
				return original_open(path, access)
			end
			hs.json.decode = function()
				return { log_path = "/fixture.log", model = "fixture" }
			end
			fire_timer_delay(ctx, 0.5)
			io.open = original_open
			hs.json.decode = original_decode
			helpers.assert_true(active)
			helpers.assert_true(parked,
				"a refused reattach that created work must run its parking inverse")
			helpers.assert_eq(reattach_opts.is_current(), false,
				"refusal must revoke manager callbacks before compensation")

			ctx.set_epoch(1)
			helpers.assert_true(ctx.owner.pause())
			ctx.set_paused(true)
			ctx.set_epoch(2)
			helpers.assert_true(ctx.owner.resume())
			helpers.assert_eq(parked, false)
			helpers.assert_true(reattach_opts.resume_is_current(),
				"the local owner may resume inside the still-unpublished transaction")
			helpers.assert_eq(reattach_opts.is_current(), false,
				"business callbacks must remain fenced while global state is still PAUSED")
			ctx.set_paused(false)
			helpers.assert_true(reattach_opts.is_current(),
				"only the committed global RESUMED state may re-authorize business callbacks")
		end)
	end

	for _, probe_mode in ipairs({ "nil", "throw" }) do
		helpers.it("retains ambiguous reattachment ownership after probe "
			.. probe_mode, function()
			local pause_calls = 0
			local resume_calls = 0
			local ctx = load_real_startup_owner(nil, {
				reattach_download = function() return false end,
				has_reattached_download = function()
					if probe_mode == "throw" then error("reattach ownership probe exploded") end
					return nil
				end,
				pause_reattached_download = function()
					pause_calls = pause_calls + 1
					return true
				end,
				resume_reattached_download = function()
					resume_calls = resume_calls + 1
					return true
				end,
			})
			local original_open = io.open
			local original_decode = hs.json.decode
			io.open = function(path, access)
				if path == "/tmp/hs_mlx_active_download.json" then
					return {
						read = function() return "fixture" end,
						close = function() return true end,
					}
				end
				return original_open(path, access)
			end
			hs.json.decode = function()
				return { log_path = "/fixture.log", model = "fixture" }
			end
			fire_timer_delay(ctx, 0.5)
			io.open = original_open
			hs.json.decode = original_decode

			helpers.assert_eq(pause_calls, 1,
				"an unreadable ownership probe must compensate the ambiguous owner")
			ctx.set_epoch(1)
			helpers.assert_true(ctx.owner.pause())
			helpers.assert_eq(pause_calls, 2,
				"the compensated owner must remain in the exact global pause snapshot")
			ctx.set_paused(true)
			ctx.set_epoch(2)
			helpers.assert_true(ctx.owner.resume())
			helpers.assert_eq(resume_calls, 1)
		end)
	end

	helpers.it("does not retain a reattachment that settles synchronously", function()
		local pause_calls = 0
		local resume_calls = 0
		local terminal_calls = 0
		local ctx = load_real_startup_owner(nil, {
			reattach_download = function(_, opts)
				terminal_calls = terminal_calls + 1
				helpers.assert_true(opts.on_terminal())
				terminal_calls = terminal_calls + 1
				helpers.assert_true(opts.on_terminal())
				return true
			end,
			has_reattached_download = function() return false end,
			pause_reattached_download = function()
				pause_calls = pause_calls + 1
				return true
			end,
			resume_reattached_download = function()
				resume_calls = resume_calls + 1
				return true
			end,
		})
		local original_open = io.open
		local original_decode = hs.json.decode
		io.open = function(path, access)
			if path == "/tmp/hs_mlx_active_download.json" then
				return {
					read = function() return "fixture" end,
					close = function() return true end,
				}
			end
			return original_open(path, access)
		end
		hs.json.decode = function()
			return { log_path = "/fixture.log", model = "fixture" }
		end
		fire_timer_delay(ctx, 0.5)
		io.open = original_open
		hs.json.decode = original_decode
		helpers.assert_eq(terminal_calls, 2)

		ctx.set_epoch(1)
		helpers.assert_true(ctx.owner.pause())
		ctx.set_paused(true)
		ctx.set_epoch(2)
		helpers.assert_true(ctx.owner.resume())
		helpers.assert_eq(pause_calls, 0,
			"a synchronously settled owner must not be snapshotted")
		helpers.assert_eq(resume_calls, 0,
			"duplicate terminals must not create a phantom resume intent")
	end)

	helpers.it("absorbs an already-dispatched stale failure after pause", function()
		local ctx = load_real_startup_owner()
		fire_timer_delay(ctx, 1)
		local probe = ctx.probes[1]
		helpers.assert_not_nil(probe)
		ctx.set_epoch(1)
		helpers.assert_true(ctx.owner.pause())
		ctx.set_paused(true)
		probe.on_fail("stale")
		helpers.assert_eq(ctx.state.llm_enabled, true)
		helpers.assert_eq(ctx.get_saves(), 0)
		helpers.assert_eq(ctx.get_menu_updates(), 0)
		helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false }),
			"a stale manager cancellation may not disable or unlock during PAUSED")
	end)

	for _, delay in ipairs({ 1, 3 }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("retains startup lease after mutate-then-" .. mode
				.. " success restoration on timer " .. tostring(delay), function()
				local ctx = load_real_startup_owner()
				fire_timer_delay(ctx, delay)
				ctx.set_prediction_mode(mode)
				helpers.assert_eq(ctx.probes[1].on_ok(), false)
				helpers.assert_eq(ctx.get_prediction_state(), true)
				ctx.set_epoch(1)
				ctx.set_prediction_mode("true")
				helpers.assert_true(ctx.owner.pause())
				helpers.assert_eq(ctx.get_prediction_state(), false)
				ctx.set_paused(true)
				ctx.set_epoch(2)
				helpers.assert_true(ctx.owner.resume())
				helpers.assert_eq(ctx.get_prediction_state(), true)
				ctx.probes[1].on_ok()
				helpers.assert_eq(ctx.get_prediction_state(), true,
					"duplicate startup success may not consume or restore a second lease")
			end)
		end
	end

	helpers.it("runs a startup request made during PAUSED exactly once on resume", function()
		local ctx = load_real_startup_owner(nil, { initial_paused = true })
		helpers.assert_true(ctx.startup_result)
		helpers.assert_eq(#ctx.timers, 0,
			"late construction must defer every startup timer while PAUSED")
		ctx.set_epoch(1)
		helpers.assert_true(ctx.owner.resume())
		ctx.set_paused(false)
		helpers.assert_eq(#ctx.timers, 3)
		helpers.assert_true(ctx.owner.resume())
		helpers.assert_eq(#ctx.timers, 3,
			"duplicate resume must not replay the deferred startup request")
	end)

	helpers.it("keeps the startup lease when a later resume owner rolls back", function()
		local ctx = load_real_startup_owner()
		ctx.set_epoch(1)
		helpers.assert_true(ctx.owner.pause())
		ctx.set_paused(true)
		ctx.set_epoch(2)
		helpers.assert_true(ctx.owner.resume())
		helpers.assert_eq(ctx.get_prediction_state(), false,
			"a restarted startup cycle must retain its lease until its own terminal")
		helpers.assert_true(ctx.owner.pause(),
			"same-epoch rollback must reuse the original had-lock snapshot")
		helpers.assert_eq(ctx.get_prediction_state(), false)
		helpers.assert_true(ctx.owner.resume())
		helpers.assert_eq(ctx.get_prediction_state(), false)
		helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false }),
			"pause/resume rollback may not expose either replacement cycle")
		ctx.set_paused(false)
		local replacement = fire_timer_delay(ctx, 1, 6)
		helpers.assert_not_nil(replacement)
		ctx.probes[#ctx.probes].on_ok()
		helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false, true }),
			"the committed replacement terminal must restore the lease exactly once")
	end)

	helpers.it("retains startup work intent across failed inverse and fresh pause retry", function()
		local ctx = load_real_startup_owner()
		ctx.set_epoch(1)
		helpers.assert_true(ctx.owner.pause())
		ctx.set_paused(true)
		ctx.set_epoch(2)
		ctx.set_arm_failure("false", 1, 1)
		helpers.assert_eq(ctx.owner.resume(), false)
		ctx.set_epoch(3)
		ctx.set_arm_failure("true", nil, 0)
		helpers.assert_true(ctx.owner.pause())
		ctx.set_epoch(4)
		helpers.assert_true(ctx.owner.resume())
		local replacement = fire_timer_delay(ctx, 1, 5)
		helpers.assert_not_nil(replacement,
			"the original active startup cycle must survive a new pause epoch")
	end)

	helpers.it("invalidates already-dispatched probes and re-arms only the committed cycle", function()
		local ctx = load_real_startup_owner()
		helpers.assert_eq(#ctx.timers, 3,
			"reattach, primary, and backup timers must be owned")
		fire_timer_delay(ctx, 1)
		fire_timer_delay(ctx, 3)
		helpers.assert_eq(#ctx.probes, 2,
			"positive control must dispatch both real startup probes")

		ctx.set_epoch(1)
		helpers.assert_true(ctx.owner.pause())
		ctx.set_paused(true)
		ctx.set_epoch(2)
		helpers.assert_true(ctx.owner.resume())
		ctx.set_paused(false)

		local native_starts = 0
		for index = 1, 2 do
			local old_probe = ctx.probes[index]
			if old_probe.opts.is_current() then
				native_starts = native_starts + 1
				old_probe.on_ok()
			end
		end
		helpers.assert_eq(native_starts, 0,
			"manager-side is_current must fence probes dispatched before pause")
		helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false }),
			"the startup lock remains owned while the replacement cycle is pending")

		local new_primary = fire_timer_delay(ctx, 1, 4)
		helpers.assert_not_nil(new_primary,
			"resume must re-arm the primary timer from the committed cycle")
		local current_probe = ctx.probes[#ctx.probes]
		helpers.assert_true(current_probe.opts.is_current())
		native_starts = native_starts + 1
		current_probe.on_ok()
		helpers.assert_eq(native_starts, 1)
		helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false, true }),
			"the real startup owner must consume its prediction lock once")
	end)

	helpers.it("replays one startup deferred during PAUSED after a later owner refuses resume", function()
		local script_control = load_inventory_context({
			skip_dynamic_owners = {
				llm_startup = true,
				llm_model_switcher = true,
			},
		})
		helpers.assert_true(script_control.pause_all())
		helpers.assert_true(script_control.is_paused())

		local prediction_calls = {}
		local ctx = load_real_startup_owner(nil, {
			script_control = script_control,
			prediction_calls = prediction_calls,
		})
		helpers.assert_true(ctx.startup_result,
			"construction during PAUSED must accept and retain startup intent")
		helpers.assert_eq(#ctx.timers, 0,
			"deferred startup may not arm timers before a resume attempt")

		local later_resume_calls = 0
		helpers.assert_true(script_control.register_pause_owner("llm_model_switcher", {
			pause = function() return true end,
			resume = function()
				later_resume_calls = later_resume_calls + 1
				return later_resume_calls > 1
			end,
		}))
		helpers.assert_eq(script_control.resume_all(), false,
			"the later registered owner refusal must roll the real startup owner back")
		helpers.assert_true(script_control.is_paused())
		helpers.assert_true(helpers.deep_equal(prediction_calls, { false }),
			"same-epoch rollback must retain and reassert the startup prediction lease")
		helpers.assert_eq(#ctx.timers, 3,
			"the refused attempt must own the exact reattach, primary, and backup timers")
		for _, timer in ipairs(ctx.timers) do timer.fn() end
		helpers.assert_eq(#ctx.probes, 0,
			"timers from the rolled-back deferred attempt must remain fenced")

		local first_retry_timer = #ctx.timers + 1
		helpers.assert_true(script_control.resume_all())
		helpers.assert_eq(script_control.is_paused(), false)
		helpers.assert_eq(#ctx.timers, 6,
			"the retained startup intent must re-arm exactly one replacement timer set")
		helpers.assert_true(helpers.deep_equal(prediction_calls, { false, false }),
			"retry must reassert the same retained lease instead of acquiring a duplicate")
		local primary = fire_timer_delay(ctx, 1, first_retry_timer)
		helpers.assert_not_nil(primary)
		helpers.assert_eq(#ctx.probes, 1,
			"the successful retry must launch the deferred requirements cycle once")

		helpers.assert_true(script_control.resume_all())
		helpers.assert_eq(#ctx.timers, 6,
			"duplicate RESUMED delivery may not replay the consumed startup request")
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("keeps both startup timers inert when stop returns " .. mode, function()
			local ctx = load_real_startup_owner(mode)
			ctx.set_epoch(1)
			helpers.assert_eq(ctx.owner.pause(), false,
				"both timer cleanup refusals must reject the pause owner")
			for _, timer in ipairs(ctx.timers) do timer.fn() end
			helpers.assert_eq(#ctx.probes, 0,
				"even a native late delivery must be fenced before fallible stop")
			ctx.set_stop_mode("true")
			ctx.set_epoch(2)
			helpers.assert_true(ctx.owner.resume(),
				"retained exact timers must be retryable before re-arm")
			helpers.assert_true(#ctx.timers >= 6,
				"only after cleanup settles may the prior timer set be re-armed")
		end)
	end
end)

helpers.describe("HS-012 real reattached MLX work fence", function()
	helpers.it("parks poll, stream, and terminal effects until global RESUMED commits", function()
		local timers = {}
		local timer_stop_mode = "true"
		local native_task = nil
		local native_task_running = false
		local icon_updates = 0
		local window_updates = 0
		local terminal_updates = 0
		local exit_available = false
		reset_module("tests.stubs.hs")
		local hs_stub = require("tests.stubs.hs")
		hs_stub.__reset()
		_G.hs = hs_stub
		package.loaded["hs"] = hs_stub
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.notifications"] = { notify = function() return true end }
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		hs_stub.timer.new = function(_, callback)
			local running = false
			local native = { callback = callback }
			function native:start()
				running = true
				return self
			end
			function native:running() return running end
			function native:stop()
				if timer_stop_mode == "throw" then error("reattach timer stop exploded") end
				if timer_stop_mode == "false" then return false end
				if timer_stop_mode == "nil" then return nil end
				running = false
				return self
			end
			timers[#timers + 1] = native
			return native
		end
		reset_module("adapters.timer_scheduler")
		require("adapters.timer_scheduler")
		package.loaded["adapters.task_lifecycle"] = {
			native = function(_, _, on_done, on_stream)
				native_task = {
					on_done = on_done,
					on_stream = on_stream,
					terminate = function()
						native_task_running = false
						return true
					end,
					isRunning = function() return native_task_running end,
				}
				return native_task
			end,
			start = function()
				native_task_running = true
				return true
			end,
		}
		package.loaded["ui.download_window"] = {
			show = function() return true end,
			update = function() window_updates = window_updates + 1; return true end,
			complete = function()
				terminal_updates = terminal_updates + 1
				return true
			end,
		}
		reset_module("ui.menu.menu_llm.models_manager_mlx_download")
		local obj = {}
		require("ui.menu.menu_llm.models_manager_mlx_download").install({
			obj = obj,
			deps = {
				active_tasks = {},
				update_icon = function()
					icon_updates = icon_updates + 1
					return true
				end,
			},
			presets = { {
				families = { {
					models = { {
						name = "fixture",
						hardware_requirements = { mlx = { download_gb = 1 } },
					} },
				} },
			} },
			project_venv_python_escaped = "python",
			invalidate_installed_cache = function() return true end,
		})
		local original_open = io.open
		io.open = function(path, access)
			if path == "/definitely-missing-hs012.exit" then
				if not exit_available then return nil end
				return {
					read = function() return "0" end,
					close = function() return true end,
				}
			end
			return original_open(path, access)
		end
		local authorized = true
		helpers.assert_true(obj.reattach_download({
			model = "fixture",
			log_path = "/definitely-missing-hs012.log",
			exit_path = "/definitely-missing-hs012.exit",
		}, {
			is_current = function() return authorized end,
		}))
		helpers.assert_not_nil(native_task)
		helpers.assert_eq(#timers, 1)
		local active_poll_index = 1
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			timer_stop_mode = mode
			timers[active_poll_index].callback()
			helpers.assert_eq(#timers, active_poll_index,
				mode .. " terminal-stop refusal may not create a poll successor")
			timer_stop_mode = "true"
			timers[active_poll_index].callback()
			helpers.assert_eq(#timers, active_poll_index + 1,
				mode .. " settlement must release exactly one deferred poll callback")
			timers[active_poll_index].callback()
			helpers.assert_eq(#timers, active_poll_index + 1,
				mode .. " duplicate native delivery must remain inert")
			active_poll_index = active_poll_index + 1
		end
		local icon_before = icon_updates
		local window_before = window_updates

		helpers.assert_true(obj.pause_reattached_download())
		authorized = false
		timers[active_poll_index].callback()
		native_task.on_stream(nil, "__BYTES__:500000000", "")
		helpers.assert_eq(icon_updates, icon_before)
		helpers.assert_eq(window_updates, window_before,
			"already-dispatched tail output must be inert while parked")

		authorized = true
		helpers.assert_true(obj.resume_reattached_download({
			is_current = function() return authorized end,
		}))
		helpers.assert_eq(#timers, active_poll_index + 1,
			"the poll delivery parked during pause must be re-armed once")
		native_task.on_stream(nil, "__BYTES__:500000000", "")
		helpers.assert_true(icon_updates > icon_before)
		helpers.assert_true(window_updates > window_before,
			"positive resume control proves the same real callback can publish")

		helpers.assert_true(obj.pause_reattached_download())
		authorized = false
		exit_available = true
		native_task.on_done()
		helpers.assert_eq(window_updates, window_before + 1,
			"late tail completion must remain parked without terminal UI effects")
		helpers.assert_eq(terminal_updates, 0)

		local globally_resumed = false
		helpers.assert_true(obj.resume_reattached_download({
			resume_is_current = function() return true end,
			is_current = function() return globally_resumed end,
		}))
		helpers.assert_eq(#timers, active_poll_index + 2,
			"tail completion must cross an owned post-resume commit timer")
		helpers.assert_eq(terminal_updates, 0,
			"local owner resume may not publish terminal UI while ScriptControl is PAUSED")

		-- Simulate a later ScriptControl owner refusing in the same resume epoch.
		helpers.assert_true(obj.pause_reattached_download())
		timers[active_poll_index + 2].callback()
		helpers.assert_eq(terminal_updates, 0,
			"the post-resume timer must remain inert after same-epoch rollback")

		helpers.assert_true(obj.resume_reattached_download({
			resume_is_current = function() return true end,
			is_current = function() return globally_resumed end,
		}))
		helpers.assert_eq(#timers, active_poll_index + 3,
			"retry must re-arm the exact parked commit delivery once")
		helpers.assert_eq(terminal_updates, 0)
		globally_resumed = true
		timers[active_poll_index + 3].callback()
		helpers.assert_eq(terminal_updates, 1,
			"only the globally committed retry may publish terminal UI")
		timers[active_poll_index + 3].callback()
		helpers.assert_eq(terminal_updates, 1,
			"duplicate native delivery may not repeat the terminal effect")
		io.open = original_open
	end)
end)
