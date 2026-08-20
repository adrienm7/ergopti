--- tests/unit/ui/test_patch_personal_toml_dedup.lua

--- Regression test for ui-windows-b-4: hotstrings_config_window/init.lua
--- patch_personal_toml() scanned for a field line with `field_line = i`,
--- overwriting on each match. When a [_meta] block contained two "delay ="
--- lines only the last index survived, so the first stale line was left in
--- the file after patching.
---
--- The UI now delegates this operation to infra.toml.record_editor. This test
--- exercises the public operation instead of pinning the helper's local variable
--- names, so a refactor cannot make the regression guard fail while preserving
--- behaviour (or pass merely because a particular identifier remains in source).

local helpers = require("tests.helpers")

-- The source check proves the UI reaches the tested operation. The behavioural
-- assertions below prove the duplicate-removal invariant itself.
local src = helpers.read_driver_source("local function global_default_delay_ms")
helpers.assert_true(src ~= nil, "ui/hotstrings_config_window/init.lua source must be locatable")
helpers.assert_true(
	src:find("TomlRecordEditor.patch_table_field", 1, true) ~= nil,
	"patch_personal_toml must delegate complete-record edits to TomlRecordEditor"
)

local Editor = require("infra.toml.record_editor")
local duplicated = table.concat({
	"[_meta]",
	"delay = 100",
	"description = \"kept\"",
	"delay = 200",
	"delay = 300",
	"",
	"[personal]",
	"foo = \"bar\"",
}, "\n") .. "\n"

local replaced = assert(Editor.patch_table_field(duplicated, "[_meta]", "delay", "750"))
local _, replacement_count = replaced:gsub("delay%s*=", "")
helpers.assert_eq(replacement_count, 1,
	"replacing a duplicated field must leave exactly one assignment")
helpers.assert_true(replaced:find("delay = 750", 1, true) ~= nil,
	"the first assignment must receive the replacement value")
helpers.assert_true(replaced:find('description = "kept"', 1, true) ~= nil,
	"unrelated records in the same table must survive")

local removed = assert(Editor.patch_table_field(duplicated, "[_meta]", "delay", nil))
helpers.assert_true(removed:find("delay%s*=", 1, false) == nil,
	"removing a duplicated field must delete every assignment")
helpers.assert_true(removed:find('description = "kept"', 1, true) ~= nil,
	"removing duplicates must preserve unrelated records")

print("[PASS] test_patch_personal_toml_dedup")
