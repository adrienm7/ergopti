--- tests/unit/platform/remap/onboarding_install/test_terminal_ordering.lua

--- ==============================================================================
--- MODULE: Onboarding Installer terminal ordering
--- DESCRIPTION:
--- Exercises terminal ordering through the shared isolated native fixture.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.onboarding_install_fixture")
local Scenario = require("tests.support.onboarding_install_scenarios")
local with_fixture = Fixture.with_fixture
local tasks_for_stage = Scenario.tasks_for_stage
local advance_to_stage = Scenario.advance_to_stage

helpers.describe("HS-011 onboarding terminal ordering", function()
	helpers.it("HS-011 protects the installer terminal before stop continuation", function()
		with_fixture({}, function(onboarding, calls)
			local order = {}
			local download = advance_to_stage(onboarding, calls, "download", function(ok)
				order[#order + 1] = { kind = "installer", ok = ok }
				error("synthetic cancellation observer failure")
			end)
			helpers.assert_true(onboarding.stop(function(ok)
				order[#order + 1] = { kind = "stop", ok = ok }
			end))
			helpers.assert_eq(#order, 0)
			download:complete(1, "", "cancelled")
			helpers.assert_eq(#order, 2)
			helpers.assert_eq(order[1].kind, "installer")
			helpers.assert_eq(order[2].kind, "stop")
			helpers.assert_true(order[2].ok == true)
		end)
	end)

	helpers.it("HS-011 joins installer terminal before reporting wizard timer failure", function()
		with_fixture({ timer_cancel_results = { false, false, false } },
			function(onboarding, calls)
				local order = {}
				local task = advance_to_stage(onboarding, calls, "download", function(ok)
					order[#order + 1] = { kind = "installer", ok = ok }
				end)
				local construction_count = #calls.tasks
				package.loaded["infra.dialog_util"] = {
					block_alert = function()
						return "karabiner.onboarding.btn_open_settings"
					end,
				}
				onboarding.health_check = function()
					return {
						all_ok = false,
						ke_installed = true,
						grabber_present = true,
						sysext_activated = false,
						grabber_running = true,
					}
				end
				onboarding.open_system_extensions_pane = function() end
				onboarding.is_sysext_activated = function() return false end
				onboarding.run_first_run_wizard()
				helpers.assert_eq(calls.timer_every_attempts, 1)

				helpers.assert_true(onboarding.stop(function(ok)
					order[#order + 1] = { kind = "stop", ok = ok }
				end))
				helpers.assert_eq(#order, 0,
					"timer failure cannot overtake an accepted task termination")
				helpers.assert_eq(calls.timer_cancel_attempts, 3)
				task:complete(1, "", "cancelled")

				helpers.assert_eq(#order, 2)
				helpers.assert_eq(order[1].kind, "installer")
				helpers.assert_true(order[1].ok == false)
				helpers.assert_eq(order[2].kind, "stop")
				helpers.assert_true(order[2].ok == false)
				helpers.assert_nil(onboarding._active_tasks[task])
				helpers.assert_eq(#calls.tasks, construction_count)
			end)
	end)

	helpers.it("HS-011 a late predecessor completion cannot clear its successor owner", function()
		with_fixture({}, function(onboarding, calls)
			local predecessor = advance_to_stage(onboarding, calls, "download")
			helpers.assert_true(onboarding.stop() == false)
			predecessor:complete(1, "", "cancelled")
			advance_to_stage(onboarding, calls, "download")
			local downloads = tasks_for_stage(calls, "download")
			local successor = downloads[#downloads]
			helpers.assert_true(successor ~= predecessor)

			predecessor:complete(0, "", "duplicate")
			helpers.assert_true(onboarding._active_tasks[successor] ~= nil,
				"the old exact callback must not clear the current task pin")
			helpers.assert_eq(#tasks_for_stage(calls, "checksum"), 0)
		end)
	end)
end)
