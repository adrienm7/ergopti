--- tests/unit/ui/menu/menu_llm/test_models_manager_hw_engine_select.lua

--- Regression test for ui-menu-llm-models-2: hardware_requirements were
--- selected with `is_mlx and req.mlx or req.ollama or {}`. When is_mlx=true
--- but req.mlx is nil (model has no MLX requirements), the Lua `and/or` chain
--- evaluates to req.ollama — silently using the wrong engine's requirements.
---
--- Fix: use `is_mlx and (req.mlx or {}) or (req.ollama or {})` so the MLX
--- branch never returns nil (falls back to an empty table first) and the
--- `or` fallthrough to req.ollama cannot occur.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "ui/menu/menu_llm/models_manager.lua"
local fh = io.open(src_path, "r")
if not fh then error("models_manager.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Test 1: the buggy bare pattern `and req.mlx or req.ollama or {}` must not
-- appear. The bare form fails when req.mlx is nil (is_mlx=true path falls
-- through to req.ollama).
local buggy = src:find("and req.mlx or req.ollama or {}", 1, true) ~= nil
helpers.assert_true(
	not buggy,
	"models_manager.lua must not use bare 'and req.mlx or req.ollama or {}' (ui-menu-llm-models-2)"
)

-- Test 2: the fixed form uses parentheses to force the or-fallback inside each
-- engine branch. Both occurrences (ensure_ram_cache and get_model_size_logic)
-- must use this pattern.
local fixed_count = 0
for _ in src:gmatch("is_mlx and %(req%.mlx or {}%) or %(req%.ollama or {}%)") do
	fixed_count = fixed_count + 1
end
helpers.assert_true(
	fixed_count >= 2,
	"models_manager.lua must have at least 2 fixed 'is_mlx and (req.mlx or {}) or (req.ollama or {})' sites, found: " .. fixed_count
)

print("[PASS] test_models_manager_hw_engine_select")
