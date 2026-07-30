--- tests/unit/modules/keymap/test_preview_render_off_hid_thread.lua

--- ==============================================================================
--- MODULE: Regression — the hotstring preview must not render on the HID thread
---         (preview-render-off-hid-thread)
--- DESCRIPTION:
--- The preview tooltip rendered synchronously inside the keyboard callback, on
--- every preview keystroke. Rendering is not cheap: resolving the anchor
--- performs cross-process accessibility IPC and creates and destroys eventtaps.
--- Against a beach-balling front app that IPC blocks until the AX timeout — long
--- enough for macOS to disable the whole keyboard tap for being unresponsive,
--- which takes the driver down with it. Every keystroke was paying a cost whose
--- worst case is losing the keyboard entirely.
---
--- ROOT CAUSE ENCODED: the LLM tooltip already defers its own re-renders for
--- exactly this reason and says so in its comments. The hotstring preview — the
--- one that fires on far more keystrokes — was never migrated.
---
--- WHY DEFERRING NEEDS A STAMP: one runloop tick is a window in which the
--- preview can be superseded by the next keystroke or dismissed outright. An
--- unstamped deferral resurrects a tooltip the user has already dismissed, which
--- would trade a latency bug for a ghost-tooltip bug. Each request is therefore
--- stamped and a superseded render drops itself.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =====================================================
-- =======================================================
-- ======= 1/ The render is deferred, then stamped =======
-- =======================================================
-- =====================================================

helpers.describe("llm_bridge: the preview render leaves the keyboard callback", function()
	helpers.it("shows the preview through a deferral, not inline", function()
		local src = helpers.read_driver_source("_preview_render_generation")
		helpers.assert_true(src ~= nil and src ~= "",
			"llm_bridge must be locatable by its preview-render stamp")

		local code = src:gsub("%-%-[^\n]*", "")
		local at = code:find("tooltip.show_stacked", 1, true)
		helpers.assert_true(at ~= nil, "the preview must still be rendered at some point")

		local before = code:sub(math.max(1, at - 400), at)
		helpers.assert_true(before:find("TimerScheduler.after", 1, true) ~= nil,
			"the render must be scheduled off the keyboard callback. Resolving the tooltip anchor "
				.. "performs cross-process AX IPC on every preview keystroke, and against a hung "
				.. "front app that blocks until the AX timeout — long enough for macOS to disable "
				.. "the keyboard tap for being unresponsive")
		helpers.assert_true(before:find("_preview_render_generation", 1, true) ~= nil,
			"and it must be stamped, so a render superseded during its deferral drops itself "
				.. "instead of resurrecting a dismissed tooltip")
	end)

	helpers.it("the deferred body re-checks the stamp before rendering", function()
		local src = helpers.read_driver_source("_preview_render_generation")
		local code = src:gsub("%-%-[^\n]*", "")

		local at = code:find("tooltip.show_stacked", 1, true)
		helpers.assert_true(at ~= nil, "the preview render must exist")

		-- Capturing a stamp is worthless without comparing it at fire time. The
		-- comparison must sit INSIDE the deferred body, between the schedule and
		-- the render — that is the whole mechanism.
		local body = code:sub(math.max(1, at - 200), at)
		helpers.assert_true(body:find("~= _preview_render_generation", 1, true) ~= nil,
			"the deferred body must compare its captured stamp against the current one and "
				.. "return early when superseded. Capturing without comparing protects nothing, "
				.. "and the render would repaint a tooltip that has since been dismissed")
	end)
end)




-- =====================================================
-- =====================================================
-- ======= 2/ Every dismissal invalidates ==============
-- =====================================================
-- =====================================================

helpers.describe("llm_bridge: dismissals cancel a pending render", function()
	helpers.it("every hide path bumps the stamp", function()
		local src = helpers.read_driver_source("_preview_render_generation")
		local code = src:gsub("%-%-[^\n]*", "")

		-- Every dismissal in this module counts, in BOTH spellings: hide() and the
		-- forced variant the preview-disable setters use. A render already waiting
		-- on its tick would land right after either one and put the tooltip back.
		local hides, guarded = 0, 0
		local pos = 1
		while true do
			local at = code:find("tooltip.hide", pos, true)
			if not at then break end
			pos = at + 1
			hides = hides + 1
			-- A short lookback rather than the same line: the invalidation may
			-- legitimately sit on the preceding line, but a window this narrow
			-- still cannot credit a different hide site's guard.
			if code:sub(math.max(1, at - 160), at):find("invalidate_pending_preview", 1, true) then
				guarded = guarded + 1
			end
		end

		helpers.assert_true(hides >= 3,
			"the scan must reach the real hide sites (found " .. hides .. ")")
		helpers.assert_eq(guarded, hides,
			"every hide must first invalidate any pending render (" .. guarded .. "/" .. hides
				.. "). One that does not lets a render armed a tick earlier put the tooltip back "
				.. "on screen after the user dismissed it")
	end)

	helpers.it("reset_predictions invalidates too", function()
		local src = helpers.read_driver_source("_preview_render_generation")
		local code = src:gsub("%-%-[^\n]*", "")
		local at = code:find("function M.reset_predictions", 1, true)
		helpers.assert_true(at ~= nil, "reset_predictions must exist")

		local body = code:sub(at, at + 400)
		helpers.assert_true(body:find("invalidate_pending_preview", 1, true) ~= nil,
			"reset_predictions is the Escape trap's dismissal path — it must drop a pending "
				.. "render as well, or Escape hides the tooltip and the deferral brings it back")
	end)
end)

