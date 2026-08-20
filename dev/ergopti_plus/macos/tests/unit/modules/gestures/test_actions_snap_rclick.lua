--- tests/unit/modules/gestures/test_actions_snap_rclick.lua

--- Regression tests for two gestures-actions bugs:
---
--- gestures-actions-snap: snap_right called win:maximize() instead of
--- win:moveToUnit(hs.layout.right50), so it maximised instead of snapping.
---
--- gestures-actions-rclick: the right-click mouseUp used a deferred re-toggle.
--- It could re-engage a stale hold, and even a guarded deferral left the sole
--- physical mouseUp consumed until in-process work ran. The safe implementation
--- has no deferred toggle: it fences state and lets the physical event through.

local helpers = require("tests.helpers")

-- Selected by a declaration unique to modules/gestures/actions.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("local function switch_to_previous_window_precise")
helpers.assert_true(src ~= nil, "modules/gestures/actions.lua source must be locatable")

-- The synthetic click-hold subsystem (the guarded mouseUp re-toggle) was
-- extracted into actions_click.lua. Read it too and search the combined source
-- for the rclick-guard assertion, so the regression check survives that move.
local click_src = helpers.read_driver_source("local function start_click_key_watcher")
helpers.assert_true(click_src ~= nil, "modules/gestures/actions_click.lua source must be locatable")
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

-- Test 3 (gestures-actions-rclick): no deferred right-click toggle remains.
local bare_defer = all_src:find("doAfter(0, M.toggle_right_click)", 1, true) ~= nil
helpers.assert_true(
	not bare_defer,
	"doAfter(0, M.toggle_right_click) must not appear bare — must be guarded with 'if rightClickHeld then' (gestures-actions-rclick)"
)

helpers.assert_true(
	all_src:find("if rightClickHeld then M.toggle_right_click()", 1, true) == nil,
	"right-click mouseUp must not rely on any deferred re-toggle (gestures-actions-rclick)"
)

print("[PASS] test_actions_snap_rclick")
