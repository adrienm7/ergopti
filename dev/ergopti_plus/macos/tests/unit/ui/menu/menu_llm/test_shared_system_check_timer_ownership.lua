--- tests/unit/ui/menu/menu_llm/test_shared_system_check_timer_ownership.lua

local helpers = require("tests.helpers")

local MODULES = {
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
			authorized = true,
			reentrant_pause_on_first_execute = false,
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
			execute = function(command)
				fixture.executes[#fixture.executes + 1] = command
				if fixture.reentrant_pause_on_first_execute
					and #fixture.executes == 1 then
					fixture.child_present_during_execute =
						fixture.children[fixture.child] ~= nil
					fixture.execute_pause_result = fixture.pause()
				end
				if command:find("hw.memsize", 1, true) then
					return tostring(64 * 1024 * 1024 * 1024)
				end
				return "100"
			end,
			application = {
				get = function()
					if fixture.application_mode == "get_throw" then
						error("system-check application.get failure")
					end
					if fixture.reentrant_pause_on_application_get then
						fixture.child_present_during_application_get =
							fixture.children[fixture.child] ~= nil
						fixture.application_get_pause_result = fixture.pause()
					end
					return nil
				end,
				find = function()
					if fixture.application_mode == "find_throw" then
						error("system-check application.find failure")
					end
					return nil
				end,
			},
			focus = function()
				fixture.focus_calls = (fixture.focus_calls or 0) + 1
				if fixture.reentrant_pause_on_focus then fixture.pause() end
				return true
			end,
		})

		package.loaded["infra.logger"] = helpers.make_logger_stub()
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
		function fixture.arm()
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

	helpers.it("publishes provenance before a system probe re-enters PAUSE", function()
		with_fixture(function(fixture)
			fixture.reentrant_pause_on_first_execute = true
			helpers.assert_eq(fixture.arm(), false)
			helpers.assert_true(fixture.child_present_during_execute,
				"the first native probe must already have an adopted callback owner")
			helpers.assert_eq(fixture.execute_pause_result, false,
				"PAUSE cannot publish while the exact system probe remains on-stack")
			helpers.assert_eq(#fixture.executes, 1,
				"the revoked first probe must fence the sibling disk probe")
			helpers.assert_eq(fixture.dialogs, 0)
			helpers.assert_eq(fixture.downloads, 0)
			helpers.assert_eq(fixture.settles, 1)
			helpers.assert_nil(fixture.children[fixture.child])
		end)
	end)

	helpers.it("revalidates owner identity after freshness re-enters PAUSE", function()
		with_fixture(function(fixture)
			fixture.reentrant_pause_on_freshness = true
			helpers.assert_eq(fixture.arm(), false)
			helpers.assert_true(fixture.child_present_during_freshness)
			helpers.assert_eq(fixture.freshness_pause_result, false)
			helpers.assert_eq(#fixture.executes, 0,
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

	for _, mode in ipairs({ "get_throw", "find_throw" }) do
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
