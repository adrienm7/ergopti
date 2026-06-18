--- tests/unit/ui/test_personal_info_editor_port_leak.lua

--- Regression test for ui-windows-b-5: personal_info_editor/init.lua
--- only stopped the HTTP server when the user hit /save or /cancel.
--- If the browser tab was closed without interaction, _srv was never
--- stopped and the port (18743) remained bound indefinitely.
---
--- Fix: extracted a stop_server() helper, exposed M.close() for explicit
--- teardown, added a SESSION_TIMEOUT_SEC watchdog timer that fires if the
--- session idles, and simplified the two inline close lambdas to use the helper.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "ui/personal_info_editor/init.lua"
local fh = io.open(src_path, "r")
if not fh then error("personal_info_editor/init.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Test 1: A SESSION_TIMEOUT_SEC constant must be defined.
local has_timeout_const = src:find("SESSION_TIMEOUT_SEC", 1, true) ~= nil
helpers.assert_true(
	has_timeout_const,
	"personal_info_editor/init.lua must define SESSION_TIMEOUT_SEC (ui-windows-b-5)"
)

-- Test 2: A _timeout state variable must be declared.
local has_timeout_var = src:find("local _timeout", 1, true) ~= nil
helpers.assert_true(
	has_timeout_var,
	"personal_info_editor/init.lua must declare local _timeout for the watchdog timer (ui-windows-b-5)"
)

-- Test 3: A stop_server() local helper must exist.
local has_stop_server = src:find("local function stop_server()", 1, true) ~= nil
helpers.assert_true(
	has_stop_server,
	"personal_info_editor/init.lua must define a local stop_server() helper (ui-windows-b-5)"
)

-- Test 4: M.close() must be exposed for explicit teardown.
local has_m_close = src:find("function M.close()", 1, true) ~= nil
helpers.assert_true(
	has_m_close,
	"personal_info_editor/init.lua must expose M.close() for explicit port cleanup (ui-windows-b-5)"
)

-- Test 5: The watchdog timer must be started after opening the browser.
local has_watchdog_arm = src:find("timer.doAfter(SESSION_TIMEOUT_SEC", 1, true) ~= nil
helpers.assert_true(
	has_watchdog_arm,
	"personal_info_editor/init.lua must arm a timer.doAfter(SESSION_TIMEOUT_SEC, ...) watchdog (ui-windows-b-5)"
)

-- Test 6: The watchdog must call stop_server when it fires.
-- Confirm the timer body references stop_server.
local timeout_pos = src:find("timer.doAfter(SESSION_TIMEOUT_SEC", 1, true)
local timeout_body = src:sub(timeout_pos, timeout_pos + 200)
local has_stop_in_watchdog = timeout_body:find("stop_server", 1, true) ~= nil
helpers.assert_true(
	has_stop_in_watchdog,
	"personal_info_editor/init.lua watchdog timer must call stop_server() (ui-windows-b-5)"
)

print("[PASS] test_personal_info_editor_port_leak")
