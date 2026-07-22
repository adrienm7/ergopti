--- tests/unit/lib/test_healthcheck_poll_timer_leak.lua

--- Regression test for lib-health-1: reopening the healthcheck window previously
--- leaked the copy-button poll timer. The `_poll_timer` was a local variable
--- inside show_window(), so each reopen call created a new local while the old
--- timer kept firing indefinitely — polling a deleted webview.
---
--- Fix: _poll_timer and _stop_poll() are now module-level variables. show_window()
--- calls _stop_poll() before deleting the old webview so the old timer is
--- always cancelled before a new one is created.

local helpers = require("tests.helpers")

-- After the F2 split, the poll-timer / window logic lives in core.lua.
local src_path = helpers.driver_root() .. "ui/healthcheck/core.lua"
local fh = io.open(src_path, "r")
if not fh then error("healthcheck core.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Test 1: _poll_timer must be declared at module level (before any function).
-- A module-level local appears before the first `function` or `local function`
-- definition that uses it. We detect this by checking that a bare
-- `local _poll_timer` assignment appears in the file.
local poll_decl_pos = src:find("local _poll_timer = nil", 1, true)
helpers.assert_true(
	poll_decl_pos ~= nil,
	"healthcheck.lua must declare _poll_timer at module level (lib-health-1)"
)

-- Test 2: _stop_poll must be a module-level function (not a local function
-- nested inside show_window). We detect this by checking that `local function
-- _stop_poll` appears in the source, which is the module-level declaration
-- pattern used in this codebase.
local stop_fn_pos = src:find("local function _stop_poll()", 1, true)
helpers.assert_true(
	stop_fn_pos ~= nil,
	"healthcheck.lua must define _stop_poll() as a module-level local function (lib-health-1)"
)

-- Test 3: _stop_poll() is called in the window-reopen cleanup path — i.e.,
-- inside the `if _window then` block — so the OLD timer is stopped before the
-- old webview is deleted. The cleanup pattern: _stop_poll() then _window:delete().
local window_cleanup = src:find("_stop_poll()\n\t\tpcall(function() _window:delete()", 1, true)
	or src:find("_stop_poll()\r\n\t\tpcall(function() _window:delete()", 1, true)
helpers.assert_true(
	window_cleanup ~= nil,
	"healthcheck.lua must call _stop_poll() before deleting the old window (lib-health-1 reopen cleanup)"
)

print("[PASS] test_healthcheck_poll_timer_leak")
