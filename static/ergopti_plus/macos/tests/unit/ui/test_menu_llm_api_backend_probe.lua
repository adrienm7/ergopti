--- tests/unit/ui/test_menu_llm_api_backend_probe.lua

--- Regression test for ui-menu-llm-core-1: probe_llm_health() in
--- menu_llm/init.lua had no branch for backend == "api". It fell through to
--- the MLX URL, so a residual MLX server would light the orange "warming"
--- indicator even when the active backend was remote API.
---
--- Fix: added an early return for backend == "api" at the top of
--- probe_llm_health so no async probe is launched in that mode.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "ui/menu/menu_llm/init.lua"
local fh = io.open(src_path, "r")
if not fh then error("menu_llm/init.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Locate probe_llm_health body.
local fn_pos = src:find("local function probe_llm_health(", 1, true)
helpers.assert_true(fn_pos ~= nil, "menu_llm/init.lua must define probe_llm_health (ui-menu-llm-core-1)")
local fn_body = src:sub(fn_pos, fn_pos + 400)

-- Test 1: the function must short-circuit for backend == "api".
local has_api_guard = fn_body:find('backend == "api"', 1, true) ~= nil
helpers.assert_true(
	has_api_guard,
	'probe_llm_health must guard on backend == "api" and return early (ui-menu-llm-core-1)'
)

-- Test 2: the api guard must appear before any URL construction.
local api_guard_pos = fn_body:find('backend == "api"', 1, true)
local url_pos       = fn_body:find("url = ", 1, true)
helpers.assert_true(
	api_guard_pos ~= nil and (url_pos == nil or api_guard_pos < url_pos),
	"api guard must precede URL construction in probe_llm_health (ui-menu-llm-core-1)"
)

print("[PASS] test_menu_llm_api_backend_probe")
