--- tests/unit/ui/menu/structure/test_active_layout_rows.lua

--- ==============================================================================
--- MODULE: Active Layout Rows Tests
--- DESCRIPTION:
--- Layout > « Input sources » on Linux: the desktop's layouts with the active
--- one ticked, a choice switching the desktop, the declared status line on a
--- desktop with no backend and the settings row on an empty list. The manifest
--- now declares the list for every driver, and the layout menu owner provides it;
--- the install rows stay macOS-only with a reason naming the other routes.
--- ==============================================================================

local helpers = require("tests.helpers")
local Rows = require("ui.menu.active_layout_rows")

local CHOICES = {
	{ id = "xkb:fr", label = "fr", active = false },
	{ id = "xkb:fr+ergopti", label = "fr+ergopti", active = true },
}

--- A recording world over a fake switcher.
--- @param backend string|nil
--- @param choices table
local function world(backend, choices)
	local state = { selected = {}, redraws = 0, errors = {}, answer = true, refreshes = 0 }
	state.switcher = {
		backend = function() return backend end,
		choices = function() return choices end,
		refresh = function(on_done)
			state.refreshes = state.refreshes + 1
			on_done(false)
		end,
		select = function(id, on_done)
			state.selected[#state.selected + 1] = id
			on_done(state.answer, state.answer and nil or "gsettings failed")
		end,
	}
	state.ctx = {
		t = function(key) return key end,
		on_changed = function() state.redraws = state.redraws + 1 end,
		show_error = function(message) state.errors[#state.errors + 1] = message end,
		switch = { switcher = function() return state.switcher end },
	}
	return state
end

local function read(path)
	local file = assert(io.open(path, "rb"))
	local text = file:read("*a")
	assert(file:close())
	return text
end

helpers.describe("active layout rows", function()
	helpers.it("lists the desktop's layouts with the active one ticked and disabled", function()
		local state = world("gnome", CHOICES)
		local rows = Rows.rows(state.ctx)
		helpers.assert_eq(#rows, 2)
		helpers.assert_eq(rows[1].label, "fr")
		helpers.assert_eq(rows[1].checked, false)
		helpers.assert_eq(rows[2].checked, true)
		helpers.assert_eq(rows[2].disabled, true, "the active layout is not chosen again")
		helpers.assert_eq(state.refreshes, 1, "each build asks for a fresh reading")
	end)

	helpers.it("switches the desktop to a chosen layout and tells a refusal", function()
		local state = world("kde", CHOICES)
		local rows = Rows.rows(state.ctx)
		rows[1].action()
		helpers.assert_eq(state.selected[1], "xkb:fr")
		helpers.assert_eq(#state.errors, 0)
		helpers.assert_eq(state.redraws, 1, "the menu redraws on the new active layout")
		state.answer = false
		rows[1].action()
		helpers.assert_eq(state.errors[1], "menu.layout.select_failed", "a refused switch is told")
	end)

	helpers.it("shows why on a desktop that cannot change its layout", function()
		local state = world(nil, {})
		local rows = Rows.rows(state.ctx)
		helpers.assert_eq(#rows, 1)
		helpers.assert_true(tostring(rows[1].label):find("GNOME, KDE", 1, true) ~= nil
			or rows[1].label == "menu.layout.active_layouts_unsupported_desktop", tostring(rows[1].label))
		helpers.assert_eq(state.refreshes, 0, "no desktop is read without a backend")
	end)

	helpers.it("opens the backend's own keyboard settings and refuses to guess one", function()
		helpers.assert_eq(Rows.settings_command("gnome"), "gnome-control-center keyboard")
		helpers.assert_eq(Rows.settings_command("kde"), "systemsettings kcm_keyboard")
		helpers.assert_eq(Rows.settings_command("x11"), nil)
		local ran = {}
		local shell = { has_command = function() return true end, run = function(line) ran[#ran + 1] = line; return true end }
		helpers.assert_eq(Rows.open_settings("kde", shell), true)
		helpers.assert_eq(ran[1], "systemsettings kcm_keyboard >/dev/null 2>&1 &")
		helpers.assert_eq(Rows.open_settings("x11", shell), false)
		helpers.assert_eq(Rows.open_settings("gnome", { has_command = function() return false end, run = shell.run }), false)
		helpers.assert_eq(#ran, 1)
	end)

	helpers.it("is declared for every driver and provided by the layout menu owner", function()
		local Json = require("json")
		local manifest = Json.decode(read(helpers.driver_root() .. "/../_shared/modules/menu/menu_manifest.json"))
		local found
		for _, row in ipairs(manifest.layout_menu) do
			if row.id == "active_layouts" then found = row end
		end
		helpers.assert_eq(type(found), "table", "the list is declared")
		helpers.assert_eq(found.platforms, nil, "the list is no longer macOS-only")
		-- The .bundle rows stay macOS-only and the Windows install row Windows-only;
		-- each reason says where the other systems install from.
		local bundle, system
		for _, row in ipairs(manifest.layout_menu) do
			if row.id == "layout_bundle" then bundle = row end
			if row.id == "layout_system_install" then system = row end
		end
		helpers.assert_eq(bundle.reason_key, "platform_reason.layout_install_is_the_macos_bundle")
		helpers.assert_eq(type(system), "table", "Windows declares its install row")
		helpers.assert_eq(system.platforms[1], "ahk")
		helpers.assert_eq(#system.platforms, 1, "the Windows install row is Windows-only")
		local english = Json.decode(read(helpers.driver_root() .. "/../_shared/data/locales/en.json"))
		local reason = english[bundle.reason_key]
		helpers.assert_true(type(reason) == "string" and reason:find("Install the Ergopti system layout", 1, true) ~= nil
			and reason:find(english["menu.layout.manage"], 1, true) ~= nil, "the reason names both install routes")
		helpers.assert_true(english[system.reason_key]:find(english["menu.layout.manage"], 1, true) ~= nil,
			"the Windows row tells Linux where to install from")
		local owner = assert(helpers.read_module_source("ui.menu.menu_layouts"))
		helpers.assert_true(owner:find('providers["active_layouts"]', 1, true) ~= nil, "the provider exists")
		helpers.assert_true(owner:find('require("ui.menu.active_layout_rows").rows(', 1, true) ~= nil)
	end)
end)

return true
