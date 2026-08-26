--- tests/unit/ui/menu/test_startup_layout_pause_generation.lua

--- ==============================================================================
--- MODULE: Startup Layout Pause-Generation Regression
--- DESCRIPTION:
--- Runs ui.menu.start with in-memory boundaries, commits a pause through the real
--- registered listener, then fires the real four-second startup callback. A boot
--- snapshot of false must not overwrite the more recent paused layout state.
--- ==============================================================================

local helpers = require("tests.helpers")

local scheduled_timers = setmetatable({}, {__mode = "v"})
local timer_sequence = 0
local layout_states = {}
local prime_counts = {apps = 0, keyboard_layout = 0, karabiner = 0}
local pause_listener
local paused = false

local hs_stub = helpers.load_with_stubs("infra.logger") and _G.hs
hs_stub.timer = {
	new = function(delay, callback)
		local timer = {
			delay = delay,
			callback = callback,
			running_state = false,
		}
		function timer:start()
			self.running_state = true
			timer_sequence = timer_sequence + 1
			self.id = timer_sequence
			scheduled_timers[self.id] = self
			return self
		end
		function timer:stop()
			self.running_state = false
			if self.id ~= nil then scheduled_timers[self.id] = nil end
			return self
		end
		function timer:running() return self.running_state end
		function timer:fire()
			if self.running_state ~= true then return false end
			self.running_state = false
			if self.id ~= nil then scheduled_timers[self.id] = nil end
			self.callback()
			return true
		end
		return setmetatable(timer, {
			__gc = function(value) value.running_state = false end,
		})
	end,
	secondsSinceEpoch = function() return 100 end,
}
hs_stub.timer.doAfter = function(delay, callback)
	local timer = hs_stub.timer.new(delay, callback)
	timer:start()
	return timer
end

local shortcuts = {
	is_paused = function() return paused end,
	set_on_pause_change = function(callback) pause_listener = callback end,
	set_shortcut_action = function() end,
	set_extras = function() end,
}

local state = {
	trigger_char = "★",
	layout_pause_switch_enabled = true,
	layout_on_pause = "French",
	layout_on_resume = "Ergopti_v2_2_2_plus",
	script_control_enabled = true,
	script_control_shortcuts = {
		return_key = "script_pause_toggle",
		backspace = "script_reload",
		escape = "script_quit",
	},
	update_channel = "dev",
	update_check_interval_seconds = 3600,
}

package.loaded["infra.logger"] = helpers.make_logger_stub()
package.loaded["infra.notifications"] = { notify = function() end }
package.loaded["ui.hotstring_editor"] = { set_update_menu = function() end }
package.loaded["infra.text_utils"] = {
	escape_gsub_replacement = function(value) return value end,
	shell_quote = function(value) return value end,
}
package.loaded["infra.i18n"] = { get = function(key) return key end }
package.loaded["infra.ui_restore"] = {}
package.loaded["infra.preferences"] = {
	build_initial_state = function() return state end,
	load = function() return {}, "present" end,
	merge_saved_data = function() end,
	save = function() end,
	get_group_name = function() return "test" end,
}
package.loaded["ui.menu.builder"] = {
	generate = function() return {} end,
	invalidate_cache = function() end,
}
package.loaded["ui.menu.hotstring_counter"] = { invalidate_cache = function() end }
package.loaded["ui.menu.menu_paths"] = {
	is_initialized = function() return true end,
	get = function() return "/tmp/ergopti-test" end,
	get_config_dir = function() return "/tmp/ergopti-test" end,
	open_editor = function() end,
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
	start_config_watcher = function()
		return { stop = function() end }
	end,
	start_theme_watcher = function()
		return { stop = function() end }
	end,
}
package.loaded["modules.updater"] = {
	get_check_interval = function() return 3600 end,
	start_background_checks = function() end,
}
package.loaded["adapters.tray_menu"] = {
	adopt = function() end,
	setMenu = function() end,
}
package.loaded["infra.termination_coordinator"] = { request_exit = function() return true end }

