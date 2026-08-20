--- tests/unit/adapters/test_tray_menu_adapter.lua

--- ==============================================================================
--- MODULE: TrayMenu Adapter — behaviour with and without a backend
--- DESCRIPTION:
--- What the port-facing adapter does on a machine that can host a tray, and on
--- one that cannot.
---
--- WHY BOTH HALVES MATTER:
--- The daemon calls setIcon, setMenu and pump unconditionally, from the event
--- loop, on every machine. A headless server, a TTY session and a desktop
--- missing libayatana all reach this code — and hotstring expansion has nothing
--- to do with having a tray, so none of them may be turned into a crash or a
--- stall. Equally, a machine that CAN host one must actually get the menu: the
--- previous adapter degraded so gracefully that it degraded on every machine and
--- nobody noticed for the life of the driver.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Installs a stand-in indicator and loads the adapter over it.
--- @param available boolean Whether the machine can host a tray.
--- @return table adapter, table log
local function with_indicator(available)
	local log = { menus = {}, icons = {}, pumps = 0, created = nil, destroyed = 0 }
	package.loaded["platform.tray.appindicator"] = {
		is_available = function() return available end,
		create = function(id, icon, title)
			if not available then return false end
			log.created = { id = id, icon = icon, title = title }
			return true
		end,
		set_menu = function(items) log.menus[#log.menus + 1] = items ; return true end,
		set_icon = function(icon) log.icons[#log.icons + 1] = icon ; return true end,
		pump = function() log.pumps = log.pumps + 1 ; return 0 end,
		destroy = function() log.destroyed = log.destroyed + 1 end,
		is_live = function() return log.created ~= nil end,
	}
	return helpers.load_module("adapters.tray_menu"), log
end





-- =================================================================
-- =================================================================
-- ======= 1/ On a machine that can host a tray ====================
-- =================================================================
-- =================================================================

helpers.describe("tray_menu: with a backend", function()

	helpers.it("creates the icon on first use and reports the backend", function()
		local tray, log = with_indicator(true)
		tray.setMenu({ { title = "Quitter", fn = function() end } })
		helpers.assert_true(log.created ~= nil, "the first setMenu brings the icon up")
		helpers.assert_eq(tray.getBackend(), "appindicator",
			"the daemon logs which backend it got; nil there used to be the answer "
				.. "on every machine")
	end)

	helpers.it("never resolves the icon to an empty name", function()
		local tray, log = with_indicator(true)
		tray.setMenu({})
		helpers.assert_true(log.created.icon ~= "",
			"an empty icon name draws a blank, unclickable space in the panel — "
				.. "which is what shipped, because the assets directory does not exist "
				.. "and the resolved value went into a local nothing read")
	end)

	helpers.it("passes the menu tree through unchanged", function()
		local tray, log = with_indicator(true)
		local tree = {
			{ title = "Hotstrings", menu = { { title = "Rolls", checked = true } } },
			{ separator = true },
			{ title = "Quitter", fn = function() end },
		}
		tray.setMenu(tree)
		helpers.assert_eq(log.menus[#log.menus], tree,
			"the adapter is a binding, not a transformer; anything it rewrote here "
				.. "would be a second menu vocabulary to keep in sync")
	end)

	helpers.it("rebuilds on every setMenu, because a toggle changes the tree", function()
		local tray, log = with_indicator(true)
		tray.setMenu({ { title = "A" } })
		tray.setMenu({ { title = "B" } })
		helpers.assert_eq(#log.menus, 2,
			"a menu built once at startup shows stale checkmarks for the rest of the "
				.. "session, which is what the driver did")
	end)

	helpers.it("tears down and comes back", function()
		local tray, log = with_indicator(true)
		tray.setMenu({ { title = "A" } })
		tray.destroy()
		helpers.assert_eq(log.destroyed, 1, "destroy reaches the backend")
		tray.setMenu({ { title = "B" } })
		helpers.assert_true(log.created ~= nil, "and the reload path can bring it back")
	end)

	helpers.it("pumps without blocking", function()
		local tray, log = with_indicator(true)
		tray.setMenu({})
		tray.pump()
		helpers.assert_eq(log.pumps, 1, "the event loop drains the tray on every tick")
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 2/ On a machine that cannot ============================
-- =================================================================
-- =================================================================

helpers.describe("tray_menu: with no backend", function()

	helpers.it("keeps the menu for later instead of discarding it", function()
		local tray = with_indicator(false)
		tray.setMenu({ { title = "Quitter" } })
		helpers.assert_eq(#tray.getMenu(), 1,
			"a headless boot that later gains a display should not have lost the menu")
		helpers.assert_eq(tray.getBackend(), nil,
			"and the absence must be reported honestly rather than as a working tray")
	end)

	helpers.it("accepts every call the daemon makes, without raising", function()
		local tray = with_indicator(false)
		-- The daemon calls all of these unconditionally from its event loop.
		-- Hotstring expansion has nothing to do with having a tray, so none of
		-- them may become a crash on a TTY or a headless server.
		local ok, err = pcall(function()
			tray.setIcon({ title = "Ergopti" })
			tray.setIcon(nil)
			tray.setMenu(nil)
			tray.setMenu({})
			tray.setTooltip("hello")
			tray.setTooltip(nil)
			tray.pump()
			tray.destroy()
			tray.destroy()
			tray.pump()
		end)
		helpers.assert_eq(ok, true, "no call may raise without a backend: " .. tostring(err))
	end)

	helpers.it("treats a non-table menu as empty rather than propagating it", function()
		local tray = with_indicator(false)
		tray.setMenu("not a menu")
		helpers.assert_eq(#tray.getMenu(), 0,
			"a malformed menu must not reach the widget builder, where it would "
				.. "raise inside GTK with no Lua traceback")
	end)

end)
