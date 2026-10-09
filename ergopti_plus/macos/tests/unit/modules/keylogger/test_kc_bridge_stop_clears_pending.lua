--- tests/unit/modules/keylogger/test_kc_bridge_stop_clears_pending.lua

--- Regression test for keylogger-support-4: kc_bridge.stop() did not clear
--- the _pending_down table. If a key was physically held down when the
--- keylogger was stopped and then released after it restarted, the "U:" release
--- event would compute hold_ms = now - old_down_at, where old_down_at was from
--- before the stop, yielding an arbitrarily large (and logged) hold duration.
---
--- Fix: _pending_down = {} added to M.stop() so the cross-cycle stale timestamp
--- is discarded; the release after restart safely computes hold_ms = 0 (guarded
--- by the `down_at and ...` nil-check that was already there).

local helpers = require("tests.helpers")

-- Selected by a declaration unique to modules/keylogger/kc_bridge.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("local function build_managed_output_set")
helpers.assert_true(src ~= nil, "modules/keylogger/kc_bridge.lua source must be locatable")

-- Test 1: stop() function exists.
local stop_pos = src:find("\nfunction M.stop()", 1, true)
helpers.assert_true(
	stop_pos ~= nil,
	"kc_bridge.lua must have M.stop() function (keylogger-support-4)"
)

-- Test 2: _pending_down = {} appears inside the stop() body.
-- Extract from "function M.stop()" to its closing "end".
local after_stop = src:sub(stop_pos)
local stop_end   = after_stop:find("\nend\n", 1, true)
local stop_body  = stop_end and after_stop:sub(1, stop_end) or after_stop

local clears_pending = stop_body:find("_pending_down = {}", 1, true) ~= nil
helpers.assert_true(
	clears_pending,
	"kc_bridge.lua M.stop() must reset _pending_down = {} to prevent aberrant hold_ms after stop/start (keylogger-support-4)"
)

print("[PASS] test_kc_bridge_stop_clears_pending")
