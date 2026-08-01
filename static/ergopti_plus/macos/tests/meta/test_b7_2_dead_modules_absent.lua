--- tests/meta/test_b7_2_dead_modules_absent.lua

--- ==============================================================================
--- MODULE: B7.2 Dead Module Absence Guard
--- DESCRIPTION:
--- Regression guard ensuring the three dead Lua modules deleted in B7.2 have
--- not been re-introduced. A re-introduction would violate §5.6 (No Unused
--- Fallback Code) by re-adding files with zero runtime callers.
---
--- Targets removed in B7.2:
---   • macos/ui/menu/menu_script_control.lua — superseded by dyn_script_control
---     in menu_shortcuts.lua; zero require() callers in the runtime.
---   • macos/infra/color_utils.lua + _shared/lua/color_utils/init.lua — one-line
---     identity re-export with zero production callers (tests used lib.color_utils
---     directly; test file deleted alongside the shim).
---   • _shared/lua/keycodes/qwerty_names.lua — platform-neutral mapping table
---     with zero callers anywhere in any driver.
--- ==============================================================================

local helpers = require("tests.helpers")

local DRIVER_ROOT  = helpers.driver_root()
local SHARED_ROOT  = DRIVER_ROOT .. "../_shared/"

--- Returns true when path does NOT exist.
--- @param path string Absolute or relative filesystem path.
--- @return boolean
local function file_absent(path)
	local fh = io.open(path, "r")
	if fh then fh:close(); return false end
	return true
end





-- ==================================================
-- ==================================================
-- ======= 1/ Dead module absence (B7.2 §5.6) =======
-- ==================================================
-- ==================================================

helpers.describe("B7.2: dead modules must not be present (§5.6)", function()

	helpers.it("ui/menu/menu_script_control.lua is absent (superseded by dyn_script_control)", function()
		helpers.assert_true(
			file_absent(DRIVER_ROOT .. "ui/menu/menu_script_control.lua"),
			"ui/menu/menu_script_control.lua must not exist — dead module deleted in B7.2 (§5.6)"
		)
	end)

	helpers.it("infra/color_utils.lua is absent (zero-caller identity shim)", function()
		helpers.assert_true(
			file_absent(DRIVER_ROOT .. "infra/color_utils.lua"),
			"infra/color_utils.lua must not exist — dead shim deleted in B7.2 (§5.6)"
		)
	end)

	helpers.it("_shared/lua/color_utils/init.lua is absent (only caller was the deleted shim)", function()
		helpers.assert_true(
			file_absent(SHARED_ROOT .. "lua/color_utils/init.lua"),
			"_shared/lua/color_utils/init.lua must not exist — dead module deleted in B7.2 (§5.6)"
		)
	end)

	helpers.it("_shared/lua/keycodes/qwerty_names.lua is absent (zero callers in all drivers)", function()
		helpers.assert_true(
			file_absent(SHARED_ROOT .. "lua/keycodes/qwerty_names.lua"),
			"_shared/lua/keycodes/qwerty_names.lua must not exist — dead module deleted in B7.2 (§5.6)"
		)
	end)

end)
