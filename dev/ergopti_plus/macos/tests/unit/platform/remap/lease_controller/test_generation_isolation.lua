--- tests/unit/platform/remap/lease_controller/test_generation_isolation.lua

--- ==============================================================================
--- MODULE: Lease Controller Generation Isolation Regression
--- DESCRIPTION:
--- Exercises real lease ownership with task and timer callbacks kept in one scope.
--- ==============================================================================

local helpers = require("tests.helpers")
local support = require("tests.support.lease_controller_fixture")
local with_fixture = support.with_fixture
local find_native_revoke = support.find_native_revoke

helpers.describe("karabiner lease controller: generation isolation", function()
	helpers.it("does not release a stop barrier while an older generation still fences", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			local old_variables = controller.variables()
			controller.start()
			ctx.chunk(1, "READY\n")
			local old_stopped, new_stopped = nil, nil
			controller.stop("old generation", function(ok) old_stopped = ok end)
			local old_stop_timer = ctx.timers[#ctx.timers]

			local replacement = controller.variables()
			controller.start()
			ctx.chunk(2, "READY\n")
			controller.stop("replacement generation", function(ok) new_stopped = ok end)

			old_stop_timer.fired = true
			old_stop_timer.fn()
			helpers.assert_eq(ctx.spawns[3].args[1], "--karabiner-lease-revoke",
				"the old timeout must capture only its own generation")
			helpers.assert_eq(ctx.spawns[3].args[3], old_variables.mode)
			ctx.chunk(2, "STOPPED\n")
			helpers.assert_nil(new_stopped,
				"new STOPPED cannot outrun the older generation's still-pending fence")
			helpers.assert_nil(old_stopped)
			helpers.assert_eq(controller.status(), "fencing",
				"aggregate status must deterministically expose the unsafe retiring set")

			ctx.complete(3, 0, "")
			helpers.assert_true(old_stopped == true and new_stopped == true)
			helpers.assert_eq(controller.status(), "idle")
			helpers.assert_eq(replacement.token, "ffeeddccbbaa99887766554433221100")
		end)
	end)

	helpers.it("publishes safe status before a failure callback starts a replacement", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			local old_token = controller.token()
			local callback_status = nil
			local replacement = nil
			local replacement_started = nil
			controller.start(function(ok)
				helpers.assert_true(ok == false)
				callback_status = controller.status()
				replacement = controller.variables()
				replacement_started = controller.start()
			end)

			ctx.complete(1, 9, "")
			helpers.assert_nil(replacement, "failure callback must remain blocked before exact fencing")
			helpers.assert_nil(controller.variables(),
				"even a direct retry must not allocate while failed writers remain ambiguous")
			ctx.complete(2, 0, "")

			helpers.assert_eq(callback_status, "failed",
				"re-entrant callback must observe the post-fence phase, never stale fencing")
			helpers.assert_not_nil(replacement)
			helpers.assert_true(replacement.token ~= old_token)
			helpers.assert_true(replacement_started == true)
			helpers.assert_eq(controller.status(), "starting")
			helpers.assert_eq(ctx.spawns[3].args[1], "--karabiner-lease-worker")
		end)
	end)

	helpers.it("publishes IDLE before stopping an already-safe FAILED controller", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			local phases = {}
			controller.init(function(phase, token)
				phases[#phases + 1] = { phase = phase, token = token }
			end)
			local failed_variables = controller.variables()
			ctx.next_start_result = false
			helpers.assert_true(controller.start() == false)
			helpers.assert_eq(controller.status(), "failed")
			local spawn_count = #ctx.spawns
			local timer_count = #ctx.timers
			local callback_calls = 0
			local callback_ok, callback_reason, callback_phase = nil, nil, nil

			helpers.assert_true(controller.stop("shutdown safe failure", function(ok, reason)
				callback_calls = callback_calls + 1
				callback_ok = ok
				callback_reason = reason
				callback_phase = controller.status()
			end))

			helpers.assert_eq(callback_calls, 1,
				"an empty aggregate barrier must settle synchronously exactly once")
			helpers.assert_true(callback_ok == true)
			helpers.assert_eq(callback_reason, "already-stopped")
			helpers.assert_eq(callback_phase, "idle",
				"successful STOP proof must be public before a teardown callback re-enters")
			helpers.assert_eq(controller.status(), "idle")
			helpers.assert_eq(phases[#phases].phase, "idle")
			helpers.assert_nil(phases[#phases].token)
			helpers.assert_eq(#ctx.spawns, spawn_count)
			helpers.assert_eq(#ctx.timers, timer_count)
			helpers.assert_eq(#ctx.spawns[1].inputs, 0)
			helpers.assert_nil(find_native_revoke(ctx, failed_variables),
				"normalizing a proven-safe failure must not launch another helper")
		end)
	end)

	helpers.it("publishes IDLE before a stop joined to an in-flight failure fence", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			local phases = {}
			controller.init(function(phase, token)
				phases[#phases + 1] = { phase = phase, token = token }
			end)
			local failed_variables = controller.variables()
			controller.start()
			ctx.chunk(1, "READY\n")
			ctx.chunk(1, "UNKNOWN_AFTER_READY\n")
			helpers.assert_eq(controller.status(), "fencing")
			local exact_revoke = find_native_revoke(ctx, failed_variables)
			helpers.assert_eq(exact_revoke, ctx.spawns[2])
			helpers.assert_eq(exact_revoke.args[3], failed_variables.mode)
			helpers.assert_eq(exact_revoke.args[4], failed_variables.revoked)
			local spawn_count = #ctx.spawns
			local callback_calls = 0
			local callback_ok, callback_reason, callback_phase = nil, nil, nil
			local callback_publication = nil

			helpers.assert_true(controller.stop("shutdown during failure fence", function(ok, reason)
				callback_calls = callback_calls + 1
				callback_ok = ok
				callback_reason = reason
				callback_phase = controller.status()
				callback_publication = phases[#phases]
			end))
			helpers.assert_eq(callback_calls, 0,
				"accepted FENCING is not yet proof that teardown is safe")
			helpers.assert_eq(#ctx.spawns, spawn_count,
				"joining an exact fence must not launch or signal a generic Karabiner process")
			helpers.assert_eq(#ctx.spawns[1].inputs, 0,
				"joining FENCING must not send a second transport command")

			ctx.complete(2, 0, "")
			helpers.assert_eq(callback_calls, 1)
			helpers.assert_true(callback_ok == true)
			helpers.assert_eq(callback_reason, "fallback-revoked")
			helpers.assert_eq(callback_phase, "idle",
				"the aggregate fence must publish the explicit Stop intent before its callback")
			helpers.assert_eq(callback_publication.phase, "idle",
				"lease consumers must receive IDLE before the teardown callback re-enters")
			helpers.assert_eq(controller.status(), "idle")
			ctx.complete(2, 0, "")
			helpers.assert_eq(callback_calls, 1,
				"a duplicate native completion must not re-settle the Stop callback")
			helpers.assert_eq(#ctx.spawns, spawn_count,
				"late completions must remain confined to the captured exact revoker")
		end)
	end)

	helpers.it("applies aggregate Stop intent to every simultaneous retiring generation", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			local phases = {}
			controller.init(function(phase, token)
				phases[#phases + 1] = { phase = phase, token = token }
			end)

			local first = controller.variables()
			controller.start()
			ctx.chunk(1, "READY\n")
			controller.stop("retire first generation")
			local second = controller.variables()
			controller.start()
			ctx.chunk(2, "READY\n")
			ctx.chunk(2, "BROKEN_REPLACEMENT\n")
			helpers.assert_eq(controller.status(), "fencing")
			helpers.assert_true(first.token ~= second.token)
			helpers.assert_eq(find_native_revoke(ctx, second), ctx.spawns[3])
			local spawn_count = #ctx.spawns
			local callback_calls = 0
			local callback_phase = nil

			helpers.assert_true(controller.stop("aggregate shutdown", function(ok)
				callback_calls = callback_calls + 1
				helpers.assert_true(ok == true)
				callback_phase = controller.status()
			end))
			helpers.assert_eq(callback_calls, 0)
			helpers.assert_eq(#ctx.spawns, spawn_count)
			helpers.assert_eq(ctx.spawns[1].inputs[#ctx.spawns[1].inputs], "STOP\n")
			helpers.assert_eq(#ctx.spawns[2].inputs, 0,
				"joining the failed replacement must not send an unfenced generic STOP")

			ctx.chunk(1, "STOPPED\n")
			helpers.assert_eq(callback_calls, 0,
				"the first retiree cannot outrun the replacement's exact fallback")
			ctx.complete(3, 0, "")
			helpers.assert_eq(callback_calls, 1)
			helpers.assert_eq(callback_phase, "idle",
				"the final failed retiree must inherit the aggregate Stop intent")
			helpers.assert_eq(phases[#phases].phase, "idle")
			helpers.assert_eq(controller.status(), "idle")
			helpers.assert_eq(#ctx.spawns, spawn_count,
				"aggregate settlement must stay exact-token-only across both retirees")
		end)
	end)

	helpers.it("clears the retired token from an IDLE publication after STOPPED", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			local phases = {}
			controller.init(function(phase, token)
				phases[#phases + 1] = { phase = phase, token = token }
			end)
			local retired = controller.variables()
			controller.start()
			ctx.chunk(1, "READY\n")

			controller.stop("normal token cleanup")
			ctx.chunk(1, "STOPPED\n")

			local phase, snapshot = controller.status()
			helpers.assert_eq(phase, "idle")
			helpers.assert_nil(snapshot.token)
			helpers.assert_eq(phases[#phases].phase, "idle")
			helpers.assert_nil(phases[#phases].token,
				"IDLE must not publish the retired exact-generation identity")
			helpers.assert_true(retired.token ~= nil)
		end)
	end)

	helpers.it("clears the retired token from an IDLE publication after fallback", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			local phases = {}
			controller.init(function(phase, token)
				phases[#phases + 1] = { phase = phase, token = token }
			end)
			local retired = controller.variables()
			controller.start()
			ctx.chunk(1, "READY\n")
			ctx.next_input_result = false

			controller.stop("fallback token cleanup")
			helpers.assert_eq(find_native_revoke(ctx, retired), ctx.spawns[2])
			ctx.complete(2, 0, "")

			local phase, snapshot = controller.status()
			helpers.assert_eq(phase, "idle")
			helpers.assert_nil(snapshot.token)
			helpers.assert_eq(phases[#phases].phase, "idle")
			helpers.assert_nil(phases[#phases].token,
				"fallback IDLE must not leak the revoked generation identity")
		end)
	end)

	helpers.it("accepts a broken STOP channel but settles only after fallback fencing", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.start()
			ctx.chunk(1, "READY\n")
			ctx.next_input_result = false
			local stopped_ok, stopped_reason = nil, nil

			helpers.assert_true(controller.stop("broken channel", function(ok, reason)
				stopped_ok, stopped_reason = ok, reason
			end), "accepted fallback cleanup must not trigger an eager caller rollback")
			helpers.assert_nil(stopped_ok)
			helpers.assert_eq(controller.status(), "fencing")
			ctx.complete(2, 0, "")
			helpers.assert_true(stopped_ok == true)
			helpers.assert_eq(stopped_reason, "fallback-revoked")
			helpers.assert_eq(controller.status(), "idle")
		end)
	end)

	helpers.it("keeps stop accepted when its acknowledgement timer cannot be armed", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.start()
			ctx.chunk(1, "READY\n")
			ctx.next_timer_fired = true
			local callback_calls = 0
			local stopped_ok = nil

			local accepted = controller.stop("timer unavailable", function(ok)
				callback_calls = callback_calls + 1
				stopped_ok = ok
			end)

			helpers.assert_true(accepted,
				"an accepted exact fallback fence must not make disable roll back eagerly")
			helpers.assert_eq(callback_calls, 0)
			helpers.assert_eq(controller.status(), "fencing")
			ctx.complete(2, 0, "")
			helpers.assert_eq(callback_calls, 1)
			helpers.assert_true(stopped_ok == true,
				"fallback proof satisfies the requested system-wide stopped state")
			helpers.assert_eq(controller.status(), "idle")
		end)
	end)

	helpers.it("does not arm a phantom timeout after synchronous STOPPED", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.start()
			ctx.chunk(1, "READY\n")
			local timer_count = #ctx.timers
			ctx.next_input_chunk = "STOPPED\n"
			local callback_calls = 0

			helpers.assert_true(controller.stop("immediate stop", function(ok)
				callback_calls = callback_calls + 1
				helpers.assert_true(ok == true)
			end))
			helpers.assert_eq(callback_calls, 1)
			helpers.assert_eq(controller.status(), "idle")
			helpers.assert_eq(#ctx.timers, timer_count,
				"STOPPED consumed inside set_input must prevent a later stale timeout")
		end)
	end)

	helpers.it("joins two stop callers until the same STOPPED acknowledgement", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.start()
			ctx.chunk(1, "READY\n")
			local first, second = nil, nil

			helpers.assert_true(controller.stop("first", function(ok) first = ok end))
			helpers.assert_true(controller.stop("second", function(ok) second = ok end),
				"a duplicate stop must join the retiring generation")
			helpers.assert_nil(first)
			helpers.assert_nil(second, "duplicate stop must not report already-stopped early")
			helpers.assert_eq(#ctx.spawns[1].inputs, 1, "STOP must be written only once")

			ctx.chunk(1, "STOPPED\n")
			helpers.assert_true(first == true and second == true,
				"both callers must settle from the same revocation proof")
		end)
	end)

	helpers.it("fails every joined stop caller on the same STOPPED timeout", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.start()
			ctx.chunk(1, "READY\n")
			local first, second = nil, nil
			controller.stop("first timeout", function(ok) first = ok end)
			controller.stop("second timeout", function(ok) second = ok end)

			ctx.fire_latest_timer()
			helpers.assert_nil(first, "a protocol timeout is not yet a revocation proof")
			helpers.assert_nil(second, "joined callers must wait for the native fallback fence")
			ctx.complete(2, 0, "")
			helpers.assert_true(first == true and second == true,
				"fallback fencing fulfills the requested safe stop for every caller")
		end)
	end)

	helpers.it("stops safely before READY without treating late READY as corruption", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.start()

			local stopped_ok = nil
			controller.stop("stop during activation", function(ok) stopped_ok = ok end)
			ctx.chunk(1, "READY\nSTOPPED\n")

			helpers.assert_true(stopped_ok == true, "STOPPED must acknowledge a stop queued during activation")
			helpers.assert_true(ctx.spawns[1].closed, "the controller must close stdin after STOPPED")
			helpers.assert_eq(controller.status(), "idle", "late READY must never reactivate a detached generation")
		end)
	end)

	helpers.it("ignores a superseded PAUSED ACK while waiting for STOPPED", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.start()
			ctx.chunk(1, "READY\n")
			controller.pause()

			local stopped_ok = nil
			controller.stop("stop during pause", function(ok) stopped_ok = ok end)
			ctx.chunk(1, "PAUSED\nSTOPPED\n")

			helpers.assert_true(stopped_ok == true,
				"an in-flight pause ACK must not make the later STOPPED acknowledgement fail")
			helpers.assert_eq(controller.status(), "idle", "stop must remain the final user intent")
		end)
	end)

	helpers.it("waits for an exact native fence when STOPPED times out", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			local vars = controller.variables()
			controller.start()
			ctx.chunk(1, "READY\n")

			local stopped_ok = nil
			controller.stop("missing stop ack", function(ok) stopped_ok = ok end)
			ctx.fire_latest_timer()

			helpers.assert_nil(stopped_ok,
				"missing STOPPED cannot settle before the fallback has fenced the exact variables")
			helpers.assert_true(not ctx.spawns[1].terminated,
				"the controller must not signal even its native worker; stdin EOF drives cleanup")
			helpers.assert_not_nil(find_native_revoke(ctx, vars),
				"STOPPED timeout must invoke exact token fallback revocation")
			helpers.assert_eq(controller.status(), "fencing",
				"a detached generation remains visible until fallback revocation succeeds")
			ctx.complete(2, 0, "")
			helpers.assert_true(stopped_ok == true,
				"fallback proof fulfills disable even when the primary STOPPED protocol degraded")
			helpers.assert_eq(controller.status(), "idle", "a detached failed generation cannot own new status")
		end)
	end)

	helpers.it("an old STOPPED/completion cannot mutate or revoke the new token", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			local old_vars = controller.variables()
			controller.start()
			ctx.chunk(1, "READY\n")

			local stopped_ok = nil
			helpers.assert_true(controller.stop("test replacement", function(ok) stopped_ok = ok end),
				"stop must be accepted")
			helpers.assert_eq(controller.status(), "stopping",
				"a detached generation remains retiring until STOPPED proves revocation")
			helpers.assert_eq(ctx.spawns[1].inputs[#ctx.spawns[1].inputs], "STOP\n",
				"stop must request an acknowledged revocation")
			helpers.assert_true(not ctx.spawns[1].closed,
				"the helper must stay alive until STOPPED so completion cannot overtake the ACK")

			local new_vars = controller.variables()
			helpers.assert_true(new_vars.token ~= old_vars.token, "the replacement must use a distinct token")
			controller.start()
			ctx.chunk(2, "READY\n")
			helpers.assert_eq(controller.status(), "active", "new generation must activate independently")

			ctx.chunk(1, "STOPPED\n")
			helpers.assert_true(ctx.spawns[1].closed,
				"STOPPED must close stdin and let the helper observe EOF after its ACK")
			ctx.complete(1, 0, "STOPPED\n")
			helpers.assert_true(stopped_ok == true, "old stop callback may complete after replacement")
			helpers.assert_eq(controller.status(), "active", "old callbacks must not mutate the new phase")

			helpers.assert_nil(find_native_revoke(ctx, old_vars),
				"an acknowledged STOPPED fence must not launch redundant detached cleanup")
			helpers.assert_nil(find_native_revoke(ctx, new_vars),
				"old completion must never revoke the new variables")
		end)
	end)

	helpers.it("does not publish a late failure from a detached generation over its replacement", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			local phases = {}
			controller.init(function(phase, token)
				phases[#phases + 1] = { phase = phase, token = token }
			end)
			local old_token = controller.token()
			controller.start()
			ctx.chunk(1, "READY\n")
			controller.stop("replace stale generation")

			local new_token = controller.token()
			controller.start()
			ctx.chunk(2, "READY\n")
			helpers.assert_true(new_token ~= old_token, "replacement must carry a fresh capability")
			local publications_before_late_failure = #phases

			ctx.chunk(1, "BROKEN_AFTER_DETACH\n")

			helpers.assert_eq(controller.status(), "active",
				"a stale protocol failure must not replace the live generation phase")
			helpers.assert_eq(#phases, publications_before_late_failure,
				"a detached generation must not publish failed and tear down replacement inputs")
			local saw_old_stopping = false
			for _, publication in ipairs(phases) do
				if publication.phase == "stopping" and publication.token == old_token then
					saw_old_stopping = true
				end
			end
			helpers.assert_true(saw_old_stopping,
				"the intentional detached stopping transition must remain observable")
		end)
	end)

	helpers.it("accepts the final STOPPED chunk when completion arrives first", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.start()
			ctx.chunk(1, "READY\n")

			local stopped_ok = nil
			controller.stop("completion ordering", function(ok) stopped_ok = ok end)
			ctx.complete(1, 0, "", true)
			helpers.assert_nil(stopped_ok,
				"completion must defer its verdict because the final stream callback can still follow")
			ctx.fire_zero_timers()
			helpers.assert_nil(stopped_ok,
				"one runloop turn is not a documented bound for hs.task's final stream callback")

			ctx.chunk(1, "STOPPED\n")
			helpers.assert_true(stopped_ok == true,
				"the documented final streaming callback must still satisfy STOPPED")
			helpers.assert_eq(controller.status(), "idle", "old completion ordering must preserve detached state")
		end)
	end)

	helpers.it("cancels a failed fallback retry when a late STOPPED proves safety", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.start()
			ctx.chunk(1, "READY\n")
			controller.stop("late protocol proof")

			ctx.complete(1, 0, "", true)
			helpers.assert_eq(#ctx.spawns, 2,
				"worker completion must start the redundant exact-generation revoker")
			ctx.complete(2, 1, "", true)
			local retry = ctx.timers[#ctx.timers]
			helpers.assert_true(retry and retry.delay == 1 and not retry.cancelled,
				"a failed detached revoker must retain its bounded retry before protocol proof")

			ctx.chunk(1, "STOPPED\n")
			helpers.assert_true(retry.cancelled,
				"late STOPPED must cancel the now-redundant fallback retry timer")
			local spawn_count = #ctx.spawns
			retry.fn()
			helpers.assert_eq(#ctx.spawns, spawn_count,
				"a queued callback from the cancelled retry must be generation-fenced")
		end)
	end)

	helpers.it("fails a completed stop only when the existing STOPPED deadline expires", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.start()
			ctx.chunk(1, "READY\n")

			local stopped_ok = nil
			controller.stop("missing final stream", function(ok) stopped_ok = ok end)
			ctx.complete(1, 0, "", true)
			helpers.assert_nil(stopped_ok, "completion alone cannot prove the final ACK is absent")

			ctx.fire_latest_timer()
			helpers.assert_nil(stopped_ok,
				"the STOPPED deadline alone cannot certify that the fallback fence completed")
			ctx.complete(2, 0, "")
			helpers.assert_true(stopped_ok == true,
				"the callback succeeds only after exact native fallback revocation succeeds")
		end)
	end)
end)
