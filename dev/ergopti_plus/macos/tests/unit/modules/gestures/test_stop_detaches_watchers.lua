--- tests/unit/modules/gestures/test_stop_detaches_watchers.lua

--- ==============================================================================
--- MODULE: gestures M.stop() Watcher Detachment Regression Tests
--- DESCRIPTION:
--- Regression suite that verifies M.stop() tears down every gesture watcher
--- and marks the module as disabled. Specifically guards against the failure
--- mode where watcher stop() calls are silently skipped, leaving dangling
--- subscriptions that continue to fire frame callbacks after teardown.
---
--- FEATURES & RATIONALE:
--- 1. Mock Watcher Injection: Watchers are injected via _G.ERGOPTI_TOUCH_WATCHERS
---    (the same global table the module aliases as its local touch_watchers), so
---    M.stop() operates on our controlled objects without needing a real trackpad.
--- 2. Running-State Tracking: Each mock watcher exposes running() mirroring the
---    real touchdevice watcher API — stop() flips it to false so assertions read
---    the same field the module itself would inspect.
--- 3. Enabled-Flag Guard: CoreState.enabled is observable only via M.is_enabled();
---    the test asserts it is false after M.stop() so the dispatch gate is closed.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =======================================
-- =======================================
-- ======= 1/ Module Setup & Stubs =======
-- =======================================
-- =======================================

-- Stub the sub-modules before loading gestures so they do not attempt real OS calls
package.loaded["lib.logger"] = nil
helpers.load_with_stubs("lib.logger")

package.loaded["modules.gestures.actions"] = {
	AX_NAMES             = {},
	SG_NAMES             = {},
	init                 = function() end,
	get_sg_names         = function() return {} end,
	get_label            = function() return "" end,
	force_cleanup        = function() end,
	toggle_right_click   = function() end,
	trigger_lookup       = function() end,
	is_right_click_held  = function() return false end,
}

package.loaded["modules.gestures.engine"] = {
	init          = function() end,
	process_frame = function() end,
}

package.loaded["modules.gestures.conflicts"] = {
	on_action_changed    = function() end,
	apply_all_overrides  = function() end,
	restore_all_overrides = function() end,
}

-- Reset the module so each describe block starts from a clean state
package.loaded["modules.gestures"] = nil

local Gestures = helpers.load_with_stubs("modules.gestures")





-- =======================================
-- =======================================
-- ======= 2/ Mock Watcher Factory =======
-- =======================================
-- =======================================

--- Creates a mock touchdevice watcher object.
--- The watcher starts in running state; stop() sets running to false,
--- mirroring the contract of the real hs._asm touchdevice watcher.
--- @return table Mock watcher with running(), stop(), and alive() methods.
local function make_mock_watcher()
	local w = { _running = true, stop_called = 0 }
	function w:running() return self._running end
	function w:alive()   return self._running end
	function w:stop()
		self.stop_called = self.stop_called + 1
		self._running = false
	end
	function w:start()
		self._running = true
	end
	return w
end

--- Clears the module's live watcher and device tables in-place.
--- The module aliases _G.ERGOPTI_TOUCH_WATCHERS and _G.ERGOPTI_TOUCH_DEVICES
--- into local variables at load time — replacing the globals with a new table
--- does not update those locals. We must clear the EXISTING table objects so
--- that subsequent key assignments reach the same table the module holds.
--- @param watcher_ids_to_remove table|nil Array of integer device IDs to remove.
local function clear_live_tables(watcher_ids_to_remove)
	-- Wipe all entries currently in the module's live watcher table
	for k in pairs(_G.ERGOPTI_TOUCH_WATCHERS) do
		_G.ERGOPTI_TOUCH_WATCHERS[k] = nil
	end
	-- Wipe all entries currently in the module's live device table
	for k in pairs(_G.ERGOPTI_TOUCH_DEVICES) do
		_G.ERGOPTI_TOUCH_DEVICES[k] = nil
	end
end





-- ===========================================
-- ===========================================
-- ======= 3/ Watcher Detachment Tests =======
-- ===========================================
-- ===========================================

