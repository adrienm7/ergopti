--- tests/unit/ui/editors/lifecycle/test_native_close_retirement.lua

--- ==============================================================================
--- MODULE: Editor Native Window Release
--- DESCRIPTION:
--- Editors discard their Lua owners on user close. The
--- real factory must opt those windows into native reference retirement, while
--- explicit deferred deletion cannot consume a newly opened window.
--- ==============================================================================

local helpers = require("tests.helpers")
require("logger")

--- Runs one real controller and factory over isolated native reference ownership.
--- @param module_name string Window controller to load.
--- @param scenario function Receives controller and native observations.
local function with_window(module_name, scenario)
	local prior_lfs = rawget(_G, "lfs")
	rawset(_G, "lfs", nil)
	local outcome = table.pack(xpcall(function()
		return helpers.with_stub_scope({
			"ui.layer_editor", "ui.action_picker", "ui.layout_manager", "ui.menu.menu_paths",
			"infra.config_paths", "adapters.program_providers", "program_provider_picker", "modules.keymap.layout_registry",
			"keymap.layer_editor", "keymap.layers", "platform.remap.nav_layer", "infra.keycodes", "adapters.file_system",
			"infra.text_utils", "text_utils", "compat.utf8", "layouts.manager_bridge",

			"adapters.apple_shortcuts", "adapters.apple_shortcuts_native", "adapters.shell_runner", "adapters.task_environment",
			"diagnostics.runtime_log", "platform.remap.lease_helper", "program_parameter",
			"brightness_actions", "brightness_actions_data", "config_migrate", "diagnostics.operation_reporter",
			"infra.fs_dir", "keycodes", "lfs", "module_source_directory", "module_source_identity", "modules.keymap.layout",
			"toml_codec.basic_string", "toml_codec.bom", "toml_codec.key_path", "toml_codec.leaf_rows",
			"toml_codec.record_scanner", "toml_codec.writer",
			"adapters.webview_result", "ui.ui_builder", "adapters.timer_scheduler", "infra.deferred_work", "infra.paced_job", "infra.paced_json",
			"infra.log_folders", "locale.core", "json", "adapters.json_codec", "diagnostics.redact",
			"window_titles", "webview.presentation", "infra.launcher_environment", "adapters.log_transport",
			"app_dirs", "infra.logger", "infra.locale", "_generated.logger_sub_files", "webview.i18n_seed",
			"tests.support.native_webview_close_fixture",
		}, function()
			local h = { windows = {}, retained = {}, deferred = {}, script_refs = {}, timers = {}, bridges = {}, errors = {} }
			local logger = helpers.make_logger_stub()
			logger.error = function(_, message, ...) h.errors[#h.errors + 1] = string.format(message, ...) end
			package.loaded["infra.logger"] = logger
			local construct = require("tests.support.native_webview_close_fixture")(h)
			local function new_window()
				local view = construct()
				function view:allowNewWindows() assert(not self.disposed); return self end
				function view:frame() assert(not self.disposed); return { x = 0, y = 0, w = 460, h = 380 } end
				function view:evaluateJavaScript()
					assert(not self.disposed, "retired windows cannot receive JavaScript")
					return self
				end
				return view
			end
			package.loaded["adapters.program_providers"] = {}
			package.loaded["modules.keymap.layout_registry"] = { snapshot = function() return { platform = "macos", installed = {} } end }
			package.loaded["infra.config_paths"] = {
				is_initialized = function() return true end,
				get_config_dir = function() return "/virtual/config/" end,
				get_logs_dir = function() return "/virtual/logs/" end,
			}
			local window = helpers.load_with_stubs(module_name, {
				webview = { new = new_window, windowMasks = { titled = 1, closable = 2, resizable = 8 },
					usercontent = { new = function()
						local controller = {}
						function controller:setCallback(callback) self.callback = callback; h.script_refs[self] = callback; return self end
						h.bridges[#h.bridges + 1] = controller
						return controller
					end } },
				timer = { absoluteTime = function() return 1000000000 end, secondsSinceEpoch = function() return 1 end,
					new = function(_, receive)
						local timer = { active = false, receive = receive }
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
			local translations = package.loaded["infra.i18n"]
			local translated = translations.get
			translations.get = function(key, ...)
				if key == "menu.paths.window_title" then return "Folders" end
				return translated(key, ...)
			end
			if module_name == "ui.menu.menu_paths" then assert(window.init("/virtual/app/", function() end)) end
			function h.show()
				if module_name == "ui.layer_editor" then
					return window.open({ karabiner = { regenerate = function() return true end } })
				elseif module_name == "ui.action_picker" then
					return window.open({ title = "Native close fixture", items = {} }, function() return true end)
				elseif module_name == "ui.menu.menu_paths" then return window.open_editor()
				else return window.open() end
			end
			function h.close()
				if module_name == "ui.layer_editor" or module_name == "ui.action_picker" then return window.close() end
				h.bridges[#h.bridges].callback({ body = { action = module_name == "ui.layout_manager" and "close" or "cancel" } })
				return true
			end
			function h.drain()
				while #h.deferred > 0 do table.remove(h.deferred, 1)() end
			end
			scenario(window, h)
		end)
	end, debug.traceback))
	rawset(_G, "lfs", prior_lfs)
	if not outcome[1] then error(outcome[2], 0) end
end

helpers.describe("editor close retires native references", function()
	for _, module_name in ipairs({ "ui.layer_editor", "ui.action_picker", "ui.layout_manager", "ui.menu.menu_paths" }) do
		helpers.it("retires native user close and reopens " .. module_name, function()
			with_window(module_name, function(_, h)
				helpers.assert_true(h.show(), table.concat(h.errors, "\n"))
				local first = h.windows[1]
				first:user_close()
				helpers.assert_nil(h.retained[first], "dropping an editor's Lua owner cannot release native udRef")
				helpers.assert_eq(first.deletes, 0, "user close must own automatic native destruction")
				helpers.assert_true(h.show(), table.concat(h.errors, "\n"))
				local successor = h.windows[2]
				helpers.assert_true(h.retained[successor])
				helpers.assert_eq(successor.disposed, false)
				helpers.assert_true(h.close())
				h.drain()
				helpers.assert_nil(next(h.retained))
			end)
		end)
		helpers.it("keeps deferred explicit deletion exact for " .. module_name, function()
			with_window(module_name, function(_, h)
				helpers.assert_true(h.show(), table.concat(h.errors, "\n"))
				local first = h.windows[1]
				helpers.assert_true(h.close())
				helpers.assert_true(h.retained[first], "visible native delete must await its fade completion")
				helpers.assert_eq(first.deletes, 1)
				helpers.assert_true(h.show(), table.concat(h.errors, "\n"))
				local successor = h.windows[2]
				h.drain()
				helpers.assert_nil(h.retained[first])
				helpers.assert_true(h.retained[successor], "old deletion must preserve the reopened editor")
				helpers.assert_eq(successor.disposed, false)
				helpers.assert_true(h.close())
				h.drain()
				helpers.assert_nil(next(h.retained))
			end)
		end)
	end
end)
