--- tests/support/ui/menu/shortcuts/tap_hold_menu_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_tap_hold_menu
--- DESCRIPTION:
--- Prelude shared by the test_tap_hold_menu_* test files: their modules, stubs and
--- helpers. Each part loads it fresh, so no state leaks from one file to the
--- next.
--- ==============================================================================

local helpers = require("tests.helpers")

local DEFAULTS = require("core.fs.engine.paths").shared("tap_hold/data/defaults.toml")

local WRITER = "tap_hold.engine.writer"

local PICKER = "shortcuts.ui.action_picker.bridge"

local SCOPE = "tap_hold.engine.scope"

--- A fake writer recording its calls.
local function fake_writer(calls)
	local writer = {}
	for _, name in ipairs({ "set_tap", "set_hold", "set_native", "set_threshold", "set_enabled" }) do
		writer[name] = function(first, second, third)
			if name == "set_tap" or name == "set_threshold" then
				if third ~= nil then
					assert(type(third) == "function", "deferred editor guard")
					if third() ~= true then return false end
				end
				calls[#calls + 1] = { name, first, second }
			else
				calls[#calls + 1] = { name, first, second, third }
			end
			return true
		end
	end
	return writer
end

--- Builds the menu with a real tap-hold manager on the shared defaults, a fake
--- writer and a fake picker, and returns the Tap-Holds section.
local function build(calls, picked, user_text)
	local Manager = helpers.load_module("tap_hold.engine.manager")
	local user_path = os.tmpname()
	os.remove(user_path)
	-- The keys in tap_hold.toml, the switch and the timings in the config.toml beside it.
	local config_path = require("tests.support.tap_hold_fixture").write(user_path, user_text)
	Manager.init({
		keyboard_hook = { set_remapper = function() end, key_text = function() return nil end,
			held_modifiers = function() return {} end,
			held_text_modifier_codes = function() return {} end,
			held_shortcut_modifier_codes = function() return {} end },
		execute_action = function() end,
		on_text_injected = function() end,
		action_names = function() return { "open_url" } end,
		defaults_path = DEFAULTS,
		user_path = user_path,
		config_path = config_path,
	})
	package.loaded[WRITER] = fake_writer(calls)
	package.loaded[SCOPE] = {
		apply = function(mode, ...)
			-- A pause no longer reaches the scope (EDD-1, edd1-paused-writes).
			calls[#calls + 1] = { "scope", mode, select("#", ...) }
			return true
		end,
	}
	package.loaded[PICKER] = {
		open = function(opts, on_confirm)
			picked.opts = opts
			picked.confirm = on_confirm
			return true
		end,
	}
	local mb = helpers.load_module("menu.ui.builder.builder")
	local changed = 0
	local items = mb.build({ _version = "test", on_quit = function() end, tap_holds = Manager, is_paused = function() return false end,
		on_menu_changed = function() changed = changed + 1 end })
	local title = require("core.i18n.engine.i18n").get("menu.tapholds.title")
	local section = nil
	for _, item in ipairs(items) do
		if item.title == title then section = item end
	end
	return section, Manager
end

local function restore(Manager)
	Manager._reset_for_test()
	package.loaded[WRITER] = nil
	package.loaded[SCOPE] = nil
	package.loaded[PICKER] = nil
end

--- The rows of a section that open a per-key submenu. The lone modifier tap
--- window (tap_holds.lone_modifier_tap_max_ms) is the one other submenu of the
--- section: its choices are no key.
local function key_rows(section)
	local lone_tap = string.format(require("core.i18n.engine.i18n").get("menu.tapholds.lone_tap_title"), "")
	local rows = {}
	for _, row in ipairs(section.menu or {}) do
		if type(row.menu) == "table" and row.title:sub(1, #lone_tap) ~= lone_tap then rows[#rows + 1] = row end
	end
	return rows
end

--- The first row of `rows` whose title starts with `prefix`.
local function find(rows, prefix)
	for _, row in ipairs(rows) do
		if type(row.title) == "string" and row.title:sub(1, #prefix) == prefix then return row end
	end
	return nil
end

return {
	helpers = helpers,
	DEFAULTS = DEFAULTS,
	WRITER = WRITER,
	PICKER = PICKER,
	SCOPE = SCOPE,
	fake_writer = fake_writer,
	build = build,
	restore = restore,
	key_rows = key_rows,
	find = find,
}
