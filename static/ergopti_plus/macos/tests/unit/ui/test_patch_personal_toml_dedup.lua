--- tests/unit/ui/test_patch_personal_toml_dedup.lua

--- Regression test for ui-windows-b-4: hotstrings_config_window/init.lua
--- patch_personal_toml() scanned for a field line with `field_line = i`,
--- overwriting on each match. When a [_meta] block contained two "delay ="
--- lines only the last index survived, so the first stale line was left in
--- the file after patching.
---
--- Fix: replaced field_line (scalar) with field_lines (array). On replace,
--- the first match is updated and extras are removed in reverse-index order.
--- On remove, all matches are removed in reverse order.

local helpers = require("tests.helpers")

-- Selected by a declaration unique to ui/hotstrings_config_window/init.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("local function global_default_delay_ms")
helpers.assert_true(src ~= nil, "ui/hotstrings_config_window/init.lua source must be locatable")

-- Test 1: old scalar field_line assignment must not appear in the scan loop.
-- The pattern is: `field_line = i` (direct assignment, not declaration).
local has_old_scalar = src:find("field_line%s*=%s*i\n", 1, false) ~= nil
	or src:find("\t\t\t\tfield_line = i", 1, true) ~= nil
helpers.assert_true(
	not has_old_scalar,
	"patch_personal_toml must not use scalar field_line = i in the scan loop (ui-windows-b-4)"
)

-- Test 2: field_lines (array) must be used instead.
local has_field_lines = src:find("field_lines", 1, true) ~= nil
helpers.assert_true(
	has_field_lines,
	"patch_personal_toml must collect matches into field_lines array (ui-windows-b-4)"
)

-- Test 3: removal must iterate in reverse order.
local has_reverse_remove = src:find("#field_lines, 2, -1", 1, true) ~= nil
helpers.assert_true(
	has_reverse_remove,
	"patch_personal_toml replace must remove extra duplicates in reverse order (ui-windows-b-4)"
)

-- Test 4: the remove branch must also iterate all field_lines in reverse order.
local has_remove_all = src:find("#field_lines, 1, -1", 1, true) ~= nil
helpers.assert_true(
	has_remove_all,
	"patch_personal_toml remove branch must delete all duplicate field lines (ui-windows-b-4)"
)

print("[PASS] test_patch_personal_toml_dedup")
