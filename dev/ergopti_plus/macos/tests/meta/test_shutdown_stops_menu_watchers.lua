--- tests/meta/test_shutdown_stops_menu_watchers.lua

--- ==============================================================================
--- MODULE: Guard — the shutdown callback stops every watcher, not just one table
--- DESCRIPTION:
--- hs.shutdownCallback stops everything pinned in _G.script_watchers and cites,
--- in its own comment, the reason: a stray filesystem callback firing during the
--- Lua-state teardown window. The menubar's config pathwatcher and theme watcher
--- are held on the menu module instead of in that table, so they were never
--- stopped — the hazard the comment describes, left open for the two watchers
--- most likely to fire (a config write and a theme change).
---
--- ROOT CAUSE ENCODED:
--- A teardown that enumerates ONE registry rather than asking each owner. The
--- guard checks both halves: the callback must ask, and the menu must answer.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("shutdown: the menubar's own watchers are stopped too", function()

	helpers.it("the menu module exposes a way to stop the watchers it owns", function()
		-- load_with_stubs + eviction, never a bare require: a plain require here
		-- leaves the real ui.menu (and everything it pulls in) in package.loaded
		-- for every later test file, which is the discovery-order contamination
		-- this suite has been bitten by before.
		package.loaded["ui.menu"] = nil
		local menu = helpers.load_with_stubs("ui.menu")
		helpers.assert_type(menu.stop_watchers, "function",
			"the menu holds the config pathwatcher and the theme watcher, so it is the only "
			.. "place that can stop them; without this the shutdown callback cannot ask")
		package.loaded["ui.menu"] = nil
	end)

	helpers.it("the shutdown callback calls it", function()
		local src = helpers.read_driver_source("hs.shutdownCallback")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"init.lua must be readable or this asserts nothing")
		helpers.assert_true(src:find("stop_watchers", 1, true) ~= nil,
			"stopping _G.script_watchers alone leaves the menubar's watchers live during "
			.. "teardown, which is the exact hazard that loop's comment cites")
	end)

end)
