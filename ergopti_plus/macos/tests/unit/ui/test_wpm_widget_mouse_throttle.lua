--- tests/unit/ui/test_wpm_widget_mouse_throttle.lua

--- Regression test for ui-windows-a-4: wpm_widget.lua registered an
--- hs.eventtap for mouseMoved and updated _last_mouse_sec on every event.
--- mouseMoved fires hundreds of times per second during continuous mouse
--- movement, causing each move to re-enter the Lua VM and add jitter to
--- the input pipeline.
---
--- Fix: added MOUSE_MOVE_THROTTLE_SEC constant (0.2 s); the mouseMoved
--- handler now only updates _last_mouse_sec if the elapsed time since
--- the previous update is >= MOUSE_MOVE_THROTTLE_SEC. Clicks and scroll
--- events always update immediately (they bypass the throttle).

local helpers = require("tests.helpers")

-- Selected by a declaration unique to ui/wpm/wpm_widget.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("local function resolve_shared_constants_path")
helpers.assert_true(src ~= nil, "ui/wpm/wpm_widget.lua source must be locatable")

-- Test 1: MOUSE_MOVE_THROTTLE_SEC constant must be defined.
local throttle_val = src:match("local MOUSE_MOVE_THROTTLE_SEC%s*=%s*([%d%.]+)")
helpers.assert_true(
	throttle_val ~= nil,
	"wpm_widget.lua must define MOUSE_MOVE_THROTTLE_SEC constant (ui-windows-a-4)"
)
local tv = tonumber(throttle_val)
helpers.assert_true(
	tv ~= nil and tv > 0,
	"MOUSE_MOVE_THROTTLE_SEC must be a positive number (ui-windows-a-4)"
)

-- Test 2: The callback must accept the event argument (function(e)).
local has_event_arg = src:find("function(e)", 1, true) ~= nil
helpers.assert_true(
	has_event_arg,
	"wpm_widget.lua eventtap callback must accept event argument function(e) (ui-windows-a-4)"
)

-- Test 3: The throttle must be applied for mouseMoved.
local has_throttle_check = src:find("MOUSE_MOVE_THROTTLE_SEC", 1, true) ~= nil
	and src:find("is_move", 1, true) ~= nil
helpers.assert_true(
	has_throttle_check,
	"wpm_widget.lua must throttle mouseMoved using MOUSE_MOVE_THROTTLE_SEC (ui-windows-a-4)"
)

-- Test 4: Non-move events must bypass the throttle (no throttle on click/scroll).
local cb_pos = src:find("function(e)", 1, true)
helpers.assert_true(cb_pos ~= nil, "callback with e argument must exist (ui-windows-a-4)")
local cb_body = src:sub(cb_pos, cb_pos + 400)
-- The throttle condition must include `not is_move` OR `(now - _last_mouse_sec) >= ...`
-- so non-move events always update
local has_non_move_bypass = cb_body:find("not is_move", 1, true) ~= nil
helpers.assert_true(
	has_non_move_bypass,
	"wpm_widget.lua throttle must bypass for non-move events (not is_move) (ui-windows-a-4)"
)

print("[PASS] test_wpm_widget_mouse_throttle")