helpers.describe("M.stop() detaches all gesture watchers", function()
	helpers.it("stop() calls stop() on every injected watcher", function()
		-- Clear the live tables that the module alias already points at;
		-- assigning a fresh table to the global would bypass the module's local
		clear_live_tables()

		local w1 = make_mock_watcher()
		local w2 = make_mock_watcher()

		-- Inject watchers under arbitrary device IDs matching the module's table layout
		_G.ERGOPTI_TOUCH_WATCHERS[1001] = w1
		_G.ERGOPTI_TOUCH_WATCHERS[1002] = w2

		Gestures.stop()

		-- Each watcher must have had stop() called exactly once
		helpers.assert_eq(w1.stop_called, 1, "watcher 1001: stop() call count")
		helpers.assert_eq(w2.stop_called, 1, "watcher 1002: stop() call count")
	end)

	helpers.it("all injected watchers report running() == false after M.stop()", function()
		clear_live_tables()

		local watchers = {}
		for i = 1, 3 do
			local w = make_mock_watcher()
			_G.ERGOPTI_TOUCH_WATCHERS[2000 + i] = w
			watchers[i] = w
		end

		Gestures.stop()

		for i, w in ipairs(watchers) do
			helpers.assert_eq(
				w:running(),
				false,
				"watcher " .. tostring(2000 + i) .. ": running() must be false after M.stop()"
			)
		end
	end)

	helpers.it("touch_watchers table is empty after M.stop()", function()
		clear_live_tables()

		_G.ERGOPTI_TOUCH_WATCHERS[3001] = make_mock_watcher()
		_G.ERGOPTI_TOUCH_WATCHERS[3002] = make_mock_watcher()

		Gestures.stop()

		-- recycle_watchers(false) nils every entry — the shared global is now empty
		local count = 0
		for _ in pairs(_G.ERGOPTI_TOUCH_WATCHERS) do count = count + 1 end
		helpers.assert_eq(count, 0, "ERGOPTI_TOUCH_WATCHERS must be empty after M.stop()")
	end)

	helpers.it("M.stop() is safe when no watchers are registered", function()
		clear_live_tables()

		-- Must not raise with an empty watcher table
		local ok = pcall(Gestures.stop)
		helpers.assert_true(ok, "M.stop() must not throw when touch_watchers is empty")
	end)
end)





-- =========================================
-- =========================================
-- ======= 4/ CoreState Enabled Flag =======
-- =========================================
-- =========================================

helpers.describe("M.stop() clears CoreState.enabled", function()
	helpers.it("is_enabled() returns false immediately after M.stop()", function()
		clear_live_tables()

		-- Restore the enabled flag first so the test does not depend on prior state
		Gestures.enable_all()
		helpers.assert_eq(Gestures.is_enabled(), true, "precondition: module must be enabled before stop()")

		Gestures.stop()

		helpers.assert_eq(
			Gestures.is_enabled(),
			false,
			"is_enabled() must return false after M.stop()"
		)
	end)

	helpers.it("enabled flag stays false even when watchers were already empty", function()
		clear_live_tables()

		Gestures.enable_all()
		Gestures.stop()

		helpers.assert_eq(Gestures.is_enabled(), false, "CoreState.enabled must be false after M.stop() with no watchers")
	end)

	helpers.it("enabled flag is false regardless of watcher count", function()
		clear_live_tables()

		-- Populate with three mock watchers
		for i = 1, 3 do
			_G.ERGOPTI_TOUCH_WATCHERS[4000 + i] = make_mock_watcher()
		end

		Gestures.enable_all()
		Gestures.stop()

		helpers.assert_eq(Gestures.is_enabled(), false, "CoreState.enabled must be false after M.stop() with multiple watchers")
	end)
end)





-- ====================================
-- ====================================
-- ======= 5/ Idempotence Guard =======
-- ====================================
-- ====================================

helpers.describe("M.stop() idempotence", function()
	helpers.it("calling M.stop() twice does not raise", function()
		clear_live_tables()

		_G.ERGOPTI_TOUCH_WATCHERS[5001] = make_mock_watcher()

		local ok1 = pcall(Gestures.stop)
		local ok2 = pcall(Gestures.stop)

		helpers.assert_true(ok1, "first M.stop() must not throw")
		helpers.assert_true(ok2, "second M.stop() must not throw")
		helpers.assert_eq(Gestures.is_enabled(), false, "CoreState.enabled must remain false after double stop()")
	end)
end)
