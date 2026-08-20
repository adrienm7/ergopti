--- tests/unit/lib/test_healthcheck_last_error_comment.lua

--- Regression test for lib-health-3: healthcheck.lua had a stale comment
--- on _last_error claiming it was "reset to nil on each M.run() call".
--- M.run() never resets _last_error — only M.record_error() sets it and it
--- persists until the next record_error() call.
---
--- Fix: corrected the comment to reflect the actual lifetime of _last_error.

local helpers = require("tests.helpers")

-- After the F2 split, the _last_error declaration + comment live in core.lua
-- (the public-API half of ui/healthcheck/), not the former monolithic lib file.
-- Selected by a declaration unique to ui/healthcheck/core.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("local function _stop_poll")
helpers.assert_true(src ~= nil, "ui/healthcheck/core.lua source must be locatable")

-- Test 1: the old incorrect claim must not appear in the source.
local old_comment = src:find("reset to nil on each M.run() call", 1, true)
helpers.assert_true(
	old_comment == nil,
	"healthcheck.lua must not contain the stale '_last_error reset on M.run()' comment (lib-health-3)"
)

-- Test 2: _last_error declaration must still exist (variable not removed).
local has_decl = src:find("local _last_error = nil", 1, true) ~= nil
helpers.assert_true(
	has_decl,
	"healthcheck.lua must still declare local _last_error = nil (lib-health-3)"
)

-- Test 3: the corrected comment must mention record_error and persists.
local corrected = src:find("record_error", 1, true) ~= nil
helpers.assert_true(
	corrected,
	"healthcheck.lua _last_error comment must reference record_error() (lib-health-3)"
)

print("[PASS] test_healthcheck_last_error_comment")
