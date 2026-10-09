--- tests/unit/platform/remap/onboarding_install/test_artifact_cleanup.lua

--- ==============================================================================
--- MODULE: Onboarding Installer artifact cleanup
--- DESCRIPTION:
--- Exercises artifact cleanup through the shared isolated native fixture.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.onboarding_install_fixture")
local Scenario = require("tests.support.onboarding_install_scenarios")
local with_fixture = Fixture.with_fixture
local advance_to_stage = Scenario.advance_to_stage
local CLEANUP_DEADLINE_PROBE_LIMIT = Scenario.CLEANUP_DEADLINE_PROBE_LIMIT

helpers.describe("HS-011 onboarding artifact cleanup", function()
	for _, artifact in ipairs({ "partial", "mount" }) do
		for _, refusal in ipairs({ false, "throw" }) do
			helpers.it("HS-011 " .. artifact .. " cleanup " .. tostring(refusal)
				.. " retries autonomously", function()
				local options = { remove_results = { refusal, true } }
				if artifact == "mount" then
					options = { detach_results = { refusal, true } }
				end
				with_fixture(options, function(onboarding, calls)
					local order = {}
					local stage = "download"
					if artifact == "mount" then stage = "install" end
					local task = advance_to_stage(onboarding, calls, stage, function(ok)
						order[#order + 1] = { kind = "installer", ok = ok }
					end)
					local construction_count = #calls.tasks
					helpers.assert_true(onboarding.stop(function(ok)
						order[#order + 1] = { kind = "stop", ok = ok }
					end))
					helpers.assert_eq(#order, 0)

					task:complete(1, "", "cancelled")
					helpers.assert_eq(#order, 0,
						"artifact refusal must retain the joined lifecycle until retry")
					helpers.assert_not_nil(onboarding._install_owner)
					helpers.assert_true(calls.fire_next_timer())
					helpers.assert_eq(#order, 2)
					helpers.assert_eq(order[1].kind, "installer")
					helpers.assert_true(order[1].ok == false)
					helpers.assert_eq(order[2].kind, "stop")
					helpers.assert_true(order[2].ok == true)
					helpers.assert_nil(onboarding._install_owner)
					local attempts = #calls.removes
					if artifact == "mount" then attempts = #calls.detaches end
					helpers.assert_eq(attempts, 2)
					helpers.assert_eq(#calls.tasks, construction_count,
						"artifact cleanup retry must not create a new installer")
				end)
			end)
		end
	end

	for _, artifact in ipairs({ "partial", "mount" }) do
		for _, refusal in ipairs({ false, "throw" }) do
			helpers.it("HS-011 terminal " .. artifact .. " debt " .. tostring(refusal)
				.. " retries without another lifecycle action", function()
				local options = { remove_results = { refusal, true } }
				if artifact == "mount" then
					options = { detach_results = { refusal, true } }
				end
				with_fixture(options, function(onboarding, calls)
					local outcomes = {}
					local stage = "download"
					if artifact == "mount" then stage = "install" end
					local task = advance_to_stage(onboarding, calls, stage, function(ok, detail)
						outcomes[#outcomes + 1] = { ok = ok, detail = detail }
					end)
					local construction_count = #calls.tasks

					task:complete(1, "", "synthetic terminal failure")
					helpers.assert_eq(#outcomes, 1)
					helpers.assert_true(outcomes[1].ok == false)
					helpers.assert_not_nil(onboarding._install_owner,
						"terminal cleanup refusal must retain the exact owner")
					helpers.assert_true(calls.fire_next_timer(),
						"terminal cleanup debt must retry without Pause, Disable, or Stop")
					helpers.assert_nil(onboarding._install_owner)
					helpers.assert_eq(#outcomes, 1,
						"cleanup settlement must not redeliver the installer terminal")
					local attempts = #calls.removes
					if artifact == "mount" then attempts = #calls.detaches end
					helpers.assert_eq(attempts, 2)
					helpers.assert_eq(#calls.tasks, construction_count,
						"terminal cleanup retry must not construct a new installer stage")
				end)
			end)
		end
	end

	for _, artifact in ipairs({ "partial", "mount" }) do
		helpers.it("HS-011 terminal " .. artifact
			.. " debt retries through multiple refusals", function()
			local options = { remove_results = { false, false, true } }
			if artifact == "mount" then
				options = { detach_results = { false, false, true } }
			end
			with_fixture(options, function(onboarding, calls)
				local outcomes = {}
				local stage = artifact == "mount" and "install" or "download"
				local task = advance_to_stage(onboarding, calls, stage, function(ok)
					outcomes[#outcomes + 1] = ok
				end)
				task:complete(1, "", "synthetic terminal failure")
				helpers.assert_eq(#outcomes, 1)
				helpers.assert_true(outcomes[1] == false)
				helpers.assert_true(calls.fire_next_timer())
				helpers.assert_not_nil(onboarding._install_owner,
					"a second refusal must retain autonomous cleanup ownership")
				helpers.assert_true(calls.fire_next_timer(),
					"the same terminal debt must re-arm without user action")
				helpers.assert_nil(onboarding._install_owner)
				local attempts = #calls.removes
				if artifact == "mount" then attempts = #calls.detaches end
				helpers.assert_eq(attempts, 3)
				helpers.assert_eq(#outcomes, 1)
			end)
		end)

		helpers.it("HS-011 terminal " .. artifact
			.. " debt exhausts its bounded retry owner", function()
			local refusals = { false, false, false, false, false }
			local options = { remove_results = refusals }
			if artifact == "mount" then options = { detach_results = refusals } end
			with_fixture(options, function(onboarding, calls)
				local outcomes = {}
				local stage = artifact == "mount" and "install" or "download"
				local task = advance_to_stage(onboarding, calls, stage, function(ok)
					outcomes[#outcomes + 1] = ok
				end)
				task:complete(1, "", "synthetic terminal failure")
				local timer_fires = 0
				while calls.fire_next_timer() do
					timer_fires = timer_fires + 1
					if timer_fires >= CLEANUP_DEADLINE_PROBE_LIMIT then break end
				end
				helpers.assert_true(timer_fires > 1
					and timer_fires < CLEANUP_DEADLINE_PROBE_LIMIT)
				helpers.assert_not_nil(onboarding._install_owner,
					"exhaustion must retain exact cleanup debt")
				helpers.assert_eq(#outcomes, 1,
					"retry exhaustion must not redeliver the installer terminal")
				local attempts = #calls.removes
				if artifact == "mount" then attempts = #calls.detaches end
				helpers.assert_eq(attempts, 4,
					"one immediate attempt plus three bounded retries are expected")
			end)
		end)
	end

end)
