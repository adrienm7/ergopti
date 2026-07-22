--- tests/unit/ui/test_menu_about_restore_checked.lua

--- ==============================================================================
--- MODULE: Regression — self-update restore-rename is checked (SU-2)
--- DESCRIPTION:
--- On a failed move-in-place the install path renamed the backup back to target
--- but discarded the result and logged "restored backup" unconditionally — a
--- false-positive log if the restore itself failed (which would leave the running
--- app only at <app>.bak). The L229 comment also wrongly claimed os.rename "falls
--- back to copy" cross-volume (it returns EXDEV, no copy).
---
--- Fix: capture and branch on the restore os.rename result, and correct the
--- comment. The install path is a local function needing deep filesystem stubs, so
--- this is pinned at source.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("menu_about: self-update restore rename is checked (SU-2)", function()
	local function read_src()
		local path = helpers.driver_root() .. "ui/menu/menu_about.lua"
		local fh = io.open(path, "r")
		helpers.assert_true(fh ~= nil, "cannot open menu_about.lua at " .. tostring(path))
		local src = fh:read("*a"); fh:close()
		return src
	end

	helpers.it("captures the restore os.rename result instead of discarding it", function()
		local src = read_src()
		helpers.assert_true(src:find("local ok_restore = os.rename(backup_app, target)", 1, true) ~= nil,
			"the backup-restore rename must capture its result (ok_restore)")
		helpers.assert_true(src:find("AND restore failed", 1, true) ~= nil,
			"a failed restore must surface a distinct, precise error (app left at .bak)")
	end)

	helpers.it("drops the misleading 'falls back to copy' comment", function()
		local src = read_src()
		helpers.assert_true(src:find("Cross%-volume falls back to copy") == nil,
			"the false 'Cross-volume falls back to copy' comment must be gone (os.rename = rename(2), no copy)")
	end)
end)
