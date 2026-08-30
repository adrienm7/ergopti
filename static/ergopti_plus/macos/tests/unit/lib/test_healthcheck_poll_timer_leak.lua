--- tests/unit/lib/test_healthcheck_poll_timer_leak.lua

--- Regression test for lib-health-1: reopening the healthcheck window previously
--- leaked the copy-button poll timer. The `_poll_timer` was a local variable
--- inside show_window(), so each reopen call created a new local while the old
--- timer kept firing indefinitely — polling a deleted webview.
---
--- Fix: _poll_timer and _stop_poll() are module-level variables. The exact
--- close transaction deletes the old WebView, invalidates it, and settles the
--- old timer before show_window() can allocate a successor.

local helpers = require("tests.helpers")

-- After the F2 split, the poll-timer / window logic lives in core.lua.
-- Selected by a declaration unique to ui/healthcheck/core.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("local function _stop_poll")
helpers.assert_true(src ~= nil, "ui/healthcheck/core.lua source must be locatable")

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

-- Test 3: the exact close transaction owns poll cleanup, and reopening invokes
-- that transaction before native successor allocation. Native delete commits
-- first so a refusal retains the still-live window and poller together.
local close_start = src:find("local function close_owned_window", 1, true)
local close_end = close_start and src:find("local function schedule_continuation", close_start, true)
local close_body = close_start and close_end and src:sub(close_start, close_end - 1)
helpers.assert_true(
	close_body ~= nil and close_body:find("_stop_poll()", 1, true) ~= nil,
	"the healthcheck close transaction must settle the exact copy poller"
)

local show_start = src:find("function M.show_window()", 1, true)
local successor = show_start and src:find("pcall(hs.webview.new", show_start, true)
local reopen_close = show_start and src:find("close_owned_window(_window", show_start, true)
helpers.assert_true(
	reopen_close ~= nil and successor ~= nil and reopen_close < successor,
	"healthcheck reopen must settle the old window runtime before successor allocation"
)

print("[PASS] test_healthcheck_poll_timer_leak")
