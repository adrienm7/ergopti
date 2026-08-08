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

	helpers.it("Shift+Tab navigation uses the retained post-eventtap FIFO", function()
		local src = read_src()
		local start = src:find('defer_runtime_action("LLM tooltip Shift-Tab navigation"', 1, true)
		helpers.assert_not_nil(start, "Shift+Tab must enter the retained deferred-action API")
		helpers.assert_true(src:sub(start, start + 300):find("M.navigate(direction)", 1, true) ~= nil,
			"the deferred Shift+Tab closure must own navigation")
	end)

	helpers.it("arrow navigation uses the retained post-eventtap FIFO", function()
		local src = read_src()
		local start = src:find('defer_runtime_action("LLM tooltip arrow navigation"', 1, true)
		helpers.assert_not_nil(start, "arrow navigation must enter the retained deferred-action API")
		helpers.assert_true(src:sub(start, start + 300):find("M.navigate(nav_direction)", 1, true) ~= nil,
			"the deferred arrow closure must own navigation")
	end)

	helpers.it("every navigation call in the eventtap belongs to a deferred action", function()
		local src = read_src()
		-- Isolate the keyDown watcher body (from its creation to start_watchers' end).
		local s = src:find("event_types.keyDown", 1, true)
		helpers.assert_true(s ~= nil, "could not locate the keyDown watcher")
		local body = src:sub(s, s + 7000):gsub("%-%-[^\n]*", "")
		local count, pos = 0, 1
		while true do
			local at = body:find("M.navigate(", pos, true)
			if not at then break end
			count = count + 1
			local prefix = body:sub(math.max(1, at - 300), at)
			helpers.assert_true(prefix:find("defer_runtime_action", 1, true) ~= nil,
				"navigation call " .. count .. " must remain inside a retained deferred action")
			pos = at + 1
		end
		helpers.assert_eq(count, 2,
			"the guard must enumerate both current navigation branches")
	end)
end)
