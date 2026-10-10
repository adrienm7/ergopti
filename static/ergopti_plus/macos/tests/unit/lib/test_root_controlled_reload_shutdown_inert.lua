--- tests/unit/lib/test_root_controlled_reload_shutdown_inert.lua

--- ==============================================================================
--- MODULE: Root controlled-reload shutdown handoff
--- DESCRIPTION:
--- Loads the real root init chunk through its first-run early return, then drives
--- the real TerminationCoordinator and the actual hs.shutdownCallback installed
--- by init.lua. A controlled finalizer has already closed the asynchronous logger
--- and fenced the exact Karabiner lease when native hs.reload triggers that
--- callback; a second teardown would reopen the synchronous logger and request
--- the same lease again. Uncontrolled shutdown must remain active.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULE_NAMES = {
	"hs",
	"tests.stubs.hs",
	"infra.logger",
	"adapters.timer_scheduler",
	"adapters.keyboard_geometry",
	"adapters.synthetic_input",
	"platform.remap.ke_lifecycle",
	"platform.remap.lease_controller",
	"infra.boot_profiler",
	"adapters.boot_journal",
	"infra.i18n",
	"infra.locale",
	"modules.diagnostics.crash_reporter",
	"infra.reload_guard",
	"infra.emergency_exit",
	"infra.termination_coordinator",
	"infra.teardown_transaction",
	"infra.startup_transaction",
	"infra.config_paths",
	"infra.paths",
	"modules.hotstrings.hotstrings_config",
	"infra.factory_reset_journal",
	"modules.gestures",
	"modules.keymap",
	"infra.manifest_reader",
	"toml_codec.writer",
	"modules.shortcuts",
	"modules.dynamic_hotstrings",
	"adapters.toml_cache",
	"infra.toml.reader",
	"infra.timings",
	"infra.launcher_guard",
	"adapters.file_system",
	"platform.remap",
	"ui.menu",
	"ui.menu.menu_llm",
	"modules.llm.mlx_deps_checker",
	"modules.llm.ollama_deps_checker",
	"modules.llm.backend_detector",
	"infra.notifications",
	"ui.error_dialog",
	"infra.ui_restore",
	"ui.onboarding",
}

