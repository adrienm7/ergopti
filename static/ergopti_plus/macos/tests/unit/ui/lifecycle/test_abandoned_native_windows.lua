--- tests/unit/ui/lifecycle/test_abandoned_native_windows.lua

--- ==============================================================================
--- MODULE: Abandoned Native Window Release
--- DESCRIPTION:
--- Download and typing dashboards discard their Lua owners on user close. The
--- real factory must opt those windows into native reference retirement, while
--- explicit deferred deletion cannot consume a newly opened window.
--- ==============================================================================

local helpers = require("tests.helpers")
require("logger")

--- Runs one real controller and factory over isolated native reference ownership.
--- @param module_name string Window controller to load.
--- @param scenario function Receives controller and native observations.
local function with_window(module_name, scenario)
	helpers.with_stub_scope({
		"ui.download_window", "ui.download_window.javascript", "ui.download_window.pending_queue",
		"ui.metrics_typing", "ui.metrics_typing.projection", "ui.metrics_typing.snapshot",
		"ui.ui_builder", "ui.webview_close_owner", "adapters.timer_scheduler", "infra.deferred_work", "infra.paced_job", "infra.paced_json",
		"infra.log_folders", "locale.core", "json", "adapters.json_codec", "diagnostics.redact",
		"window_titles", "webview.presentation", "infra.launcher_environment", "adapters.log_transport",
		"app_dirs", "infra.logger", "infra.locale", "_generated.logger_sub_files", "webview.i18n_seed",
		"modules.keystats.log_manager", "tests.support.native_webview_close_fixture",
	}, function()
		local h = { windows = {}, retained = {}, deferred = {}, script_refs = {}, timers = {} }
		local construct = require("tests.support.native_webview_close_fixture")(h)
		local function new_window()
			local view = construct()
			function view:frame() assert(not self.disposed); return { x = 0, y = 0, w = 460, h = 380 } end
			function view:evaluateJavaScript()
				assert(not self.disposed, "retired windows cannot receive JavaScript")
				return self
			end
			return view
		end
		package.loaded["modules.keystats.log_manager"] = { on_ingest_done = function() return true end }
		local window = helpers.load_with_stubs(module_name, {
			webview = { new = new_window, windowMasks = { titled = 1, closable = 2, resizable = 8 },
				usercontent = { new = function()
					local controller = {}
					function controller:setCallback(callback) h.script_refs[self] = callback; return self end
					return controller
				end } },
			timer = { absoluteTime = function() return 1000000000 end, secondsSinceEpoch = function() return 1 end,
				new = function(delay, receive)
					local timer = { active = false, receive = receive, delay = delay }
					function timer:start() self.active = true; return self end
					function timer:stop() self.active = false; return self end
					function timer:running() return self.active end
					h.timers[#h.timers + 1] = timer
					return timer
				end },
			fs = { dir = function() return function() end, {} end },
			drawing = { windowLevels = { normal = 0, floating = 3 } },
			focus = function() end,
			screen = { mainScreen = function()
				return { frame = function() return { x = 0, y = 0, w = 1400, h = 900 } end }
			end },
		})
		function h.show(on_abort)
			if module_name == "ui.download_window" then
				return window.show({ kind = "mlx_model", model = "fixture", on_abort = on_abort })
			end
			return window.show()
		end
		function h.close()
			if module_name == "ui.download_window" then return window.hide() end
			return window.close()
		end
		function h.drain()
			h.drain_native_close()
		end
		scenario(window, h)
	end)
end

helpers.describe("discarded UI windows release native references", function()
	for _, module_name in ipairs({ "ui.download_window", "ui.metrics_typing" }) do
		helpers.it("retires user-closed " .. module_name .. " and opens a healthy successor", function()
			with_window(module_name, function(window, h)
				helpers.assert_true(h.show())
				local first = h.windows[1]
				first:user_close()
				h.drain()
				helpers.assert_nil(h.retained[first], "dropping the Lua owner cannot release native udRef")
				helpers.assert_eq(first.deletes, 1, "user close owns one deferred native delete")
				helpers.assert_nil(next(h.script_refs))
				helpers.assert_true(h.show())
				local successor = h.windows[2]
				helpers.assert_true(h.retained[successor])
				helpers.assert_eq(successor.disposed, false)
				if module_name == "ui.metrics_typing" then helpers.assert_eq(window._wv, successor)
				else helpers.assert_true(window.is_active()) end
				helpers.assert_true(h.close())
				h.drain()
				helpers.assert_nil(next(h.retained))
				helpers.assert_nil(next(h.script_refs))
				if module_name == "ui.metrics_typing" then helpers.assert_nil(window._timer) end
			end)
		end)

		helpers.it("keeps explicit deferred deletion exact for " .. module_name, function()
			with_window(module_name, function(window, h)
				helpers.assert_true(h.show())
				local first = h.windows[1]
				helpers.assert_true(h.close())
				helpers.assert_eq(#h.deferred, 1)
				helpers.assert_true(h.retained[first], "native fade completion has not run")
				helpers.assert_true(h.show())
				local successor = h.windows[2]
				h.drain()
				helpers.assert_nil(h.retained[first])
				helpers.assert_eq(first.deletes, 1)
				helpers.assert_true(h.retained[successor], "old close must not consume the new window")
				helpers.assert_eq(successor.disposed, false)
				if module_name == "ui.metrics_typing" then helpers.assert_eq(window._wv, successor)
				else helpers.assert_true(window.is_active()) end
				helpers.assert_true(h.close())
				h.drain()
				helpers.assert_nil(next(h.retained))
			end)
		end)
	end

	helpers.it("keeps the download successor opened inside its native close callback", function()
		with_window("ui.download_window", function(window, h)
			helpers.assert_true(h.show(function()
				helpers.assert_nil(next(h.script_refs), "old bridge is released before producer callbacks")
				helpers.assert_true(h.show())
			end))
			local first = h.windows[1]
			first:user_close()
			h.drain()
			helpers.assert_eq(#h.windows, 2)
			helpers.assert_nil(h.retained[first])
			helpers.assert_true(h.retained[h.windows[2]])
			helpers.assert_true(window.is_active())
			helpers.assert_true(h.close())
			h.drain()
			helpers.assert_nil(next(h.retained))
			helpers.assert_nil(next(h.script_refs))
		end)
	end)
end)
