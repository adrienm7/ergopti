--- tests/unit/ui/test_models_manager_mlx_home_guard.lua

--- Regression test for ui-menu-llm-models-4: get_installed_models() called
--- `home .. "/.cache/huggingface/hub/"` without checking whether HOME was
--- set. If os.getenv("HOME") returns nil (sandbox or unusual environment),
--- the concatenation crashes Lua with "attempt to concatenate a nil value".
---
--- Fix: added an early-return guard after os.getenv("HOME") — log ERROR and
--- return the empty installed table if HOME is not set.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "ui/menu/menu_llm/models_manager_mlx.lua"
local fh = io.open(src_path, "r")
if not fh then error("models_manager_mlx.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Locate the get_installed_models block.
local fn_start = src:find("get_installed_models", 1, true)
helpers.assert_true(
	fn_start ~= nil,
	"models_manager_mlx.lua must contain get_installed_models (ui-menu-llm-models-4)"
)

local fn_body = src:sub(fn_start, fn_start + 600)

-- Test 1: A nil-check on home must appear before the concatenation.
local has_home_guard = fn_body:find("if not home then", 1, true) ~= nil
helpers.assert_true(
	has_home_guard,
	"models_manager_mlx.lua get_installed_models must guard os.getenv('HOME') with nil-check (ui-menu-llm-models-4)"
)

-- Test 2: The guard must early-return on nil HOME.
local guard_pos = fn_body:find("if not home then", 1, true)
local guard_block = fn_body:sub(guard_pos, guard_pos + 150)
local has_return = guard_block:find("return", 1, true) ~= nil
helpers.assert_true(
	has_return,
	"models_manager_mlx.lua HOME nil-guard must return early (ui-menu-llm-models-4)"
)

-- Test 3: The guard must appear before the concatenation `home .. `.
local home_concat_pos = fn_body:find('home .. "/', 1, true)
helpers.assert_true(
	guard_pos < home_concat_pos,
	"models_manager_mlx.lua nil-guard on HOME must appear before the `home ..` concatenation (ui-menu-llm-models-4)"
)

print("[PASS] test_models_manager_mlx_home_guard")
