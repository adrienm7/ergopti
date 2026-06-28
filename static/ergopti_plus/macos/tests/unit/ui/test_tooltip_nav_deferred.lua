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
--- Fix: defer the navigate/re-render via hs.timer.doAfter(0, ...) so the heavy AX
--- work runs on the next runloop tick, off the HID thread. Driving the full tooltip
--- + AX stack is impractical here, so the deferral is pinned at source: BOTH nav
--- call sites must go through doAfter(0), never a bare synchronous M.navigate.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("tooltip_llm navigation is deferred off the eventtap thread", function()
	local function read_src()
		local path = helpers.driver_root() .. "ui/tooltip/tooltip_llm.lua"
		local fh = assert(io.open(path, "r"))
		local src = fh:read("*a"); fh:close()
		return src
	end

	helpers.it("Shift+Tab navigation defers M.navigate via doAfter(0)", function()
		local src = read_src()
		helpers.assert_true(src:find("doAfter(0, function() M.navigate(direction)", 1, true) ~= nil,
			"Shift+Tab must defer M.navigate(direction) via hs.timer.doAfter(0, ...)")
	end)

	helpers.it("arrow navigation defers M.navigate via doAfter(0)", function()
		local src = read_src()
		helpers.assert_true(src:find("doAfter(0, function() M.navigate(nav_direction)", 1, true) ~= nil,
			"arrow navigation must defer M.navigate(nav_direction) via hs.timer.doAfter(0, ...)")
	end)

	helpers.it("the eventtap handler makes NO bare synchronous M.navigate call", function()
		local src = read_src()
		-- Isolate the keyDown watcher body (from its creation to start_watchers' end).
		local s = src:find("event_types.keyDown", 1, true)
		helpers.assert_true(s ~= nil, "could not locate the keyDown watcher")
		local body = src:sub(s, s + 2500)
		-- Inside the tap, every M.navigate must be wrapped in a doAfter(0) closure;
		-- a bare `\n<tabs>M.navigate(` (statement position) would run on the HID thread.
		helpers.assert_true(body:find("\n%s*M%.navigate%(") == nil,
			"the keyDown eventtap must not call M.navigate synchronously (blocking AX on the HID thread)")
	end)
end)
