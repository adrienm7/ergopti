--- tests/support/ui/owned_window_close_fixture.lua

--- ==============================================================================
--- MODULE: Owned Native Window Controller Fixture
--- DESCRIPTION:
--- Composes real window controllers, the WebView factory and scheduler over
--- the shared native reference model. Only native ports, read-only shipped
--- data and external check/ingest owners are controlled by each scenario.
--- ==============================================================================

local helpers = require("tests.helpers")
require("logger")

--- Runs one real controller and factory over isolated native reference ownership.
--- @param module_name string Window controller to load.
--- @param scenario function Receives controller and native observations.
local function run_window(module_name, scenario)
	helpers.with_stub_scope({
		"ui.config_cleanup", "config_cleanup_session", "config_cleanup", "ui.onboarding", "onboarding_answers",
		"ui.update_check", "updater.check_session", "modules.updater", "adapters.update_launcher",
		"ui.metrics_apps", "infra.dialog_util", "infra.toml.writer", "infra.toml.codec", "infra.manifest_reader",
		"tests.support.onboarding_shared_data", "adapters.file_system", "hs.spaces",
		"toml_codec.writer", "config_unused_keys", "diagnostics.operation_reporter", "toml_codec.record_list",
		"config_outdated", "module_source_identity", "toml_codec.leaf_rows", "lfs", "module_source_directory",
		"config_migrate", "toml_codec.record_scanner", "toml_codec.key_path", "toml_codec.basic_string",
		"toml_codec.bom", "toml_codec.cleanup_roots", "config_user_models",
		"infra.notifications", "config_defaults", "text_utils", "hotstrings.personal_files", "compat.utf8",
		"infra.fs_dir", "adapters.webview_result", "config_file_inverse", "onboarding_publication", "infra.config_paths",
		"llm.model_catalogue", "adapters.shell_runner", "webview.document_csp", "diagnostics.runtime_log",
		"adapters.task_environment", "modules.updater.config_backup", "updater.release_sources", "updater.channels",
		"updater.version", "updater.release_install", "updater.release_assets", "network.failure", "updater.config_backup",
		"ui.model_browser", "ui.changelog",
		"ui.ui_builder", "ui.webview_close_owner", "adapters.timer_scheduler", "infra.deferred_work", "infra.paced_job", "infra.paced_json",
		"infra.log_folders", "locale.core", "json", "adapters.json_codec", "diagnostics.redact",
		"window_titles", "webview.presentation", "infra.launcher_environment", "adapters.log_transport",
		"app_dirs", "infra.logger", "infra.locale", "_generated.logger_sub_files", "webview.i18n_seed",
		"modules.keylogger.log_manager", "tests.support.native_webview_close_fixture",
	}, function()
		local h = { windows = {}, retained = {}, deferred = {}, script_refs = {}, controllers = {}, timers = {} }
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
		package.loaded["modules.updater"] = { current_version = function() return "v1.0.0" end }
		package.loaded["adapters.update_launcher"] = {}
		package.loaded["infra.dialog_util"] = { block_alert = function() return true end }
		package.loaded["modules.keylogger.log_manager"] = { on_ingest_done = function() return true end }
		local window = helpers.load_with_stubs(module_name, {
			spaces = { activeSpaceOnScreen = function() return 1 end, moveWindowToSpace = function() return true end },
			webview = { new = new_window, windowMasks = { titled = 1, closable = 2, resizable = 8 },
				usercontent = { new = function()
					local controller = {}
					h.controllers[#h.controllers + 1] = controller
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
		if module_name == "ui.onboarding" then require("tests.support.onboarding_shared_data").install() end
		if module_name == "ui.changelog" then
			local files = require("adapters.file_system")
			local original = files.read
			files.read = function(path, ...)
				for _, name in ipairs({ "channels", "defaults" }) do
					if path:match("/modules/updater/" .. name .. "%.json$") then
						local file = assert(io.open(helpers.shared("modules/updater/" .. name .. ".json"), "r"))
						local data = file:read("*a")
						file:close()
						return data
					end
				end
				return original(path, ...)
			end
		end
		function h.show()
			if module_name == "ui.model_browser" then return window.open({ presets = {}, active_backend = "mlx" }) end
			if module_name == "ui.changelog" then return window.open() end
			if module_name == "ui.config_cleanup" then return window.open({ path = "/virtual/config.toml" }) end
			if module_name == "ui.onboarding" then return window.run("/virtual/config.toml") end
			if module_name == "ui.update_check" then return window.open({
				channel_owner = { get = function() return "dev" end, set = function() return true end },
				checks = { check_now = function() return true end },
			}) end
			return window.show()
		end
		function h.close()
			if module_name == "ui.config_cleanup" then
				h.script_refs[h.controllers[#h.controllers]]({ body = { action = "close", session = "" } })
			elseif module_name == "ui.update_check" then
				h.script_refs[h.controllers[#h.controllers]]({ body = { action = "close" } })
			elseif module_name == "ui.onboarding" then
				-- Invalid answers exercise the real fail_commit close without authorizing a write.
				h.script_refs[h.controllers[#h.controllers]]({ body = { action = "finish", answers = {} } })
			else return window.close() end
			return true
		end
		function h.drain()
			h.drain_native_close()
		end
		scenario(window, h)
	end)
end

return function(module_name, scenario)
	-- The C filesystem binding publishes a legacy global as well as its module.
	-- Restore both identities, including a cold process, even if a case raises.
	local previous_lfs = rawget(_G, "lfs")
	rawset(_G, "lfs", nil)
	local result = table.pack(xpcall(function()
		return run_window(module_name, scenario)
	end, debug.traceback))
	rawset(_G, "lfs", previous_lfs)
	if not result[1] then error(result[2], 0) end
	return table.unpack(result, 2, result.n)
end
