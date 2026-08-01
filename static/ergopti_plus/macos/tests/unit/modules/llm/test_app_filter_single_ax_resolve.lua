--- tests/unit/modules/llm/test_app_filter_single_ax_resolve.lua

--- ==============================================================================
--- MODULE: Regression — is_blocked must resolve the focused AX element once
--- DESCRIPTION:
--- app_filter.is_blocked runs inside the keyDown eventtap callback. Its two
--- filters — secure-field and URL-bar — each called get_focused_element(front)
--- independently, so a browser with both enabled paid the cross-process
--- Accessibility round-trip TWICE for every accepted prediction.
---
--- Cumulative AX latency inside a tap callback is exactly what gets a CGEventTap
--- disabled by macOS (kCGEventTapDisabledByTimeout), and this driver has already
--- been bitten by that class twice (infra/vscode_bridge's frame cache, the wrap-text
--- selection cache). Halving the traffic is the smallest correct step.
---
--- The resolver is LAZY on purpose: the combinations that resolve nothing today —
--- secure filter off with a non-browser frontmost, for instance — must keep paying
--- nothing, so a fix that resolved eagerly at the top of is_blocked would be a
--- regression for them. Both directions are asserted.
---
--- NOTE ON SCOPE: this removes the DUPLICATE resolution. A cross-keystroke cache
--- (the TTL pattern in infra/vscode_bridge, or the event-driven invalidation in
--- keymap/utils) would remove the rest, and is deliberately left as separate work
--- rather than smuggled into a latency fix.
--- ==============================================================================

local helpers = require("tests.helpers")

-- A bundle id present in the module's BROWSER_BUNDLE_IDS table.
local BROWSER_BUNDLE = "com.apple.Safari"




-- ==============================================
-- ==============================================
-- ======= 1/ Counting AX Resolutions ===========
-- ==============================================
-- ==============================================

--- Loads app_filter with an AX tree that counts focused-element resolutions.
--- @param bundle string Bundle id reported by the frontmost app.
--- @return table filter, table counter, userdata front
local function load_filter(bundle)
	local counter = { resolves = 0 }

	local element = {
		attributeValue = function(_self, attr)
			if attr == "AXRole" then return "AXTextField" end
			return nil
		end,
	}
	local app_element = {
		attributeValue = function(_self, attr)
			if attr == "AXFocusedUIElement" then
				counter.resolves = counter.resolves + 1
				return element
			end
			return nil
		end,
	}

	-- is_blocked resolves the frontmost app itself via hs.application, so the stub
	-- must supply it there rather than through the state argument.
	local front = {
		bundleID = function() return bundle end,
		title    = function() return "Safari" end,
		pid      = function() return 4242 end,
		name     = function() return "Safari" end,
		path     = function() return "/Applications/Safari.app" end,
	}

	package.loaded["modules.llm.app_filter"] = nil
	local AF = helpers.load_with_stubs("modules.llm.app_filter", {
		application = {
			frontmostApplication = function() return front end,
			watcher = { activated = 1 },
		},
		axuielement = {
			applicationElementForPID = function(_pid) return app_element end,
			applicationElement       = function(_pid) return app_element end,
		},
	})

	return AF, counter, front
end




-- ==============================================
-- ==============================================
-- ======= 2/ Once, And Only When Needed ========
-- ==============================================
-- ==============================================

helpers.describe("app_filter resolves the focused element at most once per call", function()
	helpers.it("does not resolve twice when both filters are enabled", function()
		local AF, counter, front = load_filter(BROWSER_BUNDLE)

		AF.is_blocked({ frontmost = front }, {}, true, true)

		helpers.assert_true(counter.resolves <= 1, string.format(
			"is_blocked must resolve the focused AX element at most once per call, got %d. "
			.. "This runs inside the keyDown eventtap, and cumulative cross-process AX "
			.. "latency there is what gets the tap disabled by macOS", counter.resolves))
	end)

	helpers.it("does not resolve at all when neither filter needs it", function()
		-- Laziness matters: the combinations that pay nothing today must keep paying
		-- nothing, so an eager resolve at the top of is_blocked would be a regression.
		local AF, counter, front = load_filter(BROWSER_BUNDLE)

		AF.is_blocked({ frontmost = front }, {}, false, false)

		helpers.assert_eq(counter.resolves, 0,
			"with both filters disabled nothing needs the focused element, so no AX "
			.. "round-trip may happen at all")
	end)
end)
