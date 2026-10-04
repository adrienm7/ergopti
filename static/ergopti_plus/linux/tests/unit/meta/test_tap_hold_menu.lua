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
local SCOPE = "infra.tap_hold_scope"

--- A fake writer recording its calls.
local function fake_writer(calls)
	local writer = {}
	for _, name in ipairs({ "set_tap", "set_hold", "set_native", "set_threshold", "set_enabled" }) do
		writer[name] = function(...)
			calls[#calls + 1] = { name, ... }
			return true
		end
	end
	return writer
end

--- Builds the menu with a real tap-hold manager on the shared defaults, a fake
--- writer and a fake picker, and returns the Tap-Holds section.
local function build(calls, picked, user_text)
	user_text = require("tests.support.tap_hold_fixture").with_preset(user_text)
	local Manager = helpers.load_module("platform.remap.tap_hold_manager")
	local user_path = os.tmpname()
	os.remove(user_path)
	if user_text then
		local fh = assert(io.open(user_path, "w"))
		fh:write(user_text)
		fh:close()
	end
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
	})
	package.loaded[WRITER] = fake_writer(calls)
	package.loaded[SCOPE] = {
		apply = function(mode, is_paused)
			calls[#calls + 1] = { "scope", mode, is_paused() }
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
	package.loaded[SCOPE] = nil
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

	helpers.it("has the Windows rows: switch, restore, clear, and one row per key", function()
		local calls, picked = {}, {}
		local section, Manager = build(calls, picked)
		local ok, err = pcall(function()
			helpers.assert_true(section ~= nil, "a Tap-Holds section in the tray")
			local engine_keys = 0
			for _ in pairs(require("platform.remap.tap_hold_engine").KEY_CODES) do engine_keys = engine_keys + 1 end
			helpers.assert_eq(#key_rows(section), engine_keys, "every key the engine can remap has its row")
			local i18n = require("infra.i18n")
			local reset = find(section.menu, i18n.get("common.restore_recommended"))
			local disable = find(section.menu, i18n.get("common.clear_to_system"))
			local toggle = find(section.menu, i18n.get("menu.tapholds.enable"))
			helpers.assert_not_nil(reset, "the recommended restore row")
			helpers.assert_not_nil(disable, "the clear-to-system row")
			helpers.assert_not_nil(toggle, "the feature switch")
			-- The maintainer's first group (2026-09-30): switch, restore, clear,
			-- then a separator, and no scope row below it.
			helpers.assert_eq(section.menu[1], toggle)
			helpers.assert_eq(section.menu[2], reset)
			helpers.assert_eq(section.menu[3], disable)
			helpers.assert_eq(section.menu[4].title, "-")
			for index = 5, #section.menu do
				local title = section.menu[index].title
				helpers.assert_true(title ~= reset.title and title ~= disable.title,
					"no scope row may follow the first group")
			end
			local asked = {}
			local execute = os.execute
			os.execute = function(command)
				if command:find("zenity", 1, true) then
					asked[#asked + 1] = command
					return 1
				end
				return execute(command)
			end
			local ran, raised = pcall(function()
				reset.fn()
				disable.fn()
			end)
			os.execute = execute
			if not ran then error(raised, 0) end
			toggle.fn()
			-- Both apply at once, after the scope's backups: the restore since
			-- restore-recommended-no-confirm, the clear since 2026-09-30.
			helpers.assert_eq(#asked, 0, "no scope row asks")
			helpers.assert_eq(calls[1], { "scope", "recommended", false })
			helpers.assert_eq(calls[2], { "scope", "clear", false })
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

	helpers.it("names every hold by its translated label, never by its stored id", function()
		local calls, picked = {}, {}
		local section, Manager = build(calls, picked)
		local ok, err = pcall(function()
			local i18n = require("infra.i18n")
			local alt_gr = find(key_rows(section), i18n.get("tap_hold.group.alt_gr"))
			helpers.assert_true(alt_gr ~= nil, "an AltGr row")
			helpers.assert_contains(alt_gr.title, "  /  " .. i18n.get("tap_hold.hold.alt_gr"),
				"the row shows the hold's label")
			helpers.assert_nil(alt_gr.title:find("alt_gr", 1, true), "not the id the file stores")
			local hold = find(alt_gr.menu, string.format(i18n.get("tap_hold.picker.hold"), ""):sub(1, 4))
			local combo = i18n.get("tap_hold.hold.ctrl") .. " + " .. i18n.get("tap_hold.hold.shift")
			helpers.assert_true(find(hold.menu, combo) ~= nil, "the picker offers '" .. combo .. "'")
			helpers.assert_true(#hold.menu > 30, "every hold option is a row")
			for _, row in ipairs(hold.menu) do
				helpers.assert_true(type(row.title) == "string", "every hold row has a title")
				helpers.assert_nil(row.title:find("[%w_]%+[%w_]"), "raw combination id: " .. row.title)
				helpers.assert_nil(row.title:find("_", 1, true), "raw modifier id: " .. row.title)
			end
		end)
		restore(Manager)
		if not ok then error(err, 0) end
	end)

	helpers.it("shows a reordered combination as the hold it is, not as none", function()
		local calls, picked = {}, {}
		local section, Manager = build(calls, picked, '[tap_hold.keys.caps_lock]\nhold_modifier = "Shift + Ctrl"\n')
		local ok, err = pcall(function()
			local i18n = require("infra.i18n")
			local combo = i18n.get("tap_hold.hold.ctrl") .. " + " .. i18n.get("tap_hold.hold.shift")
			local caps = find(key_rows(section), i18n.get("tap_hold.group.caps_lock"))
			helpers.assert_contains(caps.title, "  /  " .. combo)
			local hold = find(caps.menu, string.format(i18n.get("tap_hold.picker.hold"), ""):sub(1, 4))
			local checked = {}
			for _, row in ipairs(hold.menu) do
				if row.checked then checked[#checked + 1] = row.title end
			end
			helpers.assert_eq(checked, { combo }, "the picker ticks the option in force")
		end)
		restore(Manager)
		if not ok then error(err, 0) end
	end)

	helpers.it("has a label for every modifier of every hold in all 21 locales", function()
		local HoldOptions = require("tap_hold.hold_options")
		local Json = require("json")
		local Paths = require("infra.paths")
		local picker = require("platform.remap.tap_hold_loader").load(DEFAULTS, nil).hold_picker
		local options = HoldOptions.build(picker)
		helpers.assert_true(#options > #picker.modifiers, "the shipped picker must be read, or this proves nothing")
		local order_fh = assert(io.open(Paths.shared("data/locale_order.json"), "r"))
		local locales = Json.decode(order_fh:read("*a")).order
		order_fh:close()
		helpers.assert_eq(#locales, 21, "every shipped locale")
		for _, code in ipairs(locales) do
			local fh = assert(io.open(Paths.shared("data/locales/" .. code .. ".json"), "r"))
			local strings = Json.decode(fh:read("*a"))
			fh:close()
			local function translate(key)
				local value = strings[key]
				if type(value) ~= "string" or value == "" then error(code .. ".json lacks " .. key, 0) end
				return value
			end
			for _, option in ipairs(options) do
				local label = HoldOptions.label(option, translate)
				if option.kind == "modifier" then
					local expected = {}
					for modifier in option.id:gmatch("[^+]+") do expected[#expected + 1] = translate("tap_hold.hold." .. modifier) end
					helpers.assert_true(#expected >= 1, code .. ": " .. option.id .. " names at least one modifier")
					helpers.assert_eq(label, table.concat(expected, " + "), code .. ": " .. option.id)
				end
			end
		end
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

	-- The keys sat in one undivided list in the Windows order (Engine.KEY_ORDER),
	-- with no hand; the shared key catalogue now decides the hand of each.
	helpers.it("lists the keys by hand, with a separator after Space and AltGr opening the right hand", function()
		local calls, picked = {}, {}
		local section, Manager = build(calls, picked)
		local ok, err = pcall(function()
			local i18n = require("infra.i18n")
			local rows = section.menu
			local function index_of(title)
				for index, row in ipairs(rows) do
					if row.title == title then return index end
				end
				return nil
			end
			local function key_index(label_key)
				local prefix = i18n.get(label_key) .. "  :"
				for index, row in ipairs(rows) do
					if type(row.title) == "string" and row.title:sub(1, #prefix) == prefix then return index end
				end
				return nil
			end
			local left = index_of(i18n.section("menu.tapholds.left_hand_tap_hold"))
			local right = index_of(i18n.section("menu.tapholds.right_hand_tap_hold"))
			helpers.assert_not_nil(left, "the « Main gauche (tap/hold) » header")
			helpers.assert_not_nil(right, "the « Main droite (tap/hold) » header")
			local space = key_index("tap_hold.group.space")
			helpers.assert_true(space ~= nil and space > left and space < right, "Space is a left-hand key")
			helpers.assert_eq(space, right - 2, "Space is the last left-hand key")
			helpers.assert_true(rows[space + 1].title == "-" or rows[space + 1].separator == true,
				"a separator follows the last left-hand key")
			helpers.assert_eq(key_index("tap_hold.group.alt_gr"), right + 1, "AltGr is the first right-hand key")
			helpers.assert_true(key_index("tap_hold.group.enter") > right, "Enter is a right-hand key")
		end)
		restore(Manager)
		if not ok then error(err, 0) end
	end)

end)
