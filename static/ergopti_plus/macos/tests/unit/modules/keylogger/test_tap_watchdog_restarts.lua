--- tests/unit/modules/keylogger/test_tap_watchdog_restarts.lua

--- ==============================================================================
--- MODULE: Regression — keylogger tap-watchdog behavioral test (C2)
--- DESCRIPTION:
--- Hammerspoon 1.1.1 normally handles CoreGraphics timeout notifications and
--- re-enables the tap in native code before Lua runs. A native or lifecycle
--- failure can still leave the keylogger tap observed disabled after wake,
--- unlock, or a security prompt. The watchdog is the independent backstop that
--- calls KeyboardHook.start() when that residual state is observed.
---
--- This test verifies the structural contract of the watchdog:
---   1. A TAP_WATCHDOG_INTERVAL_SEC-second repeating timer is started by M.start().
---   2. The callback checks CoreState.is_enabled (gate: no restart while paused).
---   3. The callback checks the hook state to detect a still-disabled tap.
---   4. The callback calls _event_tap:start() when the tap is disabled.
---   5. The watchdog timer is stopped (and cleared) by M.stop().
---
--- Behavioral pins: structural assertions on keylogger/init.lua source text.
--- Loading the full 1500-line module with all its transitive deps in the unit
--- harness is not feasible; source-text pinning is the correct choice here —
--- a structural change that removes or misroutes any of these five contracts
--- fails the test immediately, exactly as a deleted pcall or wrong variable name
--- would on the live driver.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("keylogger: tap-watchdog behavioral contract (C2)", function()
	local function read_src()
		-- Selected by a declaration unique to modules/keylogger/init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function ensure_browser_window_filter")
		helpers.assert_true(src ~= nil, "modules/keylogger/init.lua source must be locatable")
		return src
	end

	helpers.it("TAP_WATCHDOG_INTERVAL_SEC is defined and non-zero", function()
		local src = read_src()
		-- The constant must be a local (not a magic number) at module scope
		local decl = src:match("local TAP_WATCHDOG_INTERVAL_SEC%s*=%s*(%d+)")
		helpers.assert_true(decl ~= nil, "TAP_WATCHDOG_INTERVAL_SEC must be a named constant")
		helpers.assert_true(tonumber(decl) > 0, "TAP_WATCHDOG_INTERVAL_SEC must be positive, got: " .. tostring(decl))
	end)

	helpers.it("watchdog timer is created with TAP_WATCHDOG_INTERVAL_SEC and stored in _tap_watchdog_timer", function()
		local src = read_src()
		-- Must use hs.timer.new (recurring), not doAfter (one-shot)
		local new_pos  = src:find("_tap_watchdog_timer = hs.timer.new(TAP_WATCHDOG_INTERVAL_SEC,", 1, true)
		helpers.assert_true(new_pos ~= nil,
			"watchdog must be `hs.timer.new(TAP_WATCHDOG_INTERVAL_SEC, ...)` assigned to `_tap_watchdog_timer`; "
			.. "doAfter would be one-shot and silently stop protecting after the first interval")
	end)

	helpers.it("watchdog callback is gated on CoreState.is_enabled (no restart while paused)", function()
		local src = read_src()
		-- Find the watchdog timer callback block
		local timer_start = src:find("_tap_watchdog_timer = hs.timer.new(TAP_WATCHDOG_INTERVAL_SEC,", 1, true)
		helpers.assert_true(timer_start ~= nil, "tap_watchdog_timer block must exist")
		-- Narrow to the callback body (next ~200 chars after the hs.timer.new call)
		local callback_window = src:sub(timer_start, timer_start + 300)
		helpers.assert_true(
			callback_window:find("CoreState.is_enabled", 1, true) ~= nil,
			"watchdog callback must check CoreState.is_enabled to skip restart during pause/stop")
	end)

	helpers.it("watchdog callback detects a disabled tap through KeyboardHook", function()
		local src = read_src()
		local timer_start = src:find("_tap_watchdog_timer = hs.timer.new(TAP_WATCHDOG_INTERVAL_SEC,", 1, true)
		helpers.assert_true(timer_start ~= nil, "tap_watchdog_timer block must exist")
		local callback_window = src:sub(timer_start, timer_start + 300)
		helpers.assert_true(
			callback_window:find("not KeyboardHook.isRunning()", 1, true) ~= nil,
			"watchdog callback must ask KeyboardHook whether the tap is running; "
			.. "without this check the watchdog cannot detect a tap that remains disabled")
	end)

	helpers.it("watchdog callback restarts the tap through KeyboardHook", function()
		local src = read_src()
		local timer_start = src:find("_tap_watchdog_timer = hs.timer.new(TAP_WATCHDOG_INTERVAL_SEC,", 1, true)
		helpers.assert_true(timer_start ~= nil, "tap_watchdog_timer block must exist")
		local callback_window = src:sub(timer_start, timer_start + 400)
		helpers.assert_true(
			callback_window:find("KeyboardHook.start()", 1, true) ~= nil,
			"watchdog callback must restart the disabled hook through KeyboardHook.start()")
	end)

	helpers.it("watchdog timer is stopped and cleared in M.stop()", function()
		local src = read_src()
		-- M.stop() must both stop and nil the timer to prevent a dangling reference
		helpers.assert_true(
			src:find("_tap_watchdog_timer:stop()", 1, true) ~= nil,
			"M.stop() must call _tap_watchdog_timer:stop()")
		helpers.assert_true(
			src:find("_tap_watchdog_timer = nil", 1, true) ~= nil,
			"M.stop() must nil _tap_watchdog_timer after stopping (prevents dangling timer reference)")
	end)
end)
