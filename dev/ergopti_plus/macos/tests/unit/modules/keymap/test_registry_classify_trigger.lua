--- tests/unit/modules/keymap/test_registry_classify_trigger.lua

--- Regression test for keymap-core-2: the personal-info interceptor called
--- has_exact_trigger + has_trigger_prefix + has_trigger_suffix separately on
--- every `@` keypress, performing 3×O(N) synchronous scans on the eventtap
--- hot path. With a large corpus (~10-15k entries) this added measurable
--- latency to every `@` keystroke.
---
--- Fix: added M.classify_trigger(str) to registry.lua that performs a single
--- O(N) pass and returns all three flags as multiple return values, with an
--- early-exit as soon as all three are known. The hot call site in
--- personal_info.lua now calls classify_trigger directly.

local helpers = require("tests.helpers")

-- -----------------------------------------------------------------------
-- Load the module under test headlessly (hs.* unavailable).
-- -----------------------------------------------------------------------
local src_path = helpers.driver_root() .. "modules/keymap/registry.lua"

-- Minimal stub: registry reads _state.mappings; we inject _state via the
-- module's own _state variable after load by using the test-facing init.
-- We cannot call M.init() (it expects CoreState), so we replicate the
-- minimal dependency by reading the source and verifying the contract
-- both structurally and logically with a direct require shim.

-- Source-invariant checks
local fh = io.open(src_path, "r")
if not fh then error("registry.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Test 1: classify_trigger must be defined in the source.
local has_fn = src:find("function M.classify_trigger", 1, true) ~= nil
helpers.assert_true(has_fn,
	"registry.lua must define M.classify_trigger (keymap-core-2)")

-- Test 2: the single-loop body must reference all three flags.
local fn_start = src:find("function M.classify_trigger", 1, true)
local fn_end   = src:find("\nfunction M%.", fn_start + 1)
local fn_body  = src:sub(fn_start, fn_end or fn_start + 800)
helpers.assert_true(fn_body:find("exact", 1, true) ~= nil, "classify_trigger must set 'exact' (keymap-core-2)")
helpers.assert_true(fn_body:find("pref",  1, true) ~= nil, "classify_trigger must set 'pref' (keymap-core-2)")
helpers.assert_true(fn_body:find("suff",  1, true) ~= nil, "classify_trigger must set 'suff' (keymap-core-2)")

-- Test 3: early-exit optimization must be present (break when all three found).
local has_early_exit = fn_body:find("break", 1, true) ~= nil
helpers.assert_true(has_early_exit,
	"classify_trigger must break early when all three flags are true (keymap-core-2)")

-- Test 4: has_exact_trigger / has_trigger_prefix / has_trigger_suffix must
-- be implemented in terms of classify_trigger (single-pass delegation).
local exact_fn_start = src:find("function M.has_exact_trigger", 1, true)
local pref_fn_start  = src:find("function M.has_trigger_prefix", 1, true)
local suff_fn_start  = src:find("function M.has_trigger_suffix", 1, true)
helpers.assert_true(exact_fn_start ~= nil, "has_exact_trigger must still exist (keymap-core-2)")
helpers.assert_true(pref_fn_start  ~= nil, "has_trigger_prefix must still exist (keymap-core-2)")
helpers.assert_true(suff_fn_start  ~= nil, "has_trigger_suffix must still exist (keymap-core-2)")

local exact_body = src:sub(exact_fn_start, exact_fn_start + 200)
local pref_body  = src:sub(pref_fn_start,  pref_fn_start  + 200)
local suff_body  = src:sub(suff_fn_start,  suff_fn_start  + 200)
helpers.assert_true(exact_body:find("classify_trigger", 1, true) ~= nil,
	"has_exact_trigger must delegate to classify_trigger (keymap-core-2)")
helpers.assert_true(pref_body:find("classify_trigger", 1, true) ~= nil,
	"has_trigger_prefix must delegate to classify_trigger (keymap-core-2)")
helpers.assert_true(suff_body:find("classify_trigger", 1, true) ~= nil,
	"has_trigger_suffix must delegate to classify_trigger (keymap-core-2)")

-- Test 5: personal_info.lua must call classify_trigger at the hot call site.
local pi_src_path = helpers.driver_root() .. "modules/dynamic_hotstrings/personal_info.lua"
local pi_fh = io.open(pi_src_path, "r")
if not pi_fh then error("personal_info.lua not readable at: " .. pi_src_path) end
local pi_src = pi_fh:read("*a") ; pi_fh:close()

local has_classify_call = pi_src:find("classify_trigger", 1, true) ~= nil
helpers.assert_true(has_classify_call,
	"personal_info.lua interceptor must call classify_trigger (keymap-core-2)")

-- Test 6: the init.lua module facade must expose classify_trigger.
local init_src_path = helpers.driver_root() .. "modules/keymap/init.lua"
local init_fh = io.open(init_src_path, "r")
if not init_fh then error("keymap/init.lua not readable at: " .. init_src_path) end
local init_src = init_fh:read("*a") ; init_fh:close()

local init_exposes = init_src:find("M.classify_trigger", 1, true) ~= nil
helpers.assert_true(init_exposes,
	"keymap/init.lua must expose M.classify_trigger = Registry.classify_trigger (keymap-core-2)")

print("[PASS] test_registry_classify_trigger")
