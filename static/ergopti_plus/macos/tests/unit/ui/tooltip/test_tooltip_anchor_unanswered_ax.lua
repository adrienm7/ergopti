--- tests/unit/ui/tooltip/test_tooltip_anchor_unanswered_ax.lua

--- ==============================================================================
--- MODULE: Tooltip anchor — an application that does not answer Accessibility
--- DESCRIPTION:
--- Each Accessibility read an application leaves unanswered holds the main
--- thread for the whole 0.5 s messaging timeout. The caret cascade asked up to
--- seven reads plus two focused-window reads per render, so the field run's
--- hotstring preview over Ergopti's own selftest window held the main thread
--- 2515 ms (2026-10-31 14:13:39). One render now stops at the first unanswered
--- read, the application is not asked again for a short cooldown, and this
--- process's own windows are never asked (tooltip-anchor-unanswered-ax).
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.tooltip_renderer_fixture")

--- Installs an Accessibility double whose every read is unanswered.
--- @param pid number Frontmost application's pid.
--- @return table counts { ax, windows }
local function unanswered_world(pid)
	local counts = { ax = 0, windows = 0 }
	local function unanswered()
		counts.ax = counts.ax + 1
		return nil, "Messaging failed"
	end
	local element = { attributeValue = unanswered, parameterizedAttributeValue = unanswered }
	package.loaded["hs.axuielement"] = { systemWideElement = function()
		return { attributeValue = function()
			counts.ax = counts.ax + 1
			return element
		end }
	end }
	hs.application.frontmostApplication = function() return { pid = function() return pid end } end
	hs.window.focusedWindow = function()
		counts.windows = counts.windows + 1
		return nil
	end
	return counts
end

helpers.describe("tooltip anchor with unanswered Accessibility (tooltip-anchor-unanswered-ax)", function()
	Fixture.it("stops at the first unanswered read and skips the focused-window read", function()
		helpers.with_stub_scope({ "hs.axuielement" }, function()
			local renderer = Fixture.load()
			require("adapters.accessibility_permission").reset_unanswered_for_tests()
			local counts = unanswered_world(4242)
			local anchor, screen = renderer.resolve_placement()
			helpers.assert_nil(anchor, "an unanswered caret falls back to the screen")
			helpers.assert_type(screen, "table")
			helpers.assert_eq(counts.ax, 2, "the focused element, then the first unanswered read only")
			helpers.assert_eq(counts.windows, 0, "the focused-window read would wait out the timeout too")

			renderer.resolve_placement()
			helpers.assert_eq(counts.ax, 2, "the unanswering application is not asked again during its cooldown")
			helpers.assert_eq(counts.windows, 0)
		end)
	end)

	Fixture.it("never asks this process's own windows", function()
		helpers.with_stub_scope({ "hs.axuielement" }, function()
			local renderer = Fixture.load()
			require("adapters.accessibility_permission").reset_unanswered_for_tests()
			local counts = unanswered_world(hs.processInfo.processID)
			local anchor = renderer.resolve_placement()
			helpers.assert_nil(anchor)
			helpers.assert_eq(counts.ax, 0, "this process's AX server answers on the thread that asks")
			helpers.assert_eq(counts.windows, 0)
		end)
	end)
end)
