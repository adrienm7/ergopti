--- tests/unit/ui/test_tooltip_nav_deferred.lua

--- ==============================================================================
--- MODULE: Regression — tooltip navigation defers its AX-bearing render off the tap
--- DESCRIPTION:
--- Audit finding F-M9. The LLM-prediction tooltip's keyDown eventtap called
--- M.navigate() SYNCHRONOUSLY on Shift+Tab and arrow navigation. M.navigate ->
--- Renderer.render -> resolve_anchor runs synchronous cross-process accessibility
--- queries (AXFocusedUIElement / AXBoundsForRange). Against a hung / beach-balling
--- focused app those block the HID/eventtap thread for the AX timeout, tripping
--- kCGEventTapDisabledByTimeout — macOS then disables the tap and keystrokes leak
--- straight through until it re-enables. This violates project-macos-eventtap-no-blocking.
---
--- Fix: defer the navigate/re-render through SyntheticInput's retained
--- post-eventtap FIFO so the heavy AX work runs after the HID callback. The
--- companion action-epoch test drives the callback; this class guard enumerates
--- BOTH navigation call sites so a newly added sibling cannot bypass the FIFO.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("tooltip_llm navigation is deferred off the eventtap thread", function()
	local function read_src()
		-- Selected by a declaration unique to ui/tooltip/tooltip_llm.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function refresh_chain_timing")
		helpers.assert_true(src ~= nil, "ui/tooltip/tooltip_llm.lua source must be locatable")
		return src
	end

	helpers.it("(tooltip-navigation-deferred) Shift+Tab navigation uses the retained post-eventtap FIFO", function()
		local src = read_src()
		local label_at = src:find('"LLM tooltip Shift-Tab navigation"', 1, true)
		helpers.assert_not_nil(label_at, "Shift+Tab must enter the retained deferred-action API")
		local branch = src:sub(math.max(1, label_at - 100), label_at + 100)
		helpers.assert_true(branch:find("defer_navigation(", 1, true) ~= nil
			and branch:find("direction", 1, true) ~= nil,
			"the Shift+Tab direction must be committed by the deferred renderer path")
	end)

	helpers.it("(tooltip-navigation-deferred) arrow navigation uses the retained post-eventtap FIFO", function()
		local src = read_src()
		local label_at = src:find('"LLM tooltip arrow navigation"', 1, true)
		helpers.assert_not_nil(label_at, "arrow navigation must enter the retained deferred-action API")
		local branch = src:sub(math.max(1, label_at - 100), label_at + 100)
		helpers.assert_true(branch:find("defer_navigation(", 1, true) ~= nil
			and branch:find("nav_direction", 1, true) ~= nil,
			"the arrow direction must be committed by the deferred renderer path")
	end)

	helpers.it("(tooltip-navigation-deferred) every navigation call in the eventtap belongs to a deferred action", function()
		local src = read_src()
		-- Isolate the keyDown watcher body (from its creation to start_watchers' end).
		local s = src:find("event_types.keyDown", 1, true)
		helpers.assert_true(s ~= nil, "could not locate the keyDown watcher")
		local body = src:sub(s, s + 7000):gsub("%-%-[^\n]*", "")
		local count, pos = 0, 1
		while true do
			local at = body:find("defer_navigation(", pos, true)
			if not at then break end
			count = count + 1
			pos = at + 1
		end
		helpers.assert_eq(count, 2,
			"the guard must enumerate both current navigation branches")
		local helper_start = src:find("local function defer_navigation", 1, true)
		local helper_body = helper_start and src:sub(helper_start, helper_start + 1000) or ""
		helpers.assert_true(helper_body:find("defer_runtime_action(label", 1, true) ~= nil
			and helper_body:find("return render_navigation()", 1, true) ~= nil,
			"defer_navigation may commit O(1) state inline, but its AX/canvas render must use the retained FIFO")
	end)
end)
