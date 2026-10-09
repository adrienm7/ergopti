--- tests/unit/modules/llm/test_mlx_deps_progress_no_regression.lua

--- Regression test for lib-deps-2: mlx_deps_checker.lua iterated
--- MARKER_PROGRESS with pairs() and called llm_progress.set_progress(pct)
--- for each matching marker individually. Since pairs() visits table keys in
--- arbitrary order, a chunk containing multiple markers (e.g. UV_INSTALLED=15
--- and DEPS_SYNCED=100) could call set_progress(100) then set_progress(15),
--- regressing the progress bar backwards.
---
--- Fix: accumulate all matching pcts per chunk, then call set_progress once
--- with the maximum, so the bar only ever advances.

local helpers = require("tests.helpers")

-- Selected by a declaration unique to modules/llm/mlx_deps_checker.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("local function resolve_bootstrap_script_path")
helpers.assert_true(src ~= nil, "modules/llm/mlx_deps_checker.lua source must be locatable")

-- Locate the complete MARKER_PROGRESS iteration block by stable statements.
-- A fixed-width slice became a false negative as lifecycle guards were added.
local block_pos = src:find("local max_pct = nil", 1, true)
helpers.assert_true(
	block_pos ~= nil,
	"mlx_deps_checker.lua must use a max_pct accumulator in the MARKER_PROGRESS loop (lib-deps-2)"
)

local block_end = block_pos and src:find("\n\t\treturn true", block_pos, true) or nil
helpers.assert_true(
	block_end ~= nil,
	"mlx_deps_checker.lua progress handler must retain a terminal return after marker processing"
)

local block = src:sub(block_pos, block_end)

-- Test 1: max_pct must be computed as the maximum across all matching markers.
local has_max_compare = block:find("pct > max_pct", 1, true) ~= nil
helpers.assert_true(
	has_max_compare,
	"mlx_deps_checker.lua must compare pct > max_pct to find the maximum (lib-deps-2)"
)

-- Test 2: set_progress must be called ONCE (after the loop) with max_pct.
local has_single_call = block:find("set_progress, max_pct", 1, true) ~= nil
helpers.assert_true(
	has_single_call,
	"mlx_deps_checker.lua must call set_progress with max_pct (not inside the loop) (lib-deps-2)"
)

-- Test 3: set_progress must remain after the accumulation loop. Ordering the
-- stable statements avoids guessing where a nested Lua `end` belongs.
local loop_start = block:find("for marker, pct in pairs", 1, true)
local max_guard = block:find("if max_pct and owns_window() then", 1, true)
local set_progress = block:find("set_progress, max_pct", 1, true)
helpers.assert_true(
	loop_start ~= nil and max_guard ~= nil and set_progress ~= nil
		and loop_start < max_guard and max_guard < set_progress,
	"mlx_deps_checker.lua must call set_progress only after the marker accumulation loop (lib-deps-2)"
)

print("[PASS] test_mlx_deps_progress_no_regression")