for _, module_name in ipairs({
	"ui.menu.menu_gestures",
	"ui.menu.menu_shortcuts",
	"ui.menu.menu_hotstrings",
	"ui.menu.menu_metrics",
	"ui.menu.menu_remap",
	"ui.menu.menu_about",
}) do
	package.loaded[module_name] = {}
end
package.loaded["ui.menu.menu_keyboard_layout"] = {
	schedule_pause_layout_switch = function(is_paused)
		layout_states[#layout_states + 1] = is_paused
	end,
	prime = function() prime_counts.keyboard_layout = prime_counts.keyboard_layout + 1 end,
}
package.loaded["ui.menu.menu_llm"] = { create = function() return {} end }
package.loaded["ui.menu.menu_apps"] = {
	prime = function() prime_counts.apps = prime_counts.apps + 1 end,
}
package.loaded["ui.menu.menu_remap"] = {
	prime = function() prime_counts.karabiner = prime_counts.karabiner + 1 end,
}
package.loaded["modules.llm"] = { set_backend = function() end }
package.loaded["modules.keylogger"] = {}
package.loaded["modules.shortcuts"] = shortcuts
package.loaded["modules.dynamic_hotstrings"] = {}
package.loaded["modules.gestures"] = {}
package.loaded["infra.personal_shortcuts"] = { load = function() end }

package.loaded["adapters.timer_scheduler"] = nil
package.loaded["ui.menu.init"] = nil
local Menu = require("ui.menu.init")

--- Finds one captured timer by its delay.
--- @param delay number Timer delay in seconds.
--- @return table|nil timer
local function find_timer(delay)
	for _, timer in pairs(scheduled_timers) do
		if timer.delay == delay and timer.running_state == true then return timer end
	end
	return nil
end

helpers.describe("audit pause fence: startup layout timer live state", function()
	helpers.it("audit startup layout: never dispatches a stale resume snapshot after a newer pause", function()
		Menu.start("/tmp/ergopti-test/", {}, {}, {}, {}, {}, nil, {})
		collectgarbage("collect")
		collectgarbage("collect")
		local startup_timer = find_timer(4)
		local cache_prime_timer = find_timer(2)
		helpers.assert_true(type(pause_listener) == "function",
			"ui.menu.start must register the real pause-change listener")
		helpers.assert_true(startup_timer and type(startup_timer.callback) == "function",
			"GC must not erase the four-second startup layout callback")
		helpers.assert_true(cache_prime_timer and type(cache_prime_timer.callback) == "function",
			"GC must not erase the two-second menu cache-prime callback")

		startup_timer:fire()
		helpers.assert_eq(#layout_states, 1,
			"the unpaused startup callback must make one observable layout request")
		helpers.assert_eq(layout_states[1], false,
			"an unchanged startup state must still request the configured resume layout")

		paused = true
		pause_listener(true)
		local calls_after_pause = #layout_states
		Menu.start("/tmp/ergopti-test/", {}, {}, {}, {}, {}, nil, {})
		collectgarbage("collect")
		collectgarbage("collect")
		local paused_startup_timer = find_timer(4)
		helpers.assert_true(paused_startup_timer ~= nil,
			"a second startup transaction must retain its own one-shot callback")
		paused_startup_timer:fire()

		helpers.assert_true(calls_after_pause > 0 and layout_states[calls_after_pause] == true,
			"the pause listener must first request the paused layout")
		helpers.assert_eq(#layout_states, calls_after_pause + 1,
			"the startup callback must make one observable layout request")
		helpers.assert_eq(layout_states[#layout_states], true,
			"a stale startup callback must observe the live pause state, never its boot-time false snapshot")

		cache_prime_timer:fire()
		helpers.assert_eq(prime_counts.keyboard_layout, 1)
		helpers.assert_eq(prime_counts.apps, 1)
		helpers.assert_eq(prime_counts.karabiner, 1)
	end)
end)
