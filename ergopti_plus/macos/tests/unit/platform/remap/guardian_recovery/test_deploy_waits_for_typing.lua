--- tests/unit/platform/remap/guardian_recovery/test_deploy_waits_for_typing.lua

--- ==============================================================================
--- MODULE: Recovery Deploy Typing Deferral
--- DESCRIPTION:
--- A lease recovery deploys karabiner.json under a fresh token, and Karabiner
--- reloads every rule when that file changes. The deploy waits for a short
--- input silence, within a bounded delay, so the reload never lands mid-word.
--- An unknown idle time never delays it.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.guardian_recovery_fixture")
local TOKENS = fixture.TOKENS
local assert_delays = fixture.assert_delays
local has_log = fixture.has_log
local with_remap = fixture.with_remap





-- =============================================
-- =============================================
-- ======= 1/ Deferral While Keys Move =========
-- =============================================
-- =============================================

helpers.describe("Karabiner recovery deploy waits for typing to pause", function()
	helpers.it("(deploy-typing-deferral) holds the deploy while input is recent, then deploys", function()
		with_remap({ guardian_status = "ready", input_idle_seconds = 0.1 }, function(_, calls)
			calls.publish_failed(TOKENS[1])
			assert_delays(calls, { 1.0 })

			calls.recovery_timers[1]:fire()
			helpers.assert_eq(calls.builds, 0, "a reload must not land while keys are moving")
			assert_delays(calls, { 1.0, 0.25 })
			helpers.assert_true(has_log(calls, "deferred-for-typing"),
				"the deferral must be visible in the log")

			calls.input_idle_seconds = 2.0
			calls.recovery_timers[2]:fire()
			helpers.assert_eq(calls.build_tokens[1], TOKENS[2])
			helpers.assert_eq(calls.deploy_tokens[1], TOKENS[2])
			calls.deliver_ready()
			calls.deliver_resumed()
			helpers.assert_eq(calls.phase, "active")
		end)
	end)

	helpers.it("deploys after the bounded delay even when typing never pauses", function()
		with_remap({ guardian_status = "ready", input_idle_seconds = 0.1 }, function(_, calls)
			calls.publish_failed(TOKENS[1])
			calls.recovery_timers[1]:fire()
			local fired = 1
			while calls.builds == 0 and fired < 40 do
				fired = fired + 1
				calls.recovery_timers[fired]:fire()
			end
			helpers.assert_eq(calls.build_tokens[1], TOKENS[2], "the deferral is bounded")
			helpers.assert_eq(fired, 21, "twenty 0.25 s rechecks (five seconds), then the deploy")
			helpers.assert_true(has_log(calls, "typing deferral bound"))
		end)
	end)

	helpers.it("deploys at once when the input idle time is unknown", function()
		with_remap({ guardian_status = "ready" }, function(_, calls)
			calls.publish_failed(TOKENS[1])
			calls.recovery_timers[1]:fire()
			helpers.assert_eq(calls.build_tokens[1], TOKENS[2])
			assert_delays(calls, { 1.0 })
		end)
	end)
end)
