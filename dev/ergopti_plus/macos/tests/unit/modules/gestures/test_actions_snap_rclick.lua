--- tests/unit/modules/gestures/test_actions_snap_rclick.lua

--- Regression tests for two gestures-actions bugs:
---
--- gestures-actions-snap: snap_right called win:maximize() instead of
--- win:moveToUnit(hs.layout.right50), so it maximised instead of snapping.
---
--- gestures-actions-rclick: the right-click mouseUp deferred toggle had no
--- guard: `hs.timer.doAfter(0, M.toggle_right_click)`. If rightClickHeld was
--- cleared by a concurrent key-down before the callback fired, the re-toggle
--- created a phantom hold. The left-click path already had the guard.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "modules/gestures/actions.lua"
local fh = io.open(src_path, "r")
if not fh then error("modules/gestures/actions.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- The synthetic click-hold subsystem (the guarded mouseUp re-toggle) was
-- extracted into actions_click.lua. Read it too and search the combined source
-- for the rclick-guard assertion, so the regression check survives that move.
local click_path = helpers.driver_root() .. "modules/gestures/actions_click.lua"
local cfh = io.open(click_path, "r")
local click_src = cfh and cfh:read("*a") or ""
if cfh then cfh:close() end
local all_src = src .. "\n" .. click_src

-- Test 1 (gestures-actions-snap): snap_right uses moveToUnit(hs.layout.right50).
local right50 = src:find("moveToUnit(hs.layout.right50)", 1, true) ~= nil
helpers.assert_true(
	right50,
	"snap_right must call moveToUnit(hs.layout.right50), not win:maximize() (gestures-actions-snap)"
)

-- Test 2 (gestures-actions-snap): snap_right does NOT call maximize() on
-- the same line as the right50 snap (to rule out a maximize call left there).
-- We verify this structurally: the right50 call must appear in the snap_right
-- registration block which uses the "snap_right" key string.
local snap_right_block_start = src:find('"snap_right"', 1, true)
local snap_right_block_end   = src:find('"maximize"', snap_right_block_start or 1, true)
helpers.assert_true(
	snap_right_block_start ~= nil,
	"snap_right action must be registered"
)
helpers.assert_true(
	snap_right_block_end > snap_right_block_start + 50,
	"snap_right and maximize should be separate blocks (gestures-actions-snap)"
)

-- Test 3 (gestures-actions-rclick): the deferred right-click toggle is guarded.
-- Pre-fix: `doAfter(0, M.toggle_right_click)` — no state check.
-- Post-fix: `doAfter(0, function() if rightClickHeld then M.toggle_right_click() end end)`.
local bare_defer = all_src:find("doAfter(0, M.toggle_right_click)", 1, true) ~= nil
helpers.assert_true(
	not bare_defer,
	"doAfter(0, M.toggle_right_click) must not appear bare — must be guarded with 'if rightClickHeld then' (gestures-actions-rclick)"
)

local guarded_defer = all_src:find("if rightClickHeld then M.toggle_right_click()", 1, true) ~= nil
helpers.assert_true(
	guarded_defer,
	"right-click deferred toggle must be guarded with 'if rightClickHeld then' (gestures-actions-rclick)"
)

print("[PASS] test_actions_snap_rclick")
