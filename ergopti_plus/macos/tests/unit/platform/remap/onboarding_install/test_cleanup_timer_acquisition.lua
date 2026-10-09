--- tests/unit/platform/remap/onboarding_install/test_cleanup_timer_acquisition.lua

--- ==============================================================================
--- MODULE: Onboarding Installer cleanup timer acquisition
--- DESCRIPTION:
--- Exercises cleanup timer acquisition through the shared isolated native fixture.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.onboarding_install_fixture")
local Scenario = require("tests.support.onboarding_install_scenarios")
local with_fixture = Fixture.with_fixture
local advance_to_stage = Scenario.advance_to_stage

helpers.describe("HS-011 onboarding cleanup timer acquisition", function()
	for _, refusal in ipairs({ false, "nil", "throw" }) do
		helpers.it("HS-011 cleanup timer " .. tostring(refusal)
			.. " settles joined lifecycle failure", function()
			with_fixture({ timer_after_results = { refusal, refusal, refusal } },
				function(onboarding, calls)
				local order = {}
				local task = advance_to_stage(onboarding, calls, "download", function(ok)
					order[#order + 1] = { kind = "installer", ok = ok }
				end)
				helpers.assert_true(onboarding.stop(function(ok, detail)
					order[#order + 1] = { kind = "stop", ok = ok, detail = detail }
				end))
				helpers.assert_eq(calls.last_timer_after_kind, tostring(refusal),
					"the fixture must preserve the exact timer refusal shape")
				helpers.assert_eq(calls.timer_after_attempts, 3,
					"constructor refusal must consume one bounded autonomous fallback series")
				helpers.assert_eq(#order, 2,
					"retry timer refusal must not leave the lifecycle waiter pending")
				helpers.assert_eq(order[1].kind, "installer")
				helpers.assert_true(order[1].ok == false)
				helpers.assert_eq(order[2].kind, "stop")
				helpers.assert_true(order[2].ok == false)
				helpers.assert_eq(order[2].detail, "onboarding-cleanup-timer-refused")
				helpers.assert_true(onboarding._active_tasks[task] ~= nil)
				helpers.assert_not_nil(onboarding._install_owner)

				task:complete(1, "", "cancelled")
				helpers.assert_nil(onboarding._active_tasks[task])
				helpers.assert_nil(onboarding._install_owner)
				helpers.assert_eq(#order, 2,
					"late exact cleanup must not redeliver a terminal")
			end)
		end)
	end

	helpers.it("HS-011 cleanup timer constructor refusal rolls back before retry", function()
		with_fixture({ timer_after_results = { false, true } }, function(onboarding, calls)
			local order = {}
			local task = advance_to_stage(onboarding, calls, "download", function(ok)
				order[#order + 1] = { kind = "installer", ok = ok }
			end)
			local construction_count = #calls.tasks
			helpers.assert_true(onboarding.stop(function(ok)
				order[#order + 1] = { kind = "stop", ok = ok }
			end))
			helpers.assert_eq(calls.timer_after_attempts, 2,
				"a settled constructor refusal must acquire its bounded successor autonomously")
			helpers.assert_nil(calls.timers[1].timer,
				"the refused exact timer wrapper must settle before replacement")
			helpers.assert_not_nil(calls.timers[2].timer)
			helpers.assert_eq(#order, 0)

			task:complete(1, "", "cancelled")
			helpers.assert_eq(#order, 2)
			helpers.assert_eq(order[1].kind, "installer")
			helpers.assert_true(order[1].ok == false)
			helpers.assert_eq(order[2].kind, "stop")
			helpers.assert_true(order[2].ok == true)
			helpers.assert_nil(onboarding._install_owner)
			helpers.assert_eq(#calls.tasks, construction_count,
				"timer acquisition fallback must never restart the installer")
		end)
	end)

end)
