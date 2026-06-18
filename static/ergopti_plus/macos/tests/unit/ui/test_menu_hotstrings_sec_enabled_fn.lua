--- tests/unit/ui/test_menu_hotstrings_sec_enabled_fn.lua

--- Regression test for ui-menu-layout-hot-2: menu_hotstrings.lua build_custom()
--- referenced `is_sec_enabled_fn` inside the personal-extension tree-building
--- loop (line ~1119). That variable was never defined in the surrounding scope —
--- it resolves to the global nil, making `not is_sec_enabled_fn` always true and
--- counting all sections as active, regardless of their enabled state.
---
--- Fix: replaced the undefined reference with a `sec_enabled_fn` local derived
--- from `ctx.keymap.is_section_enabled`, consistent with all other call sites.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "ui/menu/menu_hotstrings.lua"
local fh = io.open(src_path, "r")
if not fh then error("menu_hotstrings.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Test 1: The two exact code expressions that used the undefined variable must not appear.
-- (Comments referencing it by name are OK; the actual variable-reference patterns are not.)
local has_code_not   = src:find("not is_sec_enabled_fn ", 1, true) ~= nil
local has_code_call  = src:find("or is_sec_enabled_fn(", 1, true) ~= nil
helpers.assert_true(
	not has_code_not and not has_code_call,
	"menu_hotstrings.lua must not use is_sec_enabled_fn as a code variable (ui-menu-layout-hot-2)"
)

-- Test 2: The replacement uses is_section_enabled from ctx.keymap.
local has_correct = src:find("ctx.keymap.is_section_enabled", 1, true) ~= nil
helpers.assert_true(
	has_correct,
	"menu_hotstrings.lua must use ctx.keymap.is_section_enabled in the extension tree loop (ui-menu-layout-hot-2)"
)

print("[PASS] test_menu_hotstrings_sec_enabled_fn")
