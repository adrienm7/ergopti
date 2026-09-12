--- tests/unit/platform/remap/guardian_recovery/test_external_gates.lua

--- ==============================================================================
--- MODULE: Guardian Recovery External Gates
--- DESCRIPTION:
--- Exercises exact-lease recovery with a scoped native environment.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.guardian_recovery_fixture")
local TOKENS = fixture.TOKENS
local assert_delays = fixture.assert_delays
local has_log = fixture.has_log
local count_logs = fixture.count_logs
local with_remap = fixture.with_remap

helpers.describe("Karabiner recovery external gates", function()
	helpers.it("gates bundled boot regeneration before build and resumes after approval", function()
		with_remap({
			initial_phase = "idle",
			guardian_status = "requires_approval",
			guardian_probe_deferred = true,
		}, function(remap, calls)
			local results = {}
			helpers.assert_true(remap.regenerate(function(ok, reason)
				results[#results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_eq(calls.guardian_probe_count, 1)
			helpers.assert_eq(calls.builds, 0)
			helpers.assert_eq(calls.deploys, 0)
			helpers.assert_eq(calls.starts_paused, 0)

			calls.deliver_guardian_probe("requires_approval", nil, 1)
			assert_delays(calls, { 3.0 })
			helpers.assert_eq(calls.builds, 0,
				"a live legacy guardian must not bypass current Background Items approval")

			calls.recovery_timers[1]:fire()
			helpers.assert_eq(calls.guardian_probe_count, 2)
			calls.deliver_guardian_probe("ready", nil, 2)
			helpers.assert_eq(calls.builds, 1)
			helpers.assert_eq(calls.deploys, 1)
			helpers.assert_eq(calls.starts_paused, 1)
			helpers.assert_eq(#results, 0,
				"native readiness alone must not publish activation success")

			calls.deliver_ready()
			calls.deliver_resumed()
			helpers.assert_eq(#results, 1)
			helpers.assert_true(results[1].ok == true)
		end)
	end)

	helpers.it("coalesces bundled public regenerations behind one guardian proof", function()
		with_remap({
			initial_phase = "idle",
			guardian_status = "ready",
			guardian_probe_deferred = true,
		}, function(remap, calls)
			local callback_count = 0
			helpers.assert_true(remap.regenerate(function() callback_count = callback_count + 1 end))
			helpers.assert_true(remap.regenerate(function() callback_count = callback_count + 1 end))
			helpers.assert_eq(calls.guardian_probe_count, 1,
				"equivalent rebuilds must share the exact native observation")

			calls.deliver_guardian_probe("ready", nil, 1)
			helpers.assert_eq(calls.builds, 1)
			helpers.assert_eq(calls.deploys, 1)
			calls.deliver_ready()
			calls.deliver_resumed()
			helpers.assert_eq(callback_count, 2,
				"coalescing must preserve every joined public completion")
		end)
	end)

	helpers.it("gates bundled enable before committing the persisted state", function()
		with_remap({
			enabled = false,
			initial_phase = "idle",
			guardian_status = "requires_approval",
			guardian_probe_deferred = true,
		}, function(remap, calls)
			local callback_ok = nil
			local saves_before_enable = calls.saves
			helpers.assert_true(remap.set_enabled(true, function(ok) callback_ok = ok end))
			helpers.assert_true(remap.get_enabled() == false,
				"approval waiting must not commit enabled=true early")
			helpers.assert_eq(calls.builds, 0)
			helpers.assert_eq(calls.saves, saves_before_enable,
				"approval waiting must not add a preference write")

			calls.deliver_guardian_probe("ready", nil, 1)
			helpers.assert_eq(calls.builds, 1)
			helpers.assert_eq(calls.starts_paused, 1)
			calls.deliver_ready()
			helpers.assert_true(remap.get_enabled() == true)
			helpers.assert_eq(calls.saves, saves_before_enable + 1)
			calls.deliver_resumed()
			helpers.assert_true(callback_ok == true)
		end)
	end)

	helpers.it("gates bundled resume before redeploying paused rules", function()
		with_remap({
			initial_phase = "paused",
			paused = true,
			guardian_status = "requires_approval",
			guardian_probe_deferred = true,
		}, function(remap, calls)
			local callback_ok = nil
			helpers.assert_true(remap.resume(function(ok) callback_ok = ok end))
			helpers.assert_eq(calls.builds, 0)
			helpers.assert_eq(calls.deploys, 0)

			calls.deliver_guardian_probe("ready", nil, 1)
			helpers.assert_eq(calls.builds, 1)
			helpers.assert_eq(calls.deploys, 1)
			calls.deliver_ready()
			calls.deliver_resumed()
			helpers.assert_true(callback_ok == true)
		end)
	end)

	helpers.it("cancels a bundled regeneration probe before a late ready callback", function()
		with_remap({
			guardian_status = "ready",
			guardian_probe_deferred = true,
		}, function(remap, calls)
			local callback_ok, callback_reason = nil, nil
			helpers.assert_true(remap.regenerate(function(ok, reason)
				callback_ok, callback_reason = ok, reason
			end))
			helpers.assert_eq(calls.builds, 0)

			helpers.assert_true(remap.pause())
			helpers.assert_true(callback_ok == false)
			helpers.assert_eq(callback_reason, "script-pause-requested")
			helpers.assert_eq(calls.guardian_probe_terminations, 1)
			calls.deliver_guardian_probe("requires_approval", nil, 1)
			helpers.assert_eq(calls.builds, 0)
			helpers.assert_eq(calls.deploys, 0)
			helpers.assert_eq(calls.guardian_cached_status, "ready",
				"a cancelled status task must not rewrite the menu cache")
		end)
	end)

	helpers.it("times out a silent bundled regeneration probe without building", function()
		with_remap({
			initial_phase = "idle",
			guardian_status = "ready",
			guardian_probe_deferred = true,
		}, function(remap, calls)
			helpers.assert_true(remap.regenerate())
			helpers.assert_eq(#calls.guardian_probe_timers, 1)
			calls.guardian_probe_timers[1]:fire()

			helpers.assert_eq(calls.guardian_probe_terminations, 1)
			helpers.assert_eq(calls.builds, 0)
			helpers.assert_eq(calls.deploys, 0)
			assert_delays(calls, { 3.0 })
		end)
	end)

	helpers.it("lets direct Hammerspoon public regeneration skip native status", function()
		with_remap({
			initial_phase = "idle",
			guardian_status = nil,
		}, function(remap, calls)
			helpers.assert_true(remap.regenerate())
			helpers.assert_eq(calls.guardian_probe_count, 0)
			helpers.assert_eq(calls.builds, 1)
			helpers.assert_eq(calls.deploys, 1)
		end)
	end)

	helpers.it("keeps direct Hammerspoon development recovery free of native probes", function()
		with_remap({ guardian_status = nil }, function(_, calls)
			calls.publish_failed(TOKENS[1])
			helpers.assert_eq(calls.guardian_probe_count, 0)
			assert_delays(calls, { 1.0 })

			calls.recovery_timers[1]:fire()
			helpers.assert_eq(calls.guardian_probe_count, 0,
				"an absent launcher environment must retain direct HS development mode")
			helpers.assert_eq(calls.build_tokens[1], TOKENS[2])
		end)
	end)

	helpers.it("never opens guardian settings while the integration is disabled", function()
		with_remap({
			enabled = false,
			guardian_status = "requires_approval",
		}, function(remap, calls)
			local results = {}
			helpers.assert_true(remap.open_guardian_settings(function(ok, reason)
				results[#results + 1] = { ok = ok, reason = reason }
			end) == false)
			helpers.assert_eq(calls.guardian_settings_opens, 0,
				"disabled integration must not cross the native settings boundary")
			helpers.assert_eq(#results, 1)
			helpers.assert_eq(results[1].ok, false)
			helpers.assert_eq(results[1].reason, "integration-disabled")
		end)
	end)

	helpers.it("never opens guardian settings when cached approval is not required", function()
		with_remap({
			guardian_status = "ready",
		}, function(remap, calls)
			local results = {}
			helpers.assert_true(remap.open_guardian_settings(function(ok, reason)
				results[#results + 1] = { ok = ok, reason = reason }
			end) == false)
			helpers.assert_eq(calls.guardian_settings_opens, 0,
				"ready cached status must not cross the native settings boundary")
			helpers.assert_eq(#results, 1)
			helpers.assert_eq(results[1].ok, false)
			helpers.assert_eq(results[1].reason, "approval-not-required")
		end)
	end)

	helpers.it("opens guardian settings exactly once for enabled approval-required state", function()
		with_remap({
			guardian_status = "requires_approval",
		}, function(remap, calls)
			local results = {}
			helpers.assert_true(remap.open_guardian_settings(function(ok, reason)
				results[#results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_eq(calls.guardian_settings_opens, 1)
			helpers.assert_eq(#results, 1)
			helpers.assert_eq(results[1].ok, true)
			helpers.assert_eq(results[1].reason, "opened")
		end)
	end)

	helpers.it("polls requires_approval and unavailable without spending recovery budget", function()
		with_remap({
			guardian_status = "requires_approval",
			guardian_probe_statuses = { "requires_approval", "unavailable", "ready" },
			build_failures = 1,
		}, function(_, calls)
			calls.publish_failed(TOKENS[1])
			helpers.assert_eq(calls.guardian_probe_count, 1)
			assert_delays(calls, { 3.0 })
			helpers.assert_eq(calls.builds, 0)
			helpers.assert_eq(calls.deploys, 0)

			calls.recovery_timers[1]:fire()
			helpers.assert_eq(calls.guardian_probe_count, 2)
			assert_delays(calls, { 3.0, 3.0 })
			helpers.assert_eq(calls.builds, 0)

			calls.recovery_timers[2]:fire()
			helpers.assert_eq(calls.guardian_probe_count, 3)
			assert_delays(calls, { 3.0, 3.0, 1.0 })
			helpers.assert_eq(calls.builds, 0,
				"a ready observation must retain the ordinary first-attempt backoff")

			calls.recovery_timers[3]:fire()
			helpers.assert_eq(calls.guardian_probe_count, 4,
				"the actual retry must re-probe before rebuilding")
			helpers.assert_eq(calls.builds, 1)
			helpers.assert_eq(calls.deploys, 0)
			assert_delays(calls, { 3.0, 3.0, 1.0, 10.0 })
		end)
	end)

	helpers.it("trusts a fresh native ready probe over stale startup approval state", function()
		with_remap({
			guardian_status = "requires_approval",
			guardian_probe_statuses = { "ready" },
		}, function(_, calls)
			calls.publish_failed(TOKENS[1])
			helpers.assert_eq(calls.guardian_probe_count, 1)
			helpers.assert_eq(#calls.guardian_probe_timers, 0,
				"a synchronously settled probe must not retain a watchdog timer")
			assert_delays(calls, { 1.0 })
			helpers.assert_eq(calls.builds, 0)

			calls.recovery_timers[1]:fire()
			helpers.assert_eq(calls.guardian_probe_count, 2)
			helpers.assert_eq(calls.build_tokens[1], TOKENS[2])
		end)
	end)

	helpers.it("observes runtime guardian revocation and later reapproval", function()
		with_remap({
			guardian_status = "ready",
			guardian_probe_statuses = { "requires_approval", "ready" },
		}, function(_, calls)
			calls.publish_failed(TOKENS[1])
			assert_delays(calls, { 3.0 })
			helpers.assert_eq(calls.builds, 0)

			calls.recovery_timers[1]:fire()
			assert_delays(calls, { 3.0, 1.0 })
			helpers.assert_eq(calls.builds, 0)

			calls.recovery_timers[2]:fire()
			helpers.assert_eq(calls.guardian_probe_count, 3)
			helpers.assert_eq(calls.build_tokens[1], TOKENS[2])
		end)
	end)

	for _, failure in ipairs({
		{
			label = "malformed output",
			options = {
				guardian_status = "ready",
				guardian_probe_statuses = {
					{ status = nil, error = "synthetic-malformed-guardian-status" },
				},
			},
		},
		{
			label = "helper start failure",
			options = {
				guardian_status = "ready",
				guardian_probe_start_failures = 1,
			},
		},
	}) do
		helpers.it("keeps recovery fail-closed after guardian " .. failure.label, function()
			with_remap(failure.options, function(_, calls)
				calls.publish_failed(TOKENS[1])
				assert_delays(calls, { 3.0 })
				helpers.assert_eq(calls.builds, 0)
				helpers.assert_eq(calls.deploys, 0)

				calls.recovery_timers[1]:fire()
				assert_delays(calls, { 3.0, 1.0 })
				helpers.assert_eq(calls.builds, 0)
			end)
		end)
	end

	helpers.it("times out a silent guardian probe without charging recovery", function()
		with_remap({
			guardian_status = "ready",
			guardian_probe_deferred = true,
		}, function(_, calls)
			calls.publish_failed(TOKENS[1])
			helpers.assert_eq(calls.guardian_probe_count, 1)
			helpers.assert_eq(#calls.guardian_probe_timers, 1)
			helpers.assert_eq(calls.guardian_probe_timers[1].delay, 2.0)
			helpers.assert_eq(#calls.recovery_timers, 0)

			calls.guardian_probe_timers[1]:fire()
			helpers.assert_eq(calls.guardian_probe_termination_attempts, 1)
			helpers.assert_eq(calls.guardian_probe_terminations, 1,
				"timeout must terminate the exact silent helper")
			assert_delays(calls, { 3.0 })
			helpers.assert_eq(calls.builds, 0)
			helpers.assert_eq(calls.deploys, 0)
			helpers.assert_eq(calls.starts_paused, 0)
		end)
	end)

	helpers.it("keeps a cancelled guardian-probe timeout callback inert", function()
		with_remap({
			guardian_status = "ready",
			guardian_probe_deferred = true,
		}, function(remap, calls)
			calls.publish_failed(TOKENS[1])
			local stale_timeout = calls.guardian_probe_timers[1]
			helpers.assert_true(type(stale_timeout) == "table")

			helpers.assert_true(remap.pause())
			helpers.assert_eq(calls.guardian_probe_termination_attempts, 1)
			stale_timeout:fire(true)

			helpers.assert_eq(calls.guardian_probe_termination_attempts, 1,
				"the stale timeout must not touch the already-cancelled exact handle")
			helpers.assert_eq(#calls.recovery_timers, 0)
			helpers.assert_eq(calls.guardian_probe_count, 1)
			helpers.assert_eq(calls.builds, 0)
			helpers.assert_eq(calls.deploys, 0)
		end)
	end)

	helpers.it("warns only when the repeated non-ready guardian status changes", function()
		with_remap({
			guardian_status = "ready",
			guardian_probe_statuses = {
				"requires_approval",
				"requires_approval",
				"requires_approval",
				"unavailable",
				"unavailable",
			},
		}, function(_, calls)
			calls.publish_failed(TOKENS[1])
			for index = 1, 4 do calls.recovery_timers[index]:fire() end

			helpers.assert_eq(calls.guardian_probe_count, 5)
			assert_delays(calls, { 3.0, 3.0, 3.0, 3.0, 3.0 })
			helpers.assert_eq(count_logs(calls, "warn", "guardian"), 2,
				"only the first non-ready status and its one transition may warn")
			helpers.assert_eq(calls.builds, 0)
		end)
	end)

	helpers.it("coalesces one guardian probe and ignores duplicate completion", function()
		with_remap({
			guardian_status = "ready",
			guardian_probe_deferred = true,
		}, function(_, calls)
			calls.publish_failed(TOKENS[1])
			calls.publish_failed(TOKENS[1])
			helpers.assert_eq(calls.guardian_probe_count, 1,
				"duplicate FAILED must join the exact in-flight probe")
			helpers.assert_eq(#calls.recovery_timers, 0)

			calls.deliver_guardian_probe("ready", nil, 1)
			assert_delays(calls, { 1.0 })
			calls.deliver_guardian_probe("ready", nil, 1)
			assert_delays(calls, { 1.0 })

			calls.recovery_timers[1]:fire()
			helpers.assert_eq(calls.guardian_probe_count, 2)
			helpers.assert_eq(calls.builds, 0)
			calls.publish_failed(TOKENS[1])
			helpers.assert_eq(calls.guardian_probe_count, 2,
				"FAILED during the retry's preflight probe must still coalesce")

			calls.deliver_guardian_probe("ready", nil, 2)
			helpers.assert_eq(calls.build_tokens[1], TOKENS[2])
			calls.deliver_guardian_probe("ready", nil, 2)
			helpers.assert_eq(calls.builds, 1,
				"duplicate native completion must never regenerate twice")
		end)
	end)

	local cancellation_cases = {
		{
			label = "Pause",
			cancel = function(remap) return remap.pause() end,
		},
		{
			label = "Disable",
			cancel = function(remap) return remap.set_enabled(false) end,
		},
		{
			label = "explicit Stop",
			cancel = function(remap) return remap.stop_lease() end,
		},
		{
			label = "local teardown",
			cancel = function(remap, calls)
				calls.phase = "idle"
				calls.current_token = nil
				return remap.teardown_local()
			end,
		},
	}
	for _, case in ipairs(cancellation_cases) do
		helpers.it("makes a late guardian probe inert after " .. case.label, function()
			with_remap({
				guardian_status = "ready",
				guardian_probe_deferred = true,
			}, function(remap, calls)
				calls.publish_failed(TOKENS[1])
				helpers.assert_eq(calls.guardian_probe_count, 1)
				helpers.assert_true(case.cancel(remap, calls))
				helpers.assert_eq(calls.guardian_probe_terminations, 1,
					case.label .. " must terminate the exact native probe handle")

				calls.deliver_guardian_probe("requires_approval", nil, 1)
				helpers.assert_eq(#calls.recovery_timers, 0)
				helpers.assert_eq(calls.builds, 0)
				helpers.assert_eq(calls.deploys, 0)
				helpers.assert_eq(calls.starts_paused, 0)
				helpers.assert_eq(calls.guardian_cached_status, "ready",
					case.label .. " must invalidate cache authority before termination")
			end)
		end)
	end

	helpers.it("retries a failed guardian-probe termination before local teardown commits", function()
		with_remap({
			guardian_status = "ready",
			guardian_probe_deferred = true,
			guardian_probe_termination_failures = 1,
		}, function(remap, calls)
			calls.publish_failed(TOKENS[1])
			helpers.assert_eq(calls.guardian_probe_count, 1)

			helpers.assert_true(remap.pause())
			helpers.assert_eq(calls.guardian_probe_termination_attempts, 1)
			helpers.assert_eq(calls.guardian_probe_terminations, 0,
				"a false terminate result must not release exact handle ownership")

			calls.phase = "idle"
			calls.current_token = nil
			helpers.assert_true(remap.teardown_local(),
				"teardown must retry and prove the retained native handle termination")
			helpers.assert_eq(calls.guardian_probe_termination_attempts, 2)
			helpers.assert_eq(calls.guardian_probe_terminations, 1)

			calls.deliver_guardian_probe("requires_approval", nil, 1)
			helpers.assert_eq(#calls.recovery_timers, 0)
			helpers.assert_eq(calls.builds, 0)
			helpers.assert_eq(calls.deploys, 0)
			helpers.assert_eq(calls.starts_paused, 0)
			helpers.assert_eq(calls.guardian_cached_status, "ready")
		end)
	end)

	helpers.it("waits for the newest post-TIS layout before building the replacement", function()
		with_remap({ guardian_status = "ready", cancel_fails = true }, function(_, calls)
			calls.publish_failed(TOKENS[1])
			local stale_recovery = calls.recovery_timers[1]
			calls.layout_revision = "layout-b"
			calls.input_source_callback("Layout B")
			stale_recovery:fire(true)
			helpers.assert_eq(calls.builds, 0,
				"the pre-layout recovery callback must be stale even when cancellation failed")

			local layout_timer = calls.latest_layout_timer()
			helpers.assert_true(type(layout_timer) == "table")
			layout_timer:fire()
			helpers.assert_eq(calls.resolved_revision, "layout-b")
			helpers.assert_eq(#calls.recovery_timers, 2)
			helpers.assert_eq(calls.recovery_timers[2].delay, 1.0)
			calls.recovery_timers[2]:fire()
			helpers.assert_eq(calls.build_tokens[1], TOKENS[2])
			helpers.assert_eq(calls.build_layouts[1], "layout-b",
				"replacement config must consume the settled layout, never the crash-time key map")
		end)
	end)

	local transient_layout_failures = {
		{
			label = "timer arm",
			fails_during_arm = true,
			inject = function(calls) calls.hs_timer_failures_remaining = 1 end,
		},
		{
			label = "pause query",
			inject = function(calls) calls.pause_query_failures_remaining = 1 end,
		},
		{
			label = "lease status query",
			inject = function(calls) calls.status_failures_remaining = 1 end,
			assert_after_failure = function(calls)
				helpers.assert_true(has_log(calls, "synthetic-lease-status-failure"),
					"an async status exception must reach the file-logger boundary")
			end,
		},
		{
			label = "action resolution",
			inject = function(calls) calls.resolve_failures_remaining = 1 end,
		},
		{
			label = "shortcut rebind",
			inject = function(calls) calls.rebind_failures_remaining = 1 end,
		},
		{
			label = "missing shortcut rebind API",
			inject = function(calls)
				calls.saved_rebind = calls.shortcuts.rebind_for_layout
				calls.shortcuts.rebind_for_layout = nil
			end,
			repair = function(calls)
				calls.shortcuts.rebind_for_layout = calls.saved_rebind
			end,
		},
	}

	for _, failure in ipairs(transient_layout_failures) do
		helpers.it("recovers after one transient layout " .. failure.label .. " failure", function()
			with_remap({ guardian_status = "ready" }, function(_, calls)
				calls.publish_failed(TOKENS[1])
				calls.layout_revision = "layout-b"
				failure.inject(calls)
				calls.input_source_callback("Layout B")

				if not failure.fails_during_arm then
					local settle_timer = calls.latest_layout_timer()
					helpers.assert_true(type(settle_timer) == "table")
					settle_timer:fire()
				end
				if failure.assert_after_failure then failure.assert_after_failure(calls) end
				if failure.repair then failure.repair(calls) end

				local retry_timer = calls.latest_layout_timer()
				helpers.assert_true(type(retry_timer) == "table",
					"a transient layout failure must retain an owned retry timer")
				helpers.assert_eq(retry_timer.delay, 1.0)
				retry_timer:fire()
				helpers.assert_eq(calls.resolved_revision, "layout-b")
				helpers.assert_eq(#calls.recovery_timers, 2,
					"layout completion must rearm the guardian-loss recovery series")

				calls.recovery_timers[2]:fire()
				helpers.assert_eq(calls.build_tokens[1], TOKENS[2])
				helpers.assert_eq(calls.build_layouts[1], "layout-b")
				calls.deliver_ready()
				calls.deliver_resumed()
				helpers.assert_eq(calls.phase, "active")
			end)
		end)
	end

	helpers.it("keeps recovery fail-closed after layout retries exhaust and resumes on a new event",
		function()
			with_remap({ guardian_status = "ready" }, function(_, calls)
				calls.publish_failed(TOKENS[1])
				calls.layout_revision = "layout-b"
				calls.pause_query_failures_remaining = 4
				calls.input_source_callback("Layout B")

				calls.latest_layout_timer():fire()
				for _, expected_delay in ipairs({ 1.0, 10.0, 30.0 }) do
					local retry_timer = calls.latest_layout_timer()
					helpers.assert_eq(retry_timer.delay, expected_delay)
					retry_timer:fire()
				end
				helpers.assert_eq(calls.builds, 0)
				helpers.assert_eq(#calls.recovery_timers, 1,
					"exhaustion must not bypass the unresolved layout barrier")

				calls.layout_revision = "layout-c"
				calls.input_source_callback("Layout C")
				calls.latest_layout_timer():fire()
				helpers.assert_eq(#calls.recovery_timers, 2,
					"a new physical layout event must revive the retained recovery")
				calls.recovery_timers[2]:fire()
				helpers.assert_eq(calls.build_layouts[1], "layout-c")
			end)
		end)

	helpers.it("never resumes a stale generation after its layout barrier exhausts", function()
		with_remap({ guardian_status = "ready" }, function(_, calls)
			calls.publish_failed(TOKENS[1])
			calls.recovery_timers[1]:fire()
			helpers.assert_eq(calls.phase, "starting")
			helpers.assert_eq(calls.build_layouts[1], "layout-a")

			calls.layout_revision = "layout-b"
			calls.pause_query_failures_remaining = 4
			calls.input_source_callback("Layout B")
			calls.latest_layout_timer():fire()
			for _ = 1, 3 do calls.latest_layout_timer():fire() end

			calls.deliver_ready()
			helpers.assert_eq(calls.phase, "idle",
				"the layout-A generation must be fenced after the layout-B barrier exhausts")
			helpers.assert_eq(calls.resume_requests, 0,
				"an exhausted barrier remains authoritative even after its pending record is released")

			calls.layout_revision = "layout-c"
			calls.input_source_callback("Layout C")
			calls.latest_layout_timer():fire()
			assert_delays(calls, { 1.0, 1.0 })
			calls.recovery_timers[2]:fire()
			helpers.assert_eq(calls.build_tokens[2], TOKENS[3])
			helpers.assert_eq(calls.build_layouts[2], "layout-c")
		end)
	end)

	helpers.it("retries after layout arrives between worker start and READY", function()
		with_remap({ guardian_status = "ready" }, function(_, calls)
			calls.publish_failed(TOKENS[1])
			calls.recovery_timers[1]:fire()
			helpers.assert_eq(calls.phase, "starting")

			calls.layout_revision = "layout-c"
			calls.input_source_callback("Layout C")
			calls.deliver_ready()
			helpers.assert_eq(calls.phase, "idle",
				"a layout-raced PAUSED token must be fenced before it can RESUME stale keycodes")
			helpers.assert_eq(calls.resume_requests, 0)
			helpers.assert_eq(#calls.recovery_timers, 1,
				"the retry waits for the retained TIS-settle pipeline")

			calls.latest_layout_timer():fire()
			assert_delays(calls, { 1.0, 1.0 })
			calls.recovery_timers[2]:fire()
			helpers.assert_eq(calls.build_tokens[#calls.build_tokens], TOKENS[3])
			helpers.assert_eq(calls.build_layouts[#calls.build_layouts], "layout-c")
		end)
	end)

	helpers.it("fences a recovery generation when layout changes before RESUMED", function()
		with_remap({ guardian_status = "ready" }, function(_, calls)
			calls.publish_failed(TOKENS[1])
			calls.recovery_timers[1]:fire()
			calls.deliver_ready()
			helpers.assert_eq(calls.phase, "resuming")
			helpers.assert_eq(calls.resume_requests, 1)

			calls.layout_revision = "layout-d"
			calls.input_source_callback("Layout D")
			helpers.assert_eq(calls.phase, "idle",
				"the exact old-layout generation must be fenced before RESUMED can activate it")
			helpers.assert_eq(#calls.resume_callbacks, 0,
				"the exact STOP must settle the in-flight RESUME callback")
			helpers.assert_eq(#calls.recovery_timers, 1,
				"the replacement waits for the post-TIS layout barrier")

			calls.latest_layout_timer():fire()
			assert_delays(calls, { 1.0, 1.0 })
			calls.recovery_timers[2]:fire()
			helpers.assert_eq(calls.build_tokens[2], TOKENS[3])
			helpers.assert_eq(calls.build_layouts[2], "layout-d")
		end)
	end)
end)
