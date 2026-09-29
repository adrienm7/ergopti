--- tests/unit/ui/test_about_menu_uninstall.lua

--- ==============================================================================
--- MODULE: Uninstall Closes The Version / Updates Submenu (Linux tray)
--- DESCRIPTION:
--- « Désinstaller Ergopti » sat at the bottom of Configuration, between the
--- rows that tune the configuration, where removing the application read as
--- one more setting. It now closes the Version / Updates submenu, set apart by
--- a separator, next to the build it removes; it keeps its label key and runs
--- the same transaction (ui/menu/uninstall.lua), which quits the daemon through
--- ctx.on_quit. Configuration ends on login startup, with no dangling
--- separator. Built through the real tray builder and renderer.
--- ==============================================================================

local helpers = require("tests.helpers")

--- The submenu of the top-level row whose title is the translation of `key`.
local function submenu_of(items, key)
	local label = require("infra.i18n").get(key)
	for _, item in ipairs(items) do
		if item.title == label then return item.menu end
	end
	return nil
end

--- Builds the tray with the uninstall transaction replaced by a recorder.
--- @param quits table Counts ctx.on_quit calls.
--- @return table items, table runs
local function build(quits)
	local runs = {}
	local previous = package.loaded["ui.menu.uninstall"]
	package.loaded["ui.menu.uninstall"] = { run = function(opts) runs[#runs + 1] = opts end }
	local mb = helpers.load_module("ui.menu.menu_builder")
	local ok, items = pcall(mb.build, {
		_version = "9.9.9",
		on_quit = function() quits.count = quits.count + 1 end,
	})
	if not ok then
		package.loaded["ui.menu.uninstall"] = previous
		error(items, 0)
	end
	return items, runs, function() package.loaded["ui.menu.uninstall"] = previous end
end

helpers.describe("tray (linux): Uninstall closes the Version / Updates submenu", function()
	helpers.it("is the last About row, after a separator, and runs the uninstall transaction", function()
		local quits = { count = 0 }
		local items, runs, restore = build(quits)
		local ok, err = pcall(function()
			local i18n = require("infra.i18n")
			local rows = submenu_of(items, "menu.about.title")
			helpers.assert_true(type(rows) == "table" and #rows >= 3, "the tray must carry the About submenu")
			local last = rows[#rows]
			helpers.assert_eq(last.title, i18n.get("menu.global.uninstall"), "Uninstall closes the submenu")
			helpers.assert_eq(rows[#rows - 1].title, "-", "a separator sets it apart")
			helpers.assert_eq(rows[#rows - 2].title, i18n.get("menu.about.open_releases_page"),
				"it follows the releases rows")
			helpers.assert_true(last.disabled ~= true, "Uninstall stays live")
			local fn = last.fn or last.action
			helpers.assert_eq(type(fn), "function", "Uninstall carries its handler")
			helpers.assert_eq(#runs, 0, "building the menu must not start the transaction")
			fn()
			helpers.assert_eq(#runs, 1, "the row starts the uninstall transaction once")
			helpers.assert_eq(runs[1].title, i18n.get("menu.global.uninstall"), "under its own label")
			helpers.assert_eq(type(runs[1].confirm), "function", "the transaction asks before removing")
			runs[1].quit()
			helpers.assert_eq(quits.count, 1, "the transaction quits through the daemon's own quit")
		end)
		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("is drawn once in the whole tray, never in Configuration", function()
		local items, _, restore = build({ count = 0 })
		local ok, err = pcall(function()
			local i18n = require("infra.i18n")
			local label = i18n.get("menu.global.uninstall")
			local rows = submenu_of(items, "menu.configuration.title")
			helpers.assert_true(type(rows) == "table", "the tray must carry the Configuration submenu")
			for _, row in ipairs(rows) do
				helpers.assert_true(row.title ~= label, "Configuration no longer offers Uninstall")
			end
			helpers.assert_true(rows[#rows].title ~= "-", "Configuration ends on a row, not a separator")
			local found = 0
			for _, item in ipairs(items) do
				for _, row in ipairs(type(item.menu) == "table" and item.menu or {}) do
					if row.title == label then found = found + 1 end
				end
			end
			helpers.assert_eq(found, 1, "Uninstall is drawn once in the tray")
		end)
		restore()
		if not ok then error(err, 0) end
	end)
end)
