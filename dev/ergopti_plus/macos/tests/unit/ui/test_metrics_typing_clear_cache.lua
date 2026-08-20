--- tests/unit/ui/test_metrics_typing_clear_cache.lua

--- Regression test for ui-windows-b-3: metrics_typing/init.lua clear_cache
--- handler reset _range_cache and _manifest_cache but left _last_query set.
--- push_live_update() checks `M._last_query` to decide whether to arm the
--- live-update flag — with a stale _last_query still set, a push_live_update
--- call immediately after a clear would re-fetch against the just-wiped state.
---
--- Fix: added `M._last_query = nil` in the clear_cache branch.

local helpers = require("tests.helpers")

-- Selected by a declaration unique to ui/metrics_typing/init.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("local function _maybe_invalidate_range_cache")
helpers.assert_true(src ~= nil, "ui/metrics_typing/init.lua source must be locatable")

-- Locate the clear_cache handler block.
local cc_start = src:find('query.action == "clear_cache"', 1, true)
helpers.assert_true(
	cc_start ~= nil,
	"metrics_typing/init.lua must contain the clear_cache action branch (ui-windows-b-3)"
)

-- Extract up to 400 chars from that point to cover the handler body.
local cc_body = src:sub(cc_start, cc_start + 400)

-- Test 1: _last_query must be reset to nil in the clear_cache branch.
local has_last_query_clear = cc_body:find("_last_query = nil", 1, true) ~= nil
helpers.assert_true(
	has_last_query_clear,
	"metrics_typing/init.lua clear_cache must set M._last_query = nil to prevent stale re-fetch (ui-windows-b-3)"
)

-- Test 2: The reset must appear before (or alongside) the cache clears —
-- confirm all three resets are within the same block.
local has_range_clear    = cc_body:find("_range_cache", 1, true) ~= nil
local has_manifest_clear = cc_body:find("_manifest_cache", 1, true) ~= nil
helpers.assert_true(
	has_range_clear and has_manifest_clear,
	"metrics_typing/init.lua clear_cache must still reset _range_cache and _manifest_cache (ui-windows-b-3)"
)

print("[PASS] test_metrics_typing_clear_cache")
