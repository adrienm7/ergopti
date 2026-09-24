--- tests/unit/meta/test_tap_hold_menu.lua

--- ==============================================================================
--- MODULE: The Linux Tap-Holds Tray Menu
--- DESCRIPTION:
--- The menu Windows has: the feature switch, reset and disable-all, and one row
--- per key with its tap picker, hold picker and delay. Before, this driver had
--- a « Kanata » submenu whose tap prompt took free text that broke kanata's
--- whole configuration, whose hold rows could not clear a default hold, and
--- which started a process the daemon never supervised.
--- ==============================================================================

local helpers = require("tests.helpers")

local DEFAULTS = require("infra.paths").shared("tap_hold/defaults.toml")
local WRITER = "platform.remap.tap_hold_writer"
local PICKER = "ui.action_picker.bridge"

--- A fake writer recording its calls.
local function fake_writer(calls)
	local writer = {}
	for _, name in ipairs({ "set_tap", "set_hold", "set_native", "set_threshold", "set_enabled",
		"disable_all", "reset_all" }) do
		writer[name] = function(...)
			calls[#calls + 1] = { name, ... }
			return true
		end
	end
	return writer
end

--- Builds the menu with a real tap-hold manager on the shared defaults, a fake
--- writer and a fake picker, and returns the Tap-Holds section.
local function build(calls, picked)
	local Manager = helpers.load_module("platform.remap.tap_hold_manager")
	local user_path = os.tmpname()
	os.remove(user_path)
	Manager.init({
		keyboard_hook = { set_remapper = function() end },
		execute_action = function() end,
		action_names = function() return { "open_url" } end,
		defaults_path = DEFAULTS,
		user_path = user_path,
	})
	package.loaded[WRITER] = fake_writer(calls)
	package.loaded[PICKER] = {
		open = function(opts, on_confirm)
			picked.opts = opts
			picked.confirm = on_confirm
			return true
		end,
	}
	local mb = helpers.load_module("ui.menu.menu_builder")
	local changed = 0
	local items = mb.build({ _version = "test", on_quit = function() end, tap_holds = Manager,
		on_menu_changed = function() changed = changed + 1 end })
	local title = require("infra.i18n").get("menu.tapholds.title")
	local section = nil
	for _, item in ipairs(items) do
		if item.title == title then section = item end
	end
	return section, Manager
end

local function restore(Manager)
	Manager._reset_for_test()
	package.loaded[WRITER] = nil
	package.loaded[PICKER] = nil
end

--- The rows of a section that open a per-key submenu.
local function key_rows(section)
	local rows = {}
	for _, row in ipairs(section.menu or {}) do
		if type(row.menu) == "table" then rows[#rows + 1] = row end
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

helpers.describe("Linux Tap-Holds menu", function()

	helpers.it("has the Windows rows: switch, reset, disable all, and one row per key", function()
		local calls, picked = {}, {}
		local section, Manager = build(calls, picked)
		local ok, err = pcall(function()
			helpers.assert_true(section ~= nil, "a Tap-Holds section in the tray")
			helpers.assert_eq(#key_rows(section), #require("platform.remap.tap_hold_engine").KEY_ORDER,
				"every key the engine can remap has its row")
			local i18n = require("infra.i18n")
			local reset = find(section.menu, i18n.get("tap_hold.reset_defaults"))
			local disable = find(section.menu, i18n.get("tap_hold.disable_all"))
			local toggle = find(section.menu, i18n.get("menu.tapholds.on"))
			helpers.assert_true(reset and disable and toggle, "the three top rows")
			reset.fn()
			disable.fn()
			toggle.fn()
			helpers.assert_eq(calls[1][1], "reset_all")
			helpers.assert_eq(calls[2][1], "disable_all")
			helpers.assert_eq(calls[3][1], "set_enabled")
			helpers.assert_eq(calls[3][2], false, "the switch was on, a click turns it off")
		end)
		restore(Manager)
		if not ok then error(err, 0) end
	end)

	helpers.it("sets a hold from the picker, the navigation layer included", function()
		local calls, picked = {}, {}
		local section, Manager = build(calls, picked)
		local ok, err = pcall(function()
			local i18n = require("infra.i18n")
			local caps = find(key_rows(section), i18n.get("tap_hold.group.caps_lock"))
			helpers.assert_true(caps ~= nil, "a CapsLock row")
			local hold = find(caps.menu, string.format(i18n.get("tap_hold.picker.hold"), ""):sub(1, 4))
			helpers.assert_true(hold ~= nil and type(hold.menu) == "table", "a hold picker")
			local nav = find(hold.menu, i18n.get("tap_hold.hold.nav_layer"))
			helpers.assert_true(nav ~= nil, "the navigation layer is offered")
			nav.fn()
			helpers.assert_eq(calls[1][1], "set_hold")
			helpers.assert_eq(calls[1][2], "caps_lock")
			helpers.assert_eq(calls[1][3], "layer")
			helpers.assert_eq(calls[1][4], "nav")
		end)
		restore(Manager)
		if not ok then error(err, 0) end
	end)

	helpers.it("picks a tap from the catalogue, with the key itself as an option", function()
		local calls, picked = {}, {}
		local section, Manager = build(calls, picked)
		local ok, err = pcall(function()
			local i18n = require("infra.i18n")
			local shift = find(key_rows(section), i18n.get("tap_hold.group.left_shift"))
			local tap = find(shift.menu, string.format(i18n.get("tap_hold.picker.tap"), ""):sub(1, 4))
			tap.fn()
			helpers.assert_true(picked.opts.allow_native, "the key itself is offered")
			helpers.assert_eq(picked.opts.current, "copy", "Shift taps copy by default")
			local ids = {}
			for _, item in ipairs(picked.opts.items) do ids[item.id] = true end
			for _, id in ipairs({ "copy", "paste", "enter", "one_shot_shift", "open_url" }) do
				helpers.assert_true(ids[id], id .. " can be chosen")
			end
			picked.confirm("paste")
			picked.confirm("__native__")
			helpers.assert_eq(calls[1][3], "paste")
			helpers.assert_eq(calls[2][3], "", "the native pick is the empty tap")
		end)
		restore(Manager)
		if not ok then error(err, 0) end
	end)

	helpers.it("makes a key native again from its first row", function()
		local calls, picked = {}, {}
		local section, Manager = build(calls, picked)
		local ok, err = pcall(function()
			local i18n = require("infra.i18n")
			local ctrl = find(key_rows(section), i18n.get("tap_hold.group.left_ctrl"))
			helpers.assert_true(ctrl.checked, "a configured key is ticked")
			find(ctrl.menu, i18n.get("tap_hold.action.disable")).fn()
			helpers.assert_eq(calls[1][1], "set_native")
			helpers.assert_eq(calls[1][2], "left_ctrl")
			local escape = find(key_rows(section), i18n.get("tap_hold.group.escape"))
			helpers.assert_true(not escape.checked, "an unconfigured key is not ticked")
		end)
		restore(Manager)
		if not ok then error(err, 0) end
	end)

end)
