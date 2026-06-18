--- tests/meta/test_init_mlx_cleanup_gated.lua

--- Regression test for init-boot-mlx: init.lua ran the synchronous MLX
--- cleanup block (lsof + curl --max-time 1 + pgrep) unconditionally on every
--- boot, including when LLM was disabled. The cleanup only serves the warmup
--- retry loop which is itself gated on LLM being enabled. When LLM is off,
--- the synchronous shell commands (up to ~1s for the curl probe) ran for
--- no reason on the critical boot path.
---
--- Fix: added a fast-path boot_llm_enabled check (hs.settings.get("llm.enabled")
--- ~= false) BEFORE the cleanup block; wrapped the block in if boot_llm_enabled.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "init.lua"
local fh = io.open(src_path, "r")
if not fh then error("init.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Test 1: boot_llm_enabled must appear before [BOOT-NUKE] in the file.
local gen_pos  = src:find("local boot_llm_enabled", 1, true)
local nuke_pos = src:find("[BOOT-NUKE]", 1, true)
helpers.assert_true(
	gen_pos ~= nil,
	"init.lua must declare boot_llm_enabled before the cleanup block (init-boot-mlx)"
)
helpers.assert_true(
	nuke_pos ~= nil,
	'init.lua must contain "[BOOT-NUKE]" marker in the cleanup block (init-boot-mlx)'
)
helpers.assert_true(
	gen_pos < nuke_pos,
	"boot_llm_enabled must be declared before [BOOT-NUKE] (init-boot-mlx)"
)

-- Test 2: the cleanup block must be wrapped in if boot_llm_enabled then.
-- Check in the region between gen_pos and nuke_pos.
local between = src:sub(gen_pos, nuke_pos)
local has_if_gate = between:find("if boot_llm_enabled then", 1, true) ~= nil
helpers.assert_true(
	has_if_gate,
	"the MLX cleanup block must be gated by if boot_llm_enabled then (init-boot-mlx)"
)

print("[PASS] test_init_mlx_cleanup_gated")
