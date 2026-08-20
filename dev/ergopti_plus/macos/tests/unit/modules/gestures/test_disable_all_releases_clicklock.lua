--- tests/unit/modules/gestures/test_disable_all_releases_clicklock.lua

--- ==============================================================================
--- MODULE: Regression — gestures "disable all" releases a held click-lock (F-MED-22)
--- DESCRIPTION:
--- M.suspend() and M.stop() both release a held synthetic click-lock (and unblock
--- native scroll) before quiescing gestures — see test_suspend_quiesces_scroll_
--- and_clicklock.lua and test_stop_force_cleanup.lua. M.disable_all() (the menu
--- master toggle's OFF path AND the dedicated "Disable all" gesture action, both
--- in ui/menu/menu_gestures.lua, route through this single function) did NOT:
--- it only flipped CoreState.enabled = false. An already-engaged click-drag
--- (left/right_click_toggle) was orphaned — self-healing on the next real
--- keypress/mouseUp, but leaving the OS with a button stuck down until then.
---
--- Fix: mirror suspend()/stop() — release the click-lock and unblock scroll
--- BEFORE flipping the flag.
--- ==============================================================================

local helpers = require("tests.helpers")

local function permissive(over)
	-- Any unused Engine/Actions method gestures/init touches resolves to a no-op.
	return setmetatable(over, { __index = function() return function() end end })
end





-- ===================================================================
-- ===================================================================
-- ======= 1/ disable_all releases scroll-block and click-lock =======
-- ===================================================================
-- ===================================================================

helpers.describe("gestures disable_all releases scroll-block and click-lock (F-MED-22)", function()

	helpers.it("M.disable_all() calls Engine.unblock_scroll AND Actions.force_cleanup", function()
		local calls = { unblock = 0, cleanup = 0 }
		package.loaded["modules.gestures.engine"] = permissive({
			unblock_scroll = function() calls.unblock = calls.unblock + 1 end,
		})
		package.loaded["modules.gestures.actions"] = permissive({
			force_cleanup = function() calls.cleanup = calls.cleanup + 1 end,
		})

		local Gestures = helpers.load_with_stubs("modules.gestures")
		Gestures.disable_all()
		-- The regression: both were 0 because disable_all only flipped the boolean.
		helpers.assert_eq(calls.unblock, 1)
		helpers.assert_eq(calls.cleanup, 1)
		helpers.assert_eq(Gestures.is_enabled(), false, "disable_all must still flip CoreState.enabled to false")

		package.loaded["modules.gestures.engine"]  = nil
		package.loaded["modules.gestures.actions"] = nil
		package.loaded["modules.gestures"]         = nil
	end)

	helpers.it("M.enable_all() does NOT trigger cleanup (only disable needs to release a held lock)", function()
		local calls = { unblock = 0, cleanup = 0 }
		package.loaded["modules.gestures.engine"] = permissive({
			unblock_scroll = function() calls.unblock = calls.unblock + 1 end,
		})
		package.loaded["modules.gestures.actions"] = permissive({
			force_cleanup = function() calls.cleanup = calls.cleanup + 1 end,
		})

		local Gestures = helpers.load_with_stubs("modules.gestures")
		Gestures.enable_all()
		helpers.assert_eq(calls.unblock, 0)
		helpers.assert_eq(calls.cleanup, 0)
		helpers.assert_eq(Gestures.is_enabled(), true)

		package.loaded["modules.gestures.engine"]  = nil
		package.loaded["modules.gestures.actions"] = nil
		package.loaded["modules.gestures"]         = nil
	end)

	helpers.it("M.disable(\"all\") (the legacy name-based entry point) also releases the click-lock", function()
		local calls = { unblock = 0, cleanup = 0 }
		package.loaded["modules.gestures.engine"] = permissive({
			unblock_scroll = function() calls.unblock = calls.unblock + 1 end,
		})
		package.loaded["modules.gestures.actions"] = permissive({
			force_cleanup = function() calls.cleanup = calls.cleanup + 1 end,
		})

		local Gestures = helpers.load_with_stubs("modules.gestures")
		Gestures.disable("all")
		helpers.assert_eq(calls.unblock, 1)
		helpers.assert_eq(calls.cleanup, 1)
		helpers.assert_eq(Gestures.is_enabled(), false)

		package.loaded["modules.gestures.engine"]  = nil
		package.loaded["modules.gestures.actions"] = nil
		package.loaded["modules.gestures"]         = nil
	end)

	helpers.it("source: M.disable_all reaches Engine.unblock_scroll and Actions.force_cleanup", function()
		-- Selected by a declaration unique to modules/gestures/init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function schedule_emergency_recycle")
		helpers.assert_true(src ~= nil, "modules/gestures/init.lua source must be locatable")
		local s = src:find("function M%.disable_all")
		local e = src:find("function M%.enable%(name%)")
		helpers.assert_true(s ~= nil and e ~= nil and e > s, "could not isolate M.disable_all body")
		local body = src:sub(s, e)
		helpers.assert_true(body:find("Engine.unblock_scroll", 1, true) ~= nil,
			"M.disable_all must release the scroll-block via Engine.unblock_scroll (F-MED-22)")
		helpers.assert_true(body:find("Actions.force_cleanup", 1, true) ~= nil,
			"M.disable_all must release any held click-lock via Actions.force_cleanup (F-MED-22)")
	end)
end)
