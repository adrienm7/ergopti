--- tests/unit/llm/test_api_mlx_warmup_giveup_after_discovery.lua

--- Regression test for llm-api-mlx-giveup: the warmup give-up timer was stamped
--- BEFORE the endpoints-discovery short-circuit, so the discovery window (up to
--- DISCOVERY_MAX_WAIT_SEC = 180s) consumed the warmup budget (WARMUP_GIVE_UP_SEC
--- = 120s). A large model that takes 120-180s to map into GPU memory was falsely
--- marked "load failed" before any warmup POST was ever sent.
---
--- Fix: move the `_warmup_started_at` stamp and give-up check to AFTER the
--- `if not ApiMlxDiscovery.is_discovered() then ... return end` short-circuit, so
--- the clock only starts once the endpoints are confirmed. (Discovery moved into
--- api_mlx_discovery; warmup now gates on its is_discovered() getter.)

local helpers = require("tests.helpers")

-- Selected by a declaration unique to modules/llm/api_mlx.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("local function read_user_port_override")
helpers.assert_true(src ~= nil, "modules/llm/api_mlx.lua source must be locatable")

-- Test 1: the endpoints-discovery short-circuit block must appear BEFORE the
-- `_warmup_started_at` stamp in source order.
local discovery_pos   = src:find("if not ApiMlxDiscovery.is_discovered() then", 1, true)
local stamp_pos       = src:find("_warmup_started_at = TimerScheduler.now()", 1, true)

helpers.assert_true(
	discovery_pos ~= nil,
	"api_mlx.lua warmup() must contain `if not ApiMlxDiscovery.is_discovered() then` short-circuit"
)
helpers.assert_true(
	stamp_pos ~= nil,
	"api_mlx.lua warmup() must contain `_warmup_started_at = TimerScheduler.now()` stamp"
)
helpers.assert_true(
	discovery_pos < stamp_pos,
	"Discovery short-circuit must appear BEFORE the _warmup_started_at stamp in warmup() — " ..
	"found discovery at pos " .. tostring(discovery_pos) .. ", stamp at pos " .. tostring(stamp_pos) ..
	" (llm-api-mlx-giveup)"
)

-- Test 2: give-up check (`warmup_elapsed >= WARMUP_GIVE_UP_SEC`) also appears
-- after the discovery short-circuit.
local giveup_pos = src:find("warmup_elapsed >= WARMUP_GIVE_UP_SEC", 1, true)
helpers.assert_true(
	giveup_pos ~= nil,
	"api_mlx.lua warmup() must contain `warmup_elapsed >= WARMUP_GIVE_UP_SEC` check"
)
helpers.assert_true(
	discovery_pos < giveup_pos,
	"Discovery short-circuit must appear BEFORE the give-up check in warmup() (llm-api-mlx-giveup)"
)

print("[PASS] test_api_mlx_warmup_giveup_after_discovery")
