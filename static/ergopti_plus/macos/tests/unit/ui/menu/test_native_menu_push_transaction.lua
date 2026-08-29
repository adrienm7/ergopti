--- tests/unit/ui/menu/test_native_menu_push_transaction.lua

--- ==============================================================================
--- MODULE: Native Menu Push Transaction Regression
--- DESCRIPTION:
--- Drives the real ui.menu cache controller through a refused static setMenu.
--- The candidate tree must remain dirty, no success may be logged, and the live
--- dynamic callback must retry until the native tray accepts the exact tree.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Builds an isolated ui.menu.start fixture with a controllable tray boundary.
--- @param opts table|nil Failure plan.
--- @return table fixture Captured timers, callback, counters, and logs.
local function load_fixture(opts)
	opts = opts or {}
	local scheduled_timers = {}
	local timer_sequence = 0
	local build_count = 0
	local static_push_count = 0
	local dynamic_callback = nil
	local static_results = { false, true }
	local destroyed = 0
	local logs = { info = {}, error = {} }
	local noop = function() end
	local hs_stub = helpers.load_with_stubs("infra.logger") and _G.hs

	hs_stub.timer = {
		new = function(delay, callback)
			local timer = { delay = delay, callback = callback, running_state = false }
			function timer:start()
				self.running_state = true
				timer_sequence = timer_sequence + 1
				self.id = timer_sequence
				scheduled_timers[self.id] = self
				return self
			end
			function timer:stop()
				self.running_state = false
				scheduled_timers[self.id] = nil
				return self
			end
			function timer:running() return self.running_state end
			function timer:fire()
				if self.running_state ~= true then return false end
				self.running_state = false
				scheduled_timers[self.id] = nil
				self.callback()
				return true
			end
			return timer
		end,
		secondsSinceEpoch = function() return 100 end,
	}
	hs_stub.timer.doAfter = function(delay, callback)
		local timer = hs_stub.timer.new(delay, callback)
		timer:start()
		return timer
	end

	local Logger = helpers.make_logger_stub()
	Logger.info = function(_, message, ...)
		logs.info[#logs.info + 1] = string.format(message, ...)
	end
	Logger.error = function(_, message, ...)
		logs.error[#logs.error + 1] = string.format(message, ...)
	end
	package.loaded["infra.logger"] = Logger
	package.loaded["infra.notifications"] = { notify = noop }
	package.loaded["ui.hotstring_editor"] = { set_update_menu = noop }
	package.loaded["infra.text_utils"] = {
		escape_gsub_replacement = function(value) return value end,
		shell_quote = function(value) return value end,
	}
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.ui_restore"] = {}

	local state = {
		trigger_char = "★",
		hotstrings = { common = true },
		terminator_states = {},
		script_control_shortcuts = {
			return_key = "script_pause_toggle",
			backspace = "script_reload",
			escape = "script_quit",
		},
		keymap = true,
		gestures = true,
		shortcuts = true,
		llm_enabled = true,
		keylogger_enabled = true,
		script_control_enabled = true,
		personal_info = true,
		update_channel = "dev",
		update_check_interval_seconds = 3600,
	}
	package.loaded["infra.preferences"] = {
		build_initial_state = function() return state end,
		load = function() return {}, "present" end,
		merge_saved_data = noop,
		snapshot = function() return {} end,
		save = function() return true end,
		get_group_name = function() return "common" end,
	}
	package.loaded["ui.menu.builder"] = {
		generate = function()
			build_count = build_count + 1
			return { { title = "generation-" .. build_count } }
		end,
		invalidate_cache = noop,
	}
	package.loaded["ui.menu.hotstring_counter"] = { invalidate_cache = noop }
	package.loaded["ui.menu.menu_paths"] = {
		is_initialized = function() return true end,
		get = function() return "/virtual/config.toml" end,
		get_config_dir = function() return "/virtual" end,
		open_editor = noop,
	}
	package.loaded["infra.factory_reset_journal"] = {
		path_for = function(path) return path .. ".journal" end,
		create = function()
			return {
				prepare = function() return true end,
				mark_commit = function() return true end,
				mark_prepared = function() return true end,
				clear = function() return true end,
			}
		end,
	}
	package.loaded["ui.menu.keymap_lifecycle"] = {
		ensure_started = function() return true end,
	}
	package.loaded["ui.menu.menu_state"] = {
		sync_state_to_modules = function() return true end,
	}
	package.loaded["ui.menu.menu_watchers"] = {
		start_config_watcher = function() return { stop = function() return true end } end,
		start_theme_watcher = function() return { stop = function() return true end } end,
	}
	package.loaded["modules.updater"] = {
		get_check_interval = function() return 3600 end,
		start_background_checks = noop,
	}
	package.loaded["adapters.tray_menu"] = {
		adopt = function() return true end,
		setMenu = function(items)
			if type(items) == "function" then
				dynamic_callback = items
				return opts.initial_result ~= false
			end
			static_push_count = static_push_count + 1
			return table.remove(static_results, 1)
		end,
		destroy = function() destroyed = destroyed + 1; return true end,
	}
	package.loaded["chord"] = { format = function() return "ctrl+x" end }
	package.loaded["adapters.hotkey_registrar"] = {
		bind = function() return {} end,
		setEnabled = function() return true end,
		unbind = function() return true end,
	}
	package.loaded["infra.termination_coordinator"] = {
		request_exit = function() return true end,
	}

	for _, module_name in ipairs({
		"ui.menu.menu_gestures", "ui.menu.menu_shortcuts", "ui.menu.menu_keyboard_layout",
		"ui.menu.menu_hotstrings", "ui.menu.menu_metrics", "ui.menu.menu_remap",
		"ui.menu.menu_apps", "ui.menu.menu_about",
	}) do
		package.loaded[module_name] = {}
	end
	package.loaded["ui.menu.menu_llm"] = { create = function() return {} end }
	package.loaded["modules.llm"] = { set_backend = noop }
	package.loaded["modules.keylogger"] = {}
	package.loaded["modules.shortcuts"] = {
		is_paused = function() return false end,
		set_on_pause_change = noop,
		set_shortcut_action = noop,
		set_extras = noop,
		list_shortcuts = function() return {} end,
	}
	package.loaded["modules.dynamic_hotstrings"] = {}
	package.loaded["modules.gestures"] = { SINGLE_SLOTS = { "swipe_left" } }
	package.loaded["infra.personal_shortcuts"] = { load = noop }

	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["ui.menu.init"] = nil
	local Menu = require("ui.menu.init")
	local menu = Menu.start("/virtual/", {}, {}, {}, {}, {}, nil, {})

	local function find_timer(delay)
		for _, timer in pairs(scheduled_timers) do
			if timer.delay == delay and timer.running_state == true then return timer end
		end
		return nil
	end

	return {
		menu = menu,
		find_timer = find_timer,
		dynamic_callback = function() return dynamic_callback end,
		build_count = function() return build_count end,
		static_push_count = function() return static_push_count end,
		destroyed = function() return destroyed end,
		logs = logs,
	}
end





-- ==========================================
-- ==========================================
-- ======= 1/ Native Push Transaction =======
-- ==========================================
-- ==========================================

helpers.describe("menu cache publication waits for native setMenu", function()
	helpers.it("keeps the candidate dirty and retries after a refused static push", function()
		local fixture = load_fixture()
		local function matching_count(lines, needle)
			local count = 0
			for _, line in ipairs(lines) do
				if line:find(needle, 1, true) then count = count + 1 end
			end
			return count
		end
		helpers.assert_not_nil(fixture.menu)
		local cache_prime = fixture.find_timer(2)
		helpers.assert_not_nil(cache_prime,
			"boot must retain the cache-prime owner that performs the first static push")
		helpers.assert_true(cache_prime:fire())
		helpers.assert_eq(fixture.build_count(), 1)
		helpers.assert_eq(fixture.static_push_count(), 1)
		helpers.assert_eq(matching_count(fixture.logs.error,
			"Menu tree native push failed"), 1,
			"the refused native push must be reported exactly once")
		helpers.assert_eq(matching_count(fixture.logs.info, "Menu tree rebuilt"), 0,
			"the rejected native menu must not receive a rebuild-success log")

		local dynamic_callback = fixture.dynamic_callback()
		helpers.assert_type(dynamic_callback, "function",
			"the old dynamic menu remains the recovery boundary after static refusal")
		dynamic_callback()
		helpers.assert_eq(fixture.build_count(), 2,
			"dirty state must force regeneration instead of serving the rejected cache")
		helpers.assert_eq(fixture.static_push_count(), 2,
			"the same live boundary must retry until the tray accepts publication")
		helpers.assert_eq(matching_count(fixture.logs.info, "Menu tree rebuilt"), 1,
			"success is logged only after the recovery push commits")
	end)

	helpers.it("aborts startup when the initial dynamic menu is refused", function()
		local fixture = load_fixture({ initial_result = false })
		helpers.assert_nil(fixture.menu,
			"a menubar with no installed menu callback must not be published as ready")
		helpers.assert_eq(fixture.destroyed(), 1,
			"startup refusal must release the adopted native menubar")
		helpers.assert_nil(fixture.find_timer(2),
			"cache-prime work must not be armed for an unusable tray")
	end)
end)

return true
