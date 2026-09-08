--- tests/unit/platform/remap/enable_transaction/test_exact_disable.lua

--- ==============================================================================
--- MODULE: Remap Transaction Regression
--- DESCRIPTION:
--- Preserves exact lifecycle and persistence guarantees inside one fixture scope.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.remap_transaction_fixture")

helpers.describe("karabiner set_enabled(false) is exact-lease-only", function()
	helpers.it("revokes once and performs no stock or deploy side effect", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap()

			remap.set_enabled(false)

			helpers.assert_eq(calls.stop, 1)
			helpers.assert_eq(calls.start, 0)
			helpers.assert_eq(calls.build, 0)
			helpers.assert_eq(calls.deploy, 0)
			helpers.assert_eq(calls.execute, 0,
				"disable must not probe, launch or signal a stock Karabiner process")
			calls.finish_stop(true, "stopped")
		end)
	end)

	helpers.it("coalesces repeated disable clicks while STOPPED is pending", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			remap.set_enabled(false)
			calls.stop, calls.execute = 0, 0

			remap.set_enabled(false)

			helpers.assert_eq(calls.stop, 0,
				"a pending disable must not start a second stop transaction")
			helpers.assert_eq(calls.execute, 0)
			calls.finish_stop(true, "stopped")
		end)
	end)

	helpers.it("rejects resume while the previous generation is still disabling", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({ paused = true })
			helpers.assert_true(remap.set_enabled(false))
			local build_before = calls.build
			local resumed, reason = nil, nil

			helpers.assert_true(remap.resume(function(ok, detail)
				resumed, reason = ok, detail
			end) == false)
			helpers.assert_true(resumed == false)
			helpers.assert_eq(reason, "disable-in-progress")
			helpers.assert_eq(calls.build, build_before,
				"resume must not deploy generation B before generation A reports STOPPED")
			helpers.assert_eq(calls.start_paused, 0)
			calls.finish_stop(true, "stopped")
		end)
	end)
end)

