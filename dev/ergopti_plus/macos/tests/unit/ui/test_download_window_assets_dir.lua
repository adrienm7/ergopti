--- tests/unit/ui/test_download_window_assets_dir.lua

--- Regression test for ui-windows-a-3: download_window/init.lua originally
--- computed ASSETS_DIR via a brittle gsub that searched for a hardcoded driver
--- path segment, silently returning the unchanged source dir when the segment
--- did not match — so the webview tried to load assets from the macOS driver
--- folder rather than the cross-platform _shared/ folder.
---
--- The path resolution is now centralised through Paths.shared, the single
--- source of truth for the shared root. This test pins that contract: ASSETS_DIR
--- must resolve the shared "ui/download_window" assets via Paths.shared and must
--- NOT reintroduce a hand-rolled gsub on a hardcoded driver path segment.

local helpers = require("tests.helpers")

-- Selected by a declaration unique to ui/download_window/init.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("local function ensure_webview")
helpers.assert_true(src ~= nil, "ui/download_window/init.lua source must be locatable")

-- Test 1: The old stale "drivers/hammerspoon" pattern must not appear.
local has_old_pattern = src:find("drivers/hammerspoon/ui/download_window/", 1, true) ~= nil
helpers.assert_true(
	not has_old_pattern,
	"download_window/init.lua must not use the stale 'drivers/hammerspoon/' gsub pattern (ui-windows-a-3)"
)

-- Test 2: ASSETS_DIR must resolve the shared assets via Paths.shared (the single
-- shared-tree resolver), not a hand-rolled gsub on a hardcoded driver segment.
local has_paths_shared = src:find('Paths%.shared%(%s*"ui/download_window"%s*%)') ~= nil
helpers.assert_true(
	has_paths_shared,
	"download_window/init.lua ASSETS_DIR must resolve via Paths.shared(\"ui/download_window\") (ui-windows-a-3)"
)

-- Test 3: The resource referenced must still be the shared download_window UI.
local has_shared = src:find("ui/download_window", 1, true) ~= nil
helpers.assert_true(
	has_shared,
	"download_window/init.lua ASSETS_DIR must point to the shared 'ui/download_window' assets (ui-windows-a-3)"
)

print("[PASS] test_download_window_assets_dir")
