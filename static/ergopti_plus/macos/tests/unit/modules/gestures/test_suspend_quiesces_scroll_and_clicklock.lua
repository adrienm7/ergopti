--- tests/unit/modules/gestures/test_suspend_quiesces_scroll_and_clicklock.lua

--- ==============================================================================
--- MODULE: Regression — gesture suspend quiesces scroll-block + held click-lock
--- DESCRIPTION:
--- Audit findings F-M11 / F-M12. M.suspend() only set CoreState.suspended = true,
--- which gates NEW activity but does not quiesce state armed MID-gesture:
---   F-M11 — a scroll-block armed by a 3+finger gesture keeps swallowing native
---           scroll until the user lifts all fingers (the scrollBlocker eventtap's
---           swallow decision is isBlockingScroll, cleared only on n==0 / emergency).
---   F-M12 — a held synthetic click-lock (left/right_click_toggle) keeps its drag
---           converter + key-watcher eventtaps live; force_cleanup ran only on stop().
--- Both violate "pause = everything off". Fix: M.suspend() releases both, exactly
--- as M.stop() does (Engine.unblock_scroll + Actions.force_cleanup).
--- ==============================================================================

local helpers = require("tests.helpers")

local function permissive(over)
	-- Any unused Engine/Actions method gestures/init touches resolves to a no-op.
	return setmetatable(over, { __index = function() return function() end end })
end

helpers.describe("gestures suspend releases scroll-block and click-lock", function()
	helpers.it("M.suspend() calls Engine.unblock_scroll AND Actions.force_cleanup", function()
		local calls = { unblock = 0, cleanup = 0 }
		package.loaded["modules.gestures.engine"] = permissive({
			unblock_scroll = function() calls.unblock = calls.unblock + 1 end,
		})
		package.loaded["modules.gestures.actions"] = permissive({
			force_cleanup = function() calls.cleanup = calls.cleanup + 1 end,
		})

		local Gestures = helpers.load_with_stubs("modules.gestures")
		Gestures.suspend()
		-- The regression: both were 0 because suspend only flipped the boolean.
		helpers.assert_eq(calls.unblock, 1)
		helpers.assert_eq(calls.cleanup, 1)

		-- Resume must NOT re-arm them (they re-arm naturally on the next gesture).
		Gestures.resume()
		helpers.assert_eq(calls.unblock, 1)
		helpers.assert_eq(calls.cleanup, 1)

		package.loaded["modules.gestures.engine"]  = nil
		package.loaded["modules.gestures.actions"] = nil
		package.loaded["modules.gestures"]         = nil
	end)

	helpers.it("source: M.suspend reaches Engine.unblock_scroll and Actions.force_cleanup", function()
		local path = helpers.driver_root() .. "modules/gestures/init.lua"
		local fh = assert(io.open(path, "r"))
		local src = fh:read("*a"); fh:close()
		local s = src:find("function M%.suspend")
		local e = src:find("function M%.resume")
		helpers.assert_true(s ~= nil and e ~= nil and e > s, "could not isolate M.suspend body")
		local body = src:sub(s, e)
		helpers.assert_true(body:find("Engine.unblock_scroll", 1, true) ~= nil,
			"M.suspend must release the scroll-block via Engine.unblock_scroll")
		helpers.assert_true(body:find("Actions.force_cleanup", 1, true) ~= nil,
			"M.suspend must release any held click-lock via Actions.force_cleanup")
	end)
end)

helpers.describe("gestures engine exposes a scroll-block release", function()
	helpers.it("unblock_scroll() leaves is_blocking_scroll() false (idempotent)", function()
		local Engine = helpers.load_with_stubs("modules.gestures.engine")
		helpers.assert_eq(type(Engine.unblock_scroll), "function")
		helpers.assert_eq(type(Engine.is_blocking_scroll), "function")
		Engine.unblock_scroll()
		helpers.assert_eq(Engine.is_blocking_scroll(), false)
		package.loaded["modules.gestures.engine"] = nil
	end)
end)
