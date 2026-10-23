--- tests/unit/infra/lifecycle/test_instance_admission.lua

--- ==============================================================================
--- MODULE: Driver Instance Admission Regression Tests
--- DESCRIPTION:
--- On 2026-10-21 and 2026-10-22 a second embedded runtime started beside the
--- launcher's own without the launcher environment, armed its keystats timers
--- and kept writing to the shared log behind a blocking fatal dialog
--- (hs-second-instance-2026-10-22). The same refusal path ran os.exit in any
--- Hammerspoon, so a user's own Hammerspoon pointed at Ergopti was quit
--- (hs-foreign-never-killed-2026-10-22).
--- ==============================================================================

local helpers = require("tests.helpers")
local Admission = require("infra.instance_admission")

helpers.describe("instance admission: a stray Ergopti runtime is refused (hs-second-instance-2026-10-22)", function()
	helpers.it("admits only the launcher-managed embedded runtime", function()
		helpers.assert_eq(Admission.decide("managed", true), Admission.ADMIT)
	end)

	helpers.it("refuses the embedded runtime started without the launcher, quietly and by exiting", function()
		local decision = Admission.decide("standalone", true)
		helpers.assert_eq(decision, Admission.STRAY_RUNTIME)
		helpers.assert_true(Admission.may_exit_process(decision),
			"our own stray runtime must end instead of idling with live producers")
		helpers.assert_eq(Admission.shows_dialog(decision), false,
			"a blocking dialog is what kept the stray instance's timers writing")
	end)

	helpers.it("leaves a partial launcher environment to the logger boundary's fatal report", function()
		helpers.assert_eq(Admission.decide("invalid", true), Admission.ADMIT)
	end)
end)

helpers.describe("instance admission: the user's own Hammerspoon is never killed (hs-foreign-never-killed-2026-10-22)", function()
	for _, mode in ipairs({ "standalone", "invalid" }) do
		helpers.it("refuses the driver in a stock Hammerspoon (" .. mode .. ") without exiting it", function()
			for _, packaged in ipairs({ false, "yes", 1 }) do
				local decision = Admission.decide(mode, packaged)
				helpers.assert_eq(decision, Admission.FOREIGN_HAMMERSPOON)
				helpers.assert_eq(Admission.may_exit_process(decision), false,
					"os.exit there quits the user's own application")
				helpers.assert_true(Admission.shows_dialog(decision),
					"the user must be told why the driver did not start")
			end
		end)
	end

	helpers.it("names the process without any environment value", function()
		local line = Admission.describe({ pid = 77, bundle_id = "org.example.runtime",
			bundle_path = "/Applications/ErgoptiPlus.app/Contents/Frameworks/Hammerspoon.app",
			launcher_running = true })
		helpers.assert_contains(line, "pid 77")
		helpers.assert_contains(line, "org.example.runtime")
		helpers.assert_contains(line, "launcher running: true")
	end)
end)
