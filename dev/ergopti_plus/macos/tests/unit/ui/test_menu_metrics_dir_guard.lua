--- tests/unit/ui/test_menu_metrics_dir_guard.lua

--- Regression test for ui-menu-misc-3: menu_metrics.lua called `for file in
--- fs.dir(log_dir)` in both the encrypt and decrypt toggle paths without
--- checking whether fs.dir returned a valid iterator. When log_dir does not
--- exist, fs.dir returns nil and iterating nil crashes Lua mid-toggle, leaving
--- state.keylogger_encrypt mutated but the UI unsynchronised.
---
--- Fix: both call sites now capture the fs.dir() result and guard with
--- `if dir_iter then` before entering the loop.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "ui/menu/menu_metrics.lua"
local fh = io.open(src_path, "r")
if not fh then error("menu_metrics.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Test 1: The old unguarded `for file in fs.dir(log_dir)` must not appear.
local has_unguarded = src:find("for file in fs.dir(log_dir)", 1, true) ~= nil
helpers.assert_true(
	not has_unguarded,
	"menu_metrics.lua must not iterate fs.dir(log_dir) without a nil guard (ui-menu-misc-3)"
)

-- Test 2: The nil-guard pattern must appear for both call sites.
-- We check for `dir_iter` (the variable name used in the fix) at least twice.
local count = 0
local pos = 1
while true do
	local found = src:find("dir_iter", pos, true)
	if not found then break end
	count = count + 1
	pos = found + 1
end
helpers.assert_true(
	count >= 2,
	"menu_metrics.lua must guard fs.dir with a nil-check variable in both encrypt/decrypt paths (ui-menu-misc-3)"
)

print("[PASS] test_menu_metrics_dir_guard")
