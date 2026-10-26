--- tests/unit/modules/keymap/test_direct_access_digits_native_only.lua

--- ==============================================================================
--- MODULE: layout.direct_access_digits Is Native-Only On Linux
--- DESCRIPTION:
--- The number-row override is a Windows feature: Linux takes the digits its
--- XKB layout produces. Pins the three facts that keep the toggle honest on this
--- driver: the manifest default and recommendation are "native", the shared
--- policy refuses every other mode for Linux, and the shipped configuration
--- template carries the same value, so a user never starts on a mode the driver
--- cannot apply.
--- ==============================================================================

local helpers = require("tests.helpers")
local Manifest = require("infra.manifest_reader")
local Policy = require("layout.number_row_policy")

local PATH = "layout.direct_access_digits"

helpers.describe("layout.direct_access_digits on Linux (linux-direct-access-digits)", function()
	helpers.it("declares native as the default and the recommendation", function()
		helpers.assert_eq(Manifest.default_for(PATH), "native")
		helpers.assert_eq(Manifest.recommended_for(PATH), "native")
		helpers.assert_true(Manifest.find_entry_by_path(PATH) ~= nil, "the manifest still lists the toggle")
	end)

	helpers.it("lets the shared policy apply only the native mode", function()
		helpers.assert_eq(Policy.capable("linux", "native", false), true)
		helpers.assert_eq(Policy.capable("linux", "digits", false), false)
		helpers.assert_eq(Policy.capable("linux", "symbols", true), false)
	end)

	helpers.it("ships the same value in the generated configuration template", function()
		local path = helpers.driver_root() .. "/_generated/config_template.toml"
		local file = assert(io.open(path, "rb"))
		local body = file:read("*a")
		file:close()
		helpers.assert_true(body:find('direct_access_digits = "native"', 1, true) ~= nil,
			"the template starts the layout on the native number row")
	end)
end)
