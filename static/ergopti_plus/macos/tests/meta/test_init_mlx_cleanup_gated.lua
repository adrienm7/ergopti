--- tests/meta/test_init_mlx_cleanup_gated.lua

--- Regression test for init-boot-mlx: init.lua ran the synchronous MLX
--- cleanup block (lsof + curl --max-time 1 + pgrep) unconditionally on every
--- boot, including when LLM was disabled. The cleanup only serves the warmup
--- retry loop which is itself gated on LLM being enabled. When LLM is off,
--- the synchronous shell commands (up to ~1s for the curl probe) ran for
--- no reason on the critical boot path.
---
--- Fix: added a fast-path gate (hs.settings.get("llm.enabled") ~= false) BEFORE
--- the cleanup, wrapping it in `if mlx_cleanup_enabled then`. The cleanup body
--- itself was later extracted to modules/llm/boot_cleanup.lua (run_selective_cleanup);
--- the gate stays in init.lua so a disabled-LLM boot never even loads the module.

local helpers = require("tests.helpers")

local function read(path)
	local fh = io.open(path, "r")
	if not fh then error("not readable at: " .. path) end
	local s = fh:read("*a"); fh:close()
	return s
end

local init_src = read(helpers.driver_root() .. "init.lua")

-- Test 1: init.lua must declare the gate before the cleanup call.
local gate_pos = init_src:find("local mlx_cleanup_enabled", 1, true)
local call_pos = init_src:find("boot_cleanup", 1, true)
helpers.assert_true(
	gate_pos ~= nil,
	"init.lua must declare mlx_cleanup_enabled before the cleanup call (init-boot-mlx)"
)
helpers.assert_true(
	call_pos ~= nil,
	"init.lua must call the extracted modules.llm.boot_cleanup (init-boot-mlx)"
)
helpers.assert_true(
	gate_pos < call_pos,
	"mlx_cleanup_enabled must be declared before the boot_cleanup call (init-boot-mlx)"
)

-- Test 2: the cleanup call must be wrapped in `if mlx_cleanup_enabled then`.
local between = init_src:sub(gate_pos, call_pos)
helpers.assert_true(
	between:find("if mlx_cleanup_enabled then", 1, true) ~= nil,
	"the MLX cleanup call must be gated by if mlx_cleanup_enabled then (init-boot-mlx)"
)

-- Test 3: the actual cleanup shell block (the [BOOT-NUKE] marker) now lives in
-- the extracted module, not init.lua.
local cleanup_src = read(helpers.driver_root() .. "modules/llm/boot_cleanup.lua")
helpers.assert_true(
	cleanup_src:find("[BOOT-NUKE]", 1, true) ~= nil,
	'boot_cleanup.lua must contain the "[BOOT-NUKE]" cleanup marker (init-boot-mlx)'
)

print("[PASS] test_init_mlx_cleanup_gated")
