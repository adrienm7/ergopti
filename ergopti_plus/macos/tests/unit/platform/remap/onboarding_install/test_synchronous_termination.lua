--- tests/unit/platform/remap/onboarding_install/test_synchronous_termination.lua

--- ==============================================================================
--- MODULE: Onboarding Installer synchronous termination
--- DESCRIPTION:
--- Exercises synchronous termination through the shared isolated native fixture.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.onboarding_install_fixture")
local Scenario = require("tests.support.onboarding_install_scenarios")
local with_fixture = Fixture.with_fixture
local advance_to_stage = Scenario.advance_to_stage

helpers.describe("HS-011 onboarding synchronous termination", function()
	for _, stage in ipairs({ "download", "checksum", "mount", "install" }) do
		helpers.it("HS-011 joins synchronous " .. stage .. " termination completion", function()
			with_fixture({ complete_on_terminate_stages = { [stage] = true } },
				function(onboarding, calls)
					local order = {}
					local task = advance_to_stage(onboarding, calls, stage, function(ok)
						order[#order + 1] = { kind = "installer", ok = ok }
					end)
					local construction_count = #calls.tasks
					helpers.assert_true(onboarding.stop(function(ok)
						order[#order + 1] = { kind = "stop", ok = ok }
					end))
					helpers.assert_eq(#order, 2)
					helpers.assert_eq(order[1].kind, "installer")
					helpers.assert_true(order[1].ok == false)
					helpers.assert_eq(order[2].kind, "stop")
					helpers.assert_true(order[2].ok == true)
					helpers.assert_nil(onboarding._install_owner)
					helpers.assert_nil(onboarding._active_tasks[task])
					helpers.assert_eq(#calls.tasks, construction_count)
				end)
		end)
	end

	for _, stage in ipairs({ "download", "checksum", "mount", "install" }) do
		for _, refusal in ipairs({ false, "nil", "throw" }) do
			helpers.it("HS-011 keeps synchronous " .. stage .. " termination "
				.. tostring(refusal) .. " terminal", function()
				with_fixture({
					complete_on_terminate_stages = { [stage] = true },
					terminate_results = { [stage] = { refusal } },
				}, function(onboarding, calls)
					local order = {}
					local task = advance_to_stage(onboarding, calls, stage, function(ok)
						order[#order + 1] = { kind = "installer", ok = ok }
					end)
					local construction_count = #calls.tasks
					helpers.assert_true(onboarding.stop(function(ok, detail)
						order[#order + 1] = { kind = "stop", ok = ok, detail = detail }
					end))

					helpers.assert_eq(task.last_terminate_kind, tostring(refusal))
					helpers.assert_eq(#order, 2,
						"one synchronous completion and one refusal must publish exactly once")
					helpers.assert_eq(order[1].kind, "installer")
					helpers.assert_true(order[1].ok == false)
					helpers.assert_eq(order[2].kind, "stop")
					helpers.assert_true(order[2].ok == false,
						"false, nil, or thrown terminate remains a terminal stop refusal")
					helpers.assert_eq(order[2].detail,
						"onboarding-task-termination-refused")
					helpers.assert_nil(onboarding._install_owner)
					helpers.assert_nil(onboarding._active_tasks[task])
					helpers.assert_eq(#calls.tasks, construction_count,
						"synchronous termination must construct zero successor stages")
				end)
			end)
		end
	end

	for _, stage in ipairs({ "download", "checksum", "mount", "install" }) do
		for _, refusal in ipairs({ false, "nil", "throw" }) do
			helpers.it("HS-011 returns synchronous " .. stage .. " termination "
				.. tostring(refusal) .. " refusal", function()
				with_fixture({
					complete_on_terminate_stages = { [stage] = true },
					terminate_results = { [stage] = { refusal } },
				}, function(onboarding, calls)
					local outcomes = {}
					local task = advance_to_stage(onboarding, calls, stage, function(ok)
						outcomes[#outcomes + 1] = ok
					end)
					local construction_count = #calls.tasks

					helpers.assert_true(onboarding.stop() == false,
						"callback-free stop must preserve false, nil, and thrown refusal")
					helpers.assert_eq(task.last_terminate_kind, tostring(refusal))
					helpers.assert_eq(#outcomes, 1)
					helpers.assert_true(outcomes[1] == false)
					helpers.assert_nil(onboarding._install_owner)
					helpers.assert_nil(onboarding._active_tasks[task])
					helpers.assert_eq(#calls.tasks, construction_count)
				end)
			end)
		end
	end

end)
