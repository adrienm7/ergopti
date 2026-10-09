--- tests/unit/platform/remap/onboarding_install/test_stage_completion.lua

--- ==============================================================================
--- MODULE: Onboarding Installer stage completion
--- DESCRIPTION:
--- Exercises stage completion through the shared isolated native fixture.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.onboarding_install_fixture")
local Scenario = require("tests.support.onboarding_install_scenarios")
local with_fixture = Fixture.with_fixture
local TEST_SHA = Fixture.TEST_SHA
local tasks_for_stage = Scenario.tasks_for_stage
local advance_to_stage = Scenario.advance_to_stage

helpers.describe("HS-011 onboarding stage completion", function()
	for _, stage in ipairs({ "download", "checksum", "mount", "install" }) do
		helpers.it("HS-011 current " .. stage .. " completion advances its stage once", function()
			with_fixture({}, function(onboarding, calls)
				local outcomes = {}
				local task = advance_to_stage(onboarding, calls, stage, function(ok, detail)
					outcomes[#outcomes + 1] = { ok = ok, detail = detail }
				end)
				local function complete_success()
					if stage == "checksum" then
						task:complete(0, TEST_SHA .. "  exact.part\n", "")
					elseif stage == "mount" then
						task:complete(0,
							"/dev/disk9\tApple_HFS\t/Volumes/Exact Karabiner\n", "")
					else
						task:complete(0, "", "")
					end
				end

				complete_success()
				complete_success()

				if stage == "download" then
					helpers.assert_eq(#tasks_for_stage(calls, "checksum"), 1,
						"one download task may construct only one checksum successor")
				elseif stage == "checksum" then
					helpers.assert_eq(#calls.renames, 1,
						"one checksum task may promote its exact partial only once")
					helpers.assert_eq(#tasks_for_stage(calls, "mount"), 1,
						"one checksum task may construct only one mount successor")
				elseif stage == "mount" then
					helpers.assert_eq(#tasks_for_stage(calls, "install"), 1,
						"one mount task may construct only one privileged installer")
				else
					helpers.assert_eq(#outcomes, 1,
						"one installer task may publish only one terminal")
					helpers.assert_eq(#calls.detaches, 1,
						"one installer task may detach its exact volume only once")
				end
			end)
		end)
	end

	helpers.it("HS-011 owns a real completion delivered synchronously from native start", function()
		with_fixture({ complete_on_start = true }, function(onboarding, calls)
			local outcomes = {}
			helpers.assert_true(onboarding.install_karabiner_elements(function(ok, detail)
				outcomes[#outcomes + 1] = { ok = ok, detail = detail }
			end))

			helpers.assert_eq(#calls.tasks, 4)
			for _, task in ipairs(calls.tasks) do
				helpers.assert_true(task.pinned_at_start == true,
					task.stage .. " must be owned before start can call back synchronously")
			end
			helpers.assert_eq(#outcomes, 1)
			helpers.assert_true(outcomes[1].ok == true)
			helpers.assert_nil(onboarding._install_owner)
			helpers.assert_nil(next(onboarding._active_tasks),
				"synchronous native completion must leave the task GC root empty")
			helpers.assert_eq(#calls.renames, 1)
			helpers.assert_eq(#calls.detaches, 1)
		end)
	end)

	for _, stage in ipairs({ "download", "checksum", "mount", "install" }) do
		for _, refusal in ipairs({ false, "throw" }) do
			helpers.it("HS-011 buffers synchronous " .. stage .. " completion before start "
				.. tostring(refusal), function()
				local options = {
					complete_on_start_stages = { [stage] = true },
					start_results = { [stage] = { refusal } },
				}
				with_fixture(options, function(onboarding, calls)
					local outcomes = {}
					local task = advance_to_stage(onboarding, calls, stage, function(ok, detail)
						outcomes[#outcomes + 1] = { ok = ok, detail = detail }
					end)
					helpers.assert_eq(task.last_start_kind, tostring(refusal))
					helpers.assert_eq(#outcomes, 1,
						"a refused start must choose one failure terminal")
					helpers.assert_true(outcomes[1].ok == false)
					helpers.assert_nil(onboarding._install_owner)
					helpers.assert_nil(next(onboarding._active_tasks))

					local successor = {
						download = "checksum",
						checksum = "mount",
						mount = "install",
					}
					if successor[stage] then
						helpers.assert_eq(#tasks_for_stage(calls, successor[stage]), 0,
							"pre-commit completion must not construct a successor")
					end
					local construction_count = #calls.tasks
					task:complete(0, "", "late duplicate")
					helpers.assert_eq(#outcomes, 1)
					helpers.assert_eq(#calls.tasks, construction_count)
				end)
			end)
		end
	end

end)
