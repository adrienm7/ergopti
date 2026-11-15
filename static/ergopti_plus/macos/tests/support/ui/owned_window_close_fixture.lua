--- tests/support/ui/owned_window_close_fixture.lua

--- ==============================================================================
--- MODULE: Owned Native Window Controller Fixture
--- DESCRIPTION:
--- Composes real window controllers, the WebView factory and scheduler over
--- the shared native reference model. Only native ports, read-only shipped
--- data and external check/ingest owners are controlled by each scenario.
--- ==============================================================================

local helpers = require("tests.helpers")
require("core.logger.engine")

--- Runs one real controller and factory over isolated native reference ownership.
--- @param module_name string Window controller to load.
--- @param scenario function Receives controller and native observations.
local function run_window(module_name, scenario)
	helpers.with_stub_scope({
		"settings.ui.cleanup", "settings.engine.migration.cleanup_session", "config_cleanup", "ui.onboarding", "onboarding.engine.answers",
		"ui.update_check", "updater.engine.check_session", "modules.updater", "adapters.update_launcher",
		"ui.metrics_apps", "core.ui.engine.dialog_util", "core.text.engine.toml.writer", "core.text.engine.toml.codec", "menu.engine.manifest_reader",
		"tests.support.onboarding_shared_data", "core.fs.adapters.file_system", "hs.spaces",
		"core.text.engine.toml_codec.writer", "settings.engine.migration.unused_keys", "diagnostics.engine.operation_reporter", "core.text.engine.toml_codec.record_list",
		"settings.engine.migration.outdated", "core.fs.engine.module_source_identity", "core.text.engine.toml_codec.leaf_rows", "lfs", "core.fs.engine.module_source_directory",
		"settings.engine.migration.migrate", "core.text.engine.toml_codec.record_scanner", "core.text.engine.toml_codec.key_path", "core.text.engine.toml_codec.basic_string",
		"core.text.engine.toml_codec.bom", "core.text.engine.toml_codec.cleanup_roots", "settings.engine.publication.user_models",
		"core.ui.engine.notifications", "settings.engine.publication.defaults", "core.text.engine.utils_core", "hotstrings.engine.catalogue.personal_files", "core.lifecycle.engine.compat.utf8",
		"core.fs.engine.dir", "core.ui.adapters.webview_result", "settings.engine.migration.file_inverse", "onboarding.engine.publication", "settings.engine.paths",
		"ai.engine.local_servers.model_catalogue", "core.process.adapters.shell_runner", "core.ui.engine.webview.document_csp", "diagnostics.engine.runtime_log",
		"core.process.adapters.task_environment", "modules.updater.config_backup", "updater.engine.release_sources", "updater.engine.channels",
		"updater.engine.version_core", "updater.engine.release_install", "updater.engine.release_assets", "core.network.engine.failure", "updater.engine.config_backup_core",
		"ui.model_browser", "ui.changelog",
		"core.ui.ui.builder", "core.ui.ui.webview_close_owner", "core.events.timer_scheduler", "core.timing.engine.deferred_work", "core.timing.engine.paced_job", "core.timing.engine.paced_json",
		"core.logger.engine.log_folders", "core.i18n.engine.core", "core.text.engine.json", "core.fs.adapters.json_codec", "diagnostics.engine.reports.redact",
		"core.ui.engine.window_titles", "core.ui.engine.webview.presentation", "core.lifecycle.engine.launcher_environment", "core.logger.adapters.log_transport",
		"core.fs.engine.app_dirs", "core.logger.engine.logger", "core.i18n.engine.i18n", "core.i18n.engine.locale", "_generated.logger_sub_files", "core.ui.engine.webview.i18n_seed",
		"modules.keystats.log_manager", "tests.support.native_webview_close_fixture",
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
		package.loaded["core.ui.engine.dialog_util"] = { block_alert = function() return true end }
		package.loaded["modules.keystats.log_manager"] = { on_ingest_done = function() return true end }
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
		-- The cleanup window is named by the shared manifest through the real
		-- translator; the loader's passthrough would leave it a bare key, refused.
		if module_name == "settings.ui.cleanup" then package.loaded["core.i18n.engine.i18n"] = nil end
		if module_name == "ui.onboarding" then require("tests.support.onboarding_shared_data").install() end
		if module_name == "ui.changelog" then
			local files = require("core.fs.adapters.file_system")
			local original = files.read
			files.read = function(path, ...)
				for _, name in ipairs({ "channels", "defaults" }) do
					-- The read is recognized by the file's path under the shared root.
					local real = helpers.shared("updater/data/" .. name .. ".json")
					local relative = real:sub(#helpers.shared() + 1)
					if path:sub(-#relative) == relative then
						local file = assert(io.open(real, "r"))
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
			if module_name == "settings.ui.cleanup" then return window.open({ path = "/virtual/config.toml" }) end
			if module_name == "ui.onboarding" then return window.run("/virtual/config.toml") end
			if module_name == "ui.update_check" then return window.open({
				channel_owner = { get = function() return "dev" end, set = function() return true end },
				checks = { check_now = function() return true end },
			}) end
			return window.show()
		end
		function h.close()
			if module_name == "settings.ui.cleanup" then
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
