--- tests/unit/platform/remap/onboarding_install/test_stage_revocation.lua

--- ==============================================================================
--- MODULE: Onboarding Installer stage revocation
--- DESCRIPTION:
--- Exercises stage revocation through the shared isolated native fixture.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.onboarding_install_fixture")
local Scenario = require("tests.support.onboarding_install_scenarios")
local with_fixture = Fixture.with_fixture
local TEST_SHA = Fixture.TEST_SHA
local advance_to_stage = Scenario.advance_to_stage

helpers.describe("HS-011 onboarding stage revocation", function()
	for _, stage in ipairs({ "download", "checksum", "mount", "install" }) do
		helpers.it("HS-011 stop after " .. stage .. " fences its old completion", function()
			with_fixture({}, function(onboarding, calls)
				local task = advance_to_stage(onboarding, calls, stage)
				local constructions_before_stop = #calls.tasks
				helpers.assert_true(task.pinned_at_start == true,
					stage .. " must be pinned before native start can synchronously complete")
				helpers.assert_true(onboarding.stop() == false,
					"native terminate returning the task itself is acceptance, not settlement")
				helpers.assert_eq(task.terminate_calls, 1)

				if stage == "checksum" then
					task:complete(0, TEST_SHA .. "  stale.dmg\n", "")
				elseif stage == "mount" then
					task:complete(0, "/dev/disk9\tApple_HFS\t/Volumes/Stale Karabiner\n", "")
				else
					task:complete(0, "", "")
				end

				helpers.assert_eq(#calls.tasks, constructions_before_stop,
					"a revoked " .. stage .. " callback must construct zero successors")
				helpers.assert_true(onboarding.stop() == true,
					"callback settlement must release the exact retained task")
				if stage == "mount" then
					helpers.assert_eq(#calls.detaches, 1,
						"a stale successful attach must detach its exact volume once")
					helpers.assert_contains(calls.detaches[1], "/Volumes/Stale Karabiner")
				elseif stage == "install" then
					helpers.assert_eq(#calls.detaches, 1,
						"stop and late install completion must not detach the owned mount twice")
				end
			end)
		end)
	end

	helpers.it("HS-011 retains stale mount cleanup debt until exact detach retry", function()
		with_fixture({ detach_failures = 1 }, function(onboarding, calls)
			local mount = advance_to_stage(onboarding, calls, "mount")
			helpers.assert_true(onboarding.stop() == false)
			mount:complete(0, "/dev/disk9\tApple_HFS\t/Volumes/Stale Retry\n", "")

			helpers.assert_eq(#calls.detaches, 1,
				"one stale completion gets one exact detach attempt")
			helpers.assert_not_nil(onboarding._install_owner,
				"a refused detach must retain cleanup ownership")
			helpers.assert_true(calls.fire_next_timer(),
				"the exact retained mount must retry without another user action")
			helpers.assert_eq(#calls.detaches, 2)
			helpers.assert_eq(calls.detaches[2], calls.detaches[1])
			helpers.assert_nil(onboarding._install_owner)
		end)
	end)
end)
