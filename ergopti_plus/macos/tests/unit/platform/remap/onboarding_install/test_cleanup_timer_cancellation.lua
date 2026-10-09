--- tests/unit/platform/remap/onboarding_install/test_cleanup_timer_cancellation.lua

--- ==============================================================================
--- MODULE: Onboarding Installer cleanup timer cancellation
--- DESCRIPTION:
--- Exercises cleanup timer cancellation through the shared isolated native fixture.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.onboarding_install_fixture")
local Scenario = require("tests.support.onboarding_install_scenarios")
local with_fixture = Fixture.with_fixture
local advance_to_stage = Scenario.advance_to_stage
local CLEANUP_DEADLINE_PROBE_LIMIT = Scenario.CLEANUP_DEADLINE_PROBE_LIMIT

helpers.describe("HS-011 onboarding cleanup timer cancellation", function()
	for _, refusal in ipairs({ false, "throw" }) do
		helpers.it("HS-011 cleanup retry timer cancel " .. tostring(refusal)
			.. " retains the exact handle until autonomous settlement", function()
			with_fixture({ timer_cancel_results = { refusal, true } },
				function(onboarding, calls)
					local order = {}
					local task = advance_to_stage(onboarding, calls, "download", function(ok)
						order[#order + 1] = { kind = "installer", ok = ok }
					end)
					local construction_count = #calls.tasks
					helpers.assert_true(onboarding.stop(function(ok)
						order[#order + 1] = { kind = "stop", ok = ok }
					end))
					task:complete(1, "", "cancelled")
					helpers.assert_eq(#order, 0,
						"a refused exact timer cancellation must retain the joined waiter")
					helpers.assert_eq(calls.timer_after_attempts, 2,
						"timer debt must acquire one autonomous cleanup successor")
					helpers.assert_nil(calls.timers[1].timer,
						"the adapter retry must settle the refused predecessor exactly")
					helpers.assert_true(calls.fire_next_timer())
					helpers.assert_eq(#order, 2)
					helpers.assert_eq(order[1].kind, "installer")
					helpers.assert_true(order[1].ok == false)
					helpers.assert_eq(order[2].kind, "stop")
					helpers.assert_true(order[2].ok == true)
					helpers.assert_nil(onboarding._install_owner)
					helpers.assert_eq(#calls.tasks, construction_count)
				end)
		end)
	end

	helpers.it("HS-011 cleanup retry timer survives multiple cancel refusals", function()
		with_fixture({ timer_cancel_results = { false, false, true } },
			function(onboarding, calls)
				local order = {}
				local task = advance_to_stage(onboarding, calls, "download", function(ok)
					order[#order + 1] = { kind = "installer", ok = ok }
				end)
				local construction_count = #calls.tasks
				helpers.assert_true(onboarding.stop(function(ok)
					order[#order + 1] = { kind = "stop", ok = ok }
				end))
				task:complete(1, "", "cancelled")
				helpers.assert_eq(#order, 0)
				helpers.assert_not_nil(calls.timers[1].timer,
					"two native refusals must retain the predecessor wrapper")
				helpers.assert_true(calls.fire_next_timer())
				helpers.assert_eq(#order, 2)
				helpers.assert_eq(order[1].kind, "installer")
				helpers.assert_true(order[1].ok == false)
				helpers.assert_eq(order[2].kind, "stop")
				helpers.assert_true(order[2].ok == true)
				helpers.assert_nil(onboarding._install_owner)
				helpers.assert_nil(calls.timers[1].timer)
				helpers.assert_eq(#calls.tasks, construction_count)
			end)
	end)

	helpers.it("HS-011 cleanup retry timer cancel exhaustion is terminal and retains debt", function()
		local refusals = {}
		for index = 1, 40 do refusals[index] = false end
		with_fixture({ timer_cancel_results = refusals }, function(onboarding, calls)
			local order = {}
			local task = advance_to_stage(onboarding, calls, "download", function(ok)
				order[#order + 1] = { kind = "installer", ok = ok }
			end)
			local construction_count = #calls.tasks
			helpers.assert_true(onboarding.stop(function(ok, detail)
				order[#order + 1] = { kind = "stop", ok = ok, detail = detail }
			end))
			task:complete(1, "", "cancelled")
			for _ = 1, CLEANUP_DEADLINE_PROBE_LIMIT do
				if #order == 2 then break end
				calls.fire_next_timer()
			end
			helpers.assert_eq(calls.timer_after_attempts, 3,
				"persistent timer debt must consume only the named retry budget")
			helpers.assert_eq(#order, 2,
				"timer cancellation exhaustion must not strand the lifecycle waiter")
			helpers.assert_eq(order[1].kind, "installer")
			helpers.assert_true(order[1].ok == false)
			helpers.assert_eq(order[2].kind, "stop")
			helpers.assert_true(order[2].ok == false)
			helpers.assert_eq(order[2].detail, "onboarding-cleanup-timeout")
			helpers.assert_not_nil(onboarding._install_owner,
				"terminal failure must retain the exact timer cleanup debt")
		local retained = 0
		for _, timer in ipairs(calls.timers) do
			if timer.timer ~= nil then retained = retained + 1 end
		end
		helpers.assert_true(retained > 0)
		helpers.assert_eq(#calls.tasks, construction_count)
		end)
	end)

end)
