--- tests/unit/platform/remap/onboarding_install/test_native_termination.lua

--- ==============================================================================
--- MODULE: Onboarding Installer native termination
--- DESCRIPTION:
--- Exercises native termination through the shared isolated native fixture.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.onboarding_install_fixture")
local Scenario = require("tests.support.onboarding_install_scenarios")
local with_fixture = Fixture.with_fixture
local advance_to_stage = Scenario.advance_to_stage
local CLEANUP_DEADLINE_PROBE_LIMIT = Scenario.CLEANUP_DEADLINE_PROBE_LIMIT

helpers.describe("HS-011 onboarding native termination", function()
	for _, signal in ipairs({ true, "self" }) do
		helpers.it("HS-011 terminate signal " .. tostring(signal) .. " waits for exact exit", function()
			with_fixture({ terminate_results = { download = { signal } } },
				function(onboarding, calls)
				local order = {}
				local task = advance_to_stage(onboarding, calls, "download", function(ok, detail)
					order[#order + 1] = { kind = "installer", ok = ok, detail = detail }
				end)

				helpers.assert_true(onboarding.stop(function(ok, detail)
					order[#order + 1] = { kind = "stop", ok = ok, detail = detail }
				end), "callback-form stop must join an accepted termination signal")
				helpers.assert_eq(#order, 0,
					"truthy terminate return is not proof that the subprocess exited")
				helpers.assert_true(onboarding._active_tasks[task] ~= nil)
				helpers.assert_eq(task.terminate_calls, 1)

				local construction_count = #calls.tasks
				task:complete(1, "", "cancelled")
				helpers.assert_eq(#order, 2)
				helpers.assert_eq(order[1].kind, "installer",
					"the installer terminal must precede the joined stop continuation")
				helpers.assert_true(order[1].ok == false)
				helpers.assert_eq(order[2].kind, "stop")
				helpers.assert_true(order[2].ok == true)
				helpers.assert_nil(onboarding._install_owner)
				helpers.assert_nil(onboarding._active_tasks[task])
				helpers.assert_eq(#calls.tasks, construction_count,
					"revoked task completion must construct zero successors")
			end)
		end)
	end

	helpers.it("HS-011 retries join an already accepted terminate signal", function()
		with_fixture({ terminate_results = { download = { true, false } } },
			function(onboarding, calls)
				local order = {}
				local task = advance_to_stage(onboarding, calls, "download", function(ok)
					order[#order + 1] = { kind = "installer", ok = ok }
				end)
				helpers.assert_true(onboarding.stop(function(ok)
					order[#order + 1] = { kind = "stop", ok = ok }
				end))
				helpers.assert_eq(task.terminate_calls, 1)
				helpers.assert_true(calls.fire_next_timer())
				helpers.assert_eq(task.terminate_calls, 1,
					"cleanup deadline ticks must not re-signal an accepted task")
				helpers.assert_eq(#order, 0,
					"an accepted signal waits for exact completion or the named deadline")

				task:complete(1, "", "cancelled")
				helpers.assert_eq(#order, 2)
				helpers.assert_eq(order[1].kind, "installer")
				helpers.assert_true(order[1].ok == false)
				helpers.assert_eq(order[2].kind, "stop")
				helpers.assert_true(order[2].ok == true)
			end)
	end)

	helpers.it("HS-011 repeated stop joins an already accepted terminate signal", function()
		with_fixture({ terminate_results = { download = { "self", false } } },
			function(onboarding, calls)
				local order = {}
				local task = advance_to_stage(onboarding, calls, "download", function(ok)
					order[#order + 1] = { kind = "installer", ok = ok }
				end)
				helpers.assert_true(onboarding.stop(function(ok)
					order[#order + 1] = { kind = "stop-1", ok = ok }
				end))
				helpers.assert_true(onboarding.stop(function(ok)
					order[#order + 1] = { kind = "stop-2", ok = ok }
				end))
				helpers.assert_eq(task.terminate_calls, 1,
					"a joined lifecycle caller must not re-signal an accepted task")
				helpers.assert_eq(#order, 0)

				task:complete(1, "", "cancelled")
				helpers.assert_eq(#order, 3)
				helpers.assert_eq(order[1].kind, "installer")
				helpers.assert_true(order[1].ok == false)
				helpers.assert_eq(order[2].kind, "stop-1")
				helpers.assert_true(order[2].ok == true)
				helpers.assert_eq(order[3].kind, "stop-2")
				helpers.assert_true(order[3].ok == true)
			end)
	end)

	for _, refusal in ipairs({ false, "nil", "throw" }) do
		helpers.it("HS-011 terminate refusal " .. tostring(refusal) .. " is terminal", function()
			with_fixture({
				terminate_results = { download = { refusal, "self" } },
			}, function(onboarding, calls)
				local order = {}
				local task = advance_to_stage(onboarding, calls, "download", function(ok)
					order[#order + 1] = { kind = "installer", ok = ok }
				end)
				helpers.assert_true(onboarding.stop(function(ok)
					order[#order + 1] = { kind = "stop", ok = ok }
				end))
				helpers.assert_eq(#order, 2,
					"a refused termination request must publish terminal failure immediately")
				helpers.assert_eq(order[1].kind, "installer")
				helpers.assert_true(order[1].ok == false)
				helpers.assert_eq(order[2].kind, "stop")
				helpers.assert_true(order[2].ok == false)
				helpers.assert_eq(task.last_terminate_kind, tostring(refusal),
					"the fixture must preserve a literal false rather than coalescing it")
				helpers.assert_true(onboarding._active_tasks[task] ~= nil,
					"terminal failure must retain exact cleanup debt")
				helpers.assert_eq(task.terminate_calls, 1)

				helpers.assert_true(calls.fire_next_timer(),
					"cleanup retry must be autonomous after the public terminal")
				helpers.assert_eq(task.terminate_calls, 2,
					"the timer must signal the same exact task without a second user action")
				local construction_count = #calls.tasks
				task:complete(0, "", "")
				helpers.assert_nil(onboarding._active_tasks[task])
				helpers.assert_nil(onboarding._install_owner)
				helpers.assert_eq(#order, 2,
					"cleanup completion must not redeliver terminal failure")
				helpers.assert_eq(#calls.tasks, construction_count,
					"cleanup retry must never construct a new installer stage")
			end)
		end)
	end

	helpers.it("HS-011 accepted terminate reaches a bounded cleanup deadline", function()
		with_fixture({}, function(onboarding, calls)
			local order = {}
			local task = advance_to_stage(onboarding, calls, "download", function(ok)
				order[#order + 1] = { kind = "installer", ok = ok }
			end)
			local construction_count = #calls.tasks
			helpers.assert_true(onboarding.stop(function(ok)
				order[#order + 1] = { kind = "stop", ok = ok }
			end))
			helpers.assert_eq(#order, 0)

			local timer_fires = 0
			while calls.fire_next_timer() do
				timer_fires = timer_fires + 1
				if timer_fires >= CLEANUP_DEADLINE_PROBE_LIMIT then break end
			end
			helpers.assert_true(timer_fires > 0 and timer_fires < CLEANUP_DEADLINE_PROBE_LIMIT,
				"silent native exit must reach a finite cleanup deadline")
			helpers.assert_eq(#order, 2)
			helpers.assert_eq(order[1].kind, "installer")
			helpers.assert_true(order[1].ok == false)
			helpers.assert_eq(order[2].kind, "stop")
			helpers.assert_true(order[2].ok == false)
			helpers.assert_true(onboarding._active_tasks[task] ~= nil)
			helpers.assert_not_nil(onboarding._install_owner)
			helpers.assert_eq(#calls.tasks, construction_count,
				"deadline retries must never create a replacement task")
		end)
	end)

end)
