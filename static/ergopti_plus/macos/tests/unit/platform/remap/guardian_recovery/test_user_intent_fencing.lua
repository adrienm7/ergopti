--- tests/unit/platform/remap/guardian_recovery/test_user_intent_fencing.lua

--- ==============================================================================
--- MODULE: Guardian Recovery User Intent Fencing
--- DESCRIPTION:
--- Exercises exact-lease recovery with a scoped native environment.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.guardian_recovery_fixture")
local TOKENS = fixture.TOKENS
local index_of = fixture.index_of
local assert_delays = fixture.assert_delays
local with_remap = fixture.with_remap

helpers.describe("Karabiner recovery user-intent fencing", function()
	helpers.it("lets explicit Stop cancel variable-writer recovery before IDLE", function()
		with_remap({ guardian_status = "ready" }, function(remap, calls)
			calls.ke_variables_recovery_observer(TOKENS[1], "writer-timeout")
			helpers.assert_true(remap.stop_lease())
			helpers.assert_eq(calls.phase, "idle")
			helpers.assert_eq(#calls.recovery_timers, 0,
				"a later poison-fence IDLE must not undo explicit user Stop")
		end)
	end)

	helpers.it("ignores a late writer timeout after explicit Stop already retired its token", function()
		with_remap({ guardian_status = "ready" }, function(remap, calls)
			helpers.assert_true(remap.stop_lease())
			calls.ke_variables_recovery_observer(TOKENS[1], "writer-timeout")
			calls.publish_phase("idle", nil)
			helpers.assert_eq(#calls.recovery_timers, 0,
				"an obsolete timeout must not resurrect a manually stopped generation")
		end)
	end)

	helpers.it("HS-011 surfaces onboarding stop refusal without entering Pause", function()
		with_remap({ guardian_status = "ready", onboarding_stop_failures = 1 },
			function(remap, calls)
				local pause_results = {}
				helpers.assert_true(remap.pause(function(ok, reason)
					pause_results[#pause_results + 1] = { ok = ok, reason = reason }
				end) == false)
				helpers.assert_eq(#pause_results, 1)
				helpers.assert_true(pause_results[1].ok == false)
				helpers.assert_eq(pause_results[1].reason, "onboarding-stop-incomplete")
				helpers.assert_eq(calls.phase, "active")
				helpers.assert_eq(calls.onboarding_stop_attempts, 1)
			end)
	end)

	helpers.it("keeps a cancelled queued callback inert and resumes with a fresh token", function()
		with_remap({ guardian_status = "ready", cancel_fails = true }, function(remap, calls)
			calls.publish_failed(TOKENS[1])
			local stale_timer = calls.recovery_timers[1]
			local pause_committed = false
			helpers.assert_true(remap.pause(function(ok)
				pause_committed = ok == true
				if ok == true then calls.script_paused = true end
			end))
			helpers.assert_true(pause_committed,
				"a no-live-lease PAUSE must commit the caller's local fail-closed state")
			helpers.assert_true(calls.cancel_attempts > 0)
			stale_timer:fire(true)
			helpers.assert_eq(calls.builds, 0)
			helpers.assert_eq(calls.deploys, 0)
			helpers.assert_eq(calls.starts_paused, 0)

			calls.cancel_fails = false
			helpers.assert_true(remap.resume())
			helpers.assert_eq(calls.build_tokens[1], TOKENS[2])
			calls.deliver_ready()
			helpers.assert_eq(calls.resume_requests, 1)
			calls.deliver_resumed()
		end)
	end)

	helpers.it("does not arm automatic work when FAILED arrives under pause", function()
		with_remap({ guardian_status = "ready", paused = true }, function(remap, calls)
			calls.publish_failed(TOKENS[1])
			helpers.assert_eq(#calls.recovery_timers, 0)
			helpers.assert_eq(calls.builds, 0)
			helpers.assert_true(remap.resume())
			helpers.assert_eq(calls.build_tokens[1], TOKENS[2])
		end)
	end)

	helpers.it("never sends RESUME when pause wins after the recovery worker starts", function()
		with_remap({ guardian_status = "ready" }, function(remap, calls)
			calls.publish_failed(TOKENS[1])
			calls.recovery_timers[1]:fire()
			helpers.assert_eq(calls.phase, "starting")
			helpers.assert_true(remap.pause())
			calls.deliver_ready()
			helpers.assert_eq(calls.phase, "paused")
			helpers.assert_eq(calls.resume_requests, 0,
				"the queued user pause must defeat automatic activation after READY")
			helpers.assert_eq(#calls.resume_callbacks, 0)
		end)
	end)

	helpers.it("commits Pause only after an in-flight recovery fence settles", function()
		with_remap({ guardian_status = "ready" }, function(remap, calls)
			calls.publish_failed(TOKENS[1])
			calls.recovery_timers[1]:fire()
			calls.defer_stop_exact = true
			calls.bind_failures_remaining = 1
			calls.deliver_ready()
			helpers.assert_eq(calls.phase, "stopping")
			helpers.assert_eq(#calls.recovery_timers, 2)
			local stale_retry = calls.recovery_timers[2]

			local pause_results = {}
			helpers.assert_true(remap.pause(function(ok, reason)
				pause_results[#pause_results + 1] = { ok = ok, reason = reason }
				if ok then calls.script_paused = true end
			end))
			helpers.assert_eq(#pause_results, 0,
				"Pause must not publish while retiring rules may still emit")
			stale_retry:fire(true)
			helpers.assert_eq(calls.builds, 1,
				"the cancelled recovery timer must stay inert during the fence")

			calls.complete_stop_exact()
			helpers.assert_eq(#pause_results, 1)
			helpers.assert_eq(pause_results[1].ok, true)
			helpers.assert_eq(pause_results[1].reason, "already-fail-closed")
			helpers.assert_true(calls.script_paused)
			helpers.assert_eq(calls.phase, "idle")
			helpers.assert_eq(#calls.recovery_timers, 2,
				"settling the joined fence must not resurrect automatic recovery")
		end)
	end)

	helpers.it("cancels FAILED recovery published before a joined Pause callback", function()
		with_remap({ guardian_status = "ready" }, function(remap, calls)
			calls.publish_failed(TOKENS[1])
			calls.recovery_timers[1]:fire()
			calls.begin_start_failure_fence("synthetic-worker-loss")
			helpers.assert_eq(calls.phase, "fencing")

			local pause_results = {}
			helpers.assert_true(remap.pause(function(ok, reason)
				pause_results[#pause_results + 1] = { ok = ok, reason = reason }
				if ok then calls.script_paused = true end
			end))
			helpers.assert_eq(#pause_results, 0)
			calls.complete_start_failure_fence()

			helpers.assert_eq(#pause_results, 1)
			helpers.assert_eq(pause_results[1].ok, true)
			helpers.assert_true(calls.script_paused)
			-- Pause detached the original bounded series before the exact fence
			-- published FAILED. That publication may briefly create a fresh 1 s
			-- series, but the joined stop barrier must cancel it before returning.
			assert_delays(calls, { 1.0, 1.0 })
			helpers.assert_true(calls.cancel_attempts > 0)
			local stale_retry = calls.recovery_timers[2]
			stale_retry:fire(true)
			helpers.assert_eq(calls.builds, 1,
				"the FAILED listener's pre-callback retry must be cancelled after Pause commits")
		end)
	end)

	helpers.it("lets a committed disable defeat a timer whose native stop failed", function()
		with_remap({ guardian_status = "ready", cancel_fails = true }, function(remap, calls)
			calls.publish_failed(TOKENS[1])
			local stale_timer = calls.recovery_timers[1]
			helpers.assert_true(remap.set_enabled(false))
			helpers.assert_true(remap.get_enabled() == false)
			helpers.assert_true(calls.cancel_attempts > 0)
			stale_timer:fire(true)
			helpers.assert_eq(calls.builds, 0)
			helpers.assert_eq(calls.deploys, 0)
		end)
	end)

	helpers.it("makes Disable authoritative while a recovery fence is still pending", function()
		with_remap({ guardian_status = "ready", cancel_fails = true }, function(remap, calls)
			calls.publish_failed(TOKENS[1])
			calls.recovery_timers[1]:fire()
			calls.defer_stop_exact = true
			calls.bind_failures_remaining = 1
			calls.deliver_ready()
			helpers.assert_eq(calls.phase, "stopping")
			local stale_retry = calls.recovery_timers[2]

			local disable_results = {}
			helpers.assert_true(remap.set_enabled(false, function(ok, reason)
				disable_results[#disable_results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_true(remap.get_enabled(),
				"the preference cannot commit before the exact STOP barrier")
			stale_retry:fire(true)
			helpers.assert_eq(calls.builds, 1)
			helpers.assert_eq(calls.deploys, 1)
			helpers.assert_eq(calls.starts_paused, 1)

			calls.complete_stop_exact()
			helpers.assert_true(remap.get_enabled() == false)
			helpers.assert_eq(#disable_results, 1)
			helpers.assert_eq(disable_results[1].ok, true)
			helpers.assert_eq(#calls.recovery_timers, 2)
		end)
	end)

	helpers.it("epoch-fences a queued timer as soon as revocation is requested", function()
		with_remap({ guardian_status = "ready", cancel_fails = true }, function(remap, calls)
			calls.publish_failed(TOKENS[1])
			local stale_timer = calls.recovery_timers[1]
			helpers.assert_true(remap.revoke("test-shutdown"))
			helpers.assert_true(calls.cancel_attempts > 0)
			stale_timer:fire(true)
			helpers.assert_eq(calls.builds, 0)
			helpers.assert_eq(calls.deploys, 0)
		end)
	end)

	helpers.it("retains failed timer cancellation until local teardown proves cleanup", function()
		with_remap({ guardian_status = "ready" }, function(remap, calls)
			calls.publish_failed(TOKENS[1])
			calls.cancel_failures_remaining = 2
			helpers.assert_true(remap.revoke("test-shutdown"))
			helpers.assert_eq(calls.cancel_attempts, 1)
			helpers.assert_true(remap.teardown_local() == false,
				"teardown must not claim success while a native timer remains unproven")
			helpers.assert_eq(calls.cancel_attempts, 2,
				"teardown retries the exact retained recovery timer")
			helpers.assert_true(remap.teardown_local())
			helpers.assert_eq(calls.cancel_attempts, 3)
		end)
	end)

	helpers.it("retains onboarding poll cleanup debt in the composed local teardown", function()
		with_remap({ guardian_status = "ready" }, function(remap, calls)
			helpers.assert_true(remap.revoke("test-shutdown"))
			calls.onboarding_stop_failures_remaining = 1
			helpers.assert_eq(remap.teardown_local(), false,
				"local teardown must surface an exact onboarding timer stop refusal")
			helpers.assert_eq(calls.onboarding_stop_attempts, 2)
			helpers.assert_eq(remap.teardown_local(), true,
				"the same module-owned onboarding cleanup debt must remain retryable")
			helpers.assert_eq(calls.onboarding_stop_attempts, 3)
		end)
	end)

	helpers.it("replays a worker loss hidden by a failed Disable rollback", function()
		with_remap({ guardian_status = "ready", disable_persist_failures = 1 }, function(remap, calls)
			local disable_results = {}
			helpers.assert_true(remap.set_enabled(false, function(ok, reason)
				disable_results[#disable_results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_true(remap.get_enabled())
			helpers.assert_eq(calls.build_tokens[1], TOKENS[2])
			helpers.assert_eq(calls.deploy_tokens[1], TOKENS[2])
			helpers.assert_eq(calls.starts_paused, 1)

			calls.fail_start("rollback-worker-lost", function()
				helpers.assert_eq(calls.phase, "failed")
				helpers.assert_eq(calls.current_token, nil)
				helpers.assert_eq(#disable_results, 0,
					"FAILED is published before the rollback transaction releases its gate")
				helpers.assert_eq(#calls.recovery_timers, 0,
					"the phase listener must not bypass an enabled-state transaction")
			end)

			helpers.assert_eq(#disable_results, 1)
			helpers.assert_eq(disable_results[1].ok, false)
			helpers.assert_eq(disable_results[1].reason, "persistence-failed-after-STOPPED")
			assert_delays(calls, { 1.0 })
			calls.recovery_timers[1]:fire()
			helpers.assert_true(helpers.deep_equal(calls.build_tokens, { TOKENS[2], TOKENS[3] }))
			helpers.assert_true(helpers.deep_equal(calls.deploy_tokens, { TOKENS[2], TOKENS[3] }))
			helpers.assert_eq(calls.starts_paused, 2)
			helpers.assert_eq(calls.resume_requests, 0)

			calls.deliver_ready()
			local ready_index = index_of(calls.order, "ready:" .. TOKENS[3])
			local consumer_index = index_of(calls.order, "consumer:gesture")
			local classifier_index = index_of(calls.order, "classifier")
			local resume_index = index_of(calls.order, "resume:" .. TOKENS[3])
			helpers.assert_true(ready_index < consumer_index and consumer_index < classifier_index
				and classifier_index < resume_index)
			calls.deliver_resumed()
			helpers.assert_eq(calls.phase, "active")
			helpers.assert_eq(#disable_results, 1)
		end)
	end)

	for _, failure in ipairs({
		{ label = "input bind", field = "bind_failures_remaining" },
		{ label = "classifier", field = "classifier_failures_remaining" },
	}) do
		helpers.it("waits for an exact fence after failed Disable rollback " .. failure.label,
			function()
				with_remap({ guardian_status = "ready", disable_persist_failures = 1 },
					function(remap, calls)
						local disable_results = {}
						calls.defer_stop_exact = true
						helpers.assert_true(remap.set_enabled(false, function(ok, reason)
							disable_results[#disable_results + 1] = { ok = ok, reason = reason }
						end))
						calls[failure.field] = 1
						calls.deliver_ready()

						helpers.assert_eq(calls.phase, "stopping")
						helpers.assert_eq(#calls.recovery_timers, 0,
							"no replacement may start before the exact STOP settles")
						helpers.assert_eq(#disable_results, 1)
						helpers.assert_eq(disable_results[1].ok, false)
						helpers.assert_eq(disable_results[1].reason,
							"persistence-failed-after-STOPPED")

						calls.complete_stop_exact()
						assert_delays(calls, { 1.0 })
						calls.recovery_timers[1]:fire()
						helpers.assert_true(helpers.deep_equal(
							calls.build_tokens, { TOKENS[2], TOKENS[3] }))
						helpers.assert_eq(calls.starts_paused, 2)
					end)
			end)
	end
end)
