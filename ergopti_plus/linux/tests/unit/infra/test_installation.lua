--- tests/unit/infra/test_installation.lua

--- ==============================================================================
--- MODULE: Installed Build Or Source Run (Linux)
--- DESCRIPTION:
--- infra/installation.lua is the one answer the Uninstall and Update rows, the
--- uninstall action and the Versions window ask. These cases pin each layout:
--- the system package root, an install.sh prefix (stamped or not), a stamped
--- build run in place, and an unstamped checkout, the only source run.
--- ==============================================================================

local helpers = require("tests.helpers")
local Installation = require("infra.installation")
local Version = require("infra.version")

helpers.describe("installation: installed build or source run (Linux)", function()
	helpers.it("reads the system package root and an install.sh prefix", function()
		helpers.assert_eq(Installation.layout("/usr/lib/ergopti"), { system = true })
		helpers.assert_eq(Installation.layout("/home/u/.local/lib/ergopti/linux"),
			{ system = false, prefix = "/home/u/.local" })
		helpers.assert_eq(Installation.layout("/checkout/static/ergopti_plus/linux"), { system = false })
	end)

	helpers.it("calls an unstamped checkout, and only that, a source run", function()
		local checkout = "/checkout/static/ergopti_plus/linux"
		helpers.assert_true(Installation.is_source_run(checkout, Version.SOURCE_LOCAL))
		helpers.assert_eq(Installation.is_source_run(checkout, Version.SOURCE_BUILD), false,
			"a stamped build run in place is a build")
		helpers.assert_eq(Installation.is_source_run(checkout, Version.SOURCE_UNKNOWN), false,
			"a package with a broken stamp is still a build")
		helpers.assert_eq(Installation.is_source_run("/home/u/.local/lib/ergopti/linux", Version.SOURCE_LOCAL), false,
			"install.sh copies a checkout without a stamp, and it is installed")
		helpers.assert_eq(Installation.is_source_run("/usr/lib/ergopti", Version.SOURCE_LOCAL), false)
	end)

	helpers.it("answers for the running daemon by default", function()
		local Paths = require("infra.paths")
		helpers.assert_eq(Installation.is_source_run(),
			Installation.is_source_run(Paths.driver_root(), Version.SOURCE))
	end)
end)
