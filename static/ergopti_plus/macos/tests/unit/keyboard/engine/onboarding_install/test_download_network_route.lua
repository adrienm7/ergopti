--- tests/unit/keyboard/engine/onboarding_install/test_download_network_route.lua

--- ==============================================================================
--- MODULE: Karabiner DMG Download Network Route
--- DESCRIPTION:
--- The Karabiner DMG was fetched by /usr/bin/curl with the inherited
--- Hammerspoon environment and without --proto =https, so a Mac that reaches
--- the internet only through its proxy could not install the remap engine
--- (NET-001). The real pipeline must build its download through the remap
--- network route (keyboard/engine/network_download.lua) over https only.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.onboarding_install_fixture")
local Scenario = require("tests.support.onboarding_install_scenarios")

helpers.describe("Karabiner DMG download route (net-001-remap-route)", function()
	helpers.it("downloads behind the network route, over https only", function()
		Fixture.with_fixture({}, function(onboarding, calls)
			local download = Scenario.advance_to_stage(onboarding, calls, "download")
			helpers.assert_eq(download.executable, "/bin/sh")
			helpers.assert_eq(download.args[3], "KARABINER-DMG")
			local argv = table.concat(download.args, " ", 4)
			helpers.assert_contains(argv, "--proto =https", "the DMG is fetched over https only")
			helpers.assert_contains(argv, "--output")
			download:complete(0, "", "")
		end)
	end)
end)
