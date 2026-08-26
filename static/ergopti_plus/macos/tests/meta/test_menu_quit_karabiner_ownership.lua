--- tests/meta/test_menu_quit_karabiner_ownership.lua

--- ==============================================================================
--- MODULE: Menubar Quit Uses the Exact-Fence Coordinator
--- DESCRIPTION:
--- Menubar Quit must delegate a stable reason to the root lifecycle transaction.
--- It may not call os.exit, tear down consumers, or acquire stock/personal
--- Karabiner process authority itself.
--- ==============================================================================

local helpers = require("tests.helpers")

local function quit_action_body()
	local source, err = helpers.read_driver_unit("local function safe_require")
	helpers.assert_true(source ~= nil, "ui.menu.init source must be unique: " .. tostring(err))
	local start_at = source:find("quit%s*=%s*function%(%)")
	local end_at = source:find("open_logs%s*=", start_at or 1)
	helpers.assert_true(start_at ~= nil and end_at ~= nil, "quit action must be locatable")
	return source:sub(start_at, end_at - 1)
end

--- Loads the real ui.menu.init action table over narrow pure doubles.
--- @return function quit_action
--- @return table exit_calls
--- @return table stock_calls
local function load_menu_quit_action()
	-- Reset the shared hs double before installing module doubles captured by
	-- ui.menu.init at require time.
	helpers.load_with_stubs("infra.logger")
	local exit_calls = {}
	local exit_mode = { value = "true" }
	local stock_calls = { execute = 0, launch = 0 }
	_G.hs.execute = function()
		stock_calls.execute = stock_calls.execute + 1
		return "", true
	end
	_G.hs.application.launchOrFocus = function()
		stock_calls.launch = stock_calls.launch + 1
		return true
	end

	package.loaded["infra.notifications"] = { notify = function() end }
	package.loaded["ui.menu.global_actions_transaction"] = {
		create = function(deps)
			return {
				run_exclusive = function(_, callback)
					if deps.terminal_pending() then return false end
					local ok, result = xpcall(callback, debug.traceback)
					return ok and result == true
				end,
			}
		end,
	}
	package.loaded["ui.hotstring_editor"] = {}
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.text_utils"] = {
		shell_quote = function(value) return tostring(value) end,
		escape_gsub_replacement = function(value) return tostring(value) end,
	}
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.ui_restore"] = {}
	package.loaded["infra.preferences"] = {
		build_initial_state = function()
			return {
				hotstrings = {},
				trigger_char = "★",
				script_control_enabled = false,
				script_control_shortcuts = {},
			}
		end,
		load = function() return {}, "present" end,
		merge_saved_data = function() end,
		get_group_name = function() return "group" end,
		save = function() return true end,
	}
	package.loaded["ui.menu.builder"] = { generate = function() return {} end }
	package.loaded["ui.menu.hotstring_counter"] = { invalidate_cache = function() end }
	package.loaded["ui.menu.menu_paths"] = {
		is_initialized = function() return true end,
		get = function() return "/virtual/config.toml" end,
		get_config_dir = function() return "/virtual" end,
	}
	package.loaded["infra.factory_reset_journal"] = {
		path_for = function(config_path)
			if type(config_path) ~= "string" or config_path == "" then return nil end
			return config_path .. ".ergopti-reset-journal-v1.json"
		end,
		create = function(journal_path)
			if type(journal_path) ~= "string" or journal_path == "" then
				return nil, "journal path must be a non-empty string"
			end
			return {
				prepare = function() return true end,
				mark_commit = function() return true end,
				mark_prepared = function() return true end,
				clear = function() return true end,
			}
		end,
	}
	package.loaded["ui.menu.menu_state"] = {
		sync_state_to_modules = function() return true end,
	}
	package.loaded["ui.menu.menu_watchers"] = {
		start_config_watcher = function() return {} end,
		start_theme_watcher = function() return {} end,
	}
	package.loaded["modules.updater"] = {
		get_check_interval = function() return 3600 end,
		start_background_checks = function() end,
	}
	package.loaded["adapters.tray_menu"] = {
		adopt = function() end,
		setMenu = function() end,
	}
	package.loaded["infra.termination_coordinator"] = {
		is_pending = function() return false end,
		request_exit = function(reason, code)
			exit_calls[#exit_calls + 1] = { reason = reason, code = code }
			if exit_mode.value == "throw" then error("coordinated exit fault") end
			if exit_mode.value == "nil" then return nil end
			if exit_mode.value == "false" then return false end
			return true
		end,
	}

	for _, module_name in ipairs({
		"ui.menu.menu_gestures", "ui.menu.menu_shortcuts", "ui.menu.menu_keyboard_layout",
		"ui.menu.menu_hotstrings", "ui.menu.menu_llm", "ui.menu.menu_metrics",
		"ui.menu.menu_remap", "ui.menu.menu_apps", "ui.menu.menu_about",
		"modules.llm", "modules.keylogger", "modules.dynamic_hotstrings", "modules.gestures",
	}) do
		package.loaded[module_name] = {}
	end
	local captured_actions = nil
	package.loaded["modules.shortcuts"] = {
		is_paused = function() return false end,
		set_extras = function(actions) captured_actions = actions end,
	}

	package.loaded["ui.menu.init"] = nil
	local menu = require("ui.menu.init")
	local started, start_err = pcall(menu.start, ".", {}, nil, nil, nil, {}, nil, {})
	helpers.assert_true(started, "ui.menu.init must start over the quit harness: " .. tostring(start_err))
	helpers.assert_true(type(captured_actions) == "table" and type(captured_actions.quit) == "function",
		"the real menu start must publish its quit action")
	return captured_actions.quit, exit_calls, stock_calls, exit_mode
end

helpers.describe("menu Quit uses exact lease revocation", function()
	helpers.it("requests one coordinated menu_quit exit", function()
		local body = quit_action_body()
		helpers.assert_true(body:find('TerminationCoordinator.request_exit("menu_quit", 0)', 1, true) ~= nil)
		helpers.assert_true(body:find("os.exit", 1, true) == nil,
			"only the root coordinator may exit after STOPPED")
		helpers.assert_true(body:find("karabiner.shutdown", 1, true) == nil,
			"the menu must not duplicate the lease transaction")
	end)

	helpers.it("contains no direct Karabiner reset or stock-process authority", function()
		local body = quit_action_body()
		for _, retired in ipairs({
			"run_total_reset", "is_hs_owned_bridge", "KILL_CMD",
			"karabiner.kill", "pgrep", "pkill", "launchctl",
		}) do
			helpers.assert_true(body:find(retired, 1, true) == nil,
				"menu Quit must not regain stock-process authority: " .. retired)
		end
	end)

	helpers.it("fails closed when coordinated exit throws, returns nil, or explicitly refuses", function()
		local quit_action, exit_calls, stock_calls, exit_mode = load_menu_quit_action()
		local saved_exit = os.exit
		local direct_exits = 0
		local results = {}
		local stock_execute_before = stock_calls.execute
		local stock_launch_before = stock_calls.launch
		os.exit = function() direct_exits = direct_exits + 1 end

		for _, case in ipairs({
			{ label = "throw" },
			{ label = "nil" },
			{ label = "false" },
		}) do
			exit_mode.value = case.label
			local before = #exit_calls
			local ok, accepted = pcall(quit_action)
			local call = exit_calls[#exit_calls]
			results[#results + 1] = {
				label = case.label,
				ok = ok,
				accepted = accepted,
				before = before,
				after = #exit_calls,
				reason = call and call.reason,
				code = call and call.code,
			}
		end

		os.exit = saved_exit
		for _, result in ipairs(results) do
			helpers.assert_true(result.ok,
				result.label .. " coordinator failure must not escape the menu callback")
			helpers.assert_eq(result.after, result.before + 1,
				result.label .. " must attempt the coordinated exit exactly once")
			helpers.assert_eq(result.reason, "menu_quit")
			helpers.assert_eq(result.code, 0)
			helpers.assert_eq(result.accepted, false,
				result.label .. " must not acknowledge an uncommitted exit")
		end
		helpers.assert_eq(direct_exits, 0)
		helpers.assert_eq(stock_calls.execute, stock_execute_before,
			"quit fallbacks must perform no shell/process operation")
		helpers.assert_eq(stock_calls.launch, stock_launch_before,
			"quit fallbacks must never launch the stock Karabiner GUI")
	end)
end)
