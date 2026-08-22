--- tests/unit/ui/menu/menu_llm/test_startup_timer_scheduler_ownership.lua

local helpers = require("tests.helpers")

local MODULES = {
	"adapters.timer_scheduler",
	"infra.logger",
	"modules.llm",
	"ui.menu.menu_llm.prediction_lock_registry",
	"ui.menu.menu_llm.startup_controller",
}

local function with_fixture(callback)
	helpers.with_fresh_modules(MODULES, function()
		local fixture = {
			start_mode = "success",
			stop_mode = "success",
			timers = {},
			reattach_calls = 0,
			paused = false,
			pending = false,
			epoch = 0,
		}
		local timer_stub = { secondsSinceEpoch = function() return 1 end }
		function timer_stub.doAfter(_, fn)
			fn()
			return { stop = function() return true end }
		end
		function timer_stub.new(delay, fn)
			local timer = { delay = delay, fn = fn, live = false, stops = 0 }
			function timer:start()
				self.live = true
				if fixture.start_mode == "sync_callback" then self.fn() end
				if fixture.start_mode == "reentrant_pause" then
					fixture.pending = true
					fixture.epoch = fixture.epoch + 1
					fixture.reentrant_pause_result = fixture.pause_owner.pause()
					if fixture.reentrant_pause_result ~= true then
						fixture.reentrant_resume_result = fixture.pause_owner.resume()
					end
					fixture.pending = false
				end
				if fixture.start_mode == "throw" then error("startup timer start mutation") end
				if fixture.start_mode == "false" then return false end
				if fixture.start_mode == "nil" then return nil end
				return self
			end
			function timer:stop()
				self.stops = self.stops + 1
				if fixture.stop_mode == "throw" then error("startup timer stop refusal") end
				if fixture.stop_mode == "false" then return false end
				if fixture.stop_mode == "nil" then return nil end
				self.live = false
				return self
			end
			function timer:running() return self.live end
			function timer:deliver() self.fn() end
			fixture.timers[#fixture.timers + 1] = timer
			return timer
		end

		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["modules.llm"] = { BUILTIN_PROFILES = {} }
		package.loaded["ui.menu.menu_llm.prediction_lock_registry"] = {
			new = function() error("the fixture injects the exact lock registry") end,
		}
		local script_control = {
			get_pause_epoch = function() return fixture.epoch end,
			is_paused = function() return fixture.paused end,
			is_pause_transition_pending = function() return fixture.pending end,
			register_pause_owner = function(name, owner)
				helpers.assert_eq(name, "llm_startup")
				fixture.pause_owner = owner
				return true
			end,
		}
		local models_mgr = {
			create_requirement_owner = function() return {} end,
			pause_requirements = function() return true end,
			get_installed_models = function()
				fixture.installed_reads = (fixture.installed_reads or 0) + 1
				if fixture.pause_on_installed_read == true then
					fixture.reenter_pause("installed")
				end
				return fixture.installed_models or {}
			end,
			force_mlx_check = function(_, on_ok, on_fail)
				fixture.requirement_dispatches = (fixture.requirement_dispatches or 0) + 1
				if fixture.requirement_terminal == "ok" and type(on_ok) == "function" then
					on_ok()
				elseif fixture.requirement_terminal == "fail"
					and type(on_fail) == "function" then
					on_fail("fixture failure")
				end
				return true
			end,
			reattach_download = function()
				fixture.reattach_calls = fixture.reattach_calls + 1
				if fixture.reattach_pause_on_dispatch == true then
					fixture.reattach_owned = true
					fixture.reenter_pause("reattach")
				end
				return true
			end,
			has_reattached_download = function()
				return fixture.reattach_owned == true
			end,
			pause_reattached_download = function()
				fixture.reattach_pause_calls = (fixture.reattach_pause_calls or 0) + 1
				return true
			end,
			resume_reattached_download = function()
				fixture.reattach_resume_calls = (fixture.reattach_resume_calls or 0) + 1
				return true
			end,
		}
		local Startup = helpers.load_with_stubs("ui.menu.menu_llm.startup_controller", {
			timer = timer_stub,
			json = {
				decode = function() return { log_path = "/tmp/fixture.log" } end,
			},
		})
		local state = { llm_enabled = false, llm_backend = "mlx" }
		fixture.state = state
		fixture.check_startup = Startup.new({
			state = state,
			keymap = {},
			models_mgr = models_mgr,
			guarded_check_requirements = function() return true end,
			save_prefs = function()
				fixture.save_calls = (fixture.save_calls or 0) + 1
				if fixture.pause_on_save == true then fixture.reenter_pause("save") end
				return true
			end,
			update_menu = function()
				fixture.menu_updates = (fixture.menu_updates or 0) + 1
				return true
			end,
			apply_llm_shortcut = function() return true end,
			apply_llm_profile_shortcut = function(profile_id)
				fixture.profile_applies = fixture.profile_applies or {}
				fixture.profile_applies[#fixture.profile_applies + 1] = profile_id
				if fixture.pause_on_profile_apply == true then
					fixture.pause_on_profile_apply = false
					fixture.reenter_pause("profile")
				end
				return true
			end,
			activate_hotkey = function() return true end,
			mlx_deps_checker = {},
			deps = {
				script_control = script_control,
				update_menu = function() return true end,
			},
			get_startup_silence = function() return false end,
			set_startup_silence = function(value)
				fixture.startup_silence = value == true
				if fixture.throw_on_startup_silence == true and value == true then
					error("fixture startup silence mutation")
				end
				return true
			end,
			get_trigger_hk = function() return nil end,
			get_profile_hks = function() return {} end,
			prediction_locks = {
				apply_preference = function() return true end,
				acquire = function() return true end,
				release = function() return true end,
				ensure_locked = function() return true end,
			},
		})
		function fixture.reenter_pause(label)
			fixture.pending = true
			fixture.epoch = fixture.epoch + 1
			fixture["reentrant_" .. label .. "_pause"] = fixture.pause_owner.pause()
			if fixture["reentrant_" .. label .. "_pause"] ~= true then
				fixture["reentrant_" .. label .. "_resume"] = fixture.pause_owner.resume()
			end
			fixture.pending = false
		end
		function fixture.deliver(timer)
			local saved_open = io.open
			io.open = function(path, mode)
				if path == "/tmp/hs_mlx_active_download.json" then
					if fixture.pause_on_session_open == true then
						fixture.reenter_pause("session")
					end
					return {
						read = function() return "fixture" end,
						close = function() return true end,
					}
				end
				return saved_open(path, mode)
			end
			local ok, err = xpcall(function() timer:deliver() end, debug.traceback)
			io.open = saved_open
			if not ok then error(err, 0) end
		end
		function fixture.pause(mode)
			fixture.paused = true
			fixture.pending = true
			fixture.epoch = fixture.epoch + 1
			fixture.stop_mode = mode or "success"
			local result = fixture.pause_owner.pause()
			fixture.pending = false
			return result
		end
		callback(fixture)
	end)
end

helpers.describe("startup arm_startup_timer exact TimerScheduler ownership", function()
	helpers.it("aborts exact owners when synchronous startup raises after arming", function()
		with_fixture(function(fixture)
			fixture.throw_on_startup_silence = true
			helpers.assert_eq(fixture.check_startup(), false)
			helpers.assert_eq(#fixture.timers, 1)
			helpers.assert_eq(fixture.timers[1].stops, 1)
			helpers.assert_eq(fixture.timers[1].live, false)
			helpers.assert_eq(fixture.startup_silence, false)
			fixture.deliver(fixture.timers[1])
			helpers.assert_eq(fixture.reattach_calls, 0,
				"an aborted reattachment timer must remain business-inert")
		end)
	end)

	helpers.it("runs the callback once and only after native settlement", function()
		with_fixture(function(fixture)
			helpers.assert_true(fixture.check_startup())
			helpers.assert_eq(#fixture.timers, 1)
			helpers.assert_eq(fixture.reattach_calls, 0)
			fixture.deliver(fixture.timers[1])
			helpers.assert_eq(fixture.reattach_calls, 1)
			fixture.deliver(fixture.timers[1])
			helpers.assert_eq(fixture.reattach_calls, 1)
		end)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("withholds callback while self-stop returns " .. mode, function()
			with_fixture(function(fixture)
				helpers.assert_true(fixture.check_startup())
				fixture.stop_mode = mode
				fixture.deliver(fixture.timers[1])
				helpers.assert_eq(fixture.reattach_calls, 0)
				fixture.stop_mode = "success"
				fixture.deliver(fixture.timers[1])
				helpers.assert_eq(fixture.reattach_calls, 1)
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains and fences PAUSE after " .. mode .. " cancellation", function()
			with_fixture(function(fixture)
				helpers.assert_true(fixture.check_startup())
				helpers.assert_eq(fixture.pause(mode), false)
				local timer = fixture.timers[1]
				helpers.assert_true(timer.live)
				fixture.deliver(timer)
				helpers.assert_eq(fixture.reattach_calls, 0)
				fixture.stop_mode = "success"
				helpers.assert_true(fixture.pause_owner.pause())
				fixture.deliver(timer)
				helpers.assert_eq(fixture.reattach_calls, 0)
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("blocks a sibling after a mutating " .. mode .. " start", function()
			with_fixture(function(fixture)
				fixture.start_mode = mode
				fixture.stop_mode = "false"
				helpers.assert_true(fixture.check_startup())
				helpers.assert_eq(#fixture.timers, 1)
				fixture.start_mode = "success"
				helpers.assert_true(fixture.check_startup())
				helpers.assert_eq(#fixture.timers, 1,
					"an unsettled startup slot must refuse every sibling")
				fixture.stop_mode = "success"
				helpers.assert_true(fixture.pause())
			end)
		end)
	end

	helpers.it("retains and replays reattachment after PAUSE re-enters start", function()
		with_fixture(function(fixture)
			fixture.start_mode = "reentrant_pause"
			helpers.assert_eq(fixture.check_startup(), false)
			helpers.assert_eq(fixture.reentrant_pause_result, false,
				"the in-progress acquisition cannot claim settlement before publication")
			helpers.assert_eq(fixture.reentrant_resume_result, false,
				"rollback must retain the intent until that acquisition settles")
			helpers.assert_eq(fixture.timers[1].live, false)
			fixture.deliver(fixture.timers[1])
			helpers.assert_eq(fixture.reattach_calls, 0)

			fixture.start_mode = "success"
			helpers.assert_true(fixture.pause_owner.resume())
			helpers.assert_eq(#fixture.timers, 2,
				"the settled rollback must create one exact replacement timer")
			fixture.deliver(fixture.timers[2])
			helpers.assert_eq(fixture.reattach_calls, 1)
			fixture.deliver(fixture.timers[1])
			fixture.deliver(fixture.timers[2])
			helpers.assert_eq(fixture.reattach_calls, 1,
				"old and duplicate native callbacks must remain inert")
		end)
	end)

	helpers.it("stops synchronous profile restoration after reentrant PAUSE", function()
		with_fixture(function(fixture)
			fixture.state.llm_user_profiles = {
				{ id = "profile-a" },
				{ id = "profile-b" },
			}
			fixture.state.llm_profile_shortcuts = {
				["profile-a"] = { mods = { "cmd" }, key = "a" },
				["profile-b"] = { mods = { "cmd" }, key = "b" },
			}
			fixture.pause_on_profile_apply = true
			helpers.assert_eq(fixture.check_startup(), false)
			helpers.assert_eq(fixture.reentrant_profile_pause, false)
			helpers.assert_eq(fixture.reentrant_profile_resume, false)
			helpers.assert_eq(#fixture.profile_applies, 1,
				"no sibling shortcut may bind after the nested pause fence")

			helpers.assert_true(fixture.pause_owner.resume())
			helpers.assert_eq(#fixture.profile_applies, 3,
				"the full two-profile restore may replay only after callback settlement")
		end)
	end)

	helpers.it("withholds PAUSED while the reattachment dispatch is on the stack", function()
		with_fixture(function(fixture)
			helpers.assert_true(fixture.check_startup())
			fixture.reattach_pause_on_dispatch = true
			fixture.deliver(fixture.timers[1])

			helpers.assert_eq(fixture.reentrant_reattach_pause, false,
				"the in-flight manager call must remain a visible pause capability")
			helpers.assert_eq(fixture.reentrant_reattach_resume, false,
				"rollback cannot publish while the original callback remains on-stack")
			helpers.assert_eq(fixture.reattach_pause_calls, 2,
				"the manager owner and refusal compensation must join the same work")
			helpers.assert_eq(fixture.reattach_resume_calls or 0, 0)
			helpers.assert_eq(fixture.reattach_calls, 1)
			helpers.assert_true(fixture.pause_owner.resume())
			helpers.assert_eq(fixture.reattach_resume_calls, 1)
			fixture.deliver(fixture.timers[1])
			helpers.assert_eq(fixture.reattach_calls, 1,
				"a duplicate settled timer callback must remain inert")
		end)
	end)

	helpers.it("retains the reattach intent when session I/O re-enters PAUSE", function()
		with_fixture(function(fixture)
			helpers.assert_true(fixture.check_startup())
			fixture.pause_on_session_open = true
			fixture.deliver(fixture.timers[1])
			helpers.assert_eq(fixture.reentrant_session_pause, false)
			helpers.assert_eq(fixture.reentrant_session_resume, false)
			helpers.assert_eq(fixture.reattach_calls, 0,
				"session I/O must not publish a monitor after the nested fence")

			fixture.pause_on_session_open = false
			helpers.assert_true(fixture.pause_owner.resume())
			helpers.assert_eq(#fixture.timers, 2,
				"the exact reattach intent must be rearmed only after callback settlement")
			fixture.deliver(fixture.timers[2])
			helpers.assert_eq(fixture.reattach_calls, 1)
		end)
	end)

	helpers.it("does not rearm primary requirements from a PAUSE-reentrant cache read", function()
		with_fixture(function(fixture)
			fixture.state.llm_enabled = true
			fixture.state.llm_model = "fixture-model"
			helpers.assert_true(fixture.check_startup())
			helpers.assert_eq(#fixture.timers, 3)
			fixture.pause_on_installed_read = true
			fixture.deliver(fixture.timers[2])
			helpers.assert_eq(fixture.reentrant_installed_pause, false)
			helpers.assert_eq(fixture.reentrant_installed_resume, false)
			helpers.assert_eq(#fixture.timers, 3,
				"the stale primary callback must not acquire a successor timer")

			fixture.pause_on_installed_read = false
			helpers.assert_true(fixture.pause_owner.resume())
			helpers.assert_eq(#fixture.timers, 6,
				"RESUME must restore one reattach timer and one primary/backup pair")
		end)
	end)

	helpers.it("keeps terminal finalization owned across a PAUSE-reentrant save", function()
		with_fixture(function(fixture)
			fixture.state.llm_enabled = true
			fixture.state.llm_model = "fixture-model"
			fixture.installed_models = { ["fixture-model"] = true }
			fixture.requirement_terminal = "fail"
			fixture.pause_on_save = true
			helpers.assert_true(fixture.check_startup())
			fixture.deliver(fixture.timers[2])
			helpers.assert_eq(fixture.reentrant_save_pause, false)
			helpers.assert_eq(fixture.reentrant_save_resume, false)
			helpers.assert_eq(fixture.menu_updates or 0, 0,
				"the terminal finalizer must stop at the nested pause fence")

			fixture.pause_on_save = false
			helpers.assert_true(fixture.pause_owner.resume())
			helpers.assert_eq(fixture.menu_updates, 1)
			helpers.assert_eq(fixture.state.llm_enabled, false)
		end)
	end)

	helpers.it("rejects a synchronous native delivery before commit", function()
		with_fixture(function(fixture)
			fixture.start_mode = "sync_callback"
			helpers.assert_true(fixture.check_startup())
			helpers.assert_eq(fixture.reattach_calls, 0)
		end)
	end)
end)
