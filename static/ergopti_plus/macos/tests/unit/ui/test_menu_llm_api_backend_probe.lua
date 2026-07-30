--- tests/unit/ui/test_menu_llm_api_backend_probe.lua

--- Regression test for ui-menu-llm-core-1: probe_llm_health() in
--- menu_llm/init.lua had no branch for backend == "api". It fell through to
--- the MLX URL, so a residual MLX server would light the orange "warming"
--- indicator even when the active backend was remote API.
---
--- Fix: added an early return for backend == "api" at the top of
--- probe_llm_health so no async probe is launched in that mode.
---
--- F-LOW-6: that early-return guard means _llm_health_status is never
--- ASSIGNED while backend == "api" — but nothing ever RESET it either, so a
--- prior MLX/Ollama reading (true = warming/yellow) leaked into the API
--- backend's status-dot display until an unrelated full backend round-trip
--- happened to overwrite it. Fix: M.reset_llm_health_status() clears the
--- flag, threaded through BackendPanel.build's ctx and called from the API
--- entry's switch handler in backend_panel.lua.

local helpers = require("tests.helpers")

-- Selected by a declaration unique to ui/menu/menu_llm/init.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("function M.terminate_orphan_mlx_server")
helpers.assert_true(src ~= nil, "ui/menu/menu_llm/init.lua source must be locatable")

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

-- Test 3 (F-LOW-6): menu_llm/init.lua must expose a reset function for the
-- health-status flag.
helpers.assert_true(
	src:find("function M.reset_llm_health_status()", 1, true) ~= nil,
	"menu_llm/init.lua must define M.reset_llm_health_status (F-LOW-6)"
)
local reset_fn_pos = src:find("function M.reset_llm_health_status()", 1, true)
local reset_fn_body = src:sub(reset_fn_pos, reset_fn_pos + 150)
helpers.assert_true(
	reset_fn_body:find("_llm_health_status = nil", 1, true) ~= nil,
	"M.reset_llm_health_status must set _llm_health_status back to nil (F-LOW-6)"
)

-- Test 4 (F-LOW-6): BackendPanel.build must be called with a
-- reset_llm_health_status hook wired to M.reset_llm_health_status.
helpers.assert_true(
	src:find("reset_llm_health_status = M.reset_llm_health_status", 1, true) ~= nil,
	"menu_llm/init.lua must thread M.reset_llm_health_status into BackendPanel.build's ctx (F-LOW-6)"
)

-- Test 5 (F-LOW-6): backend_panel.lua's API-backend switch handler must call
-- the reset hook when activating the API backend.
-- Selected by a declaration rather than by path, so moving or splitting the
-- module cannot turn this invariant into a path error. The selector is not
-- unique to backend_panel.lua — menu_llm/init.lua declares it too — so the
-- assertion below is written to be ORDER-INDEPENDENT: it extracts the handler
-- by its own delimiters instead of taking a fixed-width window after a hit,
-- which is what made the old form depend on where the file sat in the scan.
local panel_src = helpers.read_driver_source("local function check_backend_deps")
helpers.assert_true(panel_src ~= nil, "ui/menu/menu_llm/backend_panel.lua source must be locatable")

local api_switch_pos = panel_src:find('state.llm_backend = "api"', 1, true)
helpers.assert_true(api_switch_pos ~= nil, "backend_panel.lua must set state.llm_backend = \"api\" on API switch")
-- The handler runs from the backend flip to the `end` closing its `if`, at the
-- same indentation as the `if` itself. Bounding on that instead of on 500
-- characters keeps the check inside the one function it is about.
local api_switch_body = panel_src:sub(api_switch_pos, (panel_src:find("\n\t\t\tend\n", api_switch_pos, true) or #panel_src))
helpers.assert_true(
	api_switch_body:find("reset_llm_health_status", 1, true) ~= nil,
	"backend_panel.lua's API-backend switch handler must call reset_llm_health_status (F-LOW-6)"
)

print("[PASS] test_menu_llm_api_backend_probe")
