--- tests/unit/platform/remap/guardian_recovery/test_approval_notice.lua

--- ==============================================================================
--- MODULE: Guardian Approval Reaches The User As A Notice
--- DESCRIPTION:
--- The remap engine has no tray row any more, so the Login Items approval that
--- used to be a status row inside the Karabiner submenu must come to the user:
--- one notification per episode, whose click opens Login Items. Drives the real
--- remap bridge through the guardian recovery fixture.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.guardian_recovery_fixture")
local with_remap = fixture.with_remap

helpers.describe("guardian approval is announced, not buried in a menu", function()
	helpers.it("notifies once while a regeneration waits on Login Items approval", function()
		with_remap({
			initial_phase = "idle",
			guardian_status = "requires_approval",
			guardian_probe_deferred = true,
		}, function(remap, calls)
			helpers.assert_true(remap.regenerate(function() end))
			calls.deliver_guardian_probe("requires_approval", nil, 1)
			helpers.assert_eq(#calls.notices, 1, "the first approval observation must notify the user")
			local notice = calls.notices[1]
			helpers.assert_eq(notice.kind, "warning")
			helpers.assert_true(type(notice.message) == "string" and notice.message:find("ErgoptiPlus", 1, true),
				"the notice names the product, never the engine: " .. tostring(notice.message))
			helpers.assert_nil(notice.message:lower():find("karabiner", 1, true))
			helpers.assert_type(notice.on_click, "function")

			calls.recovery_timers[1]:fire()
			calls.deliver_guardian_probe("requires_approval", nil, 2)
			helpers.assert_eq(#calls.notices, 1, "each poll of the same episode must not notify again")
		end)
	end)

	helpers.it("stays silent when the helper is already approved", function()
		with_remap({
			initial_phase = "idle",
			guardian_status = "ready",
			guardian_probe_deferred = true,
		}, function(remap, calls)
			helpers.assert_true(remap.regenerate(function() end))
			calls.deliver_guardian_probe("ready", nil, 1)
			helpers.assert_eq(#calls.notices, 0, "an approved helper needs nothing from the user")
		end)
	end)
end)
