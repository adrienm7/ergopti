--- tests/unit/ui/test_tooltip_idle_dismiss_cancels.lua

--- ==============================================================================
--- MODULE: Regression — the idle auto-dismiss must fire the cancel contract
---         (tooltip-idle-dismiss-cancels)
--- DESCRIPTION:
--- The LLM tooltip's idle timer called M.hide and nothing else. Hiding is only
--- half of a dismissal: the prediction engine keeps its own predictions_visible
--- flag, and only the cancel callback clears it. So after the tooltip timed out
--- and vanished, the engine still believed a live prediction was on screen — and
--- the first Tab or Enter afterwards typed that stale prediction. Text the user
--- never asked for, from a tooltip that was no longer there.
---
--- ROOT CAUSE ENCODED: every OTHER dismissal path — the mouse watcher, the
--- keystroke watcher, Escape — already fired on_cancel before hiding. The idle
--- timer was the one that armed `M.hide` directly, which is why it is the one
--- that leaked. The fix routes all of them through a single dismiss() so the
--- cancel and the hide cannot come apart again; this test asserts the contract
--- at each path rather than only at the one that was broken.
---
--- WHY IT WAS SILENT: the tooltip disappeared exactly as expected. Nothing was
--- visibly wrong until a keystroke arrived seconds later and inserted a
--- prediction from a chain the user had already abandoned.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads tooltip_llm with a cancel callback installed and the idle timer
--- captured, so the timer body can be fired without waiting out the timeout.
--- @return table module, table cancels, function fire_idle
local function load_tooltip()
	local armed = {}

	-- The watchers (and with them the idle timer) are armed by a callback the
	-- RENDERER invokes once the canvas is on screen. With no canvas in the test
	-- environment the real renderer never gets there, so the contract is stubbed
	-- at its documented shape: render(blocks, state, on_shown).
	local T = helpers.load_with_stubs("ui.tooltip.tooltip_llm")
	package.loaded["ui.tooltip.renderer"] = {
		render = function(_blocks, _state, on_shown)
			if type(on_shown) == "function" then on_shown() end
			return true
		end,
		hide   = function() return true end,
		-- The width-calc pass measures text through the live canvas; without it
		-- show_predictions throws before it ever reaches the render call.
		canvas = { minimumTextSize = function() return { w = 100, h = 20 } end },
	}
	package.loaded["ui.tooltip.tooltip_llm"] = nil
	T = require("ui.tooltip.tooltip_llm")

	-- Spy installed AFTER load_with_stubs: the harness rebuilds the whole hs
	-- stub, so a spy set beforehand is silently discarded and every timer
	-- assertion below would then be measuring nothing.
	local real_doAfter = hs.timer.doAfter
	hs.timer.doAfter = function(delay, fn)
		armed[#armed + 1] = { delay = delay, fn = fn }
		return real_doAfter and real_doAfter(delay, fn) or { stop = function() end }
	end

	local cancels = {}
	T.set_cancel_callback(function() cancels[#cancels + 1] = true end)

	--- Fires the LONGEST-delay armed timer, which is the idle auto-hide: the
	--- render path also arms doAfter(0) deferrals, and firing one of those would
	--- prove nothing about the idle path.
	local function fire_idle()
		local best
		for _, t in ipairs(armed) do
			if type(t.fn) == "function" and (not best or t.delay > best.delay) then best = t end
		end
		if best then best.fn() end
		return best
	end

	return T, cancels, fire_idle, armed
end





-- ===========================================================
-- ===========================================================
-- ======= 1/ The idle timeout cancels, not just hides =======
-- ===========================================================
-- ===========================================================

helpers.describe("tooltip_llm: the idle auto-dismiss fires the cancel contract", function()
	helpers.it("arms a timer that cancels before hiding", function()
		local T, cancels, fire_idle = load_tooltip()

		-- is_enabled is the third argument and gates the whole body: omitting it
		-- returns before a timer is ever armed, and the test would then assert
		-- against a tooltip that was never shown.
		T.show_predictions({ "prédiction" }, 1, true)
		local fired = fire_idle()

		helpers.assert_true(fired ~= nil,
			"an idle auto-hide timer must be armed while the tooltip is visible — with no timer "
				.. "there is nothing to assert about and the test would pass vacuously")
		helpers.assert_true(fired and fired.delay > 0,
			"the idle timer must carry the configured timeout, not a zero-delay deferral")
		helpers.assert_true(#cancels >= 1,
			"the idle dismissal must fire on_cancel. Hiding alone leaves the engine's "
				.. "predictions_visible set, so the next Tab or Enter types the prediction that "
				.. "already timed out — text the user never asked for, from a tooltip that is "
				.. "no longer on screen")
		helpers.assert_true(not T.is_visible(),
			"and it must still actually hide the tooltip")
	end)
end)




-- ==========================================================
-- ==========================================================
-- ======= 2/ No dismissal path hides without cancelling ====
-- ==========================================================
-- ==========================================================

helpers.describe("tooltip_llm: every dismissal path goes through one contract", function()
	helpers.it("no watcher or timer calls M.hide() without cancelling first", function()
		-- Anchored on the cancel-contract setter, which only tooltip_llm has. The
		-- obvious anchor (reset_idle_timer) also names tooltip_hotstring, whose
		-- idle timer legitimately arms M.hide directly: that surface has no
		-- downstream visibility state to clear, so nothing there can go stale.
		local src = helpers.read_driver_source("_state.on_cancel = callback")
		helpers.assert_true(src ~= nil and src ~= "", "tooltip_llm source must be locatable")

		local code = src:gsub("%-%-[^\n]*", "")

		-- The dismissal helper must exist and be what the paths call. Checking for
		-- the absence of a bare M.hide would be satisfied by a file that dismisses
		-- nowhere at all.
		helpers.assert_true(code:find("local function dismiss", 1, true) ~= nil,
			"a single dismiss() must own the cancel-then-hide pair — three copies of it is how "
				.. "the idle path came to have only half")

		local uses = 0
		for _ in code:gmatch("dismiss%(\"") do uses = uses + 1 end
		helpers.assert_true(uses >= 3,
			"the mouse watcher, the keystroke watcher and the idle timer must all dismiss "
				.. "through it (found " .. uses .. ")")

		-- The idle timer specifically: it must not hand M.hide straight to doAfter.
		helpers.assert_true(code:find("doAfter%(%s*active_timeout%s*,%s*M%.hide") == nil,
			"the idle timer must not arm M.hide directly — that is the exact spelling that "
				.. "dismissed the tooltip without telling the engine")
	end)
end)
