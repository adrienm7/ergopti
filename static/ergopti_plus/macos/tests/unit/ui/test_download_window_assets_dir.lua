--- tests/unit/ui/test_download_window_assets_dir.lua

--- Regression test for ui-windows-a-3: download_window/init.lua computed
--- ASSETS_DIR via a gsub that searched for "drivers/hammerspoon/ui/download_window/"
--- — a legacy path segment that no longer appears in the actual runtime path
--- (which is now "macos/ui/download_window/"). The gsub silently returned the
--- unchanged _own_dir, so the webview tried to load assets from the macOS
--- driver folder rather than the cross-platform shared/ folder.
---
--- Fix: changed the gsub pattern to "macos/ui/download_window/" which matches
--- the real runtime path and correctly produces "shared/ui/download_window/".

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "ui/download_window/init.lua"
local fh = io.open(src_path, "r")
if not fh then error("download_window/init.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Test 1: The old stale "drivers/hammerspoon" pattern must not appear.
local has_old_pattern = src:find("drivers/hammerspoon/ui/download_window/", 1, true) ~= nil
helpers.assert_true(
	not has_old_pattern,
	"download_window/init.lua must not use the stale 'drivers/hammerspoon/' gsub pattern (ui-windows-a-3)"
)

-- Test 2: The correct "macos/ui/download_window/" pattern must be present.
local has_new_pattern = src:find("macos/ui/download_window/", 1, true) ~= nil
helpers.assert_true(
	has_new_pattern,
	"download_window/init.lua must gsub 'macos/ui/download_window/' to reach shared assets (ui-windows-a-3)"
)

-- Test 3: The replacement target must reference the shared/ folder.
local has_shared = src:find("shared/ui/download_window/", 1, true) ~= nil
helpers.assert_true(
	has_shared,
	"download_window/init.lua ASSETS_DIR must point to 'shared/ui/download_window/' (ui-windows-a-3)"
)

print("[PASS] test_download_window_assets_dir")
