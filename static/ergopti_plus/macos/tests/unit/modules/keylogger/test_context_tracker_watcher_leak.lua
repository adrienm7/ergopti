--- tests/unit/modules/keylogger/test_context_tracker_watcher_leak.lua

--- Regression test for keylogger-support-1: context_tracker attached an
--- AXValueChanged watcher on the bootstrap focused element (E1) but did not
--- set _last_focused_element after the addWatcher call. When E2 later got
--- focus, the focus-change handler's guard `if _last_focused_element` was nil
--- so removeWatcher was never called on E1 — the watcher leaked, accumulating
--- one orphan per app activation.
---
--- Fix: add `_last_focused_element = focused` immediately after the bootstrap
--- addWatcher(focused, "AXValueChanged") call in update_ax_observer().

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "modules/keylogger/context_tracker.lua"
local fh = io.open(src_path, "r")
if not fh then error("context_tracker.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Test 1: _last_focused_element is assigned inside the bootstrap `if focused then` block.
-- Find the bootstrap block and verify the assignment appears before the block closes.
-- Pre-fix: assignment only inside the focus-change handler, not the bootstrap.
local bootstrap_start = src:find('observer:addWatcher(focused, "AXValueChanged")', 1, true)
helpers.assert_true(
	bootstrap_start ~= nil,
	'context_tracker.lua bootstrap must call observer:addWatcher(focused, "AXValueChanged")'
)

-- After the bootstrap addWatcher, _last_focused_element = focused must appear
-- before the next `end` that closes the `if focused then` block.
local after_bootstrap = src:sub(bootstrap_start)
local assign_pos = after_bootstrap:find("_last_focused_element = focused", 1, true)
local end_pos    = after_bootstrap:find("\n\tend\n", 1, true)  -- first end after bootstrap

helpers.assert_true(
	assign_pos ~= nil,
	"context_tracker.lua must assign _last_focused_element = focused in bootstrap block (keylogger-support-1)"
)
helpers.assert_true(
	end_pos == nil or assign_pos < end_pos,
	"_last_focused_element = focused must appear inside the bootstrap 'if focused then' block, before its closing end (keylogger-support-1)"
)

-- Test 2: the focus-change handler still has its removeWatcher guard.
local remove_watcher = src:find('watcher:removeWatcher(_last_focused_element, "AXValueChanged")', 1, true)
helpers.assert_true(
	remove_watcher ~= nil,
	'context_tracker.lua focus-change handler must still call watcher:removeWatcher(_last_focused_element, "AXValueChanged") (keylogger-support-1)'
)

print("[PASS] test_context_tracker_watcher_leak")
