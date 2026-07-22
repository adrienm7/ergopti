--- tests/unit/ui/test_tooltip_dequeue_is_rebuild_detection.lua

--- ==============================================================================
--- MODULE: Tooltip Dequeue is_rebuild Detection Tests
--- DESCRIPTION:
--- Regression tests for bug M-09 — premature stop_dequeue() during partial-expiry
--- rebuilds caused by checking only rows[1] for an expire_at stamp instead of
--- scanning all rows.
---
--- FEATURES & RATIONALE:
--- 1. Mixed-row detection: When rows[1] carries no expire_at but rows[2] does, the
---    correct result is is_rebuild = true (the row set originates from a dequeue
---    prune cycle). The pre-fix code returned false because it short-circuited on
---    the first row, triggering stop_dequeue() and destroying the active cycle.
--- 2. Dequeue cycle preservation: asserts that the surviving expire_at stamp is
---    preserved during re-stamping so the timer fires at the correct absolute time
---    rather than computing a fresh offset from now.
--- 3. Permanent-row survival: asserts that a permanent row (no duration, no
---    expire_at) is never pruned mid-cycle.
--- ==============================================================================

local helpers = require("tests.helpers")

local Dequeue = helpers.load_with_stubs("ui.tooltip.dequeue")

local OPTS = {
	duration_field = "duration",
	expire_field   = "expire_at",
	timeout_decrement_sec = 0.2,
	timeout_floor_sec     = 0.05,
}





-- ===========================================================
-- ===========================================================
-- ======= 1/ is_rebuild Detection on Mixed-Row Arrays =======
-- ===========================================================
-- ===========================================================

helpers.describe("Dequeue: is_rebuild detection — mixed rows (M-09 regression)", function()

	-- -----------------------------------------------------------------
	-- Canonical M-09 scenario:
	--   rows[1] = permanent row (no expire_at, no duration)
	--   rows[2] = timed row that already carries an expire_at stamp
	--             (i.e. it survived a prior prune() call)
	-- Expected: is_rebuild = true because at least one row carries expire_at.
	-- Pre-fix behaviour: is_rebuild = false (only rows[1] was checked).
	-- -----------------------------------------------------------------

	helpers.it("rows[1] has no expire_at, rows[2] has expire_at → is_rebuild = true", function()
		local rows = {
			{ text = "permanent row", duration = 0 },
			{ text = "timed row",     duration = 2, expire_at = 1000.8 },
		}
		local is_rebuild = Dequeue.analyze_durations(rows, OPTS)
		helpers.assert_true(is_rebuild,
			"is_rebuild must be true when any non-first row carries expire_at")
	end)


	helpers.it("rows[1] has no expire_at but a duration, rows[2] has expire_at → is_rebuild = true", function()
		-- Variant: rows[1] has a duration value but no expire_at stamp yet;
		-- rows[2] is a carry-over from a prior cycle with an absolute stamp.
		local rows = {
			{ text = "short row", duration = 1 },
			{ text = "long row",  duration = 3, expire_at = 1002.8 },
		}
		local is_rebuild = Dequeue.analyze_durations(rows, OPTS)
		helpers.assert_true(is_rebuild,
			"is_rebuild must be true even when rows[1] still has a plain duration")
	end)


	helpers.it("no row carries expire_at → is_rebuild = false", function()
		-- Baseline: a fresh (non-rebuilt) row array with only plain durations
		-- must not be misidentified as a rebuild.
		local rows = {
			{ text = "a", duration = 1 },
			{ text = "b", duration = 2 },
		}
		local is_rebuild = Dequeue.analyze_durations(rows, OPTS)
		helpers.assert_true(not is_rebuild,
			"is_rebuild must be false when no row carries expire_at")
	end)


	helpers.it("only rows[1] has expire_at → is_rebuild = true", function()
		-- Complement of the M-09 scenario: the first row carries the stamp.
		-- This already worked before the fix; include it to prevent regression.
		local rows = {
			{ text = "timed",     duration = 1, expire_at = 1000.8 },
			{ text = "permanent", duration = 0 },
		}
		local is_rebuild = Dequeue.analyze_durations(rows, OPTS)
		helpers.assert_true(is_rebuild,
			"is_rebuild must be true when rows[1] carries expire_at")
	end)


	helpers.it("rows[3] has expire_at, rows[1] and rows[2] do not → is_rebuild = true", function()
		-- Three-row variant: ensures the full scan covers any position.
		local rows = {
			{ text = "a", duration = 0 },
			{ text = "b", duration = 1 },
			{ text = "c", duration = 2, expire_at = 1001.8 },
		}
		local is_rebuild = Dequeue.analyze_durations(rows, OPTS)
		helpers.assert_true(is_rebuild,
			"is_rebuild must be true when only the third row carries expire_at")
	end)

end)





-- ===============================================================
-- ===============================================================
-- ======= 2/ stamp_expiry_times Preserves Existing Stamps =======
-- ===============================================================
-- ===============================================================

