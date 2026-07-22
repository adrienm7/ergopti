--- tests/unit/ui/test_menu_llm_format_shortcut_none.lua

--- Regression test for ui-menu-llm-core-6: format_shortcut_title() used
--- `#mods == 1 and mods[1] == "none"` to detect the disabled state.
--- This positional check only works when "none" is the first (and only)
--- element. If future code appends an extra element before "none" or
--- produces `{"none", "x"}`, the disabled branch is silently missed.
---
--- Fix: extracted a mods_has_none() linear scan and replaced the positional
--- check with a call to it, making the detection order-independent.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "ui/menu/menu_llm/init.lua"
local fh = io.open(src_path, "r")
if not fh then error("menu_llm/init.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Test 1: The old positional check must not appear.
local has_old_check = src:find('#mods == 1 and mods[1] == "none"', 1, true) ~= nil
helpers.assert_true(
	not has_old_check,
	"menu_llm/init.lua must not use the positional `#mods == 1 and mods[1] == \"none\"` check (ui-menu-llm-core-6)"
)

-- Test 2: A mods_has_none helper must be defined.
local has_helper = src:find("mods_has_none", 1, true) ~= nil
helpers.assert_true(
	has_helper,
	"menu_llm/init.lua must define a mods_has_none() helper (ui-menu-llm-core-6)"
)

-- Test 3: format_shortcut_title must call mods_has_none.
local fn_start = src:find("local function format_shortcut_title", 1, true)
helpers.assert_true(fn_start ~= nil, "menu_llm/init.lua must contain format_shortcut_title (ui-menu-llm-core-6)")
-- Window widened from 300 to 800: the F-HIGH-6 wrong-type guard (a comment block
-- + `if type(mods) ~= "table" then …`) now precedes the mods_has_none(mods) call,
-- pushing it past the old 300-char window. Still asserts the call is present.
local fn_body = src:sub(fn_start, fn_start + 800)
local calls_helper = fn_body:find("mods_has_none(mods)", 1, true) ~= nil
helpers.assert_true(
	calls_helper,
	"menu_llm/init.lua format_shortcut_title must call mods_has_none(mods) (ui-menu-llm-core-6)"
)

print("[PASS] test_menu_llm_format_shortcut_none")
