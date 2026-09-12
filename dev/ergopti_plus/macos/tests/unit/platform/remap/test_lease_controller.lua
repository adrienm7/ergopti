--- tests/unit/platform/remap/test_lease_controller.lua

--- ==============================================================================
--- MODULE: Lease Controller Activation Identity Regression
--- DESCRIPTION:
--- Exercises real lease ownership with task and timer callbacks kept in one scope.
--- ==============================================================================

local helpers = require("tests.helpers")
local support = require("tests.support.lease_controller_fixture")
local with_fixture = support.with_fixture
local find_native_revoke = support.find_native_revoke
local UUIDS = support.UUIDS

helpers.describe("karabiner lease controller: activation identity", function()
	helpers.it("reports initialization without logging or allocating a lease", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			helpers.assert_true(controller.is_initialized() == false)
			helpers.assert_eq(ctx.helper_resolve_calls, 0,
				"the state probe must not resolve or launch the native helper")

			controller.init()
			helpers.assert_true(controller.is_initialized() == true)
			helpers.assert_eq(#ctx.spawns, 0,
				"initialization status must remain side-effect-free")
		end)
	end)

	helpers.it("parses only one canonical side-effect-free guardian status line", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			local observed = {}
			local last_cached_status = nil

			for _, fixture in ipairs({
				{ stdout = "ready\n", expected = "ready" },
				{ stdout = "requires_approval\n", expected = "requires_approval" },
				{ stdout = "unavailable\n", expected = "unavailable" },
				{ stdout = "ready\nready\n", expected = nil },
				{ stdout = "unknown\n", expected = nil },
				{ stdout = string.rep("x", 33), expected = nil },
				{ stdout = "ready\n", exit_code = 9, expected = nil },
			}) do
				local handle, reason = controller.probe_guardian_status(function(status)
					observed[#observed + 1] = status or false
				end)
				helpers.assert_true(type(handle) == "table")
				helpers.assert_eq(reason, nil)
				local spawn = ctx.spawns[#ctx.spawns]
				helpers.assert_true(helpers.deep_equal(spawn.args, { "--remap-guardian-status" }))
				ctx.complete(#ctx.spawns, fixture.exit_code or 0, fixture.stdout)
				helpers.assert_eq(observed[#observed], fixture.expected or false)
				if fixture.expected then last_cached_status = fixture.expected end
				local _, snapshot = controller.status()
				helpers.assert_eq(snapshot.guardian_status, last_cached_status,
					"only a canonical successful native probe may replace the cached status")
			end
		end)
	end)

	helpers.it("rejects a guardian probe whose exact helper cannot start", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			ctx.next_start_result = false
			local callback_count = 0
			local handle, reason = controller.probe_guardian_status(function()
				callback_count = callback_count + 1
			end)

			helpers.assert_eq(handle, nil)
			helpers.assert_eq(reason, "helper-start-failed")
			helpers.assert_eq(callback_count, 0)
		end)
	end)

	helpers.it("invalidates a cancelled guardian observation before retrying exact termination", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller({ terminate_results = { false, true } })
			controller.init()
			controller.probe_guardian_status(function() end)
			ctx.complete(1, 0, "requires_approval\n")

			local callback_count = 0
			local handle = controller.probe_guardian_status(function()
				callback_count = callback_count + 1
			end)
			helpers.assert_type(handle, "table")
			helpers.assert_true(handle.terminate() == false,
				"logical cancellation must survive a failed native terminate")
			helpers.assert_eq(ctx.spawns[2].terminate_calls, 1)

			ctx.complete(2, 0, "ready\n")
			local _, snapshot = controller.status()
			helpers.assert_eq(callback_count, 0,
				"a cancelled native completion must not reach its consumer")
			helpers.assert_eq(snapshot.guardian_status, "requires_approval",
				"a cancelled native completion must not replace cached authorization")

			helpers.assert_true(handle.terminate(),
				"the wrapper must retry termination through the same raw handle")
			helpers.assert_eq(ctx.spawns[2].terminate_calls, 2)
			helpers.assert_true(ctx.spawns[2].terminated)
		end)
	end)

	helpers.it("keeps a newer guardian ready probe over an older settings result", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.probe_guardian_status(function() end)
			ctx.complete(1, 0, "requires_approval\n")

			helpers.assert_true(controller.open_guardian_settings(function() end))
			local observed = nil
			controller.probe_guardian_status(function(status) observed = status end)
			ctx.complete(3, 0, "ready\n")
			helpers.assert_eq(observed, "ready")

			ctx.complete(2, 0, "not_required\n")
			local _, snapshot = controller.status()
			helpers.assert_eq(snapshot.guardian_status, "ready",
				"an older settings completion must not clear a newer status observation")
		end)
	end)

	helpers.it("keeps a newer guardian settings recheck over an older status completion", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.probe_guardian_status(function() end)
			ctx.complete(1, 0, "requires_approval\n")

			local stale_callback_count = 0
			controller.probe_guardian_status(function()
				stale_callback_count = stale_callback_count + 1
			end)
			helpers.assert_true(controller.open_guardian_settings(function() end))
			ctx.complete(3, 0, "not_required\n")
			ctx.complete(2, 0, "requires_approval\n")

			local _, snapshot = controller.status()
			helpers.assert_eq(stale_callback_count, 0,
				"a superseded status observation must not reach its consumer")
			helpers.assert_nil(snapshot.guardian_status,
				"an older status completion must not overwrite the newer settings recheck")
		end)
	end)

	helpers.it("returns routine guardian probe failures without per-poll controller logs", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			local baseline_warns = #ctx.logs.warn
			local baseline_errors = #ctx.logs.error
			local callback_count = 0

			ctx.helper_path = nil
			ctx.helper_error = "runtime helper identity unavailable"
			for _ = 1, 3 do
				local handle, reason = controller.probe_guardian_status(function()
					callback_count = callback_count + 1
				end)
				helpers.assert_nil(handle)
				helpers.assert_eq(reason, "runtime helper identity unavailable")
			end
			ctx.helper_path = "/test/ErgoptiPlus"
			ctx.helper_error = nil
			for _ = 1, 3 do
				ctx.next_start_result = false
				local handle, reason = controller.probe_guardian_status(function()
					callback_count = callback_count + 1
				end)
				helpers.assert_nil(handle)
				helpers.assert_eq(reason, "helper-start-failed")
			end
			for _ = 1, 3 do
				local handle = controller.probe_guardian_status(function(status, reason)
					callback_count = callback_count + 1
					helpers.assert_nil(status)
					helpers.assert_type(reason, "string")
				end)
				helpers.assert_type(handle, "table")
				ctx.complete(#ctx.spawns, 9, "malformed\n")
			end

			helpers.assert_eq(callback_count, 3,
				"only started probes may deliver routine failure callbacks")
			helpers.assert_eq(#ctx.logs.warn, baseline_warns)
			helpers.assert_eq(#ctx.logs.error, baseline_errors,
				"the polling owner, not the controller, must rate-limit external failures")
		end)
	end)

	helpers.it("accepts only one canonical guardian settings result from exact argv", function()
		with_fixture(function(load_controller)
			for _, fixture in ipairs({
				{ stdout = "opened\n", expected_ok = true, expected_reason = "opened" },
				{ stdout = "not_required\n", expected_ok = true, expected_reason = "not_required" },
				{ stdout = "opened\nopened\n", expected_ok = false },
				{ stdout = "unknown\n", expected_ok = false },
				{ stdout = string.rep("x", 33), expected_ok = false },
				{ stdout = "opened\n", exit_code = 9, expected_ok = false },
			}) do
				local controller, ctx = load_controller()
				controller.init()
				local probe_handle = controller.probe_guardian_status(function() end)
				helpers.assert_type(probe_handle, "table")
				ctx.complete(1, 0, "requires_approval\n")

				local callback_count = 0
				local callback_ok, callback_reason = nil, nil
				local accepted = controller.open_guardian_settings(function(ok, reason)
					callback_count = callback_count + 1
					callback_ok, callback_reason = ok, reason
				end)
				helpers.assert_true(accepted,
					"a cached approval requirement must permit the explicit settings request")
				local settings_task = ctx.spawns[2]
				helpers.assert_not_nil(settings_task)
				helpers.assert_true(helpers.deep_equal(settings_task.args,
					{ "--open-remap-guardian-settings" }),
					"the explicit action must pass exactly one native launcher flag")

				ctx.complete(2, fixture.exit_code or 0, fixture.stdout)
				helpers.assert_eq(callback_count, 1,
					"every accepted settings process must settle its callback exactly once")
				helpers.assert_eq(callback_ok, fixture.expected_ok)
				if fixture.expected_ok then
					helpers.assert_eq(callback_reason, fixture.expected_reason)
				else
					helpers.assert_type(callback_reason, "string")
				end
				local _, snapshot = controller.status()
				if fixture.expected_reason == "not_required" then
					helpers.assert_nil(snapshot.guardian_status,
						"a native not-required result must retire the stale approval hint")
				else
					helpers.assert_eq(snapshot.guardian_status, "requires_approval",
						"opening or rejecting Settings must not manufacture guardian readiness")
				end
			end
		end)
	end)

	helpers.it("rejects a guardian settings request whose exact helper cannot start", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.probe_guardian_status(function() end)
			ctx.complete(1, 0, "requires_approval\n")
			ctx.next_start_result = false
			local callback_count = 0
			local callback_ok, callback_reason = nil, nil

			local accepted = controller.open_guardian_settings(function(ok, reason)
				callback_count = callback_count + 1
				callback_ok, callback_reason = ok, reason
			end)

			helpers.assert_true(accepted == false)
			helpers.assert_eq(callback_count, 1)
			helpers.assert_true(callback_ok == false)
			helpers.assert_eq(callback_reason, "helper-start-failed")
			helpers.assert_true(helpers.deep_equal(ctx.spawns[2].args,
				{ "--open-remap-guardian-settings" }))
		end)
	end)

	helpers.it("joins repeated guardian settings clicks into one native request", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.probe_guardian_status(function() end)
			ctx.complete(1, 0, "requires_approval\n")
			local results = {}

			helpers.assert_true(controller.open_guardian_settings(function(ok, reason)
				results[#results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_true(controller.open_guardian_settings(function(ok, reason)
				results[#results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_eq(#ctx.spawns, 2,
				"repeated menu clicks must join the retained request instead of opening twice")

			ctx.complete(2, 0, "opened\n")
			helpers.assert_eq(#results, 2)
			for _, result in ipairs(results) do
				helpers.assert_true(result.ok == true)
				helpers.assert_eq(result.reason, "opened")
			end
		end)
	end)

	helpers.it("revalidates helper identity before each generation spawn", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.start()
			ctx.chunk(1, "READY\n")
			controller.stop("replace helper identity")
			ctx.chunk(1, "STOPPED\n")
			ctx.helper_path = nil
			ctx.helper_error = "helper inode changed"
			local callback_ok = nil

			helpers.assert_true(not controller.start(function(ok) callback_ok = ok end))
			helpers.assert_true(callback_ok == false)
			helpers.assert_eq(#ctx.spawns, 1,
				"a helper replaced between generations must never cross ShellRunner.spawn again")
			helpers.assert_eq(ctx.helper_resolve_calls, 3,
				"each generation must re-resolve identity instead of trusting a cached path")
		end)
	end)

	helpers.it("revalidates helper identity before a fallback attempt", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.start()
			ctx.chunk(1, "READY\n")
			ctx.helper_path = nil
			ctx.helper_error = "helper inode changed"

			ctx.complete(1, 9, "")

			helpers.assert_eq(#ctx.spawns, 1,
				"a changed helper must not become a detached revoker from the cached path")
			helpers.assert_eq(ctx.helper_resolve_calls, 3,
				"worker and fallback boundaries must each observe current helper identity")
			local retry = ctx.timers[#ctx.timers]
			helpers.assert_true(retry and retry.delay == 1 and not retry.cancelled,
				"failed identity revalidation must keep exact fencing pending for retry")
		end)
	end)

	helpers.it("revalidates helper identity between fallback retries", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.start()
			ctx.chunk(1, "READY\n")
			ctx.complete(1, 9, "")
			helpers.assert_eq(#ctx.spawns, 2,
				"the first fallback attempt must use the still-valid helper identity")

			ctx.helper_path = nil
			ctx.helper_error = "helper inode changed between retries"
			ctx.complete(2, 1, "")
			ctx.fire_latest_timer()

			helpers.assert_eq(#ctx.spawns, 2,
				"a replacement helper must not execute on a later fallback retry")
			helpers.assert_eq(ctx.helper_resolve_calls, 4,
				"each fallback retry must independently re-resolve the helper identity")
			local retry = ctx.timers[#ctx.timers]
			helpers.assert_true(retry and retry.delay == 1 and not retry.cancelled,
				"identity rejection must preserve the unresolved exact fence obligation")
		end)
	end)

	helpers.it("exhausts a permanently missing fallback helper and settles joined stops loudly", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			local start_results = {}
			local stop_results = {}
			controller.start(function(ok, reason)
				start_results[#start_results + 1] = { ok = ok, reason = reason }
			end)
			ctx.helper_path = nil
			ctx.helper_error = "helper identity permanently unavailable"

			ctx.complete(1, 9, "")
			helpers.assert_true(controller.stop("join exhausted fence", function(ok, reason)
				stop_results[#stop_results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_eq(#stop_results, 0,
				"joined Stop must wait while bounded fallback attempts remain")
			ctx.fire_latest_timer()
			ctx.fire_latest_timer()

			helpers.assert_eq(#ctx.spawns, 1,
				"an unresolvable helper identity must never cross ShellRunner.spawn")
			helpers.assert_eq(ctx.helper_resolve_calls, 5,
				"init, worker, and exactly three fallback identity checks are expected")
			helpers.assert_eq(#start_results, 1,
				"the failed start must settle once when bounded fencing gives up")
			helpers.assert_true(start_results[1].ok == false)
			helpers.assert_eq(#stop_results, 1)
			helpers.assert_true(stop_results[1].ok == false)
			helpers.assert_eq(stop_results[1].reason, "fallback-retry-exhausted")
			local phase, snapshot = controller.status()
			helpers.assert_eq(phase, "fencing",
				"exhaustion must never fabricate proof that the exact variables were revoked")
			helpers.assert_true(snapshot.fallback_exhausted == true)
			helpers.assert_eq(snapshot.fallback_attempts, 3)
			helpers.assert_eq(snapshot.fallback_exhausted_reason, "fallback-retry-exhausted")
			local live_fallback_timers = 0
			for _, timer in ipairs(ctx.timers) do
				if timer.delay == 1 and not timer.cancelled and not timer.fired then
					live_fallback_timers = live_fallback_timers + 1
				end
			end
			helpers.assert_eq(live_fallback_timers, 0,
				"exhaustion must not leave a fourth fallback attempt armed")
			local terminal_error = nil
			for _, event in ipairs(ctx.logs.error) do
				if type(event[2]) == "string"
					and event[2]:find("variables remain fenced", 1, true) then
					terminal_error = event
				end
			end
			helpers.assert_not_nil(terminal_error,
				"permanent fallback failure must be visible at ERROR severity")
			helpers.assert_eq(terminal_error[4], 3,
				"the terminal diagnostic must report the exact bounded attempt count")
			helpers.assert_nil(controller.token(),
				"unproven variables must still block replacement generation allocation")

			local joined_again = {}
			helpers.assert_true(controller.stop("join exhausted fence again", function(ok, reason)
				joined_again[#joined_again + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_eq(#joined_again, 1,
				"later Stop callers must receive the retained degraded terminal immediately")
			helpers.assert_true(joined_again[1].ok == false)
			helpers.assert_eq(joined_again[1].reason, "fallback-retry-exhausted")
		end)
	end)

	helpers.it("publishes guarded lifecycle phases to dependent resource owners", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			local phases = {}
			controller.init(function(phase) phases[#phases + 1] = phase end)
			controller.token()
			controller.start()
			ctx.chunk(1, "READY\n")
			ctx.complete(1, 9, "")
			helpers.assert_eq(controller.status(), "fencing")
			ctx.complete(2, 0, "")

			helpers.assert_true(helpers.deep_equal(phases, {
				"idle", "prepared", "starting", "active", "fencing", "failed",
			}), "dependents must be able to release resources after an unexpected watchdog death")
		end)
	end)

	helpers.it("stays starting until READY and uses one exact 32-hex token", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			helpers.assert_true(controller.init(), "init must succeed without external side effects")

			local token = controller.token()
			helpers.assert_eq(token, "00112233445566778899aabbccddeeff",
				"the RFC 4122 UUID must be normalized to exactly 32 lowercase hex digits")
			local vars = controller.variables()
			local contract = require("platform.remap.lease_contract")
			helpers.assert_true(helpers.deep_equal(vars, contract.variables(token)),
				"controller names must exactly equal the generator's pure mode contract")
			helpers.assert_eq(vars.mode, "ergopti_mode_" .. token, "mode name must be token-scoped")

			local ready_ok = nil
			helpers.assert_true(controller.start(function(ok) ready_ok = ok end),
				"start must report that the watchdog task launched")
			helpers.assert_eq(controller.status(), "starting", "launch alone must never imply activation")
			helpers.assert_nil(ready_ok, "the readiness callback must wait for READY")

			local watchdog = ctx.spawns[1]
			helpers.assert_eq(watchdog.executable, "/test/ErgoptiPlus",
				"watchdog must use the packaged native launcher executable")
			helpers.assert_eq(watchdog.args[1], "--karabiner-lease-worker",
				"the native worker mode must be an explicit argv entry")
			helpers.assert_eq(watchdog.args[2], "/test/karabiner_cli", "CLI path must be an argv entry")
			helpers.assert_eq(watchdog.args[3], vars.mode, "watchdog must receive only this atomic mode name")
			helpers.assert_eq(watchdog.args[4], vars.revoked,
				"watchdog must receive the exact same-generation revocation fence")
			helpers.assert_eq(watchdog.args[5], "1",
				"normal cold start must explicitly request the non-paused activation mode")
			helpers.assert_eq(watchdog.args[6], "5",
				"production heartbeat must use the bounded five-second recovery interval")

			ctx.chunk(1, "READY\n")
			helpers.assert_eq(controller.status(), "active",
				"READY follows the clean HS-originated ACTIVATE transport")
			helpers.assert_true(ready_ok == true, "start callback must succeed after READY")
			local heartbeat = ctx.timers[#ctx.timers]
			helpers.assert_true(heartbeat.repeating and heartbeat.delay == 5,
				"the recurring timer must be retained before the live phase is published")
			helpers.assert_eq(#watchdog.inputs, 0,
				"ACTIVATE is the bootstrap pulse; startup must not add a redundant CLI PING")
		end)
	end)

	helpers.it("starts a recovery generation atomically paused before READY", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			local ready_ok, ready_reason = nil, nil

			helpers.assert_true(controller.start_paused(function(ok, reason)
				ready_ok, ready_reason = ok, reason
			end), "the dedicated rollback path must accept a fresh paused generation")
			helpers.assert_eq(ctx.spawns[1].args[5], "2",
				"paused recovery must select atomic mode=2 before READY")
			helpers.assert_eq(controller.status(), "starting")
			helpers.assert_nil(ready_ok)

			ctx.chunk(1, "READY\n")
			helpers.assert_eq(controller.status(), "paused",
				"READY for an initially paused watchdog must never publish active")
			helpers.assert_true(ready_ok == true)
			helpers.assert_eq(ready_reason, "ready-paused")
			helpers.assert_eq(#ctx.spawns[1].inputs, 0,
				"atomic paused activation must not rely on a racy post-READY PAUSE write")
		end)
	end)

	helpers.it("does not let prepared activation overtake a PAUSE queued before READY", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			local token = controller.token()
			local prepared_ok, prepared_reason, prepared_accepted = nil, nil, nil
			local pause_ok, pause_reason = nil, nil

			helpers.assert_true(controller.start_paused(function(ok)
				helpers.assert_true(ok, "paused READY must reach the preparation callback")
				prepared_accepted = controller.resume_prepared(token, function(resumed, reason)
					prepared_ok, prepared_reason = resumed, reason
				end)
			end))
			helpers.assert_true(controller.pause(function(ok, reason)
				pause_ok, pause_reason = ok, reason
			end), "PAUSE while STARTING must be serialized, not dropped")

			ctx.chunk(1, "READY\n")
			helpers.assert_true(prepared_accepted == false,
				"internal activation must be refused while the older PAUSE owns intent")
			helpers.assert_true(prepared_ok == false)
			helpers.assert_eq(prepared_reason, "pause-intent-pending")
			helpers.assert_true(pause_ok == true)
			helpers.assert_eq(pause_reason, "already-paused")
			helpers.assert_eq(controller.status(), "paused")
			helpers.assert_eq(#ctx.spawns[1].inputs, 0,
				"the worker must receive no RESUME after an older PAUSE request")
		end)
	end)

	helpers.it("never becomes active when the helper exits before READY", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			local vars = controller.variables()
			local ready_ok = nil
			controller.start(function(ok) ready_ok = ok end)

			ctx.complete(1, 70, "")
			helpers.assert_eq(controller.status(), "fencing",
				"a pre-READY exit remains ambiguous until native revocation finishes")
			helpers.assert_nil(ready_ok, "start callback must not permit retry before the fence")
			helpers.assert_not_nil(find_native_revoke(ctx, vars),
				"completion fallback must revoke exactly the failed generation variables")
			ctx.complete(2, 0, "")
			helpers.assert_eq(controller.status(), "failed", "safe failure publishes only after the fence")
			helpers.assert_true(ready_ok == false, "start callback must expose activation failure after fencing")
		end)
	end)

	helpers.it("does not fence variables when the primary worker never launched", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			local first_token = controller.token()
			ctx.next_start_result = false
			local callback_calls = 0
			local callback_ok = nil

			local started = controller.start(function(ok)
				callback_calls = callback_calls + 1
				callback_ok = ok
			end)

			helpers.assert_eq(started, false)
			helpers.assert_eq(callback_calls, 1,
				"a proven prelaunch refusal must settle immediately rather than await a needless fence")
			helpers.assert_true(callback_ok == false)
			helpers.assert_eq(#ctx.spawns, 1,
				"no fallback revoker is needed when start() proves the worker never ran")
			helpers.assert_eq(controller.status(), "failed")

			local replacement = controller.variables()
			helpers.assert_not_nil(replacement)
			helpers.assert_true(replacement.token ~= first_token)
			helpers.assert_true(controller.start(), "a later executable helper may start a fresh generation")
		end)
	end)

	helpers.it("rejects a final READY chunk from an unexpectedly failed watchdog", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			local phases = {}
			local callback_calls = 0
			local callback_result = nil
			controller.init(function(phase) phases[#phases + 1] = phase end)
			controller.start(function(ok)
				callback_calls = callback_calls + 1
				callback_result = ok
			end)

			ctx.complete(1, 9, "READY\n")

			helpers.assert_eq(callback_calls, 0, "start callback must wait for the exact fallback fence")
			ctx.complete(2, 0, "")
			helpers.assert_eq(callback_calls, 1, "start callback must settle exactly once after fencing")
			helpers.assert_true(callback_result == false,
				"non-zero completion must outrank buffered protocol output")
			helpers.assert_eq(controller.status(), "failed")
			for _, phase in ipairs(phases) do
				helpers.assert_true(phase ~= "active" and phase ~= "paused",
					"final completion output must never publish a live phase")
			end
		end)
	end)

	helpers.it("retries duplicate UUIDs without ever publishing a reused token", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller({
				uuid_values = {
					UUIDS[1],
					UUIDS[1],
					UUIDS[2],
				},
			})
			controller.init()
			local first = controller.token()
			controller.stop("discard prepared token")
			local second = controller.token()

			helpers.assert_eq(first, "00112233445566778899aabbccddeeff")
			helpers.assert_eq(second, "ffeeddccbbaa99887766554433221100")
			helpers.assert_eq(ctx.uuid_index, 3,
				"the duplicate must be consumed and retried before publication")
			helpers.assert_eq(#ctx.spawns, 0, "token allocation retries must have no task side effects")
		end)
	end)

	helpers.it("fails closed when the UUID source can only repeat a used token", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller({ uuid_values = { UUIDS[1] } })
			controller.init()
			local first = controller.token()
			controller.stop("discard prepared token")
			local duplicate = controller.token()

			helpers.assert_not_nil(first)
			helpers.assert_nil(duplicate, "a reused capability must never be returned to the generator")
			helpers.assert_eq(ctx.uuid_index, 9,
				"one initial allocation plus eight bounded duplicate attempts are expected")
			helpers.assert_eq(#ctx.spawns, 0, "always-duplicate failure must not launch a watchdog")
			helpers.assert_eq(controller.status(), "failed")
		end)
	end)

	helpers.it("accepts READY delivered synchronously by the task adapter", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			ctx.ready_on_start = true
			local ready_ok = nil

			helpers.assert_true(controller.start(function(ok) ready_ok = ok end),
				"start must survive immediate streaming output")
			helpers.assert_true(ready_ok == true, "immediate READY must settle the callback")
			helpers.assert_eq(controller.status(), "active", "immediate READY must activate the lease")
		end)
	end)

	helpers.it("revokes in the completion callback when an active watchdog dies", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			local vars = controller.variables()
			controller.start()
			ctx.chunk(1, "READY\n")

			ctx.complete(1, 9, "")
			helpers.assert_eq(controller.status(), "fencing", "a dead helper cannot be declared safe prematurely")
			helpers.assert_not_nil(find_native_revoke(ctx, vars),
				"Hammerspoon completion must revoke when an untrappable watchdog death occurs")
			ctx.complete(2, 0, "")
			helpers.assert_eq(controller.status(), "failed", "dead-helper failure settles after exact fencing")
		end)
	end)

	helpers.it("retries a refused detached revoker launch until the exact helper runs", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			local vars = controller.variables()
			controller.start()
			ctx.chunk(1, "READY\n")
			ctx.next_start_result = false

			ctx.complete(1, 9, "")
			helpers.assert_eq(#ctx.spawns, 2, "watchdog death must immediately attempt detached cleanup")
			helpers.assert_eq(ctx.spawns[2].executable, "/test/ErgoptiPlus")
			helpers.assert_eq(ctx.spawns[2].args[1], "--karabiner-lease-revoke")
			helpers.assert_eq(ctx.spawns[2].args[2], "/test/karabiner_cli")
			helpers.assert_eq(ctx.spawns[2].args[3], vars.mode)
			helpers.assert_eq(ctx.spawns[2].args[4], vars.revoked)

			ctx.fire_latest_timer()
			helpers.assert_eq(#ctx.spawns, 3,
				"a refused helper launch must retry asynchronously instead of abandoning mode=1")
			helpers.assert_eq(ctx.spawns[3].args[1], "--karabiner-lease-revoke")
			helpers.assert_eq(ctx.spawns[3].args[3], vars.mode)
			helpers.assert_eq(ctx.spawns[3].args[4], vars.revoked)
			ctx.complete(3, 0, "")
		end)
	end)

	helpers.it("rejects a synchronously firing fallback retry without recursive revocation", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.start()
			ctx.chunk(1, "READY\n")
			ctx.next_start_result = false
			ctx.next_after_callback_sync = true
			local timers_before_failure = #ctx.timers

			ctx.complete(1, 9, "")

			helpers.assert_eq(controller.status(), "fencing",
				"an unretained retry must leave the generation fenced")
			helpers.assert_eq(#ctx.spawns, 2,
				"a callback fired before handle retention must not recursively launch another revoker")
			helpers.assert_eq(#ctx.timers, timers_before_failure + 1,
				"the scheduler must be attempted once without a synchronous retry spin")
			local _, snapshot = controller.status()
			helpers.assert_true(snapshot.fallback_exhausted == true,
				"a synchronously fired candidate must terminalize the logical obligation")
			helpers.assert_eq(snapshot.fallback_exhausted_reason, "fallback-retry-unavailable")
		end)
	end)

	helpers.it("contains a fallback retry scheduler exception without publishing safety", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.start()
			ctx.chunk(1, "READY\n")
			ctx.next_start_result = false
			ctx.next_after_error = "injected fallback timer failure"

			local ok, err = pcall(function() ctx.complete(1, 9, "") end)

			helpers.assert_true(ok, "timer adapter errors must not escape a task completion callback: " .. tostring(err))
			helpers.assert_eq(controller.status(), "fencing",
				"timer failure cannot certify the exact generation as revoked")
			helpers.assert_eq(#ctx.spawns, 2,
				"scheduler failure must not recursively launch an unbounded revoker loop")
			local phase, snapshot = controller.status()
			helpers.assert_eq(phase, "fencing")
			helpers.assert_true(snapshot.fallback_exhausted == true)
			helpers.assert_eq(snapshot.fallback_attempts, 1)
			helpers.assert_eq(snapshot.fallback_exhausted_reason, "fallback-retry-unavailable")
			local stopped_ok, stopped_reason = nil, nil
			helpers.assert_true(controller.stop("join unavailable fallback", function(result, reason)
				stopped_ok = result
				stopped_reason = reason
			end))
			helpers.assert_true(stopped_ok == false,
				"a scheduler failure must settle later Stop callers instead of hanging")
			helpers.assert_eq(stopped_reason, "fallback-retry-unavailable")
		end)
	end)

	helpers.it("never reuses a published token across a controller reload", function()
		with_fixture(function(load_controller)
			local settings_store = {}
			local first_controller = load_controller({
				settings_store = settings_store,
				uuid_values = { UUIDS[1] },
			})
			first_controller.init()
			helpers.assert_eq(first_controller.token(), "00112233445566778899aabbccddeeff")

			local second_controller, second_ctx = load_controller({
				settings_store = settings_store,
				uuid_values = { UUIDS[1], UUIDS[2] },
			})
			second_controller.init()
			helpers.assert_eq(second_controller.token(), "ffeeddccbbaa99887766554433221100",
				"reload must reject a token whose old Karabiner variables can still exist")
			helpers.assert_eq(second_ctx.uuid_index, 2, "the persisted collision must be retried")

			local duplicate_controller, duplicate_ctx = load_controller({
				settings_store = settings_store,
				uuid_values = { UUIDS[1] },
			})
			duplicate_controller.init()
			helpers.assert_nil(duplicate_controller.token(),
				"an always-repeating UUID source must fail closed after reload")
			helpers.assert_eq(duplicate_ctx.uuid_index, 8)
			helpers.assert_eq(#duplicate_ctx.spawns, 0)
		end)
	end)

	helpers.it("fails closed when reload cannot read the one-shot token ledger", function()
		with_fixture(function(load_controller)
			local settings_store = {}
			local first_controller = load_controller({
				settings_store = settings_store,
				uuid_values = { UUIDS[1] },
			})
			first_controller.init()
			helpers.assert_eq(first_controller.token(), "00112233445566778899aabbccddeeff")

			local reloaded, ctx = load_controller({
				settings_store = settings_store,
				settings_get_failures = 1,
				uuid_values = { UUIDS[1] },
			})
			local initialized = reloaded.init()

			helpers.assert_eq(initialized, false,
				"a reload that cannot recover token history must expose failed initialization")
			helpers.assert_nil(reloaded.token(),
				"the repeated UUID must never be republished after an ambiguous ledger read")
			helpers.assert_eq(#ctx.spawns, 0)
		end)
	end)

	helpers.it("rejects malformed persisted token history instead of filtering it", function()
		with_fixture(function(load_controller)
			local ledger_key = "ergopti.karabiner.used_tokens.v1"
			local malformed_ledgers = {
				"not-a-table",
				{ UUIDS[1] },
				{ [1] = "00112233445566778899aabbccddeeff", [3] = "ffeeddccbbaa99887766554433221100" },
			}

			for index, ledger in ipairs(malformed_ledgers) do
				local controller, ctx = load_controller({
					settings_store = { [ledger_key] = ledger },
					uuid_values = { UUIDS[1] },
				})
				helpers.assert_eq(controller.init(), false,
					"malformed ledger case " .. index .. " must fail initialization")
				helpers.assert_nil(controller.token(),
					"malformed ledger case " .. index .. " must block capability allocation")
				helpers.assert_eq(#ctx.spawns, 0)
			end
		end)
	end)

	helpers.it("keeps every managed rule inert when the packaged native helper is unavailable", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller({ helper_unavailable = true })
			controller.init()
			local variables = controller.variables()
			local started_ok = nil

			helpers.assert_not_nil(variables, "generator may still publish a fresh default-zero gate")
			helpers.assert_true(not controller.start(function(ok) started_ok = ok end))
			helpers.assert_true(started_ok == false)
			helpers.assert_eq(controller.status(), "failed")
			helpers.assert_eq(#ctx.spawns, 0, "missing helper must never fall back to a shell or direct CLI")
		end)
	end)
end)
