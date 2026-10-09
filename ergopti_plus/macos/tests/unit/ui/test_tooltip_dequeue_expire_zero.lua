--- tests/unit/ui/test_tooltip_dequeue_expire_zero.lua

--- Regression test for ui-tooltip-2: prune_expired treated expire_at == 0
--- as an already-expired timestamp. In Lua, 0 is truthy so `not exp` was
--- false, and `now_sec < 0` is always false, causing the row to be pruned.
---
--- But has_expiry_stamp() (line 52-55) explicitly treats expire_at == 0 as
--- "no expiry stamp" (returns false), meaning 0 is the sentinel for
--- "never expires". prune_expired must be consistent: keep rows with exp == 0.
---
--- Fix: changed the prune condition from `if not exp or now_sec < exp` to
--- `if not exp or exp == 0 or now_sec < exp`.

local helpers = require("tests.helpers")

-- Load the real module — it has no hs.* calls so it loads cleanly headless.
local Dequeue = require("ui.tooltip.dequeue")

local FAR_FUTURE = os.time() + 100000
local FAR_PAST   = os.time() - 100000

-- Test 1: A row with expire_at == 0 must NOT be pruned (it never expires).
local rows = { { id = 1, expire_at = 0 } }
local remaining = Dequeue.prune_expired(rows, os.time())
helpers.assert_true(
	#remaining == 1,
	"prune_expired must keep a row with expire_at == 0 (sentinel for 'never expires') (ui-tooltip-2)"
)

-- Test 2: A row with expire_at == nil must NOT be pruned (explicit nil = never).
rows = { { id = 2 } }
remaining = Dequeue.prune_expired(rows, os.time())
helpers.assert_true(
	#remaining == 1,
	"prune_expired must keep a row with no expire_at field (ui-tooltip-2)"
)

-- Test 3: A row with a far-past expire_at MUST be pruned.
rows = { { id = 3, expire_at = FAR_PAST } }
remaining = Dequeue.prune_expired(rows, os.time())
helpers.assert_true(
	#remaining == 0,
	"prune_expired must prune a row whose expire_at is in the past (ui-tooltip-2)"
)

-- Test 4: A row with a far-future expire_at must NOT be pruned.
rows = { { id = 4, expire_at = FAR_FUTURE } }
remaining = Dequeue.prune_expired(rows, os.time())
helpers.assert_true(
	#remaining == 1,
	"prune_expired must keep a row whose expire_at is in the future (ui-tooltip-2)"
)

-- Test 5: Mixed batch — expire_at==0 and far-future survive, past is pruned.
rows = {
	{ id = 5, expire_at = 0 },
	{ id = 6, expire_at = FAR_PAST },
	{ id = 7, expire_at = FAR_FUTURE },
	{ id = 8 },
}
remaining = Dequeue.prune_expired(rows, os.time())
helpers.assert_true(
	#remaining == 3,
	"prune_expired mixed: expire_at==0, future, and nil survive; past is pruned (ui-tooltip-2)"
)
-- Confirm the pruned row is the one with far-past expire_at
local ids = {}
for _, r in ipairs(remaining) do ids[r.id] = true end
helpers.assert_true(
	ids[5] and ids[7] and ids[8] and not ids[6],
	"prune_expired mixed: surviving ids must be 5, 7, 8 (not 6) (ui-tooltip-2)"
)

print("[PASS] test_tooltip_dequeue_expire_zero")
