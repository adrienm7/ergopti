--- tests/unit/lib/test_healthcheck_webview.lua

--- ==============================================================================
--- MODULE: healthcheck Dead Webview Regression Tests
--- DESCRIPTION:
--- Source-level guard for the "healthcheck-webview-dead-userdata" bug in
--- lib/healthcheck.lua.
---
--- ROOT CAUSE ENCODED:
--- The 200 ms poll timer called wv:evaluateJavaScript() with only an `if not wv`
--- nil-check before it. However, when macOS closes the webview natively (e.g. the
--- user clicks the OS window-close button), the Hammerspoon `wv` reference is NOT
--- set to nil — it becomes "dead userdata": a stale Lua object whose underlying
--- C struct has been freed. Any method call on dead userdata raises a Lua error.
--- Without a pcall, this error was raised every 200 ms indefinitely, crashing
--- the Hammerspoon runtime with no recovery path short of a force-quit.
---
--- The fix: wrap wv:evaluateJavaScript() in pcall(); on failure, log a warning
--- and call _stop_poll() so the timer disarms itself immediately.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===================================================================================================
-- ==================================================================================================
-- ======= 1/ evaluateJavaScript call is wrapped in pcall (healthcheck-webview-dead-userdata) =======
-- ==================================================================================================
-- ===================================================================================================

helpers.describe("healthcheck — evaluateJavaScript pcall guard (healthcheck-webview-dead-userdata)", function()

	local function read_source()
		-- After the F2 split, the webview poll-timer logic lives in core.lua.
		-- Selected by a declaration unique to ui/healthcheck/core.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function _stop_poll")
		helpers.assert_true(src ~= nil, "ui/healthcheck/core.lua source must be locatable")
		return src
	end

	helpers.it("evaluateJavaScript is wrapped inside a pcall", function()
		local src = read_source()
		-- Locate the pcall wrapping the evaluateJavaScript call
		local pcall_pos = src:find("pcall(function()", 1, true)
		helpers.assert_true(pcall_pos ~= nil, "healthcheck.lua must have at least one pcall wrapper")
		-- The evaluateJavaScript call must appear after the pcall opening
		local js_pos = src:find("evaluateJavaScript", pcall_pos or 1, true)
		helpers.assert_true(
			js_pos ~= nil and js_pos > (pcall_pos or 0),
			"evaluateJavaScript must appear inside a pcall block (healthcheck-webview-dead-userdata)"
		)
	end)

	helpers.it("pcall failure stops the poll timer", function()
		local src = read_source()
		-- After the pcall the code must call _stop_poll() when ok_ev is false
		helpers.assert_true(
			src:find("not ok_ev", 1, true) ~= nil,
			"healthcheck.lua must check 'not ok_ev' after the pcall (healthcheck-webview-dead-userdata)"
		)
		local not_ok_pos = src:find("not ok_ev", 1, true)
		local stop_pos   = src:find("_stop_poll()", not_ok_pos or 1, true)
		helpers.assert_true(
			stop_pos ~= nil and stop_pos > (not_ok_pos or 0),
			"_stop_poll() must be called after detecting a dead webview (healthcheck-webview-dead-userdata)"
		)
	end)

end)
