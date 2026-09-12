--- tests/unit/platform/remap/enable_transaction/test_pause_resume.lua

--- ==============================================================================
--- MODULE: Remap Transaction Regression
--- DESCRIPTION:
--- Preserves exact lifecycle and persistence guarantees inside one fixture scope.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.remap_transaction_fixture")

helpers.describe("karabiner pause/resume API exposes the complete transaction boundary", function()
	helpers.it("HS-011 withholds PAUSED while onboarding installer settlement refuses", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({ onboarding_stop_succeeds = false })
			local result, reason = nil, nil

			helpers.assert_true(remap.pause(function(ok, detail)
				result, reason = ok, detail
			end) == false)
			helpers.assert_true(result == false)
			helpers.assert_eq(reason, "onboarding-stop-incomplete")
			helpers.assert_eq(calls.onboarding_stop_attempts, 1)
			helpers.assert_eq(#calls.pause_callbacks, 0,
				"PAUSE must not reach the lease while installer cleanup is unsettled")
			helpers.assert_eq(calls.lease_phase, "active")

			calls.onboarding_stop_succeeds = true
			helpers.assert_true(remap.pause(function(ok) result = ok end))
			helpers.assert_eq(calls.onboarding_stop_attempts, 2)
			helpers.assert_eq(#calls.pause_callbacks, 1)
			calls.pause_callbacks[1](true, "paused")
			helpers.assert_true(result == true)
		end)
	end)

	helpers.it("HS-011 resumes the same PAUSE automatically after installer settlement", function()
		with_fixture(function(fixture)
			local remap, calls, installer = fixture.load_remap_with_real_onboarding()
			local result = nil

			helpers.assert_true(remap.pause(function(ok) result = ok end),
				"the real installer termination signal must be joined, not treated as exit")
			helpers.assert_nil(result)
			helpers.assert_eq(#calls.pause_callbacks, 0,
				"native PAUSE must wait below installer settlement")
			helpers.assert_eq(installer.task.terminate_calls, 1)
			helpers.assert_eq(#installer.outcomes, 0)

			installer.task:complete(1, "", "cancelled")
			helpers.assert_eq(#installer.outcomes, 1)
			helpers.assert_true(installer.outcomes[1].ok == false)
			helpers.assert_eq(#calls.pause_callbacks, 1,
				"the retained continuation must request PAUSE without a second user action")
			helpers.assert_nil(result)
			calls.pause_callbacks[1](true, "paused")
			helpers.assert_true(result == true)
		end)
	end)

	for _, mode in ipairs({ "throw", "false" }) do
		helpers.it("contains a PAUSE request returning " .. mode, function()
			with_fixture(function(fixture)
				local remap, calls = fixture.load_enabled_remap({ pause_mode = mode })
				local results = {}
				local call_ok, accepted = pcall(remap.pause, function(ok, reason)
					results[#results + 1] = { ok = ok, reason = reason }
				end)

				helpers.assert_true(call_ok, "PAUSE request failure escaped the public boundary")
				helpers.assert_true(accepted == false)
				helpers.assert_eq(#calls.pause_callbacks, 0)
				helpers.assert_eq(#results, 1, "the public callback must settle exactly once")
				helpers.assert_true(results[1].ok == false)
				helpers.assert_eq(results[1].reason,
					mode == "throw" and "request-raised" or "request-rejected")
			end)
		end)
	end

	helpers.it("settles pause only when the controller reports PAUSED", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			local result = nil

			helpers.assert_true(remap.pause(function(ok) result = ok end))
			helpers.assert_nil(result)
			calls.pause_callback(true, "paused")
			helpers.assert_true(result == true)
		end)
	end)

	helpers.it("publishing failure leaves the existing generation PAUSED and sends no RESUME", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({ paused = true, deploy_succeeds = false })
			local result = nil

			remap.resume(function(ok) result = ok end)
			helpers.assert_true(result == false)
			helpers.assert_eq(calls.build, 1)
			helpers.assert_eq(calls.deploy, 1)
			helpers.assert_eq(calls.resume or 0, 0,
				"publication failure must occur before the first RESUME write")
			helpers.assert_eq(calls.lease_bound_starts, 0)
			helpers.assert_eq(calls.stop, 0)
			helpers.assert_eq(calls.stop_exact, 0,
				"the already-PAUSED generation is the fail-closed rollback state")
		end)
	end)

	helpers.it("deploys and mounts every consumer before the first RESUME", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({ paused = true })
			local result = nil
			local starts_seen_by_callback = nil

			helpers.assert_true(remap.resume(function(ok)
				result = ok
				starts_seen_by_callback = calls.lease_bound_starts
			end))
			helpers.assert_nil(result,
				"local preparation alone must not publish success before RESUMED")
			helpers.assert_eq(calls.build, 1,
				"the private resume capability must refresh settings while script_control stays paused")
			helpers.assert_eq(calls.deploy, 1)
			helpers.assert_eq(calls.start, 0)
			helpers.assert_eq(calls.start_paused, 1)
			helpers.assert_eq(calls.lease_bound_starts, 1,
				"lease-bound inputs must mount while the generation remains PAUSED")
			helpers.assert_eq(calls.hotkey_attempts, 4)
			helpers.assert_eq(calls.classifier_refreshes, 1)
			helpers.assert_eq(calls.resume, 1,
				"explicit user resume sends exactly one RESUME after local preparation")

			calls.deliver_resumed()
			helpers.assert_eq(starts_seen_by_callback, 1,
				"the callback itself must observe already-started lease-bound inputs")
			helpers.assert_true(result == true)
		end)
	end)

	helpers.it("a failed local prerequisite retains the same PAUSED token without STOP", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({ paused = true, classifier_succeeds = false })
			local result = nil

			remap.resume(function(ok) result = ok end)
			helpers.assert_true(result == false)
			helpers.assert_eq(calls.lease_bound_starts, 1)
			helpers.assert_eq(calls.hotkey_attempts, 4)
			helpers.assert_eq(calls.unbound, 4)
			helpers.assert_eq(calls.resume or 0, 0)
			helpers.assert_eq(calls.stop, 0)
			helpers.assert_eq(calls.stop_exact, 0)
			helpers.assert_eq(calls.lease_phase, "paused")
		end)
	end)

	helpers.it("never treats retained disabled hotkey handles as live on resume", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({ paused = true, unbind_succeeds = false })
			local first_result = nil
			helpers.assert_true(remap.resume(function(ok) first_result = ok end))
			calls.deliver_resumed()
			helpers.assert_true(first_result == true)
			helpers.assert_eq(calls.resume, 1)

			calls.lease_phase = "paused"
			calls.phase_listener("paused")
			local retry_result, retry_reason = nil, nil
			helpers.assert_true(remap.resume(function(ok, reason)
				retry_result, retry_reason = ok, reason
			end))

			helpers.assert_true(retry_result == false)
			helpers.assert_eq(retry_reason, "lease-input-start-failed")
			helpers.assert_eq(calls.resume, 1,
				"a second RESUME must not be sent while all retained handles are disabled")
			helpers.assert_eq(calls.hotkey_attempts, 4,
				"non-live retained handles must not authorize or trigger fresh partial binds")
		end)
	end)

	helpers.it("keeps script-control paused when RESUMED is followed by deploy failure", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			local script_control, effects = fixture.load_resume_script_control(remap)

			helpers.assert_true(script_control.pause_all(),
				"the integration fixture must accept the pause transaction")
			effects.fire_deferred()
			helpers.assert_eq(#calls.pause_callbacks, 1)
			calls.lease_phase = "paused"
			calls.phase_listener("paused")
			calls.pause_callbacks[1](true, "paused")
			helpers.assert_true(script_control.is_paused())

			calls.fail_deploy = true
			script_control.resume_all()
			effects.fire_deferred()

			helpers.assert_eq(calls.build, 1,
				"the reproduction must reach paused regeneration")
			helpers.assert_eq(calls.deploy, 1,
				"the reproduction must fail at publication rather than before generation")
			helpers.assert_true(script_control.is_paused(),
				"RESUMED plus failed publication must not commit _is_paused=false")
			helpers.assert_eq(fixture.count_notifications(effects, "script_control.resumed", "success"), 0,
				"failed publication must never display the resume success notification")
			helpers.assert_eq(effects.calls.keymap_resume, nil)
			helpers.assert_eq(effects.calls.shortcuts_resume, nil)
			helpers.assert_eq(effects.calls.gestures_resume, nil)
			helpers.assert_eq(calls.lease_bound_starts, 0,
				"no lease-bound input may start from a generation that failed to publish")
			helpers.assert_eq(calls.start, 0,
				"a failed publication must not request ACTIVE authority")
			helpers.assert_eq(calls.resume or 0, 0,
				"publication failure must precede RESUME")
			helpers.assert_eq(#calls.pause_callbacks, 1,
				"the native generation never left PAUSED, so no rollback PAUSE is needed")

			helpers.assert_true(script_control.is_paused())
			helpers.assert_true(helpers.deep_equal(effects.pause_listener, { true }),
				"a failed resume must publish no false state transition")
			helpers.assert_eq(fixture.count_notifications(effects, "script_control.resumed", "success"), 0)
			helpers.assert_eq(fixture.count_notifications(effects, "script_control.resume_failed", "error"), 1)

			calls.fail_deploy = false
			script_control.resume_all()
			effects.fire_deferred()
			helpers.assert_true(script_control.is_paused(),
				"a retry must still wait for RESUMED before committing")
			helpers.assert_eq(calls.lease_bound_starts, 1)
			helpers.assert_eq(calls.resume, 1)
			calls.deliver_resumed()
			helpers.assert_true(not script_control.is_paused(),
				"the same public path must remain retryable from exact PAUSED")
			helpers.assert_eq(calls.lease_bound_starts, 1)
			helpers.assert_eq(fixture.count_notifications(effects, "script_control.resumed", "success"), 1)
			script_control.stop()
		end)
	end)
end)
