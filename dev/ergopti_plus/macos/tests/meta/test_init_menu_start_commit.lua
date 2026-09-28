--- tests/meta/test_init_menu_start_commit.lua

--- ==============================================================================
--- MODULE: Root Boot Requires A Committed Menubar
--- DESCRIPTION:
--- ui.menu.start returns nil when the menubar, its native menu or the initial
--- preference rollback cannot settle. Root init ignored that result, so a boot
--- without any tray still logged "Hammerspoon boot SUCCESSFUL". Root init cannot
--- be loaded by the headless suite, so this guard reads its executable source:
--- the result must be checked and must fail the boot (ERROR, then the fatal
--- boundary) before the stage is marked done and before the success line.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Returns root init.lua with full-line and trailing comments removed.
--- @return string source Root bootstrap code.
local function boot_source()
	local src, err = helpers.read_driver_unit("local function has_common_hotstring_groups")
	helpers.assert_true(src ~= nil and src ~= "", tostring(err))
	return (src:gsub("%-%-[^\n]*", ""))
end





-- ================================================
-- ================================================
-- ======= 1/ menu.start Result Is Enforced =======
-- ================================================
-- ================================================

helpers.describe("root boot: menu.start must commit before boot success", function()
	helpers.it("fails the boot loudly when menu.start returns nil", function()
		local src = boot_source()
		local call_at = src:find("local menubar = menu.start(", 1, true)
		helpers.assert_true(call_at ~= nil, "root boot must keep the menu.start result")
		local check_at = src:find("if menubar == nil then", call_at, true)
		local error_log_at = check_at and src:find("Logger.error(LOG,", check_at, true)
		local raise_at = check_at and src:find('error("menu.start did not commit")', check_at, true)
		local mark_at = src:find('Boot.mark("UI: menu.start', call_at, true)
		local success_at = src:find("boot SUCCESSFUL", call_at, true)

		helpers.assert_true(check_at ~= nil and error_log_at ~= nil and raise_at ~= nil,
			"a nil menubar must be logged as an ERROR and raised")
		helpers.assert_true(mark_at ~= nil and success_at ~= nil,
			"the stage mark and the success line must remain present")
		helpers.assert_true(call_at < check_at and check_at < error_log_at
			and error_log_at < raise_at and raise_at < mark_at and mark_at < success_at,
			"the nil check must fail the boot before the stage mark and the success line")
	end)
end)

return true
