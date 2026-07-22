--- tests/meta/test_init_mlx_kill_reload_gated.lua

--- Regression test for F3: init.lua shutdownCallback killed mlx_lm.server
--- unconditionally (including on reload), defeating the boot-path optimisation
--- that deliberately spares a healthy MLX server across sessions.
---
--- Fix (2026-06-19): wrapped the `pgrep -f 'mlx_lm.*server' | xargs kill -9`
--- block in `if not reload_guard.is_reloading() then`, matching the existing
--- KE-teardown gate at step 3 of the same callback.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "init.lua"
local fh = io.open(src_path, "r")
if not fh then error("init.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Locate the shutdown MLX kill: look for the literal shutdown-only marker
-- (the guard comment that exists only in the shutdown block)
local shutdown_marker = "Boot logic deliberately spares a healthy server across sessions"
local marker_pos = src:find(shutdown_marker, 1, true)
helpers.assert_true(
	marker_pos ~= nil,
	"init.lua must contain the shutdown MLX kill context comment"
)

-- Check that the guard appears just before or around the marker comment
local region = src:sub(marker_pos - 50, marker_pos + 500)

helpers.assert_true(
	region:find("if not reload_guard.is_reloading()", 1, true) ~= nil,
	"The shutdown MLX kill block must be guarded by 'if not reload_guard.is_reloading()'"
)

-- F-M7 moved the actual pgrep/lsof sweep into the shared
-- menu_llm.terminate_orphan_mlx_server() (so the shutdown and script_quit paths
-- cannot drift). The reload GATE — the invariant this test protects — still wraps
-- the kill: the guarded region must invoke that shared helper. The pgrep command
-- itself is asserted in test_script_quit_kills_karabiner / test_audit_senior_hs_fixes.
helpers.assert_true(
	region:find("terminate_orphan_mlx_server", 1, true) ~= nil,
	"The reload-guarded region must invoke menu_llm.terminate_orphan_mlx_server (the MLX kill)"
)

print("[PASS] test_init_mlx_kill_reload_gated")