helpers.describe("Dequeue: stamp_expiry_times preserves existing expire_at on rebuild", function()

	-- When is_rebuild = true, rows that already carry expire_at must keep
	-- their original absolute timestamp untouched. Computing a fresh offset
	-- from now would move the deadline forward, keeping rows on screen longer
	-- than intended after each prune cycle.

	helpers.it("existing expire_at on timed row is preserved (not recomputed)", function()
		local original_expire = 1000.8
		local rows = {
			{ text = "permanent", duration = 0 },
			{ text = "timed",     duration = 2, expire_at = original_expire },
		}
		local now = 1000.0  -- some base epoch value
		local stamped = select(1, Dequeue.stamp_expiry_times(rows, now, OPTS))

		helpers.assert_eq(stamped[2].expire_at, original_expire,
			"timed row's expire_at must not be overwritten on a rebuild call")
	end)


	helpers.it("permanent row without expire_at receives nil expire_at after re-stamp", function()
		local rows = {
			{ text = "permanent", duration = 0 },
			{ text = "timed",     duration = 2, expire_at = 1002.8 },
		}
		local now = 1000.0
		local stamped = select(1, Dequeue.stamp_expiry_times(rows, now, OPTS))

		helpers.assert_nil(stamped[1].expire_at,
			"permanent row must keep nil expire_at after re-stamp — it has no deadline")
	end)

end)





-- ========================================================
-- ========================================================
-- ======= 3/ prune_expired Does Not Drop Permanent =======
-- ========================================================
-- ========================================================

helpers.describe("Dequeue: prune_expired keeps permanent rows throughout cycle", function()

	-- A permanent row (expire_at = nil) must never be evicted by prune_expired(),
	-- regardless of how many prune passes have occurred.

	helpers.it("permanent row survives a prune call at any point in time", function()
		local rows = {
			{ text = "permanent", expire_at = nil },
			{ text = "timed",     expire_at = 1000.8 },
		}

		-- Prune at the exact moment the timed row expires
		local remaining = Dequeue.prune_expired(rows, 1000.8, OPTS)

		helpers.assert_eq(#remaining, 1,
			"exactly one row must survive after the timed row expires")
		helpers.assert_eq(remaining[1].text, "permanent",
			"the surviving row must be the permanent one")
	end)


	helpers.it("permanent row survives repeated prune passes (simulated dequeue cycle)", function()
		-- Simulates two dequeue tick cycles:
		--   Tick 1 (t=0.8s): timed row A expires; permanent + timed B remain.
		--   Tick 2 (t=1.8s): timed row B expires; only permanent remains.
		-- The dequeue cycle must NOT be considered exhausted while permanent row lives.

		local now = 1000.0
		local rows_after_stamp = {
			{ text = "permanent", expire_at = nil  },
			{ text = "timed_A",   expire_at = now + 0.8 },
			{ text = "timed_B",   expire_at = now + 1.8 },
		}

		-- Tick 1
		local after_tick1 = Dequeue.prune_expired(rows_after_stamp, now + 0.8, OPTS)
		helpers.assert_eq(#after_tick1, 2,
			"after tick 1: permanent + timed_B must remain")
		helpers.assert_eq(after_tick1[1].text, "permanent",
			"after tick 1: first row must be permanent")
		helpers.assert_eq(after_tick1[2].text, "timed_B",
			"after tick 1: second row must be timed_B")

		-- Tick 2
		local after_tick2 = Dequeue.prune_expired(after_tick1, now + 1.8, OPTS)
		helpers.assert_eq(#after_tick2, 1,
			"after tick 2: only permanent must remain")
		helpers.assert_eq(after_tick2[1].text, "permanent",
			"after tick 2: the surviving row must be permanent")

		-- The dequeue cycle is only destroyed when #remaining == 0, so a non-empty
		-- result here means the cycle would NOT be torn down prematurely.
		helpers.assert_true(#after_tick2 > 0,
			"dequeue cycle must not be destroyed while a permanent row is still alive")
	end)

end)





-- ===================================================================
-- ===================================================================
-- ======= 4/ should_use_dequeue_path Activates for Mixed Rows =======
-- ===================================================================
-- ===================================================================

helpers.describe("Dequeue: should_use_dequeue_path activates correctly on M-09 input", function()

	helpers.it("mixed-row array with expire_at on rows[2] activates dequeue path", function()
		-- This is the exact call made by M.show_stacked() on a rebuild tick.
		-- The pre-fix implementation of analyze_durations only checked rows[1],
		-- so should_use_dequeue_path returned false and stop_dequeue() was invoked,
		-- destroying the active cycle and preventing further destack ticks.
		local rows = {
			{ text = "permanent", duration = 0 },
			{ text = "timed",     duration = 2, expire_at = 1000.8 },
		}
		local use_dequeue = Dequeue.should_use_dequeue_path(rows, OPTS)
		helpers.assert_true(use_dequeue,
			"should_use_dequeue_path must return true so the dequeue cycle is preserved")
	end)

end)

print("[PASS] test_tooltip_dequeue_is_rebuild_detection")
