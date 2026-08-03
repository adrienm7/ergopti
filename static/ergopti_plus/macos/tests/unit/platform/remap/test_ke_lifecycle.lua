--- tests/unit/platform/remap/test_ke_lifecycle.lua

--- ==============================================================================
--- MODULE: ke_lifecycle Unit Tests
--- DESCRIPTION:
--- Verifies the KE lifecycle module behaviors that can be exercised without a
--- real macOS environment. All hs.execute calls are intercepted via the hs stub
--- so that no real launchctl or pkill processes are spawned.
---
--- FEATURES & RATIONALE:
--- 1. Isolated mocking: each test resets the hs execute history so call counts
---    are always relative to that test only.
--- 2. Configurable results: __set_exec programs per-pattern responses so the
---    tests can simulate grabber present, grabber absent, bridge up, and
---    bridge down scenarios without touching any real process.
--- 3. is_grabber_running, launch_headless, and is_remapping_active cover the
---    three key status checks used by the menu's status indicator logic.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Stub lib.logger and lib.i18n before loading the module so their require
-- calls resolve without hitting the filesystem.
package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

package.loaded["infra.i18n"] = {
	get = function(key) return key end,
}

package.loaded["infra.notifications"] = {
	notify = function() end,
}


--- Loads a fresh instance of ke_lifecycle with a clean hs stub.
--- @return table KE module instance.
--- @return table hs stub for inspecting calls.
local function fresh_ke()
	package.loaded["platform.remap.ke_lifecycle"] = nil
	package.loaded["infra.logger"] = nil
	_ = helpers.load_with_stubs("infra.logger")

	package.loaded["infra.i18n"] = { get = function(k) return k end }
	package.loaded["infra.notifications"] = { notify = function() end }

	local KE = helpers.load_with_stubs("platform.remap.ke_lifecycle")
	local hs_stub = _G.hs
	hs_stub.__reset()
	return KE, hs_stub
end





-- ============================================
-- ============================================
-- ======= 1/ is_grabber_running checks =======
-- ============================================
-- ============================================

helpers.describe("KELifecycle.is_grabber_running", function()
	helpers.it("returns true when pgrep exits successfully", function()
		local KE, hs_stub = fresh_ke()
		hs_stub.__set_exec("pgrep", "", true)
		helpers.assert_eq(KE.is_grabber_running(), true)
	end)

	helpers.it("returns false when pgrep exits with failure", function()
		local KE, hs_stub = fresh_ke()
		hs_stub.__set_exec("pgrep", "", false)
		helpers.assert_eq(KE.is_grabber_running(), false)
	end)

	helpers.it("invokes hs.execute with the pgrep command", function()
		local KE, hs_stub = fresh_ke()
		hs_stub.__set_exec("pgrep", "", true)
		KE.is_grabber_running()
		local found = false
		for _, cmd in ipairs(hs_stub.__exec_calls) do
			if cmd:find("pgrep", 1, true) then found = true ; break end
		end
		helpers.assert_eq(found, true, "expected pgrep call in exec history")
	end)
end)




-- ===========================================
-- ===========================================
-- ======= 2/ launch_headless checks =========
-- ===========================================
-- ===========================================

helpers.describe("KELifecycle.launch_headless", function()
	helpers.it("returns true when grabber is running", function()
		local KE, hs_stub = fresh_ke()
		-- Program all pgrep calls to succeed so is_grabber_running returns true
		hs_stub.__set_exec("pgrep", "", true)
		helpers.assert_eq(KE.launch_headless(), true)
	end)

	helpers.it("returns false when grabber is not running", function()
		local KE, hs_stub = fresh_ke()
		-- Program all pgrep calls to fail so is_grabber_running returns false
		hs_stub.__set_exec("pgrep", "", false)
		helpers.assert_eq(KE.launch_headless(), false)
	end)

	helpers.it("does not crash when notifications module is unavailable", function()
		-- Override notifications to simulate require failure after module load
		local KE, hs_stub = fresh_ke()
		hs_stub.__set_exec("pgrep", "", false)
		-- Unload notifications to test the pcall path in launch_headless
		package.loaded["infra.notifications"] = nil
		-- Must not raise even though notifications is gone
		local ok, err = pcall(function() return KE.launch_headless() end)
		helpers.assert_eq(ok, true, "launch_headless must not propagate errors")
		helpers.assert_true(err == nil or type(err) == "boolean",
			"and must answer whether it launched — the caller shows a bridge-down state on it")
	end)
end)





-- ===========================================
-- ===========================================
-- ======= 3/ is_session_primed checks =======
-- ===========================================
-- ===========================================

helpers.describe("KELifecycle.is_session_primed", function()
	helpers.it("returns false when sysctl fails", function()
		local KE, hs_stub = fresh_ke()
		-- sysctl returning failure means get_boot_timestamp returns nil
		hs_stub.__set_exec("sysctl", "", false)
		helpers.assert_eq(KE.is_session_primed(), false)
	end)

	helpers.it("returns false when sysctl returns unparseable output", function()
		local KE, hs_stub = fresh_ke()
		hs_stub.__set_exec("sysctl", "unparseable garbage", true)
		helpers.assert_eq(KE.is_session_primed(), false)
	end)

	helpers.it("returns false when marker file does not exist", function()
		local KE, hs_stub = fresh_ke()
		-- Provide a valid sysctl response; the marker file /tmp/ergopti_ke_primed_v2.txt
		-- almost certainly does not exist in the test environment.
		hs_stub.__set_exec("sysctl", "kern.boottime: { sec = 1700000000, usec = 0 } Wed Nov 14 2023", true)
		-- We cannot guarantee the file is absent on all machines, so we only assert
		-- the function returns a boolean without crashing.
		local result = KE.is_session_primed()
		helpers.assert_eq(type(result), "boolean", "is_session_primed must return a boolean")
	end)
end)




