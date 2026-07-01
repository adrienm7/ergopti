--- tests/unit/modules/keymap/test_synthetic_reset_guard.lua

--- ==============================================================================
--- MODULE: Synthetic-Reset Guard Regression Tests
--- DESCRIPTION:
--- Regression tests for the synthetic-event filter race condition in
--- modules/keymap/init.lua (onKeyDownRaw). The old guard reset the
--- expected_synthetic_* counters as soon as (dt > 0.5 AND arm_age > 1.0),
--- regardless of whether there were still events in flight. Under extreme OS load
--- (synthetic injection delayed > 1 s) this caused character duplication.
---
--- Fix: the guard now only resets when there are no pending events (safe) OR when
--- the arm is older than SYNTHETIC_STALE_SEC = 5.0 s (cleanup of truly lost
--- events). Events in flight are never discarded prematurely.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Encodes the OLD (buggy) reset-guard condition.
--- @param dt number Seconds since last keystroke.
--- @param arm_age number Seconds since last arm_synthetic call.
--- @return boolean True if the reset would fire.
local function old_guard_fires(dt, arm_age)
	return dt > 0.5 and arm_age > 1.0
end

--- Encodes the FIXED reset-guard condition.
--- @param dt number Seconds since last keystroke.
--- @param arm_age number Seconds since last arm_synthetic call.
--- @param pending_deletes number Number of expected synthetic backspaces.
--- @param pending_chars string Expected synthetic characters not yet filtered.
--- @param STALE_SEC number Maximum arm age before forced cleanup.
--- @return boolean True if the reset should fire.
--- @param pending_pastes number|nil Expected synthetic Cmd+V echoes not yet filtered.
local function new_guard_fires(dt, arm_age, pending_deletes, pending_chars, STALE_SEC, pending_pastes)
	pending_pastes = pending_pastes or 0
	local events_in_flight = pending_deletes > 0 or #pending_chars > 0 or pending_pastes > 0
	return dt > 0.5 and (not events_in_flight or arm_age > STALE_SEC)
end




-- ================================================================
-- ================================================================
-- ======= 1/ Old Guard — Race Condition Demonstration ============
-- ================================================================
-- ================================================================

helpers.describe("synthetic reset guard old formula: demonstrates the race condition", function()
	helpers.it("fires when dt > 0.5 AND arm_age > 1.0, even with events in flight", function()
		-- Scenario: arm at t=0, user types at t=1.5 (dt from last key > 0.5)
		-- → arm_age = 1.5 > 1.0 → reset fires regardless of pending events
		local fires = old_guard_fires(0.9, 1.5)
		helpers.assert_eq(fires, true,
			"old guard fires at arm_age=1.5, discarding in-flight synthetic events")
	end)

	helpers.it("does NOT fire when arm_age is 0.8 s (within the old 1 s window)", function()
		local fires = old_guard_fires(0.9, 0.8)
		helpers.assert_eq(fires, false,
			"old guard: arm_age=0.8 is below the 1.0 s threshold — no reset")
	end)
end)





-- ================================================================
-- ================================================================
-- ======= 2/ Fixed Guard — No Reset While Events in Flight =======
-- ================================================================
-- ================================================================

