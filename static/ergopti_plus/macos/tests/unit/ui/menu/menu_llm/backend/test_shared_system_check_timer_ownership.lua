--- tests/unit/ui/menu/menu_llm/backend/test_shared_system_check_timer_ownership.lua

local helpers = require("tests.helpers")

-- Second line, fourth column: the 100 free gigabytes `df -g /` reports.
local DF_OUTPUT = "Filesystem 512-blocks Used Available Capacity Mounted\n/dev/disk3s1 976 300 100 75% /\n"

local MODULES = {
	"adapters.shell_runner",
	"adapters.timer_scheduler",
	"infra.dialog_util",
	"infra.i18n",
	"infra.logger",
	"infra.paths",
	"modules.llm",
	"ui.menu.menu_llm.models_manager",
	"ui.menu.menu_llm.models_manager_mlx",
	"ui.menu.menu_llm.models_manager_ollama",
}

local function with_fixture(callback)
	helpers.with_fresh_modules(MODULES, function()
		local fixture = {
			start_mode = "success",
			stop_mode = "success",
			timers = {},
			dialogs = 0,
			downloads = 0,
			cancels = 0,
			executes = {},
			runs = {},
			authorized = true,
			reentrant_pause_on_focus = false,
			reentrant_pause_on_dialog = false,
			download_mode = "success",
			children = {},
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
				if fixture.start_mode == "sync" then self.fn() end
				if fixture.start_mode == "throw" then error("system-check start mutation") end
				if fixture.start_mode == "false" then return false end
				if fixture.start_mode == "nil" then return nil end
				return self
			end
			function timer:stop()
				self.stops = self.stops + 1
				if fixture.stop_mode == "throw" then error("system-check stop refusal") end
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

		-- Establish one fresh hs/TimerScheduler pair before installing the router's
		-- backend stubs. load_with_stubs intentionally clears every ui.menu module;
		-- using it on the router itself would erase those stubs and silently compose
		-- this focused test with the real Ollama maintenance prewarm.
		helpers.load_with_stubs("adapters.timer_scheduler", {
			timer = timer_stub,
			-- The system probes are asynchronous tasks now; a blocking hs.execute
			-- would hold the main thread (issue #101) and is recorded as a failure.
			execute = function(command)
				fixture.executes[#fixture.executes + 1] = command
				return ""
			end,
			-- The check finds its own process by PID (adapters.running_application),
			-- never by a name lookup that can fall back to reading every window.
			processInfo = { processID = 4242 },
			application = {
				applicationForPID = function()
					if fixture.application_mode == "pid_throw" then
						error("system-check application lookup failure")
					end
					if fixture.reentrant_pause_on_application_get then
						fixture.child_present_during_application_get =
							fixture.children[fixture.child] ~= nil
						fixture.application_get_pause_result = fixture.pause()
					end
					return nil
				end,
				get = function() error("the system check must not look itself up by name") end,
				find = function() error("the system check must not look itself up by name") end,
			},
			focus = function()
				fixture.focus_calls = (fixture.focus_calls or 0) + 1
				if fixture.reentrant_pause_on_focus then fixture.pause() end
				return true
			end,
		})

		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["adapters.shell_runner"] = {
			run = function(executable, args, on_done)
				local run = { executable = executable, args = args, on_done = on_done, terminated = 0 }
				run.handle = { terminate = function()
					run.terminated = run.terminated + 1
					return true
				end }
				fixture.runs[#fixture.runs + 1] = run
				return true, run.handle
			end,
		}
		package.loaded["infra.dialog_util"] = {
			block_alert = function()
				fixture.dialogs = fixture.dialogs + 1
				fixture.child_present_during_dialog =
					fixture.children[fixture.child] ~= nil
				if fixture.reentrant_pause_on_dialog then
					fixture.dialog_pause_result = fixture.pause()
				end
				return "menu.llm.btn_download"
			end,
		}
		package.loaded["infra.i18n"] = { get = function(key)
			if fixture.i18n_throw_key == key then
				error("system-check i18n continuation failure")
			end
			if fixture.reentrant_pause_on_i18n_key == key
				and fixture.i18n_pause_result == nil then
				fixture.i18n_pause_result = fixture.pause()
			end
			return key
		end }
		package.loaded["infra.paths"] = {
			shared_llm_path = function(name)
				return helpers.shared("modules/llm/" .. tostring(name))
			end,
		}
		package.loaded["modules.llm"] = { get_backend = function() return "mlx" end }
		local function backend()
			return {
				get_installed_models = function() return {} end,
				delete_model = function() return true end,
				get_mlx_repo = function(value) return value end,
			}
		end
		package.loaded["ui.menu.menu_llm.models_manager_mlx"] = {
			new = function() return backend() end,
		}
		package.loaded["ui.menu.menu_llm.models_manager_ollama"] = {
			new = function() return backend() end,
		}

		package.loaded["ui.menu.menu_llm.models_manager"] = nil
		local Manager = require("ui.menu.menu_llm.models_manager")
		local deps = {}
		fixture.manager = Manager.new(deps)
		fixture.system_check = deps.shared_system_check
		fixture.lifecycle = {
			adopt = function(child, pause_join)
				fixture.children[child] = pause_join
				fixture.child = child
				return true
			end,
			settle = function(child)
				if fixture.children[child] == nil then return false end
				fixture.children[child] = nil
				fixture.settles = (fixture.settles or 0) + 1
				return true
			end,
		}
		--- Completes every pending probe task the way the native task would.
		function fixture.finish_probes()
			for _, run in ipairs(fixture.runs) do
				if not run.done then
					run.done = true
					if run.terminated > 0 then
						run.on_done(false, nil)
					elseif run.executable:find("sysctl", 1, true) then
						run.on_done(true, tostring(64 * 1024 * 1024 * 1024))
					else
						run.on_done(true, DF_OUTPUT)
					end
				end
			end
		end
		--- Starts the check and leaves its probe tasks pending.
		function fixture.arm_start()
			return fixture.system_check("fixture-model", "MLX", "org/model",
				function()
					fixture.downloads = fixture.downloads + 1
					if fixture.download_mode == "throw" then
						error("system-check download dispatch failure")
					end
					if fixture.download_mode == "false" then return false end
					if fixture.download_mode == "nil" then return nil end
					return true
				end,
				function()
					fixture.cancels = fixture.cancels + 1
					fixture.child_present_during_cancel =
						fixture.children[fixture.child] ~= nil
					if fixture.reentrant_pause_on_cancel == true then
						fixture.cancel_pause_result = fixture.pause()
					end
					fixture.cancel_tail_mutations = (fixture.cancel_tail_mutations or 0) + 1
					return true
				end,
				{
					_requirement_lifecycle = fixture.lifecycle,
					is_current = function()
						if fixture.reentrant_pause_on_freshness
							and fixture.freshness_pause_result == nil then
							fixture.child_present_during_freshness =
								fixture.children[fixture.child] ~= nil
							fixture.freshness_pause_result = fixture.pause()
							return true
						end
						return fixture.authorized
					end,
				})
		end
		--- Starts the check, completes its probes and reports whether it armed.
		function fixture.arm()
			local started = fixture.arm_start()
			fixture.finish_probes()
			return started == true and fixture.cancels == 0 and #fixture.timers > 0
		end
		function fixture.pause()
			fixture.authorized = false
			local join = fixture.children[fixture.child]
			if type(join) == "function" then return join(fixture.child) end
			return true
		end
		callback(fixture)
	end)
end

helpers.describe("shared system-check exact timer requirement ownership", function()
	helpers.it("retains requirement provenance through dialog and download", function()
		with_fixture(function(fixture)
			helpers.assert_true(fixture.arm())
			helpers.assert_not_nil(fixture.children[fixture.child])
			helpers.assert_eq(fixture.dialogs, 0)
			fixture.timers[1]:deliver()
			helpers.assert_eq(fixture.timers[1].stops, 1,
				"one-shot delivery must stop the exact native timer")
			helpers.assert_true(fixture.child_present_during_dialog,
				"the requirement child must cover the full native dialog boundary")
			helpers.assert_eq(fixture.settles, 1)
			helpers.assert_nil(fixture.children[fixture.child])
			helpers.assert_eq(fixture.dialogs, 1)
			helpers.assert_eq(fixture.downloads, 1)
		end)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains and fences PAUSE after " .. mode .. " stop", function()
			with_fixture(function(fixture)
				helpers.assert_true(fixture.arm())
				fixture.stop_mode = mode
				helpers.assert_eq(fixture.pause(), false)
				local timer = fixture.timers[1]
				helpers.assert_true(timer.live)
				timer:deliver()
				helpers.assert_eq(fixture.dialogs, 0)
				helpers.assert_eq(fixture.downloads, 0)
				fixture.stop_mode = "success"
				helpers.assert_true(fixture.pause())
				helpers.assert_nil(fixture.children[fixture.child])
				timer:deliver()
				helpers.assert_eq(fixture.dialogs, 0)
				helpers.assert_eq(fixture.downloads, 0)
			end)
		end)
	end

	helpers.it("withholds the dialog while one-shot self-stop is refused", function()
		with_fixture(function(fixture)
			helpers.assert_true(fixture.arm())
			fixture.stop_mode = "false"
			fixture.timers[1]:deliver()
			helpers.assert_eq(fixture.timers[1].stops, 1)
			helpers.assert_eq(fixture.dialogs, 0)
			fixture.stop_mode = "success"
			fixture.timers[1]:deliver()
			helpers.assert_eq(fixture.timers[1].stops, 2)
			helpers.assert_eq(fixture.dialogs, 1)
			helpers.assert_eq(fixture.downloads, 1)
		end)
	end)

	helpers.it("revalidates provenance after focus re-enters PAUSE", function()
		with_fixture(function(fixture)
			helpers.assert_true(fixture.arm())
			fixture.reentrant_pause_on_focus = true
			fixture.timers[1]:deliver()
			helpers.assert_eq(fixture.dialogs, 0)
			helpers.assert_eq(fixture.downloads, 0)
		end)
	end)

	helpers.it("runs the system probes as tasks, never through a blocking hs.execute", function()
		with_fixture(function(fixture)
			helpers.assert_true(fixture.arm_start())
			helpers.assert_eq(#fixture.executes, 0,
				"a blocking probe holds the main thread (issue #101)")
			helpers.assert_eq(#fixture.runs, 2, "memory and disk are probed by one task each")
			helpers.assert_eq(fixture.runs[1].executable, "/usr/sbin/sysctl")
			helpers.assert_eq(fixture.runs[2].executable, "/bin/df")
			helpers.assert_eq(#fixture.timers, 0, "no timer is armed before both probes finish")
			fixture.finish_probes()
			helpers.assert_eq(#fixture.timers, 1)
			fixture.timers[1]:deliver()
			helpers.assert_eq(fixture.dialogs, 1)
			helpers.assert_eq(fixture.downloads, 1)
		end)
	end)

	helpers.it("keeps the adopted owner and stops the probe tasks when PAUSE arrives mid-probe", function()
		with_fixture(function(fixture)
			helpers.assert_true(fixture.arm_start())
			helpers.assert_not_nil(fixture.children[fixture.child],
				"the probe tasks already have an adopted callback owner")
			helpers.assert_eq(fixture.pause(), false,
				"PAUSE cannot publish while the exact system probes are pending")
			helpers.assert_eq(fixture.runs[1].terminated, 1)
			helpers.assert_eq(fixture.runs[2].terminated, 1)
			helpers.assert_nil(fixture.settles, "the owner settles only after the tasks report")
			fixture.finish_probes()
			helpers.assert_eq(fixture.settles, 1)
			helpers.assert_nil(fixture.children[fixture.child])
			helpers.assert_eq(#fixture.timers, 0, "a revoked check arms no timer")
			helpers.assert_eq(fixture.dialogs, 0)
			helpers.assert_eq(fixture.downloads, 0)
		end)
	end)

	helpers.it("reads free gigabytes from df output exactly as awk NR==2 column 4 did", function()
		local Manager = require("ui.menu.menu_llm.models_manager")
		helpers.assert_eq(Manager.parse_df_available_gb(DF_OUTPUT), 100)
		helpers.assert_eq(Manager.parse_df_available_gb("header only\n"), 0)
		helpers.assert_eq(Manager.parse_df_available_gb(nil), 0)
		helpers.assert_eq(Manager.parse_df_available_gb("h\n/dev/x 1 2\n"), 0)
	end)

	helpers.it("revalidates owner identity after freshness re-enters PAUSE", function()
		with_fixture(function(fixture)
			fixture.reentrant_pause_on_freshness = true
			helpers.assert_eq(fixture.arm(), false)
			helpers.assert_true(fixture.child_present_during_freshness)
			helpers.assert_eq(fixture.freshness_pause_result, false)
			helpers.assert_eq(#fixture.runs, 0,
				"a truthy stale freshness callback cannot authorize the first probe")
			helpers.assert_eq(fixture.focus_calls or 0, 0)
			helpers.assert_eq(fixture.dialogs, 0)
			helpers.assert_nil(fixture.children[fixture.child])
		end)
	end)

	helpers.it("revalidates owner identity after application lookup re-enters PAUSE", function()
		with_fixture(function(fixture)
			helpers.assert_true(fixture.arm())
			fixture.reentrant_pause_on_application_get = true
			fixture.timers[1]:deliver()
			helpers.assert_true(fixture.child_present_during_application_get)
			helpers.assert_eq(fixture.application_get_pause_result, false)
			helpers.assert_eq(fixture.focus_calls or 0, 0,
				"revoked application lookup cannot publish a focus successor")
			helpers.assert_eq(fixture.dialogs, 0)
			helpers.assert_eq(fixture.downloads, 0)
			helpers.assert_nil(fixture.children[fixture.child])
			helpers.assert_true(fixture.pause())
		end)
	end)

	helpers.it("keeps PAUSE pending while the native dialog callback is running", function()
		with_fixture(function(fixture)
			helpers.assert_true(fixture.arm())
			fixture.reentrant_pause_on_dialog = true
			fixture.timers[1]:deliver()
			helpers.assert_true(fixture.child_present_during_dialog)
			helpers.assert_eq(fixture.dialog_pause_result, false,
				"PAUSE must not publish while the dialog boundary is still on-stack")
			helpers.assert_eq(fixture.downloads, 0)
			helpers.assert_eq(fixture.cancels, 0,
				"the requirement registry already owns the re-entrant cancellation")
			helpers.assert_nil(fixture.children[fixture.child])
			helpers.assert_true(fixture.pause(),
				"the same owner must settle immediately after its callback returns")
		end)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("cancels after a " .. mode .. " download dispatch", function()
			with_fixture(function(fixture)
				fixture.download_mode = mode
				helpers.assert_true(fixture.arm())
				fixture.timers[1]:deliver()
				helpers.assert_eq(fixture.downloads, 1)
				helpers.assert_eq(fixture.cancels, 1,
					"only literal true may commit the approved download")
				helpers.assert_nil(fixture.children[fixture.child])
			end)
		end)
	end

	for _, mode in ipairs({ "pid_throw" }) do
		helpers.it("settles the parent when application lookup " .. mode, function()
			with_fixture(function(fixture)
				fixture.application_mode = mode
				helpers.assert_true(fixture.arm())
				fixture.timers[1]:deliver()
				helpers.assert_eq(fixture.dialogs, 0)
				helpers.assert_eq(fixture.downloads, 0)
				helpers.assert_eq(fixture.cancels, 1)
				helpers.assert_nil(fixture.children[fixture.child])
			end)
		end)
	end

	helpers.it("retains the owner through throwing-continuation cancellation", function()
		with_fixture(function(fixture)
			fixture.i18n_throw_key = "menu.llm.not_installed_body"
			fixture.reentrant_pause_on_cancel = true
			helpers.assert_true(fixture.arm())
			fixture.timers[1]:deliver()
			helpers.assert_true(fixture.child_present_during_cancel)
			helpers.assert_eq(fixture.cancel_pause_result, false,
				"on_cancel remains part of the owned continuation")
			helpers.assert_eq(fixture.cancels, 1)
			helpers.assert_nil(fixture.children[fixture.child])
			helpers.assert_true(fixture.pause())
		end)
	end)

	helpers.it("settles an adopted owner when pre-timer message preparation raises", function()
		with_fixture(function(fixture)
			fixture.i18n_throw_key = "menu.llm.req_ram_ok"
			fixture.reentrant_pause_on_cancel = true
			helpers.assert_eq(fixture.arm(), false)
			helpers.assert_true(fixture.child_present_during_cancel,
				"preparation failure must remain adopted through cancellation")
			helpers.assert_eq(fixture.cancel_pause_result, false)
			helpers.assert_eq(fixture.cancels, 1)
			helpers.assert_eq(#fixture.timers, 0,
				"no native timer may be armed after preparation fails")
			helpers.assert_nil(fixture.children[fixture.child])
			helpers.assert_true(fixture.pause())
		end)
	end)

	helpers.it("does not arm after message preparation re-enters PAUSE", function()
		with_fixture(function(fixture)
			fixture.reentrant_pause_on_i18n_key = "menu.llm.req_ram_ok"
			helpers.assert_eq(fixture.arm(), false)
			helpers.assert_eq(fixture.i18n_pause_result, false,
				"the adopted installing owner must keep nested PAUSE pending")
			helpers.assert_eq(#fixture.timers, 0,
				"revoked preparation must not acquire a timer successor")
			helpers.assert_nil(fixture.children[fixture.child])
			helpers.assert_true(fixture.pause())
		end)
	end)

	helpers.it("adopts cancellation before the first stale freshness check", function()
		with_fixture(function(fixture)
			fixture.authorized = false
			fixture.reentrant_pause_on_cancel = true
			helpers.assert_eq(fixture.arm(), false)
			helpers.assert_true(fixture.child_present_during_cancel,
				"stale on_cancel must still execute beneath exact requirement ownership")
			helpers.assert_eq(fixture.cancel_pause_result, false)
			helpers.assert_eq(fixture.cancel_tail_mutations, 1)
			helpers.assert_nil(fixture.children[fixture.child])
			helpers.assert_true(fixture.pause())
		end)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains cancellation ownership after a " .. mode .. " timer start refusal", function()
			with_fixture(function(fixture)
				fixture.start_mode = mode
				fixture.reentrant_pause_on_cancel = true
				helpers.assert_eq(fixture.arm(), false)
				helpers.assert_true(fixture.child_present_during_cancel)
				helpers.assert_eq(fixture.cancel_pause_result, false,
					"timer-refusal cancellation must remain visible until callback return")
				helpers.assert_eq(fixture.cancel_tail_mutations, 1)
				helpers.assert_nil(fixture.children[fixture.child])
				helpers.assert_true(fixture.pause())
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw", "sync" }) do
		helpers.it("cancels business after a " .. mode .. " timer start", function()
			with_fixture(function(fixture)
				fixture.start_mode = mode
				helpers.assert_eq(fixture.arm(), false)
				helpers.assert_eq(fixture.dialogs, 0)
				helpers.assert_eq(fixture.downloads, 0)
				helpers.assert_eq(fixture.cancels, 1)
			end)
		end)
	end
end)
