--- tests/unit/modules/shortcuts/test_keyboard_shortcuts_stop_guard.lua

--- Regression test for shortcuts-core-2: keyboard_shortcuts.stop() emitted a
--- Logger.start/success pair even when the module had never been started,
--- producing misleading "Stopped" log lines during early teardown or in tests
--- where start() was never called.
---
--- Fix: added a `if not _started then warn + return end` guard at the top of
--- M.stop() so the lifecycle pair is only logged when there is something to stop.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "modules/shortcuts/keyboard_shortcuts.lua"
local fh = io.open(src_path, "r")
if not fh then error("keyboard_shortcuts.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Locate the stop() function body.
local stop_start = src:find("function M.stop()", 1, true)
helpers.assert_true(
	stop_start ~= nil,
	"keyboard_shortcuts.lua must define M.stop() (shortcuts-core-2)"
)

local stop_body = src:sub(stop_start, stop_start + 400)

-- Test 1: The guard must check _started before logging.
local has_not_started_guard = stop_body:find("if not _started then", 1, true) ~= nil
helpers.assert_true(
	has_not_started_guard,
	"keyboard_shortcuts.lua M.stop() must guard with 'if not _started then' (shortcuts-core-2)"
)

-- Test 2: The guard must early-return (not fall through).
local guard_end = stop_body:find("if not _started then", 1, true)
local guard_block = stop_body:sub(guard_end, guard_end + 100)
local has_return = guard_block:find("return", 1, true) ~= nil
helpers.assert_true(
	has_return,
	"keyboard_shortcuts.lua M.stop() guard must return early when not started (shortcuts-core-2)"
)

-- Test 3: Logger.start must appear AFTER the guard (not before it).
local logger_start_pos = stop_body:find('Logger.start', 1, true)
local guard_pos = stop_body:find("if not _started then", 1, true)
helpers.assert_true(
	logger_start_pos ~= nil and guard_pos ~= nil and guard_pos < logger_start_pos,
	"keyboard_shortcuts.lua M.stop() guard must appear before Logger.start (shortcuts-core-2)"
)

print("[PASS] test_keyboard_shortcuts_stop_guard")
