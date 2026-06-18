--- tests/unit/ui/test_menu_paths_logger_format.lua

--- Regression test for ui-menu-misc-2: menu_paths.lua had Logger calls that
--- used "{1}", "{2}" as format placeholders throughout the file. The Logger
--- uses Lua's string.format internally, which only recognises %s, %d, etc.
--- The {N} placeholders were emitted literally, hiding actual values in logs.
---
--- Fix: replaced all '{1}' / '{2}' with '%s', and '={1}' / '={2}' with '=%s'
--- throughout the file.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "ui/menu/menu_paths.lua"
local fh = io.open(src_path, "r")
if not fh then error("menu_paths.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Test 1: No Logger call may contain a {N} placeholder.
-- Search for the patterns '{1}' or '{2}' or '{3}' as literal strings.
local has_brace_1 = src:find("'{1}'", 1, true) ~= nil
local has_brace_2 = src:find("'{2}'", 1, true) ~= nil
local has_eq_1    = src:find("={1}", 1, true) ~= nil
local has_eq_2    = src:find("={2}", 1, true) ~= nil
helpers.assert_true(
	not has_brace_1 and not has_brace_2 and not has_eq_1 and not has_eq_2,
	"menu_paths.lua must not use {1}/{2} Logger placeholders — use %s (ui-menu-misc-2)"
)

-- Test 2: At least one corrected %s format must now appear in a Logger call.
local has_percent_s_log = src:find("Logger%.%w+%(LOG, \"[^\"]*%%s", 1, false) ~= nil
helpers.assert_true(
	has_percent_s_log,
	"menu_paths.lua must have at least one Logger call with a '%%s' format argument (ui-menu-misc-2)"
)

print("[PASS] test_menu_paths_logger_format")
