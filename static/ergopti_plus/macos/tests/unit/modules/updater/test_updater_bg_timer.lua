--- tests/unit/modules/updater/test_updater_bg_timer.lua

--- ==============================================================================
--- MODULE: updater background-timer lifecycle (regression)
--- DESCRIPTION:
--- Locks down the lifecycle of the background update-check timers.
---
--- ROOT CAUSE ENCODED: M.start_background_checks() arms TWO timers — the recurring
--- hs.timer.doEvery (captured in _bg_timer) AND a one-shot hs.timer.doAfter boot
--- check. Only the doEvery was ever stored, so M.stop_background_checks() could
--- not cancel the pending boot check. After stop() (or a channel-switching
--- restart()), the orphaned doAfter would still fire background_tick on the
--- ORIGINAL channel closure — leaking a timer and running a check the user
--- disabled / re-targeted. The fix must track and stop the boot-check timer too.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads a fresh updater whose source reports a packaged (non-local) build so
--- that background checks actually arm.
local function fresh_packaged()
	package.loaded["modules.updater"] = nil
	-- TimerScheduler captures the current hs timer table and owns a live-handle
	-- registry, so every fresh updater fixture needs the matching fresh adapter
	package.loaded["adapters.timer_scheduler"] = nil
	return helpers.load_with_stubs("modules.updater", {
		processInfo = { bundleID = "com.ergopti.app", version = "1.0.0" },
	})
end

--- Counts how many timers in the hs stub are still flagged running.
local function running_timer_count()
	local n = 0
	for _, t in ipairs(_G.hs.timer.__timers) do
		if t.running then n = n + 1 end
	end
	return n
end

helpers.describe("updater: background timer lifecycle", function()
	helpers.it("stop_background_checks() cancels the boot-check timer too", function()
		local upd = fresh_packaged()
		upd.start_background_checks("stable", 100, function() end)
		-- Two timers armed: recurring doEvery + one-shot boot-check doAfter.
		helpers.assert_eq(running_timer_count(), 2, "two timers armed after start")
		upd.stop_background_checks()
		-- After stop, NO updater timer may remain running — otherwise the orphaned
		-- boot check fires after the feature was disabled.
		helpers.assert_eq(running_timer_count(), 0, "no timer left running after stop")
	end)

	helpers.it("restart does not leak the previous boot-check timer", function()
		local upd = fresh_packaged()
		upd.start_background_checks("stable", 100, function() end)
		upd.restart_background_checks("dev", 100, function() end)
		-- One full restart cycle => exactly one recurring + one boot timer alive,
		-- never the stale pair from the first start (which would be 3+).
		helpers.assert_eq(running_timer_count(), 2, "only the latest start's timers remain")
	end)
end)