local function run_isolated(options, assertions)
	if type(options) == "function" then
		assertions = options
		options = {}
	end
	options = options or {}
	local saved_modules = {}
	for _, name in ipairs(MODULE_NAMES) do saved_modules[name] = package.loaded[name] end
	local saved_globals = {
		hs = rawget(_G, "hs"),
		keymap = rawget(_G, "keymap"),
		report_crash = rawget(_G, "ergopti_report_crash"),
		script_watchers = rawget(_G, "script_watchers"),
	}
	local saved_path = package.path
	local saved_os_exit = os.exit
	local searchers = package.searchers or package.loaders
	local saved_searchers = {}
	for index, searcher in ipairs(searchers or {}) do saved_searchers[index] = searcher end

	local ok, err = xpcall(function()
		package.loaded["tests.stubs.hs"] = nil
		local hs_stub = require("tests.stubs.hs")
		hs_stub.__reset()
		local state = {
			logs = {},
			post_stop_logs = 0,
			logger_stopped = false,
			logger_stop_calls = 0,
			fatal_exit_calls = 0,
			drain_calls = 0,
			cancel_all_calls = 0,
			native_reload_calls = 0,
			lease_init_queries = 0,
			lease_status_queries = 0,
			revoke_calls = 0,
			revoke_reasons = {},
			teardown_local_calls = 0,
			mlx_stop_calls = 0,
			reload_marks = 0,
			reload_clears = 0,
			onboarding_runs = 0,
			error_dialog_inits = 0,
			error_dialog_calls = {},
		}

		local Logger = {}
		local function log(_module_name, message, ...)
			if state.logger_stopped then state.post_stop_logs = state.post_stop_logs + 1 end
			local rendered = tostring(message)
			if select("#", ...) > 0 then
				local formatted, value = pcall(string.format, rendered, ...)
				if formatted then rendered = value end
			end
			state.logs[#state.logs + 1] = rendered
		end
		for _, name in ipairs({ "debug", "trace", "done", "info", "start", "success", "warn", "error" }) do
			Logger[name] = log
		end
		function Logger.initialize_privacy(raw)
			helpers.assert_type(raw, "string", "The root owns a complete canonical policy read before logging")
		end
		function Logger.set_level() return true end
		function Logger.init_log_path() return true end
		function Logger.logs_dir() return "/virtual/logs/" end
		function Logger.classify_async_sink_boot_environment() return "managed" end
		function Logger.start_async_sink() return true end
		function Logger.enable_repeat_collapsing() return true end
		function Logger.install_runtime_error_capture() return true end
		function Logger.set_async_sink_failure_handler(handler)
			state.async_failure_handler = handler
			return true
		end
		function Logger.set_error_notification_handler(handler)
			state.notification_handler = handler
			return true
		end
		function Logger.begin_async_sink_shutdown(callback)
			state.drain_calls = state.drain_calls + 1
			callback(true)
			return true
		end
		function Logger.stop_async_sink()
			state.logger_stop_calls = state.logger_stop_calls + 1
			state.logger_stopped = true
			return true
		end

		local reload_marked = false
		local ReloadGuard = {
			clear = function()
				reload_marked = false
				state.reload_clears = state.reload_clears + 1
				return true
			end,
			mark_reload = function()
				reload_marked = true
				state.reload_marks = state.reload_marks + 1
				return true
			end,
			is_reloading = function() return reload_marked end,
		}

		local LeaseController = {
			is_initialized = function()
				state.lease_init_queries = state.lease_init_queries + 1
				return true
			end,
			status = function()
				state.lease_status_queries = state.lease_status_queries + 1
				return "running"
			end,
			stop = function(reason, callback)
				state.revoke_calls = state.revoke_calls + 1
				state.revoke_reasons[#state.revoke_reasons + 1] = reason
				callback(true, "controller-fenced")
				return true
			end,
		}
		local Karabiner = {
			revoke = function(reason, callback)
				state.revoke_calls = state.revoke_calls + 1
				state.revoke_reasons[#state.revoke_reasons + 1] = reason
				callback(true, "module-fenced")
				return true
			end,
			teardown_local = function()
				state.teardown_local_calls = state.teardown_local_calls + 1
				return true
			end,
		}
		local MenuLLM = {
			stop_mlx_server = function(callback)
				state.mlx_stop_calls = state.mlx_stop_calls + 1
				if type(callback) ~= "function" then
					state.mlx_missing_callback = true
					return false
				end
				if options.mlx_stop_mode == "deferred" then
					state.mlx_stop_callback = callback
					return true
				end
				callback(true, "fixture MLX listener absent")
				return true
			end,
			terminate_helper_processes = function() return true end,
			terminate_orphan_mlx_server = function() return true end,
		}

		local fakes = {
			["infra.logger"] = Logger,
			["adapters.timer_scheduler"] = {
				cancelAll = function()
					state.cancel_all_calls = state.cancel_all_calls + 1
					return true
				end,
			},
			["adapters.synthetic_input"] = {
				when_idle = function(callback)
					callback()
					return true
				end,
			},
			["platform.remap.ke_lifecycle"] = { HS_BOOT_READY_SETTING_KEY = "test.boot.ready" },
			["platform.remap.lease_controller"] = LeaseController,
			["infra.boot_profiler"] = {
				begin = function() end,
				stage = function() end,
				mark = function() end,
				complete = function() end,
				current_stage = function() return "fixture stage" end,
				is_complete = function() return false end,
			},
			["adapters.boot_journal"] = {
				append = function(_, message)
					state.boot_journal_messages = state.boot_journal_messages or {}
					state.boot_journal_messages[#state.boot_journal_messages + 1] = message
					return true
				end,
				record_native_scripting_state = function(runtime)
					state.scripting_state_calls = (state.scripting_state_calls or 0) + 1
					state.scripting_state_runtime = runtime
					if options.scripting_state_mode == "throw" then error("controlled observer refusal") end
					if options.scripting_state_mode == "nil" then return nil end
					if options.scripting_state_mode == "truthy" then return 1 end
					return options.scripting_state_mode ~= "false"
				end,
				set_user_log_ready = function() end,
				describe_path = function() return "folder" end,
			},
			["infra.i18n"] = {
				set_locale_injector = function() end,
				init = function() return true end,
				get = function(key) return tostring(key) end,
			},
			["infra.locale"] = {
				set_locale = function() end,
				set_trigger_provider = function() end,
			},
			["modules.diagnostics.crash_reporter"] = {
				report = function() return {} end,
				prompt_user = function() end,
			},
			["infra.reload_guard"] = ReloadGuard,
			["infra.emergency_exit"] = { request = function() return true end },
			["infra.startup_transaction"] = {},
			["infra.config_paths"] = {
				init = function() return true end,
				get_config_dir = function() return "/virtual/config" end,
				get_logs_dir = function() return "/virtual/logs/" end,
				get = function(name) return "/virtual/" .. tostring(name) end,
			},
			["infra.factory_reset_journal"] = {
				path_for = function(config_path)
					if type(config_path) ~= "string" or config_path == "" then return nil end
					return config_path .. ".ergopti-reset-journal-v1.json"
				end,
				create = function(journal_path)
					if type(journal_path) ~= "string" or journal_path == "" then
						return nil, "journal path must be a non-empty string"
					end
					return {
						reconcile = function() return true end,
						prepare = function() return true end,
						mark_commit = function() return true end,
						mark_prepared = function() return true end,
						clear = function() return true end,
					}
				end,
			},
			["modules.gestures"] = {
				stop = function() return true end,
				restore_all_overrides = function() return true end,
			},
			["modules.keymap"] = {
				get_trigger_char = function() return "★" end,
				stop = function() return true end,
			},
			["infra.manifest_reader"] = {
				default_for = function() return "★" end,
				has_default = function() return false end,
				sparse_operation = function() error("no configuration write in shutdown fixture") end,
			},
			["modules.shortcuts"] = { stop = function() return true end },
			["modules.dynamic_hotstrings"] = {},
			["adapters.toml_cache"] = { init = function() return true end },
			["infra.toml.reader"] = {
				set_cache_provider = function() end,
				-- The real cold hotstring controller grants terminal admission before
				-- its init phase. Its mandatory shipped defaults still need a real,
				-- acknowledged parser; this fixture never opens a user override file.
				parse = function(path) return require("toml_codec.reader").parse(path) end,
			},
			-- Keep this deadline independent of the native timing loader; the root
			-- coordinator reads no other timing in this early-boot fixture.
			["infra.timings"] = {
				sec = function(section, key)
					helpers.assert_eq(section .. "." .. key, "ui.user_quit_deadline_ms")
					return 12
				end,
			},
			["infra.launcher_guard"] = {
				init = function() return true end,
				stop = function() return true end,
			},
			["adapters.file_system"] = {},
			["platform.remap"] = Karabiner,
			["ui.menu"] = { stop_watchers = function() return true end },
			["ui.menu.menu_llm"] = MenuLLM,
			["modules.llm.mlx_deps_checker"] = {},
			["modules.llm.ollama_deps_checker"] = {},
			["modules.llm.backend_detector"] = {},
			["infra.notifications"] = { notify = function() return true end },
			["ui.error_dialog"] = {
				init = function()
					state.error_dialog_inits = state.error_dialog_inits + 1
					return true
				end,
				on_error = function(module_name, template, message)
					state.error_dialog_calls[#state.error_dialog_calls + 1] = { module_name, template, message }
					return true
				end,
			},
			["infra.ui_restore"] = {},
			["ui.onboarding"] = {
				should_run = function() return true end,
				run = function()
					state.onboarding_runs = state.onboarding_runs + 1
					return true
				end,
			},
		}

		for _, name in ipairs(MODULE_NAMES) do package.loaded[name] = nil end
		package.loaded["tests.stubs.hs"] = hs_stub
		package.loaded["hs"] = hs_stub
		for name, module in pairs(fakes) do package.loaded[name] = module end
		-- Exercise the production coordinator and teardown transaction, with only
		-- their native boundaries replaced by the fakes above.
		package.loaded["infra.termination_coordinator"] = nil
		package.loaded["infra.teardown_transaction"] = nil

		_G.hs = hs_stub
		_G.script_watchers = {}
		os.exit = function(code)
			state.fatal_exit_calls = state.fatal_exit_calls + 1
			state.fatal_exit_code = code
			return true
		end
		hs_stub.reload = function(...)
			state.native_reload_calls = state.native_reload_calls + 1
			state.native_reload_args = table.pack(...)
			hs_stub.shutdownCallback()
			return true
		end

		local source, source_err = helpers.read_driver_unit(
			"hs.shutdownCallback = shutdown_all_resources"
		)
		helpers.assert_not_nil(source, tostring(source_err))
		source = source:gsub("^\239\187\191", "")
		local chunk, load_err = load(
			source,
			"@" .. helpers.driver_root() .. "root_boot_chunk",
			"t",
			_G
		)
		helpers.assert_not_nil(chunk, tostring(load_err))
		chunk()
		helpers.assert_eq(state.onboarding_runs, 1,
			"the fixture must stop root boot before any input subsystem starts")
		helpers.assert_type(hs_stub.shutdownCallback, "function")

		assertions(state, hs_stub)
	end, debug.traceback)

	package.path = saved_path
	os.exit = saved_os_exit
	if searchers then
		for index = #searchers, 1, -1 do searchers[index] = nil end
		for index, searcher in ipairs(saved_searchers) do searchers[index] = searcher end
	end
	for _, name in ipairs(MODULE_NAMES) do package.loaded[name] = saved_modules[name] end
	_G.hs = saved_globals.hs
	_G.keymap = saved_globals.keymap
	_G.ergopti_report_crash = saved_globals.report_crash
	_G.script_watchers = saved_globals.script_watchers
	if not ok then error(err, 0) end
end

helpers.describe("init: controlled reload owns the native shutdown handoff", function()
	helpers.it("hands every logged ERROR to the error window, template included (error-dialog-macos)", function()
		run_isolated(function(state)
			helpers.assert_eq(state.error_dialog_inits, 1, "init.lua must initialise the error window once")
			helpers.assert_eq(type(state.notification_handler), "function",
				"init.lua must register the logger's error handler")
			helpers.assert_eq(state.notification_handler("keylogger", "Flush failed: disk full", "Flush failed: %s"), true,
				"the handler reports the error as handled")
			helpers.assert_eq(state.error_dialog_calls, { { "keylogger", "Flush failed: %s", "Flush failed: disk full" } },
				"the error window receives the module, the template and the message")
		end)
	end)
	helpers.it("awaits the real root MLX callback before final teardown and reload (HS-008)", function()
		run_isolated({ mlx_stop_mode = "deferred" }, function(state, hs_stub)
			local accepted = hs_stub.reload("mlx-callback-pending")
			helpers.assert_eq(accepted, true)
			local Hotstrings = require("modules.hotstrings.hotstrings_config")
			helpers.assert_nil(Hotstrings.get_override_path(), "the real first-run controller is still uninitialized")
			helpers.assert_nil(Hotstrings.capture_terminal_admission(), "root holds the exact cold admission during MLX cleanup")
			helpers.assert_eq(Hotstrings.init({ override_path = "/virtual/hotstrings_config.toml",
				toml_resolver = function() return nil end }), false,
				"a delayed root terminal cannot admit a new override publisher")
			helpers.assert_nil(Hotstrings.get_override_path())
			helpers.assert_eq(state.mlx_stop_calls, 1)
			helpers.assert_eq(type(state.mlx_stop_callback), "function")
			helpers.assert_eq(state.drain_calls, 0,
				"the logger cannot drain before exact MLX listener settlement")
			helpers.assert_eq(state.cancel_all_calls, 0)
			helpers.assert_eq(state.logger_stop_calls, 0)
			helpers.assert_eq(state.native_reload_calls, 0,
				"the native reload cannot run while the MLX task callback is pending")
			helpers.assert_eq(state.fatal_exit_calls, 0,
				"pending MLX teardown cannot be misclassified as a fatal failure")

			local exact_callback = state.mlx_stop_callback
			helpers.assert_eq(exact_callback(true, "fixture MLX listener absent"), true)
			helpers.assert_eq(state.mlx_stop_calls, 1,
				"the callback-driven retry must consume the settled gate without re-signalling")
			helpers.assert_eq(state.drain_calls, 1)
			helpers.assert_eq(state.cancel_all_calls, 1)
			helpers.assert_eq(state.logger_stop_calls, 1)
			helpers.assert_eq(state.native_reload_calls, 1)
			helpers.assert_eq(state.fatal_exit_calls, 0)

			exact_callback(true, "duplicate")
			helpers.assert_eq(state.native_reload_calls, 1)
			helpers.assert_eq(state.post_stop_logs, 0,
				"a duplicate MLX callback cannot reopen the finalized logger")
		end)
	end)

	helpers.it("fails the exact controlled waiter when MLX cleanup is refused (HS-008)", function()
		run_isolated({ mlx_stop_mode = "deferred" }, function(state, hs_stub)
			helpers.assert_eq(hs_stub.reload("mlx-cleanup-refused"), true)
			helpers.assert_eq(type(state.mlx_stop_callback), "function")
			helpers.assert_eq(state.drain_calls, 0)

			local exact_callback = state.mlx_stop_callback
			helpers.assert_eq(exact_callback(false, "cleanup_refused"), false)
			helpers.assert_eq(state.fatal_exit_calls, 1,
				"a negative exact teardown terminal must leave pending state through fatal exit")
			helpers.assert_true(type(state.fatal_exit_code) == "number" and state.fatal_exit_code ~= 0)
			helpers.assert_eq(state.native_reload_calls, 0)
			helpers.assert_eq(state.drain_calls, 0,
				"logger drain cannot start after listener absence was refused")
			helpers.assert_eq(state.logger_stop_calls, 0)

			exact_callback(false, "duplicate")
			helpers.assert_eq(state.fatal_exit_calls, 1,
				"the same shutdown waiter cannot publish two negative terminals")
		end)
	end)

	helpers.it("keeps uncontrolled shutdown active but makes the post-finalizer callback inert", function()
		run_isolated(function(state, hs_stub)
			hs_stub.shutdownCallback()
			helpers.assert_eq(state.revoke_calls, 1,
				"an uncontrolled quit must still request the exact managed lease fence")
			helpers.assert_eq(state.revoke_reasons[1], "hammerspoon_quit")
			helpers.assert_true(#state.logs > 0,
				"the uncontrolled backstop must retain its shutdown diagnostics")

			local revokes_before_reload = state.revoke_calls
			local lease_queries_before_reload = state.lease_status_queries
			local accepted = hs_stub.reload("causal-reload")
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(state.reload_marks, 1)
			helpers.assert_eq(state.drain_calls, 1)
			helpers.assert_eq(state.cancel_all_calls, 1)
			helpers.assert_eq(state.logger_stop_calls, 1)
			helpers.assert_eq(state.native_reload_calls, 1)
			helpers.assert_eq(state.native_reload_args[1], "causal-reload")
			helpers.assert_eq(state.revoke_calls, revokes_before_reload + 1,
				"the controlled fence must run once, and native shutdown must not request it again")
			helpers.assert_eq(state.lease_status_queries, lease_queries_before_reload + 1,
				"the callback after finalization must not even query the released lease")
			helpers.assert_eq(state.post_stop_logs, 0,
				"the native callback must not reopen the synchronous logger after final ACK/stop")
		end)
	end)
end)


helpers.describe("init: supplemental scripting state has no boot authority", function()
	for _, mode in ipairs({ "true", "false", "nil", "truthy", "throw" }) do
		helpers.it("keeps the real onboarding and shutdown owner after " .. mode .. " observation", function()
			run_isolated({ scripting_state_mode = mode }, function(state, hs_stub)
				helpers.assert_eq(state.scripting_state_calls, 1, "The managed init calls the actual observer contract once")
				helpers.assert_eq(state.scripting_state_runtime, hs_stub, "The observation receives this exact live runtime")
				helpers.assert_eq(state.onboarding_runs, 1, "The existing first-run owner remains active")
				helpers.assert_eq(state.fatal_exit_calls, 0, "A supplemental observation never kills managed boot")
				local refused = 0
				for _, message in ipairs(state.boot_journal_messages or {}) do
					if message == "Native scripting server witness publication unacknowledged." then
						refused = refused + 1
					end
				end
				helpers.assert_eq(refused, mode == "true" and 0 or 1, "Only strict true acknowledges diagnostic publication")
				hs_stub.shutdownCallback()
				helpers.assert_eq(state.revoke_calls, 1, "The unchanged shutdown owner still fences its actual lease")
			end)
		end)
	end
end)
