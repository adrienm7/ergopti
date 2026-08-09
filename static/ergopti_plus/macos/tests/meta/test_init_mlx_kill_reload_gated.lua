--- tests/meta/test_init_mlx_kill_reload_gated.lua

--- Regression test for F3: local teardown killed mlx_lm.server on reload,
--- defeating the boot-path optimisation that deliberately spares a healthy
--- MLX server across sessions.
---
--- The current transaction receives an explicit `reload` or `exit` kind. The
--- orphan sweep must be an exit-only step; the unawaitable native shutdown
--- callback never performs local process cleanup.

local helpers = require("tests.helpers")

-- Selected by a declaration unique to init.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("local function has_common_hotstring_groups")
helpers.assert_true(src ~= nil, "init.lua source must be locatable")

-- Locate the exact-fenced controlled teardown. The actual sweep must remain
-- exit-only.
local marker_pos = src:find("local function teardown_all_resources", 1, true)
helpers.assert_true(
	marker_pos ~= nil,
	"init.lua must define the shared local teardown"
)

local shutdown_pos = src:find("local function shutdown_all_resources", marker_pos, true)
helpers.assert_true(shutdown_pos ~= nil, "controlled teardown must precede native shutdown")
local region = src:sub(marker_pos, shutdown_pos - 1)

helpers.assert_true(
	region:find('if termination_kind == "exit" then', 1, true) ~= nil,
	"The orphan MLX sweep must be gated by the exact controlled termination kind"
)

-- F-M7 moved the actual pgrep/lsof sweep into the shared
-- menu_llm.terminate_orphan_mlx_server() (so the shutdown and script_quit paths
-- cannot drift). The reload GATE — the invariant this test protects — still wraps
-- the kill: the guarded region must invoke that shared helper. The pgrep command
-- itself is asserted in test_script_quit_revokes_karabiner_lease / test_audit_senior_hs_fixes.
helpers.assert_true(
	region:find("terminate_orphan_mlx_server", 1, true) ~= nil,
	"The reload-guarded region must invoke menu_llm.terminate_orphan_mlx_server (the MLX kill)"
)

print("[PASS] test_init_mlx_kill_reload_gated")
