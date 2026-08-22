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
		local calls = { unblock = 0, cleanup = 0, resume = 0 }
		package.loaded["modules.gestures.engine"] = permissive({
			unblock_scroll = function() calls.unblock = calls.unblock + 1; return true end,
		})
		package.loaded["modules.gestures.actions"] = permissive({
			force_cleanup = function() calls.cleanup = calls.cleanup + 1; return true end,
			resume_after_cleanup = function() calls.resume = calls.resume + 1; return true end,
		})

		local Gestures = helpers.load_with_stubs("modules.gestures")
		Gestures.suspend()
		-- The regression: both were 0 because suspend only flipped the boolean.
		helpers.assert_eq(calls.unblock, 1)
		helpers.assert_eq(calls.cleanup, 1)

		-- Resume reopens only logical action admission; it must not re-run cleanup
		-- or re-arm any native gesture action.
		helpers.assert_eq(Gestures.resume(), true)
		helpers.assert_eq(calls.unblock, 1)
		helpers.assert_eq(calls.cleanup, 1)
		helpers.assert_eq(calls.resume, 1)

		package.loaded["modules.gestures.engine"]  = nil
		package.loaded["modules.gestures.actions"] = nil
		package.loaded["modules.gestures"]         = nil
	end)

	helpers.it("keeps an OFF feature disabled when enable_all is attempted under PAUSE", function()
		local calls = { unblock = 0, cleanup = 0, resume = 0 }
		package.loaded["modules.gestures.engine"] = permissive({
			unblock_scroll = function() calls.unblock = calls.unblock + 1; return true end,
		})
		package.loaded["modules.gestures.actions"] = permissive({
			force_cleanup = function() calls.cleanup = calls.cleanup + 1; return true end,
			resume_after_cleanup = function() calls.resume = calls.resume + 1; return true end,
		})

		local Gestures = helpers.load_with_stubs("modules.gestures")
		helpers.assert_eq(Gestures.disable_all(), true)
		helpers.assert_eq(Gestures.is_enabled(), false)
		helpers.assert_eq(Gestures.suspend(), true)
		local cleanup_before_enable = calls.cleanup
		helpers.assert_eq(Gestures.enable_all(), false,
			"a feature toggle may not program ON intent behind ScriptControl PAUSE")
		helpers.assert_eq(Gestures.is_enabled(), false)
		helpers.assert_eq(Gestures.is_suspended(), true)
		helpers.assert_eq(calls.cleanup, cleanup_before_enable + 1,
			"the refused enable remains cleanup-only")
		helpers.assert_eq(calls.resume, 0)

		helpers.assert_eq(Gestures.resume(), true)
		helpers.assert_eq(Gestures.is_enabled(), false,
			"RESUME must restore the exact OFF snapshot without reopening actions")
		helpers.assert_eq(Gestures.is_suspended(), false)
		helpers.assert_eq(calls.resume, 0)

		package.loaded["modules.gestures.engine"] = nil
		package.loaded["modules.gestures.actions"] = nil
		package.loaded["modules.gestures"] = nil
	end)

	helpers.it("source: M.suspend reaches Engine.unblock_scroll and Actions.force_cleanup", function()
		-- Selected by a declaration unique to modules/gestures/init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function schedule_emergency_recycle")
		helpers.assert_true(src ~= nil, "modules/gestures/init.lua source must be locatable")
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
