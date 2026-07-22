--- tests/unit/modules/karabiner/test_ke_lifecycle_notify_cooldown.lua

--- ==============================================================================
--- MODULE: ke_lifecycle notify_karabiner_ready cooldown regression tests
--- DESCRIPTION:
--- Verifies that a Karabiner-ready notification suppressed by the 10s cooldown
--- is not silently dropped — the pending flag must be re-armed so the next
--- flush_pending_ready_notification() call delivers the deferred notification.
---
--- FEATURES & RATIONALE:
--- 1. Source Invariant: the cooldown branch in notify_karabiner_ready must set
---    _pending_karabiner_ready_notify = true so the notification is never lost.
--- 2. Context: two rapid re-primes (edit tap/hold < 10 s apart) would previously
---    produce only one user-visible "Karabiner ready" banner (karabiner-life-2).
--- 3. F-MED-18: re-arming the pending flag is necessary but not sufficient —
---    the ONLY caller of flush_pending_ready_notification() is a single
---    one-shot call at boot completion (init.lua). Without an actual periodic
---    retry, a notification deferred by the cooldown branch is silently
---    dropped forever, despite the debug log claiming "will retry". The fix
---    arms a real hs.timer.doAfter retry (right after the remaining cooldown
---    window) that calls M.flush_pending_ready_notification() again.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =====================================================================================
-- =====================================================================================
-- ======= 1/ Cooldown branch re-arms pending flag — source-level invariant ============
-- =====================================================================================
-- =====================================================================================

helpers.describe("ke_lifecycle notify cooldown — pending flag re-armed (karabiner-life-2 regression)", function()

	helpers.it("cooldown branch sets _pending_karabiner_ready_notify = true", function()
		local src_path = helpers.driver_root() .. "modules/karabiner/ke_lifecycle.lua"
		local fh = io.open(src_path, "r")
		helpers.assert_true(fh ~= nil, "ke_lifecycle.lua must be readable")
		local src = fh:read("*a"); fh:close()

		-- Locate the cooldown guard (KARABINER_READY_NOTIFY_COOLDOWN_SEC comparison).
		local cooldown_pos = src:find("KARABINER_READY_NOTIFY_COOLDOWN_SEC", 1, true)
		helpers.assert_true(cooldown_pos ~= nil,
			"notify_karabiner_ready must contain a cooldown check")

		-- Find the nearest return after the cooldown check; the pending flag assignment
		-- must appear between the cooldown check and that return.
		local after_cooldown = src:sub(cooldown_pos)
		local pending_pos = after_cooldown:find("_pending_karabiner_ready_notify%s*=%s*true", 1, false)
		local return_pos  = after_cooldown:find("\n\t\t\t\treturn", 1, true)

		helpers.assert_true(pending_pos ~= nil,
			"_pending_karabiner_ready_notify = true must appear after the cooldown check")
		helpers.assert_true(return_pos ~= nil,
			"there must be a return after the cooldown check")
		helpers.assert_true(pending_pos < return_pos,
			"_pending_karabiner_ready_notify must be set BEFORE the return in the cooldown branch")
	end)

end)




-- ============================================================================================
-- ============================================================================================
-- ======= 2/ Cooldown branch arms a real retry timer (F-MED-18) =============================
-- ============================================================================================
-- ============================================================================================

-- Guards F-MED-18: flush_pending_ready_notification() is only ever called once,
-- at boot completion. Re-arming the pending flag alone is not enough — without
-- an actual scheduled retry, a notification deferred by the cooldown branch is
-- lost forever the moment boot has already completed once.
helpers.describe("ke_lifecycle notify cooldown — periodic retry armed (F-MED-18 regression)", function()

	local function read_source()
		local src_path = helpers.driver_root() .. "modules/karabiner/ke_lifecycle.lua"
		local fh = io.open(src_path, "r")
		helpers.assert_true(fh ~= nil, "ke_lifecycle.lua must be readable")
		local src = fh:read("*a"); fh:close()
		return src
	end

	--- Isolates the cooldown branch: from the KARABINER_READY_NOTIFY_COOLDOWN_SEC
	--- comparison down to the "return" that ends that branch.
	local function cooldown_branch_source()
		local src = read_source()
		local cooldown_pos = src:find("KARABINER_READY_NOTIFY_COOLDOWN_SEC then", 1, true)
		helpers.assert_true(cooldown_pos ~= nil, "notify_karabiner_ready must contain the cooldown check")
		local return_pos = src:find("\n\t\t\t\treturn", cooldown_pos, true)
		helpers.assert_true(return_pos ~= nil, "the cooldown branch must end with a return")
		return src:sub(cooldown_pos, return_pos)
	end

	helpers.it("the cooldown branch schedules a real timer (hs.timer.doAfter), not just a flag flip", function()
		local branch = cooldown_branch_source()
		helpers.assert_true(branch:find("hs.timer.doAfter", 1, true) ~= nil,
			"the cooldown branch must arm an hs.timer.doAfter retry — re-arming the flag alone is not "
			.. "enough because nothing else ever calls flush_pending_ready_notification again (F-MED-18)")
	end)

	helpers.it("the retry timer's callback calls M.flush_pending_ready_notification()", function()
		local branch = cooldown_branch_source()
		local timer_pos = branch:find("hs.timer.doAfter", 1, true)
		helpers.assert_true(timer_pos ~= nil, "cooldown branch must schedule a timer")
		local after_timer = branch:sub(timer_pos)
		helpers.assert_true(after_timer:find("M.flush_pending_ready_notification()", 1, true) ~= nil,
			"the retry timer's callback must re-invoke M.flush_pending_ready_notification() (F-MED-18)")
	end)

	helpers.it("a stale retry timer is stopped before arming a new one (no piled-up retries)", function()
		local branch = cooldown_branch_source()
		helpers.assert_true(branch:find("_karabiner_ready_retry_timer", 1, true) ~= nil,
			"a dedicated _karabiner_ready_retry_timer variable must track the pending retry")
		helpers.assert_true(branch:find(":stop()", 1, true) ~= nil,
			"an existing retry timer must be stopped before a new one is armed, to avoid piling up retries")
	end)

end)
