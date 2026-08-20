--- tests/unit/modules/llm/test_ollama_deps_forward_chunk_append_log.lua

--- Regression test for lib-deps-3: ollama_deps_checker.lua forward_chunk()
--- called llm_progress.set_detail but omitted llm_progress.append_log, so
--- the progress log area stayed empty while the detail label updated.
--- mlx_deps_checker.lua already calls both; this fixes the inconsistency.
---
--- Fix: added pcall(llm_progress.append_log, line) after set_detail.

local helpers = require("tests.helpers")

-- Selected by a declaration unique to modules/llm/ollama_deps_checker.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("local function resolve_project_root")
helpers.assert_true(src ~= nil, "modules/llm/ollama_deps_checker.lua source must be locatable")

-- Test 1: append_log must appear in the source.
local has_append_log = src:find("append_log", 1, true) ~= nil
helpers.assert_true(
	has_append_log,
	"ollama_deps_checker.lua forward_chunk must call llm_progress.append_log (lib-deps-3)"
)

-- Test 2: append_log must appear inside forward_chunk.
local fc_pos = src:find("local function forward_chunk", 1, true)
helpers.assert_true(fc_pos ~= nil, "forward_chunk must exist (lib-deps-3)")
local fc_body = src:sub(fc_pos, fc_pos + 400)
local has_append_in_fc = fc_body:find("append_log", 1, true) ~= nil
helpers.assert_true(
	has_append_in_fc,
	"append_log call must be inside forward_chunk (lib-deps-3)"
)

-- Test 3: set_detail must still be present alongside append_log.
local has_set_detail_in_fc = fc_body:find("set_detail", 1, true) ~= nil
helpers.assert_true(
	has_set_detail_in_fc,
	"forward_chunk must still call set_detail (lib-deps-3)"
)

-- Test 4: append_log must come after set_detail inside forward_chunk.
local sd_pos = fc_body:find("set_detail", 1, true)
local al_pos = fc_body:find("append_log", 1, true)
helpers.assert_true(
	sd_pos ~= nil and al_pos ~= nil and al_pos > sd_pos,
	"append_log must appear after set_detail inside forward_chunk (lib-deps-3)"
)

print("[PASS] test_ollama_deps_forward_chunk_append_log")
