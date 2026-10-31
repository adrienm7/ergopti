--- tests/unit/ui/menu/structure/test_menu_part_reload.lua

--- ==============================================================================
--- MODULE: Tray Section Module Reload Guard
--- DESCRIPTION:
--- A reloaded tray root must reload its section modules (ui/menu/menu_<x>.lua).
--- Each module captures its dependencies when it loads; a module left cached
--- from an earlier load rendered the Quit row through a renderer double another
--- test module had installed, and four lifecycle tests failed only in a full run.
--- The test process reloads them (tests/support/menu_part_reload.lua); the root
--- itself never writes package.loaded.
--- ==============================================================================

local helpers = require("tests.helpers")

local ROOT = "ui.menu.builder"
local PART = "ui.menu.menu_reload_probe"
local NEIGHBOUR = "ui.menu.reload_probe_neighbour"

helpers.describe("tray section modules reload with the tray root", function()
	helpers.it("forgets a cached section module when the root file runs again", function()
		local part, neighbour = { probe = "part" }, { probe = "neighbour" }
		package.loaded[PART], package.loaded[NEIGHBOUR] = part, neighbour
		local ok, err = pcall(function()
			local builder = helpers.load_module(ROOT)
			helpers.assert_eq(type(builder.build), "function", "the real root loaded")
			helpers.assert_nil(package.loaded[PART], "a section module cached before the reload is forgotten")
			helpers.assert_true(rawequal(package.loaded[NEIGHBOUR], neighbour),
				"a module outside the section naming is kept")
		end)
		package.loaded[PART], package.loaded[NEIGHBOUR] = nil, nil
		if not ok then error(err, 0) end
	end)

	helpers.it("keeps cached section modules while the root itself stays cached", function()
		require(ROOT)
		local part = { probe = "part" }
		package.loaded[PART] = part
		local ok, err = pcall(function()
			require(ROOT)
			helpers.assert_true(rawequal(package.loaded[PART], part), "a cached root runs nothing")
		end)
		package.loaded[PART] = nil
		if not ok then error(err, 0) end
	end)

	helpers.it("reads the tray source with every section module the root binds", function()
		local source = helpers.read_menu_source()
		helpers.assert_true(source:find("function M.build(ctx)", 1, true) ~= nil, "the root itself is read")
		helpers.assert_true(source:find('require("ui.menu.menu_quit").build', 1, true) ~= nil,
			"the root binds the Quit module")
		helpers.assert_true(source:find("local function _build_quit(ctx)", 1, true) ~= nil,
			"the Quit builder is read from its own module")
	end)

	helpers.it("refuses a second installation", function()
		local ok, err = pcall(require("tests.support.menu_part_reload").install)
		helpers.assert_eq(ok, false, "the searcher is installed once")
		helpers.assert_true(tostring(err):find("already installed", 1, true) ~= nil, tostring(err))
	end)
end)