helpers.describe("synthetic reset guard fixed formula: no reset with events in flight", function()
	local STALE = 5.0  -- SYNTHETIC_STALE_SEC

	helpers.it("does NOT reset when deletes are still pending (arm_age = 1.5 s)", function()
		-- arm_age > 1.0 s would have fired the old guard; new guard holds back
		local fires = new_guard_fires(0.9, 1.5, 3, "", STALE)
		helpers.assert_eq(fires, false,
			"with 3 pending deletes at arm_age=1.5 s the reset must not fire")
	end)

	helpers.it("does NOT reset when chars are still pending (arm_age = 2.0 s)", function()
		local fires = new_guard_fires(0.9, 2.0, 0, "hello", STALE)
		helpers.assert_eq(fires, false,
			"with pending chars at arm_age=2.0 s the reset must not fire")
	end)

	helpers.it("DOES reset when nothing is pending (safe to clean up)", function()
		local fires = new_guard_fires(0.9, 1.5, 0, "", STALE)
		helpers.assert_eq(fires, true,
			"with no pending events the reset is safe and should fire")
	end)

	helpers.it("DOES reset when arm_age exceeds STALE_SEC even with pending events", function()
		-- Truly lost events: arm_age > 5.0 s → force cleanup to recover the engine
		local fires = new_guard_fires(0.9, 5.1, 3, "abc", STALE)
		helpers.assert_eq(fires, true,
			"stale arm (age > 5 s) must force a cleanup reset even if items appear pending")
	end)

	helpers.it("does NOT reset when only a PASTE echo is pending (F-MED-1, arm_age = 1.5 s)", function()
		-- A 0-delete paste expansion (LLM completion / >50-cp hotstring) leaves
		-- deletes==0 and chars=="" — the paste counter is the ONLY in-flight marker.
		local fires = new_guard_fires(0.9, 1.5, 0, "", STALE, 1)
		helpers.assert_eq(fires, false,
			"with 1 pending paste echo at arm_age=1.5 s the reset must not fire (else the Cmd+V echo wipes the buffer)")
	end)

	helpers.it("DOES reset a stale pending paste once arm_age exceeds STALE_SEC", function()
		local fires = new_guard_fires(0.9, 5.1, 0, "", STALE, 1)
		helpers.assert_eq(fires, true,
			"a truly lost paste echo (arm_age > 5 s) must still be cleaned up")
	end)

	helpers.it("does NOT reset when dt <= 0.5 (user typing continuously)", function()
		-- The dt guard ensures we only reset during a genuine typing pause
		local fires = new_guard_fires(0.3, 6.0, 0, "", STALE)
		helpers.assert_eq(fires, false,
			"dt=0.3 s is below the 0.5 s pause threshold — no reset")
	end)

	helpers.it("race condition scenario: arm at t=0, delayed delivery at t=2.0 s", function()
		-- arm_synthetic at t=0 → expected_synthetic_chars = "hello"
		-- user types at t=1.5 (dt=1.5 > 0.5, arm_age=1.5 < 5.0)
		-- old guard: fires (arm_age > 1.0) → events arrive unfiltered → duplication
		-- new guard: does NOT fire (pending_chars="hello", arm_age=1.5 < STALE)
		local old_fires = old_guard_fires(1.5, 1.5)
		local new_fires = new_guard_fires(1.5, 1.5, 0, "hello", STALE)

		helpers.assert_eq(old_fires, true,  "old guard wrongly resets before delayed events arrive")
		helpers.assert_eq(new_fires, false, "new guard correctly holds back while events are in flight")
	end)
end)




-- ================================================================
-- ================================================================
-- ======= 3/ Source Guard — Fix Permanence ======================
-- ================================================================
-- ================================================================

helpers.describe("synthetic reset guard: production source contains the fix", function()
	helpers.it("init.lua defines SYNTHETIC_STALE_SEC", function()
		local driver_root = helpers.driver_root()
		local src_path    = driver_root .. "modules/keymap/init.lua"
		local fh          = io.open(src_path, "r")
		helpers.assert_true(fh ~= nil,
			"could not open init.lua at " .. tostring(src_path))
		local src = fh:read("*a")
		fh:close()

		helpers.assert_true(
			src:find("SYNTHETIC_STALE_SEC", 1, true) ~= nil,
			"source must define SYNTHETIC_STALE_SEC constant")

		helpers.assert_true(
			src:find("events_in_flight", 1, true) ~= nil,
			"source must check events_in_flight before resetting")

		-- F-MED-1: the in-flight predicate must count pastes too, or a 0-delete
		-- paste expansion (its echo the sole in-flight marker) is wiped on a stall.
		local eif_line = src:match("events_in_flight%s*=[^\n]*")
		helpers.assert_true(eif_line ~= nil, "source must compute an events_in_flight predicate")
		helpers.assert_true(
			eif_line:find("pending_pastes", 1, true) ~= nil,
			"events_in_flight must include pending_pastes (the paste echo is the only in-flight marker for a 0-delete paste expansion)")
		helpers.assert_true(
			src:find("pending_pastes%s*=%s*CoreState%.expected_synthetic_pastes", 1, false) ~= nil,
			"pending_pastes must be read from CoreState.expected_synthetic_pastes")

		-- Old fixed-threshold pattern (> 1.0) must be replaced in the guard block
		helpers.assert_eq(
			src:find("arm_age > 1%.0", 1, false),
			nil,
			"source must NOT contain the old 'arm_age > 1.0' hard-coded threshold")
	end)
end)
