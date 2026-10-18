--- tests/unit/ui/menu/menu_llm/models/lifecycle/test_private_model_native_close.lua

--- ==============================================================================
--- MODULE: Private Model Dialog Native Close
--- DESCRIPTION:
--- Runs the actual HuggingFace prompt flow and add-model menu action through
--- the real factory. User closure must retire native window references; queued
--- explicit deletion retains its exact predecessor and never consumes a successor.
--- No token validation, model activation or process dispatch is authorized here.
--- ==============================================================================

local helpers = require("tests.helpers")
require("logger")

--- Composes a real private-model UI flow with native-shaped reference ownership.
--- @param kind string hf or custom.
--- @param scenario function Receives the fixture.
local function with_dialog(kind, scenario)
	helpers.with_stub_scope({
		"ui.menu.menu_llm.models_manager_mlx_hf", "ui.menu.menu_llm.models_selector",
		"ui.menu.menu_llm.models_manager_mlx_repo", "ui.menu.menu_llm.backend_labels",
		"adapters.task_environment", "adapters.shell_runner", "compat.utf8", "diagnostics.runtime_log",
		"infra.manifest_menu", "logger.shim", "menu.renderer", "text_utils",
		"ui.ui_builder", "adapters.timer_scheduler", "adapters.task_lifecycle", "infra.deferred_work",
		"infra.log_folders", "locale.core", "json", "adapters.json_codec", "diagnostics.redact",
		"window_titles", "webview.presentation", "infra.launcher_environment", "adapters.log_transport",
		"app_dirs", "infra.logger", "infra.locale", "_generated.logger_sub_files", "webview.i18n_seed",
		"infra.notifications", "infra.dialog_util", "tests.support.native_webview_close_fixture",
	}, function()
		local h = { windows = {}, retained = {}, deferred = {}, bridges = {}, timers = {}, terminals = {},
			saved = 0, switched = 0, settled = 0 }
		local construct = require("tests.support.native_webview_close_fixture")(h)
		local module_name = kind == "hf" and "ui.menu.menu_llm.models_manager_mlx_hf"
			or "ui.menu.menu_llm.models_selector"
		local subject = helpers.load_with_stubs(module_name, {
			webview = { windowMasks = { titled = 1, closable = 2 }, new = function()
				local view = construct()
				function view:allowNewWindows() assert(not self.disposed); return self end
				function view:evaluateJavaScript() assert(not self.disposed); return self end
				return view
			end, usercontent = { new = function()
				local bridge = {}
				function bridge:setCallback(callback) self.callback = callback; return self end
				h.bridges[#h.bridges + 1] = bridge
				return bridge
			end } },
			timer = { absoluteTime = function() return 1000000000 end, secondsSinceEpoch = function() return 1 end,
				new = function(_, receive)
					local timer = { active = false }
					function timer:start() self.active = true; return self end
					function timer:stop() self.active = false; return self end
					function timer:running() return self.active end
					function timer:deliver() receive() end
					h.timers[#h.timers + 1] = timer
					return timer
				end },
			application = { get = function() return nil end, find = function() return nil end },
			pasteboard = { getContents = function() return "hf_fixture" end },
			task = { new = function() error("private window closure must never validate a token") end },
			drawing = { windowLevels = { normal = 0, floating = 3 } },
			focus = function() end,
			screen = { mainScreen = function()
				return { frame = function() return { x = 0, y = 0, w = 1400, h = 900 } end }
			end },
		})
		if kind == "hf" then
			local manager = {}
			subject.install({ obj = manager, deps = { active_tasks = {} }, presets = {} })
			local provenance = { owner = {}, is_authorized = function() return true end,
				lifecycle = {
					adopt = function(flow) h.flow = flow; return true end,
					settle = function(flow)
						helpers.assert_eq(flow, h.flow)
						h.settled = h.settled + 1
						return true
					end,
				} }
			function h.show()
				if not manager.prompt_hf_login(function(result) h.terminals[#h.terminals + 1] = result end,
					provenance) then return false end
				h.timers[#h.timers]:deliver()
				return h.flow.webview ~= nil
			end
			function h.cancel() h.bridges[#h.bridges].callback({ body = "cancel" }) end
		else
			local menu = subject.build({
				state = { llm_backend = "mlx", llm_model = "", llm_user_models = {} },
				models_mgr = {
					get_installed_models = function() return {} end,
					get_presets = function() return {} end,
					get_model_info = function() end,
					get_model_ram = function() return 0 end,
					is_model_installed = function() return false end,
				},
				switch_model = function() h.switched = h.switched + 1 end,
				disable_model = function() return true end,
				save_prefs = function() h.saved = h.saved + 1; return true end,
				update_menu = function() return true end,
				DEFAULT_STATE = { llm_model_mlx = "", llm_model_ollama = "" },
			})
			for _, item in ipairs(menu) do
				if item.label == "menu.llm.add_model_entry" then h.show = item.action end
			end
			helpers.assert_type(h.show, "function", "the actual custom-model menu action must exist")
			function h.cancel() return h.bridges[#h.bridges].callback({ body = { action = "cancel" } }) end
		end
		function h.drain()
			while #h.deferred > 0 do table.remove(h.deferred, 1)() end
		end
		scenario(h)
	end)
end

helpers.describe("private model dialogs release abandoned native windows", function()
	for _, kind in ipairs({ "hf", "custom" }) do
		helpers.it("retires the user-closed " .. kind .. " model dialog and opens its successor", function()
			with_dialog(kind, function(h)
				helpers.assert_true(h.show())
				local first = h.windows[1]
				first:user_close()
				helpers.assert_nil(h.retained[first], "native udRef outlives a discarded Lua window owner")
				helpers.assert_eq(first.deletes, 0)
				if kind == "hf" then
					helpers.assert_eq(h.terminals, { false })
					helpers.assert_eq(h.settled, 1)
				end
				helpers.assert_true(h.show())
				local successor = h.windows[2]
				helpers.assert_true(h.retained[successor])
				helpers.assert_eq(successor.disposed, false)
				successor:user_close()
				helpers.assert_nil(next(h.retained))
				if kind == "hf" then
					helpers.assert_eq(h.terminals, { false, false })
					helpers.assert_eq(h.settled, 2)
				end
				helpers.assert_eq(h.saved, 0)
				helpers.assert_eq(h.switched, 0)
			end)
		end)

		helpers.it("keeps explicit deferred deletion exact for the " .. kind .. " model dialog", function()
			with_dialog(kind, function(h)
				helpers.assert_true(h.show())
				local first = h.windows[1]
				h.cancel()
				helpers.assert_eq(first.deletes, 1)
				helpers.assert_eq(#h.deferred, 1)
				helpers.assert_true(h.retained[first])
				if kind == "custom" then helpers.assert_true(h.show())
				else helpers.assert_eq(h.show(), false, "the prior auth flow still owns its closing window") end
				h.drain()
				helpers.assert_nil(h.retained[first])
				if kind == "hf" then
					helpers.assert_eq(h.terminals, { false })
					helpers.assert_true(h.show())
				end
				local successor = h.windows[2]
				helpers.assert_true(h.retained[successor])
				helpers.assert_eq(successor.disposed, false)
				h.cancel()
				h.drain()
				helpers.assert_nil(next(h.retained))
				if kind == "hf" then
					helpers.assert_eq(h.terminals, { false, false })
					helpers.assert_eq(h.settled, 2)
				end
				helpers.assert_eq(h.saved, 0)
				helpers.assert_eq(h.switched, 0)
			end)
		end)
	end
end)
