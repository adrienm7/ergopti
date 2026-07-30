--- tests/unit/lib/test_ui_restore_defer_reentrancy.lua

--- Regression test for lib-misc-defer: defer_reload() double-fired the reload
--- when fn() itself called defer_reload() and no UI was open at the time. The
--- inner call took the fast path (any_ui_open() == false) and fired immediately
--- while the outer fn() was still executing — two reloads from one event.
---
--- Fix: a _reload_in_flight flag gates the fast path. A re-entrant call while
--- a reload is already on the call stack stores the callback for the NEXT
--- opportunity rather than firing it immediately.

local helpers = require("tests.helpers")

-- Selected by a declaration unique to lib/ui_restore.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("local function any_ui_open")
helpers.assert_true(src ~= nil, "lib/ui_restore.lua source must be locatable")

-- Test 1: _reload_in_flight flag declared at module level.
local flag_pos = src:find("local _reload_in_flight", 1, true)
helpers.assert_true(
	flag_pos ~= nil,
	"lib/ui_restore.lua must declare _reload_in_flight at module level (lib-misc-defer)"
)

-- Test 2: the guard branches on _reload_in_flight in the fast path.
local fast_guard = src:find("if _reload_in_flight then", 1, true)
helpers.assert_true(
	fast_guard ~= nil,
	"lib/ui_restore.lua fast path must check _reload_in_flight (lib-misc-defer)"
)

-- Test 3: _reload_in_flight is set to true before calling fn.
local set_true = src:find("_reload_in_flight = true", 1, true)
helpers.assert_true(
	set_true ~= nil,
	"lib/ui_restore.lua must set _reload_in_flight = true before calling the reload fn (lib-misc-defer)"
)

-- Test 4: _reload_in_flight is reset to false after the call.
local set_false = src:find("_reload_in_flight = false", 1, true)
helpers.assert_true(
	set_false ~= nil,
	"lib/ui_restore.lua must reset _reload_in_flight = false after calling the reload fn (lib-misc-defer)"
)

print("[PASS] test_ui_restore_defer_reentrancy")
