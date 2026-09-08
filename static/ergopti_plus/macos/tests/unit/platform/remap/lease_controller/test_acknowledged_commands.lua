--- tests/unit/platform/remap/lease_controller/test_acknowledged_commands.lua

--- ==============================================================================
--- MODULE: Lease Controller Acknowledged Commands Regression
--- DESCRIPTION:
--- Exercises real lease ownership with task and timer callbacks kept in one scope.
--- ==============================================================================

local helpers = require("tests.helpers")
local support = require("tests.support.lease_controller_fixture")
local with_fixture = support.with_fixture
local find_native_revoke = support.find_native_revoke

helpers.describe("karabiner lease controller: acknowledged commands", function()
	helpers.it("serializes timer PING behind exact PONG before a queued pause", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.start()
			ctx.chunk(1, "READY\n")
			local heartbeat = ctx.fire_heartbeat_timer()

			helpers.assert_eq(ctx.spawns[1].inputs[1], "PING 1\n",
				"the retained HS timer must be the sole public heartbeat origin")
			ctx.fire_heartbeat_timer()
			helpers.assert_eq(#ctx.spawns[1].inputs, 1,
				"a second timer firing must not overwrite undrained hs.task input")
			local paused_ok = nil
			helpers.assert_true(controller.pause(function(ok) paused_ok = ok end))
			helpers.assert_eq(#ctx.spawns[1].inputs, 1,
				"pause must queue while the PING transport is unacknowledged")

			ctx.chunk(1, "PONG 1\n")
			helpers.assert_eq(ctx.spawns[1].inputs[2], "PAUSE\n",
				"the latest queued mode may write only after its exact PONG")
			ctx.chunk(1, "PAUSED\n")
			helpers.assert_true(paused_ok == true)
			helpers.assert_true(not heartbeat.cancelled,
				"the recurring heartbeat must remain retained in paused mode")
		end)
	end)

	helpers.it("lets the latest settled-state intent cancel an opposite command queued by PING", function()
		with_fixture(function(load_controller)
			for _, case in ipairs({
				{
					start = "active",
					queue = "pause",
					latest = "resume",
					phase = "active",
				},
				{
					start = "paused",
					queue = "resume",
					latest = "pause",
					phase = "paused",
				},
			}) do
				local controller, ctx = load_controller()
				controller.init()
				if case.start == "paused" then
					controller.start_paused()
				else
					controller.start()
				end
				ctx.chunk(1, "READY\n")
				ctx.fire_heartbeat_timer()

				local queued_result, latest_result
				controller[case.queue](function(ok) queued_result = ok end)
				controller[case.latest](function(ok) latest_result = ok end)

				helpers.assert_true(queued_result == false,
					"the older opposite intent must settle as superseded immediately")
				helpers.assert_true(latest_result == true,
					"the latest request for the already-settled state must succeed")
				ctx.chunk(1, "PONG 1\n")
				helpers.assert_eq(#ctx.spawns[1].inputs, 1,
					"PONG must not dispatch the superseded opposite transition")
				helpers.assert_eq(controller.status(), case.phase,
					"the final public phase must match the latest user intent")
			end
		end)
	end)

	helpers.it("heartbeats an initially paused lease and cancels the timer before STOP", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.start_paused()
			ctx.chunk(1, "READY\n")
			local heartbeat = ctx.fire_heartbeat_timer()
			helpers.assert_eq(ctx.spawns[1].inputs[1], "PING 1\n",
				"pause is a live lease mode and must still detect Hammerspoon loss")

			controller.stop("cancel heartbeat")
			helpers.assert_true(heartbeat.cancelled,
				"STOP must cancel recurring liveness before writing terminal input")
			local input_count = #ctx.spawns[1].inputs
			ctx.chunk(1, "PONG 1\n")
			helpers.assert_eq(controller.status(), "stopping",
				"a late PONG batched behind STOP must not restore the live generation")
			heartbeat.fn()
			helpers.assert_eq(#ctx.spawns[1].inputs, input_count,
				"a stale timer callback must never write after STOP")
		end)
	end)

	helpers.it("retains a failed timer cancellation and retries the same inert handle", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.start()
			ctx.chunk(1, "READY\n")
			local heartbeat = ctx.fire_heartbeat_timer()
			local input_count = #ctx.spawns[1].inputs
			ctx.cancel_target = heartbeat
			ctx.cancel_failures = 3

			controller.stop("retry failed timer cancellation")
			helpers.assert_eq(heartbeat.cancel_attempts, 3,
				"sibling lifecycle work must retry retained cancellation debt")
			helpers.assert_true(not heartbeat.cancelled)
			heartbeat.fn()
			helpers.assert_eq(#ctx.spawns[1].inputs, input_count + 1,
				"the failed-stop timer must be logically inert before native cleanup settles")

			ctx.chunk(1, "STOPPED\n")
			helpers.assert_eq(heartbeat.cancel_attempts, 4,
				"final fence settlement must retry the exact retained timer")
			helpers.assert_true(heartbeat.cancelled)
		end)
	end)

	helpers.it("fails closed on missing or stale PONG without accepting another input", function()
		with_fixture(function(load_controller)
			for _, stale_line in ipairs({ false, "PONG 2\n" }) do
				local controller, ctx = load_controller()
				controller.init()
				local variables = controller.variables()
				controller.start()
				ctx.chunk(1, "READY\n")
				ctx.fire_heartbeat_timer()
				if stale_line then
					ctx.chunk(1, stale_line)
				else
					ctx.fire_latest_timer()
				end

				helpers.assert_eq(controller.status(), "fencing",
					"a heartbeat without its exact PONG must revoke the live generation")
				helpers.assert_not_nil(find_native_revoke(ctx, variables),
					"missing or stale PONG must launch only exact-token fallback fencing")
			end
		end)
	end)

	helpers.it("treats PING_FAILED as negative transport and releases queued mode input", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.start()
			ctx.chunk(1, "READY\n")
			ctx.fire_heartbeat_timer()
			local paused_ok = nil
			controller.pause(function(ok) paused_ok = ok end)

			ctx.chunk(1, "PING_FAILED 1\n")
			helpers.assert_eq(ctx.spawns[1].inputs[2], "PAUSE\n",
				"negative heartbeat transport must clear hs.task input serialization")
			helpers.assert_nil(paused_ok)
			ctx.chunk(1, "PAUSED\n")
			helpers.assert_true(paused_ok == true)
			helpers.assert_eq(controller.status(), "paused",
				"a clean queued mode transport must reset heartbeat recovery")
		end)
	end)

	helpers.it("retries one negative heartbeat after a bounded quiet interval", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			local phases = {}
			controller.init(function(phase) phases[#phases + 1] = phase end)
			controller.start()
			ctx.chunk(1, "READY\n")
			local heartbeat = ctx.fire_heartbeat_timer()
			ctx.chunk(1, "PING_FAILED 1\n")

			helpers.assert_eq(controller.status(), "recovering",
				"negative transport must not leave the public phase claiming active")
			local retry = ctx.timers[#ctx.timers]
			helpers.assert_true(not retry.repeating and retry.delay == 1.0,
				"the first failure must retain exactly one bounded retry timer")
			helpers.assert_eq(#ctx.spawns[1].inputs, 1,
				"the failure callback must not spin a replacement CLI immediately")

			heartbeat.fn()
			helpers.assert_true(controller.refresh_liveness(),
				"wake joins the retained retry instead of bypassing its backoff")
			helpers.assert_eq(#ctx.spawns[1].inputs, 1,
				"recurring and wake origins must remain suppressed before the retry")
			retry.fn()
			helpers.assert_eq(ctx.spawns[1].inputs[2], "PING 2\n")
			ctx.chunk(1, "PONG 2\n")

			helpers.assert_eq(controller.status(), "active",
				"one clean retry must restore the exact prior settled phase")
			helpers.assert_eq(phases[#phases - 1], "recovering")
			helpers.assert_eq(phases[#phases], "active")
			helpers.assert_true(not heartbeat.cancelled,
				"recovery must keep the five-second liveness source retained")
		end)
	end)

	helpers.it("fences after the one bounded heartbeat retry also fails", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			local variables = controller.variables()
			controller.start()
			ctx.chunk(1, "READY\n")
			ctx.fire_heartbeat_timer()
			ctx.chunk(1, "PING_FAILED 1\n")
			local retry = ctx.timers[#ctx.timers]
			retry.fn()
			ctx.chunk(1, "PING_FAILED 2\n")

			helpers.assert_eq(controller.status(), "fencing",
				"a second negative transport must not remain in an endless retry state")
			helpers.assert_not_nil(find_native_revoke(ctx, variables),
				"the repeated failure must launch exact-token fallback fencing")
		end)
	end)

	helpers.it("cancels the bounded heartbeat retry before STOP", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.start()
			ctx.chunk(1, "READY\n")
			ctx.fire_heartbeat_timer()
			ctx.chunk(1, "PING_FAILED 1\n")
			local retry = ctx.timers[#ctx.timers]

			controller.stop("retry cancellation")
			helpers.assert_true(retry.cancelled,
				"STOP must make the one-shot recovery callback stale before terminal input")
			local input_count = #ctx.spawns[1].inputs
			retry.fn()
			helpers.assert_eq(#ctx.spawns[1].inputs, input_count,
				"a stale retry callback must never write after STOP")
		end)
	end)

	helpers.it("fails closed when the bounded heartbeat retry cannot be retained", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			local variables = controller.variables()
			controller.start()
			ctx.chunk(1, "READY\n")
			ctx.fire_heartbeat_timer()
			ctx.next_timer_fired = true
			ctx.chunk(1, "PING_FAILED 1\n")

			helpers.assert_eq(controller.status(), "fencing")
			helpers.assert_not_nil(find_native_revoke(ctx, variables),
				"an unretained retry must never leave an ambiguous live generation")
		end)
	end)

	helpers.it("pings immediately on wake without duplicating an in-flight transport", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.start()
			ctx.chunk(1, "READY\n")

			helpers.assert_true(controller.refresh_liveness())
			helpers.assert_true(controller.refresh_liveness(),
				"a duplicate wake may join the exact outstanding ping")
			helpers.assert_eq(#ctx.spawns[1].inputs, 1,
				"wake and unlock callbacks must not overwrite the same undrained PING")
			helpers.assert_eq(ctx.spawns[1].inputs[1], "PING 1\n")
			ctx.chunk(1, "PONG 1\n")
		end)
	end)

	helpers.it("refuses READY when the retained heartbeat timer cannot be armed", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			local variables = controller.variables()
			local started_ok = nil
			controller.start(function(ok) started_ok = ok end)
			ctx.next_timer_fired = true
			ctx.chunk(1, "READY\n")

			helpers.assert_eq(controller.status(), "fencing")
			helpers.assert_nil(started_ok,
				"READY cannot publish a live phase without its retained liveness source")
			helpers.assert_not_nil(find_native_revoke(ctx, variables))
		end)
	end)

	helpers.it("rolls back an uncommitted heartbeat timer before refusing READY", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			local variables = controller.variables()
			local started_ok = nil
			controller.start(function(ok) started_ok = ok end)
			ctx.next_every_committed = false
			ctx.chunk(1, "READY\n")
			local candidate = ctx.timers[#ctx.timers]

			helpers.assert_eq(controller.status(), "fencing",
				"an explicit uncommitted result must never publish an active lease")
			helpers.assert_nil(started_ok,
				"READY remains unsettled until the exact failed generation is fenced")
			helpers.assert_true(candidate.cancelled,
				"the uncommitted candidate must be rolled back through its exact handle")
			helpers.assert_not_nil(find_native_revoke(ctx, variables),
				"missing heartbeat ownership must fail the generation closed")
		end)
	end)

	helpers.it("rolls back an uncommitted ACK timer and rejects worker activation", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			local variables = controller.variables()
			ctx.next_after_committed = false
			local started = controller.start()
			local candidate = ctx.timers[#ctx.timers]

			helpers.assert_eq(started, false,
				"a worker without its committed READY timeout cannot be accepted")
			helpers.assert_eq(controller.status(), "fencing")
			helpers.assert_true(candidate.cancelled,
				"the uncommitted ACK candidate must be rolled back exactly")
			helpers.assert_not_nil(find_native_revoke(ctx, variables))
		end)
	end)

	helpers.it("uses ACK budgets that cover the native write sequences without sharing one magic timeout", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.start()
			helpers.assert_eq(ctx.timers[#ctx.timers].delay, 4.0,
				"READY covers native worker startup plus one atomic mode write")
			ctx.chunk(1, "READY\n")

			controller.pause()
			helpers.assert_eq(ctx.timers[#ctx.timers].delay, 2.0,
				"PAUSED/RESUMED cover one native CLI write")
			ctx.chunk(1, "PAUSED\n")

			controller.stop("budget proof")
			helpers.assert_eq(ctx.timers[#ctx.timers].delay, 7.0,
				"STOPPED covers the repeated fence cleanup sequence")
			ctx.chunk(1, "STOPPED\n")
		end)
	end)

	helpers.it("queues pause until READY instead of replacing the activation ACK", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.start()

			local paused_ok = nil
			helpers.assert_true(controller.pause(function(ok) paused_ok = ok end),
				"pause during activation must be accepted and queued")
			helpers.assert_eq(controller.status(), "starting", "READY must remain the awaited activation ACK")
			helpers.assert_eq(#ctx.spawns[1].inputs, 0,
				"no state command may overwrite task input before READY")

			ctx.chunk(1, "READY\n")
			helpers.assert_eq(ctx.spawns[1].inputs[1], "PAUSE\n", "queued pause must send after READY")
			helpers.assert_eq(controller.status(), "pausing", "PAUSED must now be awaited")
			ctx.chunk(1, "PAUSED\n")
			helpers.assert_true(paused_ok == true, "queued pause must complete only after PAUSED")
			helpers.assert_eq(controller.status(), "paused", "the lease must finish paused")
		end)
	end)

	helpers.it("lets re-entrant READY callbacks supersede an older queued mode", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()

			local started = nil
			local latest_resume = nil
			local stale_pause = nil
			controller.start(function(ok)
				started = ok
				controller.resume(function(resumed_ok) latest_resume = resumed_ok end)
			end)
			controller.pause(function(paused_ok) stale_pause = paused_ok end)

			ctx.chunk(1, "READY\n")

			helpers.assert_true(started == true and latest_resume == true,
				"READY and the re-entrant latest active intent must both settle true")
			helpers.assert_true(stale_pause == false,
				"a pause queued before READY must not overtake a newer start-callback resume")
			helpers.assert_eq(#ctx.spawns[1].inputs, 0,
				"the superseded PAUSE must never be written after READY")
			helpers.assert_eq(controller.status(), "active")
		end)
	end)

	helpers.it("serializes pause then resume and waits for each ACK", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.start()
			ctx.chunk(1, "READY\n")

			local paused_ok = nil
			local resumed_ok = nil
			helpers.assert_true(controller.pause(function(ok) paused_ok = ok end), "pause must be accepted")
			helpers.assert_eq(controller.status(), "pausing", "pause must stay pending before PAUSED")
			helpers.assert_eq(ctx.spawns[1].inputs[1], "PAUSE\n", "pause command must be one framed line")
			helpers.assert_true(controller.resume(function(ok) resumed_ok = ok end),
				"resume requested during pause must queue rather than overwrite stdin")
			helpers.assert_eq(#ctx.spawns[1].inputs, 1,
				"setInput must not be called twice before the first ACK because it discards unwritten input")

			ctx.chunk(1, "PAU")
			helpers.assert_eq(controller.status(), "pausing",
				"a partial protocol line must not be treated as an acknowledgement")
			ctx.chunk(1, "SED\nRESUMED\n")
			helpers.assert_true(paused_ok == true, "pause callback must wait for PAUSED")
			helpers.assert_eq(ctx.spawns[1].inputs[2], "RESUME\n", "queued resume must send after PAUSED")
			helpers.assert_true(resumed_ok == true, "resume callback must succeed after RESUMED")
			helpers.assert_eq(controller.status(), "active",
				"multiple complete lines in one chunk must be processed in order")
		end)
	end)

	helpers.it("ignores a cancelled same-ACK timeout queued behind a newer transition", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.start()
			ctx.chunk(1, "READY\n")

			controller.pause()
			local stale_pause_timer = ctx.timers[#ctx.timers]
			ctx.chunk(1, "PAUSED\n")
			helpers.assert_true(stale_pause_timer.cancelled)
			controller.resume()
			ctx.chunk(1, "RESUMED\n")
			controller.pause()
			helpers.assert_eq(controller.status(), "pausing")

			-- Hammerspoon may already have queued the old callback when :stop() runs.
			-- The repeated PAUSED text cannot identify which transition owns it.
			stale_pause_timer.fn()
			helpers.assert_eq(controller.status(), "pausing",
				"a cancelled earlier PAUSED timer must not fence the newer PAUSE")
			helpers.assert_eq(#ctx.spawns, 1,
				"the stale callback must not launch an exact-generation revoker")

			ctx.chunk(1, "PAUSED\n")
			helpers.assert_eq(controller.status(), "paused",
				"the current transition must still accept its own PAUSED acknowledgement")
		end)
	end)

	helpers.it("coalesces pause-resume-pause to the last requested state", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.start()
			ctx.chunk(1, "READY\n")

			local first_pause = nil
			local superseded_resume = nil
			local last_pause = nil
			controller.pause(function(ok) first_pause = ok end)
			controller.resume(function(ok) superseded_resume = ok end)
			controller.pause(function(ok) last_pause = ok end)

			helpers.assert_true(superseded_resume == false,
				"the queued intermediate resume must be explicitly rejected as superseded")
			ctx.chunk(1, "PAUSED\n")
			helpers.assert_true(first_pause == true and last_pause == true,
				"both callers requesting the final paused state must observe PAUSED")
			helpers.assert_eq(#ctx.spawns[1].inputs, 1,
				"superseded resume must never be written after PAUSED")
			helpers.assert_eq(controller.status(), "paused", "last user intent must win")
		end)
	end)

	helpers.it("does not let a detached queued command overtake re-entrant latest intent", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.start()
			ctx.chunk(1, "READY\n")

			local first_pause = nil
			local latest_pause = nil
			local stale_resume = nil
			controller.pause(function(ok)
				first_pause = ok
				-- Public callbacks are allowed to re-enter the controller. At this point
				-- PAUSED is proven, but the older queued RESUME has not been dispatched
				-- yet. This newer pause intent must cancel that stale queued command.
				controller.pause(function(latest_ok) latest_pause = latest_ok end)
			end)
			controller.resume(function(ok) stale_resume = ok end)

			ctx.chunk(1, "PAUSED\n")

			helpers.assert_true(first_pause == true and latest_pause == true,
				"both the acknowledged pause and the re-entrant latest pause must settle true")
			helpers.assert_true(stale_resume == false,
				"the older queued resume must settle false once a callback publishes newer pause intent")
			helpers.assert_eq(#ctx.spawns[1].inputs, 1,
				"the stale queued RESUME must never reach the native input stream")
			helpers.assert_eq(controller.status(), "paused",
				"callback re-entrance must preserve the latest requested state")
		end)
	end)

	helpers.it("retains an intent re-entered from a superseded queued callback", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.start()
			ctx.chunk(1, "READY\n")
			local stale_resume, latest_resume = nil, nil
			controller.pause()
			controller.resume(function(ok)
				stale_resume = ok
				controller.resume(function(latest_ok) latest_resume = latest_ok end)
			end)

			controller.pause()
			helpers.assert_true(stale_resume == false,
				"the older queued RESUME must settle before the latest callback re-enters")
			ctx.chunk(1, "PAUSED\n")
			helpers.assert_eq(ctx.spawns[1].inputs[2], "RESUME\n",
				"the re-entered RESUME must survive detachment of the superseded queue")
			ctx.chunk(1, "RESUMED\n")
			helpers.assert_true(latest_resume == true,
				"the callback attached by re-entrance must settle exactly from RESUMED")
			helpers.assert_eq(controller.status(), "active")
		end)
	end)

	helpers.it("retains STARTING intent re-entered from a superseded callback", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.start()
			local stale_pause, latest_pause = nil, nil
			controller.pause(function(ok)
				stale_pause = ok
				controller.pause(function(latest_ok) latest_pause = latest_ok end)
			end)

			controller.resume()
			helpers.assert_true(stale_pause == false,
				"the pre-READY PAUSE must be rejected before its callback re-enters")
			ctx.chunk(1, "READY\n")
			helpers.assert_eq(ctx.spawns[1].inputs[1], "PAUSE\n",
				"the re-entered PAUSE must replace the outer RESUME before READY reconciliation")
			ctx.chunk(1, "PAUSED\n")
			helpers.assert_true(latest_pause == true,
				"the re-entered pre-READY callback must not be orphaned")
			helpers.assert_eq(controller.status(), "paused")
		end)
	end)

	helpers.it("revokes the lease when a command ACK times out", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			local vars = controller.variables()
			controller.start()
			ctx.chunk(1, "READY\n")

			local paused_ok = nil
			controller.pause(function(ok) paused_ok = ok end)
			ctx.fire_latest_timer()

			helpers.assert_eq(controller.status(), "fencing", "an ambiguous pause outcome must fence first")
			helpers.assert_nil(paused_ok, "pause callback must not permit retry before fencing")
			helpers.assert_not_nil(find_native_revoke(ctx, vars), "timeout must launch exact fallback revocation")
			helpers.assert_true(not ctx.spawns[1].terminated,
				"controller must close native stdin and let the worker fence; it must not signal any process")
			ctx.complete(2, 0, "")
			helpers.assert_true(paused_ok == false, "pause callback must expose the missing ACK after fencing")
			helpers.assert_eq(controller.status(), "failed")
		end)
	end)

	helpers.it("fails closed on an unknown protocol line", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			local vars = controller.variables()
			controller.start()
			ctx.chunk(1, "READY\n")

			ctx.chunk(1, "NOT_A_PROTOCOL_ACK\n")
			helpers.assert_eq(controller.status(), "fencing", "unknown helper output must enter exact fencing")
			helpers.assert_not_nil(find_native_revoke(ctx, vars),
				"malformed protocol output must revoke only the current token")
			ctx.complete(2, 0, "")
			helpers.assert_eq(controller.status(), "failed")
		end)
	end)

	helpers.it("bounds a helper protocol line that never terminates", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			local variables = controller.variables()
			controller.start()
			ctx.chunk(1, "READY\n")

			ctx.chunk(1, string.rep("X", 40))
			helpers.assert_eq(controller.status(), "active",
				"one partial chunk below the protocol ceiling may await its newline")
			ctx.chunk(1, string.rep("Y", 25))

			helpers.assert_eq(controller.status(), "fencing",
				"a newline-free protocol stream must be bounded and fail closed")
			local revoke = find_native_revoke(ctx, variables)
			helpers.assert_not_nil(revoke, "overflow must launch exact token revocation")
		end)
	end)

	helpers.it("accepts a command acknowledgement delivered before set_input returns", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.start()
			ctx.chunk(1, "READY\n")
			local timer_count = #ctx.timers
			local callback_calls = 0
			local callback_ok = nil
			ctx.next_input_chunk = "PAUSED\n"

			local accepted = controller.pause(function(ok)
				callback_calls = callback_calls + 1
				callback_ok = ok
			end)

			helpers.assert_true(accepted,
				"a synchronously observable ACK must still be ordered after the pending command")
			helpers.assert_eq(callback_calls, 1, "the immediate ACK must settle exactly once")
			helpers.assert_true(callback_ok == true)
			helpers.assert_eq(controller.status(), "paused")
			helpers.assert_eq(#ctx.timers, timer_count,
				"an ACK already consumed during set_input must not leave a phantom timeout")
		end)
	end)

	helpers.it("keeps a pause request accepted while timer failure fences asynchronously", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.start()
			ctx.chunk(1, "READY\n")
			ctx.next_timer_fired = true
			local callback_calls = 0
			local callback_ok = nil

			local accepted = controller.pause(function(ok)
				callback_calls = callback_calls + 1
				callback_ok = ok
			end)

			helpers.assert_true(accepted,
				"timer setup failure must not trigger an eager request-rejected callback upstream")
			helpers.assert_eq(callback_calls, 0, "the callback must wait for the exact fallback fence")
			helpers.assert_eq(controller.status(), "fencing")
			ctx.complete(2, 0, "")
			helpers.assert_eq(callback_calls, 1, "the failed pause must settle exactly once after fencing")
			helpers.assert_true(callback_ok == false)
		end)
	end)
end)