helpers.describe("karabiner disable state is committed only after STOPPED", function()
	helpers.it("HS-011 withholds disabled state while onboarding installer settlement refuses", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({ onboarding_stop_succeeds = false })
			local result, reason = nil, nil

			helpers.assert_true(remap.set_enabled(false, function(ok, detail)
				result, reason = ok, detail
			end) == false)
			helpers.assert_true(result == false)
			helpers.assert_eq(reason, "onboarding-stop-incomplete")
			helpers.assert_true(remap.get_enabled())
			helpers.assert_eq(calls.save, 0)
			helpers.assert_eq(calls.stop, 0,
				"disable must not enter its STOPPED transaction before installer settlement")

			calls.onboarding_stop_succeeds = true
			helpers.assert_true(remap.set_enabled(false))
			helpers.assert_eq(calls.onboarding_stop_attempts, 2)
			helpers.assert_eq(calls.stop, 1)
		end)
	end)

	helpers.it("HS-011 resumes the same disable automatically after installer settlement", function()
		with_fixture(function(fixture)
			local remap, calls, installer = fixture.load_remap_with_real_onboarding()
			local result = nil

			helpers.assert_true(remap.set_enabled(false, function(ok) result = ok end))
			helpers.assert_nil(result)
			helpers.assert_eq(calls.stop, 0,
				"lease revocation must wait below installer settlement")

			installer.task:complete(1, "", "cancelled")
			helpers.assert_eq(#installer.outcomes, 1)
			helpers.assert_true(installer.outcomes[1].ok == false)
			helpers.assert_eq(calls.stop, 1,
				"the retained disable continuation must run without a second user action")
			helpers.assert_nil(result)
			calls.finish_stop(true, "stopped")
			helpers.assert_true(result == true)
			helpers.assert_true(not remap.get_enabled())
		end)
	end)

	helpers.it("HS-011 joins lease and installer settlement in either shutdown order", function()
		with_fixture(function(fixture)
			for _, entry_point in ipairs({ "revoke", "shutdown" }) do
				for _, first in ipairs({ "lease", "installer" }) do
					local remap, calls, installer = fixture.load_remap_with_real_onboarding()
					local result, teardown_result = nil, nil
					local label = entry_point .. " with " .. first .. " first"
					local accepted
					if entry_point == "revoke" then
						accepted = remap.revoke("HS-011-order", function(ok)
							result = ok
							if ok == true then teardown_result = remap.teardown_local() end
						end)
					else
						accepted = remap.shutdown("HS-011-order", function(ok) result = ok end)
					end
					helpers.assert_true(accepted, label .. " must be accepted")

					if first == "lease" then
						calls.finish_stop(true, "stopped")
					else
						installer.task:complete(1, "", "cancelled")
					end
					helpers.assert_nil(result,
						label .. " must not publish after only one half settles")

					if first == "lease" then
						installer.task:complete(1, "", "cancelled")
					else
						calls.finish_stop(true, "stopped")
					end
					helpers.assert_true(result == true,
						label .. " must resume automatically after the second half")
					if entry_point == "revoke" then
						helpers.assert_true(teardown_result == true,
							"the root revoke+teardown path must observe settled onboarding")
					end
					helpers.assert_eq(#installer.outcomes, 1)
					helpers.assert_eq(#installer.tasks, 1,
						"joined shutdown must not construct a replacement installer")
				end
			end
		end)
	end)

	helpers.it("HS-011 revoke publishes failure after onboarding refusal and lease settlement", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({ onboarding_stop_succeeds = false })
			local outcomes = {}

			helpers.assert_true(remap.revoke("HS-011-refusal", function(ok, detail)
				outcomes[#outcomes + 1] = { ok = ok, detail = detail }
			end), "revoke must retain ownership until its lease half settles")
			helpers.assert_eq(#outcomes, 0,
				"revoke must still join the independently accepted lease revocation")
			calls.finish_stop(true, "stopped")
			helpers.assert_eq(#outcomes, 1,
				"onboarding refusal must not leave revoke pending after the lease settles")
			helpers.assert_true(outcomes[1].ok == false)
			helpers.assert_contains(tostring(outcomes[1].detail), "installer-stop-refused")
		end)
	end)

	helpers.it("keeps exact fence success distinct from a failed local hotkey delete", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({
				initially_enabled = false,
				unbind_succeeds = false,
			})
			remap.set_enabled(true)
			calls.deliver_ready()
			calls.deliver_resumed()

			local fenced, fence_reason = nil, nil
			helpers.assert_true(remap.revoke("test_shutdown", function(ok, reason)
				fenced, fence_reason = ok, reason
			end))
			helpers.assert_nil(fenced)
			calls.finish_stop(true, "stopped")

			helpers.assert_true(fenced == true,
				"STOPPED is an exact external fact even if later local cleanup fails")
			helpers.assert_eq(fence_reason, "stopped")
			helpers.assert_true(remap.teardown_local() == false,
				"a retained local hotkey must remain retryable without invalidating STOPPED")
			helpers.assert_true(fenced == true,
				"local teardown failure must not rewrite the published exact-fence result")
			helpers.assert_true(calls.unbound > 0,
				"the failure injection must reach a real lease-bound handle delete")
		end)
	end)

	helpers.it("retains a failed gesture watcher until local teardown retry", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({
				initially_enabled = false,
				gesture_stop_failures = 2,
			})
			remap.set_enabled(true)
			calls.deliver_ready()
			calls.deliver_resumed()

			local fenced = nil
			remap.revoke("test_shutdown", function(ok) fenced = ok end)
			calls.finish_stop(true, "stopped")
			helpers.assert_true(fenced == true)
			helpers.assert_eq(remap.teardown_local(), false,
				"the first native stop refusal must keep local teardown unsettled")
			helpers.assert_eq(calls.gesture_stop_attempts, 2)
			helpers.assert_eq(remap.teardown_local(), true,
				"the exact retained watcher must be retried, not forgotten")
			helpers.assert_eq(calls.gesture_stop_attempts, 3)
		end)
	end)

	helpers.it("retains a failed lifecycle timer cleanup until local teardown retry", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({
				initially_enabled = false,
			})
			remap.set_enabled(true)
			calls.deliver_ready()
			calls.deliver_resumed()

			local fenced = nil
			remap.revoke("test_shutdown", function(ok) fenced = ok end)
			calls.finish_stop(true, "stopped")
			helpers.assert_true(fenced == true)
			calls.lifecycle_stop_failures_remaining = 1
			local attempts_before_teardown = calls.lifecycle_stop_attempts
			local first_teardown = remap.teardown_local()
			helpers.assert_eq(calls.lifecycle_stop_attempts, attempts_before_teardown + 1,
				"local teardown must invoke the lifecycle cleanup exactly once per attempt")
			helpers.assert_eq(first_teardown, false,
				"a failed exact timer cancellation must keep local teardown unsettled")
			helpers.assert_eq(remap.teardown_local(), true,
				"the retained timer cleanup must be retried before teardown commits")
			helpers.assert_eq(calls.lifecycle_stop_attempts, attempts_before_teardown + 2)
			helpers.assert_eq(calls.execute, 0,
				"timer cleanup retry must never inspect or mutate stock Karabiner processes")
		end)
	end)

	helpers.it("commits disabled after a fallback fence without starting a recovery generation", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			local result, result_reason = nil, nil

			remap.set_enabled(false, function(ok, reason)
				result, result_reason = ok, reason
			end)
			-- The real controller uses ok=true once its native detached revoker has
			-- proven every exact token inert, even when the primary STOPPED ACK was lost.
			calls.finish_stop(true, "fallback-revoked")

			helpers.assert_eq(remap.get_enabled(), false)
			helpers.assert_eq(calls.save, 1)
			helpers.assert_true(calls.saved_enabled[1] == false)
			helpers.assert_true(result == true)
			helpers.assert_eq(result_reason, "fallback-revoked")
			helpers.assert_eq(calls.build, 0)
			helpers.assert_eq(calls.deploy, 0)
			helpers.assert_eq(calls.start, 0,
				"a proven fallback fence must not silently reactivate ErgoptiPlus")
			helpers.assert_eq(calls.start_paused, 0)
		end)
	end)

	helpers.it("keeps enabled state and persistence unchanged until the exact ACK", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			local result = nil

			remap.set_enabled(false, function(ok) result = ok end)
			helpers.assert_eq(remap.get_enabled(), true,
				"a stop request is not a committed disabled state")
			helpers.assert_eq(calls.save, 0, "disabled preference must not persist before STOPPED")
			helpers.assert_nil(result, "the public completion callback must wait for STOPPED")

			calls.finish_stop(true, "stopped")
			helpers.assert_eq(remap.get_enabled(), false)
			helpers.assert_eq(calls.save, 1)
			helpers.assert_true(result == true)
		end)
	end)

	helpers.it("rolls a failed stop forward to a new READY lease without claiming disabled", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			local result = nil

			remap.set_enabled(false, function(ok) result = ok end)
			calls.finish_stop(false, "stop-cli-failed")

			helpers.assert_eq(remap.get_enabled(), true,
				"failed STOPPED must preserve the last committed enabled preference")
			helpers.assert_eq(calls.save, 0)
			helpers.assert_eq(calls.build, 1,
				"a detached failed generation must be replaced explicitly")
			helpers.assert_eq(calls.deploy, 1)
			helpers.assert_eq(calls.start, 0)
			helpers.assert_eq(calls.start_paused, 1,
				"rollback generations must also begin atomically PAUSED")
			helpers.assert_true(calls.build_token ~= calls.stopped_token,
				"rollback generation must never reuse the detached lease token")
			helpers.assert_nil(result,
				"rollback is not complete until the replacement generation acknowledges READY")

			calls.deliver_ready()
			helpers.assert_nil(result,
				"restoration still waits for the exact RESUMED acknowledgement")
			calls.deliver_resumed()
			helpers.assert_true(result == false,
				"the requested disable failed even though the previous enabled state was restored")
			helpers.assert_eq(remap.get_enabled(), true)
		end)
	end)

	helpers.it("restores a failed disable atomically in paused mode without activating normal rules", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({ paused = true })
			local result = nil

			remap.set_enabled(false, function(ok) result = ok end)
			calls.finish_stop(false, "stop-cli-failed")

			helpers.assert_eq(remap.get_enabled(), true,
				"the last committed enabled state must survive paused rollback")
			helpers.assert_eq(calls.build, 1,
				"paused rollback must still deploy rules for a fresh generation")
			helpers.assert_eq(calls.start, 0,
				"paused rollback must never use the normal atomic mode=1 activation path")
			helpers.assert_eq(calls.start_paused, 1,
				"the replacement worker must request atomic mode=2 activation")
			helpers.assert_nil(result,
				"the failed disable must remain unsettled until paused READY")

			calls.deliver_ready()
			helpers.assert_true(result == false,
				"the disable request failed even though its prior paused state was restored")
			helpers.assert_eq(calls.lease_bound_starts, 0,
				"paused recovery must not restart gesture or keylogger resources")
		end)
	end)

	helpers.it("never starts a replacement lease after deployment fails", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({ deploy_succeeds = false })
			local result = nil

			remap.set_enabled(false, function(ok) result = ok end)
			calls.finish_stop(false, "stop-cli-failed")

			helpers.assert_eq(calls.build, 1)
			helpers.assert_eq(calls.deploy, 1)
			helpers.assert_eq(calls.start, 0,
				"a generation whose config was not deployed must never receive READY authority")
			helpers.assert_eq(calls.start_paused, 0)
			helpers.assert_true(result == false,
				"rollback must surface the deploy failure instead of waiting for an impossible READY")
			helpers.assert_eq(remap.get_enabled(), true)
		end)
	end)
end)