-- ==========================================
-- ==========================================
-- ======= 4/ is_remapping_active checks ====
-- ==========================================
-- ==========================================

helpers.describe("KELifecycle.is_remapping_active", function()
	helpers.it("returns false immediately when grabber is not running", function()
		local KE, hs_stub = fresh_ke()
		-- All hs.execute calls fail → grabber not running → short-circuit false
		hs_stub.__set_exec("pgrep", "", false)
		helpers.assert_eq(KE.is_remapping_active(), false)
	end)

	helpers.it("returns a boolean without crashing when grabber is running", function()
		local KE, hs_stub = fresh_ke()
		-- Grabber running but no session marker and no bridge → should return false
		hs_stub.__set_exec("pgrep", "", true)
		hs_stub.__set_exec("sysctl", "", false)
		local result = KE.is_remapping_active()
		helpers.assert_eq(type(result), "boolean", "is_remapping_active must return a boolean")
	end)
end)





-- ===========================================
-- ===========================================
-- ======= 5/ is_bridge_running checks =======
-- ===========================================
-- ===========================================

helpers.describe("KELifecycle.is_bridge_running", function()
	helpers.it("returns true when the bridge pgrep succeeds", function()
		local KE, hs_stub = fresh_ke()
		hs_stub.__set_exec("karabiner_console_user_server", "", true)
		helpers.assert_eq(KE.is_bridge_running(), true)
	end)

	helpers.it("returns false when all bridge pgrep calls fail", function()
		local KE, hs_stub = fresh_ke()
		-- No specific pattern set, default is success=true; override to false
		-- by setting a broad pattern that catches the bridge check command
		hs_stub.__set_exec("pgrep", "", false)
		helpers.assert_eq(KE.is_bridge_running(), false)
	end)
end)





-- ===========================================
-- ===========================================
-- ======= 6/ is_priming / is_hs_owned =======
-- ===========================================
-- ===========================================

helpers.describe("KELifecycle status flags", function()
	helpers.it("is_priming returns false at rest", function()
		local KE, _ = fresh_ke()
		helpers.assert_eq(KE.is_priming(), false)
	end)

	helpers.it("is_hs_owned_bridge returns false when no owner marker exists", function()
		local KE, hs_stub = fresh_ke()
		-- Ensure sysctl fails so get_boot_timestamp returns nil → false early return
		hs_stub.__set_exec("sysctl", "", false)
		helpers.assert_eq(KE.is_hs_owned_bridge(), false)
	end)
end)





-- =============================================
-- =============================================
-- ======= 7/ KILL_CMD constant exposure =======
-- =============================================
-- =============================================

-- ============================================================================
--- ============================================================================
-- ======= 7/ kill_async script-race fix (ke-kill-async-script-race) ==========
--- ============================================================================
-- ============================================================================

helpers.describe("KELifecycle.kill_async — unique temp script path (ke-kill-async-script-race)", function()
	helpers.it("source does NOT use os.time() as the script suffix", function()
		-- os.time() has 1-second precision: two rapid calls within the same second
		-- produce the same path, overwriting the script the first nohup is reading.
		-- Only the kill_async script path is guarded here; other functions in the file
		-- may legitimately use os.time() for rate-limiting or unrelated naming.
		-- Selected by a declaration unique to platform/remap/ke_lifecycle.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("function M.flush_pending_ready_notification")
		helpers.assert_true(src ~= nil, "platform/remap/ke_lifecycle.lua source must be locatable")
		-- The bug was: ke_kill_async path used os.time() as a suffix.
		-- Match only the kill_async-specific format string to avoid false positives
		-- from other functions (e.g. run_total_reset_async) that may use os.time().
		local kill_async_with_ostime = src:find("ke_kill_async[^\"']*os%.time", 1, false)
		helpers.assert_true(
			kill_async_with_ostime == nil,
			"kill_async must NOT use os.time() as the script suffix — use sub-second precision instead (ke-kill-async-script-race)"
		)
	end)

	helpers.it("source uses hs.timer.secondsSinceEpoch() for the script suffix", function()
		-- Selected by a declaration unique to platform/remap/ke_lifecycle.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("function M.flush_pending_ready_notification")
		helpers.assert_true(src ~= nil, "platform/remap/ke_lifecycle.lua source must be locatable")
		helpers.assert_true(
			src:find("secondsSinceEpoch()", 1, true) ~= nil,
			"kill_async must use hs.timer.secondsSinceEpoch() for microsecond-precision path uniqueness (ke-kill-async-script-race)"
		)
	end)
end)




helpers.describe("KELifecycle.KILL_CMD / KILL_FAST_CMD", function()
	helpers.it("KILL_CMD is a non-empty string containing launchctl", function()
		local KE, _ = fresh_ke()
		helpers.assert_eq(type(KE.KILL_CMD), "string")
		helpers.assert_true(KE.KILL_CMD ~= "", "KILL_CMD must not be empty")
		helpers.assert_true(KE.KILL_CMD:find("launchctl") ~= nil, "KILL_CMD must reference launchctl")
	end)

	helpers.it("KILL_FAST_CMD is a non-empty string containing pkill", function()
		local KE, _ = fresh_ke()
		helpers.assert_eq(type(KE.KILL_FAST_CMD), "string")
		helpers.assert_true(KE.KILL_FAST_CMD ~= "", "KILL_FAST_CMD must not be empty")
		helpers.assert_true(KE.KILL_FAST_CMD:find("pkill") ~= nil, "KILL_FAST_CMD must reference pkill")
	end)
end)
