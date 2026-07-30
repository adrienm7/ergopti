--- tests/unit/lib/test_logger_dedup_errors_mirror.lua

--- Regression test for lib-logger-perf-002: logger.lua _flush_dedup_summary()
--- did not write the suppression summary to M.ERRORS_LOG_FILE. Identical WARNING
--- or ERROR lines were dedup'd correctly in the unified log but the errors-only
--- file only recorded the first occurrence, hiding the repeat count.
---
--- Fix: _flush_dedup_summary now appends the suppression summary line to
--- M.ERRORS_LOG_FILE when the suppressed variant level >= WARNING.

local helpers = require("tests.helpers")

-- Selected by a declaration unique to lib/logger.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("function M.set_error_notification_handler")
helpers.assert_true(src ~= nil, "lib/logger.lua source must be locatable")

-- Locate _flush_dedup_summary body.
local fn_pos = src:find("local function _flush_dedup_summary()", 1, true)
helpers.assert_true(fn_pos ~= nil, "logger.lua must define _flush_dedup_summary (lib-logger-perf-002)")
local fn_body = src:sub(fn_pos, fn_pos + 1200)

-- Test 1: the function must check variant.level >= M.LEVELS.WARNING.
local has_level_check = fn_body:find("variant.level >= M.LEVELS.WARNING", 1, true) ~= nil
helpers.assert_true(
	has_level_check,
	"_flush_dedup_summary must check variant.level >= M.LEVELS.WARNING (lib-logger-perf-002)"
)

-- Test 2: the function must open M.ERRORS_LOG_FILE for appending.
local has_errors_open = fn_body:find("M.ERRORS_LOG_FILE", 1, true) ~= nil
helpers.assert_true(
	has_errors_open,
	"_flush_dedup_summary must write to M.ERRORS_LOG_FILE for WARNING/ERROR dedup summaries (lib-logger-perf-002)"
)

-- Test 3: the ERRORS_LOG_FILE write must come BEFORE the counter reset.
local write_pos = fn_body:find("M.ERRORS_LOG_FILE", 1, true)
local reset_pos = fn_body:find("_dedup.count%s*=%s*0", 1, false)
if not reset_pos then reset_pos = fn_body:find("_dedup.count       = 0", 1, true) end
helpers.assert_true(
	write_pos ~= nil and reset_pos ~= nil and write_pos < reset_pos,
	"_flush_dedup_summary ERRORS_LOG_FILE write must precede the counter reset (lib-logger-perf-002)"
)

print("[PASS] test_logger_dedup_errors_mirror")
