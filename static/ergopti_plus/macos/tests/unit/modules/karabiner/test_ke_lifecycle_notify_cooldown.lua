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
