--- tests/unit/platform/remap/layout/test_wake_reresolves_layout_actions_wake_callback.lua

--- ==============================================================================
--- MODULE: Behavioral Wake and Lease-Phase Lifecycle Tests
--- DESCRIPTION:
--- Drives the retained caffeinate callback over pure doubles. Proves the exact
--- lease is refreshed before layout work, pause/teardown are fail-closed, and
--- callback or watcher failures reach the file-logger boundary instead of being
--- swallowed by Hammerspoon's async callback dispatcher.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.platform.remap.layout.wake_reresolves_layout_actions_fixture"] = nil
local Fixture = require("tests.support.platform.remap.layout.wake_reresolves_layout_actions_fixture")
local SCREENS_DID_UNLOCK = Fixture.SCREENS_DID_UNLOCK
local SYSTEM_DID_WAKE = Fixture.SYSTEM_DID_WAKE
local error_log_contains = Fixture.error_log_contains
local load_remap = Fixture.load_remap
local reset_layout_observations = Fixture.reset_layout_observations
local sequence_index = Fixture.sequence_index





helpers.describe("karabiner wake callback lifecycle", function()
	helpers.it("cancels and fences the deferred wizard before local teardown commits", function()
		local remap, calls = load_remap()
		local wizard_timer = calls.timers[1]
		helpers.assert_type(wizard_timer, "table",
			"enabled initialization must retain the deferred wizard timer")
		helpers.assert_eq(wizard_timer.delay, 2.0)

		helpers.assert_true(remap.stop())
		calls.deliver_stopped()
		helpers.assert_true(wizard_timer.running == false,
			"local teardown must cancel the exact deferred wizard timer")
		wizard_timer:fire(true)
		helpers.assert_eq(calls.wizard_runs, 0,
			"an already-queued wizard callback must reject the stopped lifecycle")
		helpers.assert_eq(calls.onboarding_stops, 2,
			"public revocation and final local teardown must each settle loaded onboarding")
	end)

	helpers.it("retries the exact deferred wizard within the bounded stop transaction", function()
		local remap, calls = load_remap({ timer_cancel_refusals = 1 })
		local wizard_timer = calls.timers[1]

		helpers.assert_true(remap.stop())
		calls.deliver_stopped()
		helpers.assert_eq(calls.timer_cancel_attempts, 2,
			"the aggregate stop must retry the exact refused timer within its bounded join")
		helpers.assert_true(wizard_timer.running == false,
			"the successful bounded retry must settle the original native capability")
		helpers.assert_true(remap.teardown_local(),
			"a repeated local teardown must recognize the exact timer as already settled")
		helpers.assert_eq(calls.timer_cancel_attempts, 2,
			"settled cleanup must not issue a third native cancellation")
		helpers.assert_true(wizard_timer.running == false)
		wizard_timer:fire(true)
		helpers.assert_eq(calls.wizard_runs, 0,
			"cleanup debt must remain callback-inert across every retry")
	end)

	helpers.it("renews the exact lease before redeploying the already-active generation", function()
		local _, calls = load_remap()
		helpers.assert_true(calls.init_ok, tostring(calls.init_err))
		calls.activate_initial()
		calls.sequence = {}
		calls.refresh = 0
		calls.resolve = 0
		calls.build = 0
		calls.deploy = 0
		calls.lease_start = 0
		calls.lease_pause = 0
		calls.lease_resume = 0
		calls.classifier_refresh = 0
		calls.rebind = 0

		local callback_ok, callback_err = calls.wake(SYSTEM_DID_WAKE)
		helpers.assert_true(callback_ok, tostring(callback_err))
		helpers.assert_eq(calls.sequence[1], "refresh",
			"the first post-wake side effect must prove exact-generation liveness")
		helpers.assert_eq(calls.refresh, 1)
		helpers.assert_eq(calls.resolve, 0,
			"the pre-settle callback must not read hs.keycodes.map")
		helpers.assert_eq(calls.build, 0)
		helpers.assert_true(calls.fire_latest_timer())
		helpers.assert_eq(calls.lease_pause, 0,
			"layout maintenance must never create a raw-key window by gating normal rules PAUSED")
		helpers.assert_eq(calls.lease_phase, "active")
		helpers.assert_eq(calls.resolve, 1,
			"the settled active pipeline must resolve exactly once at its consumer")
		helpers.assert_eq(calls.build, 1)
		helpers.assert_eq(calls.deploy, 1)
		helpers.assert_eq(calls.classifier_refresh, 1,
			"the redeployed generation must refresh synthetic-output classification")
		helpers.assert_eq(calls.lease_start, 0,
			"an ACTIVE replacement must not start or replace the exact lease authority")
		helpers.assert_eq(calls.rebind, 1,
			"wake and input-source changes must share the shortcut-rebind path")
		helpers.assert_eq(calls.lease_resume, 0)
		local resolve_at = sequence_index(calls.sequence, "resolve")
		local build_at = sequence_index(calls.sequence, "build")
		local deploy_at = sequence_index(calls.sequence, "deploy")
		local classifier_at = sequence_index(calls.sequence, "classifier-refresh")
		local rebind_at = sequence_index(calls.sequence, "rebind")
		helpers.assert_true(resolve_at < build_at and build_at < deploy_at)
		helpers.assert_true(deploy_at < classifier_at and classifier_at < rebind_at)
	end)

	helpers.it("refreshes while paused but never redeploys", function()
		local _, calls = load_remap({ paused = true, initial_phase = "paused" })
		calls.sequence = {}

		local callback_ok, callback_err = calls.wake(SCREENS_DID_UNLOCK)
		helpers.assert_true(callback_ok, tostring(callback_err))
		helpers.assert_eq(calls.sequence[1], "refresh")
		helpers.assert_eq(calls.refresh, 1)
		helpers.assert_eq(calls.resolve, 0)
		helpers.assert_true(calls.fire_latest_timer())
		helpers.assert_eq(calls.resolve, 1)
		helpers.assert_eq(calls.build, 0,
			"unknown wake timing must not undo the user-visible paused state")
		helpers.assert_eq(calls.deploy, 0)
		helpers.assert_eq(calls.rebind, 0,
			"paused bindings are rebuilt by the eventual resume transaction")
	end)

	helpers.it("logs async step failures and refuses a stale-layout deploy", function()
		local _, calls = load_remap({ resolve_raises = true, initial_phase = "active" })
		calls.sequence = {}

		local callback_ok, callback_err = calls.wake(SYSTEM_DID_WAKE)
		helpers.assert_true(callback_ok, tostring(callback_err))
		helpers.assert_eq(calls.sequence[1], "refresh")
		helpers.assert_true(calls.fire_latest_timer())
		helpers.assert_eq(calls.build, 0)
		helpers.assert_true(error_log_contains(calls,
			"Karabiner regeneration layout-action resolution failed"),
			"an hs.caffeinate callback exception must reach the file logger")
	end)

	helpers.it("fails closed when pause state cannot be proven", function()
		local _, calls = load_remap({ pause_raises = true })
		local callback_ok, callback_err = calls.wake(SYSTEM_DID_WAKE)

		helpers.assert_true(callback_ok, tostring(callback_err))
		helpers.assert_eq(calls.refresh, 1)
		helpers.assert_true(calls.fire_latest_timer())
		helpers.assert_eq(calls.build, 0,
			"a failed pause query must never be interpreted as unpaused")
		helpers.assert_true(error_log_contains(calls, "Settled Wake pause-state query failed"))
	end)

	helpers.it("continues the settled layout pipeline after a logged lease-refresh failure", function()
		local _, calls = load_remap({ refresh_raises = true, initial_phase = "active" })
		local callback_ok, callback_err = calls.wake(SYSTEM_DID_WAKE)

		helpers.assert_true(callback_ok, tostring(callback_err))
		helpers.assert_true(error_log_contains(calls, "Wake exact-lease liveness refresh failed"))
		helpers.assert_true(calls.fire_latest_timer())
		helpers.assert_eq(calls.resolve, 1)
		helpers.assert_eq(calls.deploy, 1,
			"independent layout work must not vanish with an async refresh exception")
	end)

	helpers.it("ignores disabled, unrelated, and post-stop retained callbacks", function()
		local disabled, disabled_calls = load_remap({ enabled = false })
		local disabled_ok, disabled_err = disabled_calls.wake(SYSTEM_DID_WAKE)
		helpers.assert_true(disabled_ok, tostring(disabled_err))
		helpers.assert_eq(disabled_calls.refresh, 0,
			"a disabled integration owns no live lease and must emit no lease write")
		helpers.assert_true(disabled_calls.fire_latest_timer())
		helpers.assert_eq(disabled_calls.resolve, 1)
		helpers.assert_eq(disabled_calls.rebind, 1,
			"disabling Ergopti Karabiner must not disable Hammerspoon layout maintenance")
		helpers.assert_eq(disabled_calls.build, 0)
		helpers.assert_eq(disabled_calls.deploy, 0)

		local remap, calls = load_remap()
		calls.activate_initial()
		calls.refresh = 0
		calls.resolve = 0
		calls.build = 0
		calls.deploy = 0
		calls.rebind = 0
		local unrelated_ok, unrelated_err = calls.wake(999)
		helpers.assert_true(unrelated_ok, tostring(unrelated_err))
		helpers.assert_eq(calls.refresh, 0)
		local wake_ok, wake_err = calls.wake(SYSTEM_DID_WAKE)
		helpers.assert_true(wake_ok, tostring(wake_err))
		local queued_timer = calls.latest_timer()
		remap.stop()
		helpers.assert_eq(calls.watcher_stop, 0,
			"lease consumers remain live until the exact native fence settles")
		queued_timer:fire(true)
		local stale_ok, stale_err = calls.wake(SYSTEM_DID_WAKE)
		helpers.assert_true(stale_ok, tostring(stale_err))
		helpers.assert_eq(calls.refresh, 1,
			"a queued callback retained after teardown must be epoch-invalidated")
		helpers.assert_eq(calls.resolve, 0)
		helpers.assert_eq(calls.deploy, 0)
		calls.deliver_stopped()
		helpers.assert_eq(calls.watcher_stop, 1,
			"the settled exact fence releases the wake watcher and pending timer")
		disabled.stop()
	end)

	helpers.it("replays a settled wake immediately after heartbeat recovery", function()
		local _, calls = load_remap()
		calls.activate_initial()
		reset_layout_observations(calls)
		calls.refresh_enters_recovery = true

		helpers.assert_true(calls.wake(SYSTEM_DID_WAKE))
		local original_timer = calls.latest_timer()
		helpers.assert_true(original_timer.delay > 0,
			"a new OS event must still wait for TIS to publish the new layout")
		original_timer:fire()
		helpers.assert_eq(calls.resolve, 0)
		helpers.assert_eq(calls.build, 0)
		helpers.assert_eq(calls.deploy, 0)
		helpers.assert_eq(calls.rebind, 0)

		calls.refresh_enters_recovery = false
		calls.publish_phase("active")
		local replay_timer = calls.latest_timer()
		helpers.assert_true(replay_timer ~= original_timer)
		helpers.assert_eq(replay_timer.delay, 0,
			"a retained event that already paid the TIS debounce must replay next-turn")
		replay_timer:fire()
		helpers.assert_eq(calls.resolve, 1)
		helpers.assert_eq(calls.build, 1)
		helpers.assert_eq(calls.deploy, 1)
		helpers.assert_eq(calls.rebind, 1)
	end)

	helpers.it("coalesces repeated layout events retained during recovery", function()
		local _, calls = load_remap()
		calls.activate_initial()
		reset_layout_observations(calls)
		calls.refresh_enters_recovery = true

		helpers.assert_true(calls.wake(SYSTEM_DID_WAKE))
		calls.latest_timer():fire()
		helpers.assert_true(calls.wake(SCREENS_DID_UNLOCK))
		calls.latest_timer():fire()
		helpers.assert_eq(calls.resolve, 0)
		helpers.assert_eq(calls.deploy, 0)

		calls.refresh_enters_recovery = false
		local timer_count_before_replay = #calls.timers
		calls.publish_phase("active")
		helpers.assert_eq(#calls.timers, timer_count_before_replay + 1,
			"the newest durable record must own exactly one recovery replay")
		calls.latest_timer():fire()
		helpers.assert_eq(calls.resolve, 1)
		helpers.assert_eq(calls.deploy, 1)
		helpers.assert_eq(calls.rebind, 1)
	end)

	for _, case in ipairs({
		{ transient = "stopping", settled = "idle" },
		{ transient = "fencing", settled = "failed" },
	}) do
		helpers.it("replays without redeploy after the exact lease settles " .. case.settled, function()
			local _, calls = load_remap()
			calls.activate_initial()
			reset_layout_observations(calls)
			calls.publish_phase(case.transient)

			helpers.assert_true(calls.wake(SYSTEM_DID_WAKE))
			calls.latest_timer():fire()
			helpers.assert_eq(calls.resolve, 0)
			helpers.assert_eq(calls.deploy, 0)

			calls.publish_phase(case.settled)
			local replay_timer = calls.latest_timer()
			helpers.assert_eq(replay_timer.delay, 0)
			replay_timer:fire()
			helpers.assert_eq(calls.resolve, 1)
			helpers.assert_eq(calls.build, 0)
			helpers.assert_eq(calls.deploy, 0)
			helpers.assert_eq(calls.rebind, 1)
			local timer_count = #calls.timers
			calls.publish_phase("active")
			helpers.assert_eq(#calls.timers, timer_count,
				"the settled non-deploying pipeline must consume its durable record")
		end)
	end

	helpers.it("refreshes Hammerspoon state without deploying from stable PREPARED", function()
		local _, calls = load_remap({ initial_phase = "prepared" })
		reset_layout_observations(calls)

		helpers.assert_true(calls.wake(SYSTEM_DID_WAKE))
		calls.latest_timer():fire()
		helpers.assert_eq(calls.resolve, 1)
		helpers.assert_eq(calls.build, 0)
		helpers.assert_eq(calls.deploy, 0)
		helpers.assert_eq(calls.rebind, 1)
	end)

	helpers.it("waits for both native PAUSED and the script pause commit", function()
		local remap, calls = load_remap()
		calls.activate_initial()
		local pause_results = {}
		helpers.assert_true(remap.pause(function(ok, reason)
			pause_results[#pause_results + 1] = { ok = ok, reason = reason }
			if ok then calls.set_script_paused(true) end
		end))
		reset_layout_observations(calls)

		helpers.assert_true(calls.wake(SYSTEM_DID_WAKE))
		calls.latest_timer():fire()
		calls.publish_phase("paused")
		local premature_replay = calls.latest_timer()
		helpers.assert_eq(premature_replay.delay, 0)
		premature_replay:fire()
		helpers.assert_eq(calls.resolve, 0,
			"native PAUSED alone must not consume a layout event before script-control commits")

		calls.deliver_pause_callbacks(true, "paused")
		helpers.assert_eq(#pause_results, 1)
		helpers.assert_true(pause_results[1].ok)
		local committed_replay = calls.latest_timer()
		helpers.assert_true(committed_replay ~= premature_replay)
		committed_replay:fire()
		helpers.assert_eq(#pause_results, 1,
			"layout replay must not resettle the originating pause transaction")
		helpers.assert_eq(calls.resolve, 1)
		helpers.assert_eq(calls.build, 0)
		helpers.assert_eq(calls.deploy, 0)
		helpers.assert_eq(calls.rebind, 0,
			"paused bindings are rebuilt only by the eventual resume transaction")
	end)

	helpers.it("waits for both native ACTIVE and the script resume commit", function()
		local remap, calls = load_remap({
			initial_phase = "paused",
			paused = true,
			model_exact_layout_fence = true,
		})
		local resume_results = {}
		local stale_token = calls.lease_token
		helpers.assert_true(remap.resume(function(ok, reason)
			resume_results[#resume_results + 1] = { ok = ok, reason = reason }
			if ok then calls.set_script_paused(false) end
		end))
		helpers.assert_eq(calls.resume_tokens[1], stale_token,
			"the fixture must reach RESUMING on the pre-layout token")
		reset_layout_observations(calls)

		helpers.assert_true(calls.wake(SYSTEM_DID_WAKE))
		helpers.assert_true(sequence_index(calls.stop_exact_tokens, stale_token) ~= nil,
			"the layout event must fence the exact pre-layout generation")
		helpers.assert_eq(calls.lease_phase, "idle",
			"the retry must remain fail-closed until the TIS settle timer fires")
		helpers.assert_eq(#resume_results, 0,
			"fencing an internal stale attempt must preserve the public Resume intent")
		local settle_timer = calls.latest_timer()
		settle_timer:fire()
		local fresh_token = calls.lease_token
		helpers.assert_true(fresh_token ~= stale_token,
			"post-TIS retry must own a fresh lease token")
		helpers.assert_eq(calls.resolve, 1)
		helpers.assert_eq(calls.build, 1)
		helpers.assert_eq(calls.deploy, 1)
		helpers.assert_eq(#resume_results, 0,
			"a rebuilt PAUSED generation is not success before READY and RESUMED")

		calls.deliver_ready()
		helpers.assert_eq(calls.resume_tokens[2], fresh_token,
			"only the fresh post-TIS generation may receive the replacement RESUME")
		helpers.assert_eq(#calls.resume_tokens, 2,
			"the stale generation must never receive a second RESUME")
		calls.deliver_resumed()
		helpers.assert_eq(#resume_results, 1)
		helpers.assert_true(resume_results[1].ok)
		local committed_replay = calls.latest_timer()
		helpers.assert_true(committed_replay ~= settle_timer)
		helpers.assert_eq(committed_replay.delay, 0)
		committed_replay:fire()
		helpers.assert_eq(#resume_results, 1,
			"layout replay must not resettle the originating resume transaction")
		helpers.assert_eq(calls.resolve, 1)
		helpers.assert_eq(calls.build, 1)
		helpers.assert_eq(calls.deploy, 1)
		helpers.assert_eq(calls.rebind, 1)
	end)

	helpers.it("retains a layout change until an enable transaction commits", function()
		local remap, calls = load_remap({
			enabled = false,
			model_exact_layout_fence = true,
		})
		local enable_results = {}
		local stale_token = calls.lease_token
		helpers.assert_true(remap.set_enabled(true, function(ok, reason)
			enable_results[#enable_results + 1] = { ok = ok, reason = reason }
		end))
		reset_layout_observations(calls)

		helpers.assert_true(calls.wake(SYSTEM_DID_WAKE))
		helpers.assert_true(sequence_index(calls.stop_exact_tokens, stale_token) ~= nil,
			"the layout event must fence the exact pre-layout Enable generation")
		helpers.assert_eq(calls.lease_phase, "idle")
		helpers.assert_eq(#calls.resume_tokens, 0,
			"the stale pre-layout generation must never receive RESUME")
		helpers.assert_eq(#enable_results, 0,
			"the internal exact fence must preserve the public Enable intent")
		helpers.assert_eq(calls.resolve, 0,
			"the private Enable retry must not read TIS before the settle timer")
		local settle_timer = calls.latest_timer()
		settle_timer:fire()
		local fresh_token = calls.lease_token
		helpers.assert_true(fresh_token ~= stale_token,
			"post-TIS Enable retry must own a fresh lease token")
		helpers.assert_eq(calls.resolve, 1)
		helpers.assert_eq(calls.build, 1)
		helpers.assert_eq(calls.deploy, 1)
		helpers.assert_eq(#enable_results, 0)

		calls.deliver_ready()
		helpers.assert_eq(calls.resume_tokens[1], fresh_token)
		helpers.assert_eq(#enable_results, 0,
			"pre-RESUME preference commit must not publish Enable success")
		calls.deliver_resumed()
		helpers.assert_eq(#enable_results, 1)
		helpers.assert_true(enable_results[1].ok)
		local committed_replay = calls.latest_timer()
		helpers.assert_true(committed_replay ~= settle_timer)
		helpers.assert_eq(committed_replay.delay, 0)
		committed_replay:fire()
		helpers.assert_eq(#enable_results, 1,
			"layout replay must not resettle the originating enable transaction")
		helpers.assert_eq(calls.resolve, 1)
		helpers.assert_eq(calls.build, 1)
		helpers.assert_eq(calls.deploy, 1)
		helpers.assert_eq(calls.rebind, 1)
	end)

	helpers.it("replays in disabled mode only after STOPPED, guardian removal and preference commit", function()
		local remap, calls = load_remap({ unregister_async = true })
		calls.activate_initial()
		local disable_results = {}
		helpers.assert_true(remap.set_enabled(false, function(ok, reason)
			disable_results[#disable_results + 1] = { ok = ok, reason = reason }
		end))
		reset_layout_observations(calls)

		helpers.assert_true(calls.wake(SYSTEM_DID_WAKE))
		calls.latest_timer():fire()
		helpers.assert_eq(calls.resolve, 0)
		calls.publish_phase("idle")
		local premature_replay = calls.latest_timer()
		helpers.assert_eq(premature_replay.delay, 0)
		premature_replay:fire()
		helpers.assert_eq(calls.resolve, 0,
			"IDLE publication alone must not outrun the disable transaction callback")
		calls.deliver_stop_callbacks(true, "stopped")
		helpers.assert_eq(#disable_results, 0, "STOPPED cannot outrun guardian removal")
		helpers.assert_eq(calls.guardian_unregistrations, 1)
		calls.unregister_callback(true, "unregistered")
		helpers.assert_eq(#disable_results, 1)
		helpers.assert_true(disable_results[1].ok)
		local replay_timer = calls.latest_timer()
		helpers.assert_eq(replay_timer.delay, 0)
		replay_timer:fire()
		helpers.assert_eq(#disable_results, 1,
			"layout replay must not resettle the originating disable transaction")
		helpers.assert_eq(calls.resolve, 1)
		helpers.assert_eq(calls.build, 0)
		helpers.assert_eq(calls.deploy, 0)
		helpers.assert_eq(calls.rebind, 1,
			"disabled Karabiner must not disable Hammerspoon layout maintenance")
	end)

	helpers.it("serializes a retained layout event behind disable rollback recovery", function()
		local remap, calls = load_remap()
		calls.activate_initial()
		local disable_results = {}
		helpers.assert_true(remap.set_enabled(false, function(ok, reason)
			disable_results[#disable_results + 1] = { ok = ok, reason = reason }
		end))
		reset_layout_observations(calls)
		helpers.assert_true(calls.wake(SYSTEM_DID_WAKE))
		calls.latest_timer():fire()

		calls.deliver_stop_failure("synthetic-stop-failure")
		local rollback_builds = calls.build
		calls.latest_timer():fire()
		helpers.assert_eq(calls.build, rollback_builds,
			"FAILED publication must not race the private rollback transaction")
		reset_layout_observations(calls)
		calls.publish_phase("paused")
		calls.latest_timer():fire()
		helpers.assert_eq(calls.build, 0,
			"a public layout rebuild must not race the private rollback generation")
		calls.deliver_start_callbacks(true, "ready-paused")
		calls.publish_phase("active")
		calls.latest_timer():fire()
		helpers.assert_eq(calls.build, 0)

		calls.deliver_resume_callbacks(true, "resumed")
		helpers.assert_eq(#disable_results, 1)
		helpers.assert_true(disable_results[1].ok == false)
		calls.latest_timer():fire()
		helpers.assert_eq(#disable_results, 1,
			"rollback replay must not resettle the failed disable transaction")
		helpers.assert_eq(calls.resolve, 0,
			"the rollback already resolved the settled layout serial before this observation reset")
		helpers.assert_eq(calls.build, 0,
			"the committed rollback generation must suppress a duplicate layout build")
		helpers.assert_eq(calls.deploy, 0,
			"the committed rollback generation must suppress a duplicate config deployment")
		helpers.assert_eq(calls.rebind, 1,
			"the consumed rollback deployment still owes exactly one shortcut rebind")
	end)

	helpers.it("rejects a cancelled timer callback without erasing its replacement", function()
		local _, calls = load_remap()
		calls.activate_initial()
		calls.sequence = {}
		calls.resolve = 0
		calls.build = 0
		calls.deploy = 0
		calls.rebind = 0
		calls.wake(SYSTEM_DID_WAKE)
		local first = calls.latest_timer()
		calls.wake(SCREENS_DID_UNLOCK)
		local second = calls.latest_timer()
		helpers.assert_true(first ~= second)
		helpers.assert_true(first.running == false, "the superseded timer must be cancelled")

		first:fire(true)
		helpers.assert_eq(calls.resolve, 0,
			"an already-queued cancelled callback must not perform stale work")
		helpers.assert_true(second.running,
			"the stale callback must not erase or cancel the retained replacement")
		second:fire()
		helpers.assert_eq(calls.resolve, 1)
		helpers.assert_eq(calls.deploy, 1)
		helpers.assert_eq(calls.rebind, 1)
		helpers.assert_eq(calls.lease_pause, 0)
		helpers.assert_eq(calls.lease_phase, "active")
	end)

	helpers.it("rejects a timer that fires before its handle can be retained", function()
		local _, calls = load_remap({ settle_timer_synchronous = true })
		local callback_ok, callback_err = calls.wake(SYSTEM_DID_WAKE)

		helpers.assert_true(callback_ok, tostring(callback_err))
		helpers.assert_eq(calls.resolve, 0)
		helpers.assert_eq(calls.deploy, 0)
		helpers.assert_true(error_log_contains(calls, "Could not schedule Wake layout refresh"),
			"a re-entrant timer implementation must fail visibly instead of losing ownership")
	end)

	helpers.it("contains constructor and start failures and records them", function()
		for _, case in ipairs({
			{ options = { constructor_raises = true }, diagnostic = "construction failed" },
			{ options = { constructor_nil = true }, diagnostic = "construction failed" },
			{ options = { start_raises = true }, diagnostic = "start failed" },
			{ options = { start_result = false }, diagnostic = "start failed" },
		}) do
			local remap, calls = load_remap(case.options)
			helpers.assert_true(calls.init_ok,
				"watcher setup failure escaped M.init(): " .. tostring(calls.init_err))
			helpers.assert_true(error_log_contains(calls, case.diagnostic),
				"watcher setup failure must be visible in the file logger")
			remap.stop()
		end
	end)

	helpers.it("retains and fences a wake watcher activated before start raises", function()
		local remap, calls = load_remap({
			start_activates_then_raises = true,
			stop_refusals = 1,
		})
		helpers.assert_true(calls.init_ok, tostring(calls.init_err))
		helpers.assert_true(calls.watcher_active,
			"the fixture must retain an active native watcher after rollback refuses")
		helpers.assert_eq(calls.watcher_stop, 1,
			"failed acquisition must immediately attempt exact-candidate rollback")

		helpers.assert_true(calls.wake(SYSTEM_DID_WAKE))
		helpers.assert_eq(calls.refresh, 0,
			"an activated but uncommitted watcher callback must remain inert")

		helpers.assert_true(remap.stop())
		calls.deliver_stopped()
		helpers.assert_eq(calls.watcher_stop, 2,
			"local teardown must retry the exact retained watcher")
		helpers.assert_true(calls.watcher_active == false,
			"the successful retry must settle the original native capability")
	end)
end)
