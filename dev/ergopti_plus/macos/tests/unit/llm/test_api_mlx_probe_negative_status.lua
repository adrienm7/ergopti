--- tests/unit/llm/test_api_mlx_probe_negative_status.lua

--- Regression test for llm-api-mlx-probe: the endpoint discovery probe accepted
--- NSURLError codes (negative integers, e.g. -1 = connection refused/reset) as
--- live routes. The original guard `r.status ~= 404 and r.status ~= 0` only
--- rejected two specific sentinels but not the full range of negative codes that
--- hs.http.asyncPost passes verbatim.
---
--- Fix: `if type(r.status) == "number" and r.status >= 200 and r.status ~= 404`
--- so any negative or sub-200 code (transport errors) is treated as a miss.

local helpers = require("tests.helpers")

-- The endpoint discovery probe was extracted from api_mlx.lua into api_mlx_discovery.lua.
-- Selected by a declaration unique to modules/llm/api_mlx_discovery.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("local function read_active_model_arg")
helpers.assert_true(src ~= nil, "modules/llm/api_mlx_discovery.lua source must be locatable")

-- Test 1: the buggy two-sentinel guard must not appear in the probe callback.
-- Pre-fix: `r.status ~= 404 and r.status ~= 0`
local buggy = src:find("r.status ~= 404 and r.status ~= 0", 1, true) ~= nil
helpers.assert_true(
	not buggy,
	"api_mlx.lua probe must not use `r.status ~= 404 and r.status ~= 0` — rejects only two sentinels, not all NSURLError negatives (llm-api-mlx-probe)"
)

-- Test 2: the fixed guard is in place.
-- Post-fix: `type(r.status) == "number" and r.status >= 200 and r.status ~= 404`
local fixed = src:find('type(r.status) == "number" and r.status >= 200 and r.status ~= 404', 1, true) ~= nil
helpers.assert_true(
	fixed,
	"api_mlx.lua probe must use `type(r.status) == \"number\" and r.status >= 200 and r.status ~= 404` to reject NSURLError negatives (llm-api-mlx-probe)"
)

print("[PASS] test_api_mlx_probe_negative_status")
