--- tests/unit/ui/menu/test_menu_init_hk_box_forward_declare.lua

--- Regression test for ui-menu-core-3: _metrics_hk_box and _apps_time_hk_box
--- were declared AFTER apply_metrics_shortcut and apply_apps_time_shortcut.
--- In Lua a local is only visible after its declaration point, so the function
--- bodies captured global nil instead of the local table — the boxes were never
--- populated and MenuState.sync_state_to_modules always received empty boxes.
---
--- Fix: forward-declare both boxes before the functions that reference them.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "ui/menu/init.lua"
local fh = io.open(src_path, "r")
if not fh then error("ui/menu/init.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Find positions of the forward declarations and the first apply_*_shortcut
-- function definition that uses the boxes.
local metrics_box_pos    = src:find("local _metrics_hk_box   = {}", 1, true)
local apps_box_pos       = src:find("local _apps_time_hk_box = {}", 1, true)
local apply_metrics_pos  = src:find("local function apply_metrics_shortcut(", 1, true)
local apply_apps_pos     = src:find("local function apply_apps_time_shortcut(", 1, true)

helpers.assert_true(
	metrics_box_pos ~= nil,
	"ui/menu/init.lua must declare local _metrics_hk_box (ui-menu-core-3)"
)
helpers.assert_true(
	apps_box_pos ~= nil,
	"ui/menu/init.lua must declare local _apps_time_hk_box (ui-menu-core-3)"
)
helpers.assert_true(
	apply_metrics_pos ~= nil,
	"ui/menu/init.lua must define apply_metrics_shortcut()"
)
helpers.assert_true(
	apply_apps_pos ~= nil,
	"ui/menu/init.lua must define apply_apps_time_shortcut()"
)
helpers.assert_true(
	metrics_box_pos < apply_metrics_pos,
	"_metrics_hk_box must be declared BEFORE apply_metrics_shortcut (ui-menu-core-3)"
)
helpers.assert_true(
	apps_box_pos < apply_apps_pos,
	"_apps_time_hk_box must be declared BEFORE apply_apps_time_shortcut (ui-menu-core-3)"
)

print("[PASS] test_menu_init_hk_box_forward_declare")
