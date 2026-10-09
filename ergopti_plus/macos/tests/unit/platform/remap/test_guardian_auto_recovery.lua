--- tests/unit/platform/remap/test_guardian_auto_recovery.lua

--- ==============================================================================
--- MODULE: Guardian Recovery Automatic Recovery
--- DESCRIPTION:
--- Exercises exact-lease recovery with a scoped native environment.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.guardian_recovery_fixture")
local TOKENS = fixture.TOKENS
local index_of = fixture.index_of
local assert_delays = fixture.assert_delays
local has_log = fixture.has_log
local with_remap = fixture.with_remap

helpers.describe("Karabiner guardian-loss automatic recovery", function()
	helpers.it("retains variable-writer recovery until the poison fence publishes IDLE", function()
		with_remap({ guardian_status = "ready" }, function(_, calls)
			helpers.assert_true(type(calls.ke_variables_recovery_observer) == "function")
			calls.ke_variables_recovery_observer(TOKENS[1], "writer-timeout")
			helpers.assert_eq(#calls.recovery_timers, 0,
				"a poisoned ACTIVE generation must wait for its exact fence")

			calls.publish_phase("stopping", TOKENS[1])
			helpers.assert_eq(#calls.recovery_timers, 0)
			calls.publish_phase("idle", nil)
			assert_delays(calls, { 1.0 })
		end)
	end)

	helpers.it("waits for exact FAILED publication before arming recovery", function()
		with_remap({ guardian_status = "ready" }, function(_, calls)
			calls.publish_phase("fencing", TOKENS[1])
			helpers.assert_eq(#calls.recovery_timers, 0)
			helpers.assert_eq(calls.builds, 0)
			calls.publish_failed(TOKENS[1])
			assert_delays(calls, { 1.0 })
		end)
	end)

	helpers.it("coalesces FAILED and activates one freshly deployed token", function()
		with_remap({ guardian_status = "ready" }, function(_, calls)
			calls.publish_failed(TOKENS[1])
			calls.publish_failed(TOKENS[1])
			assert_delays(calls, { 1.0 })

			calls.recovery_timers[1]:fire()
			helpers.assert_eq(calls.build_tokens[1], TOKENS[2])
			helpers.assert_eq(calls.deploy_tokens[1], TOKENS[2])
			helpers.assert_true(TOKENS[2] ~= TOKENS[1])
			helpers.assert_eq(calls.starts_paused, 1)
			helpers.assert_eq(calls.resume_requests, 0)

			local allocate_at = index_of(calls.order, "allocate:" .. TOKENS[2])
			local build_at = index_of(calls.order, "build:" .. TOKENS[2] .. ":layout-a")
			local deploy_at = index_of(calls.order, "deploy:" .. TOKENS[2])
			local start_at = index_of(calls.order, "start-paused:" .. TOKENS[2])
			helpers.assert_true(allocate_at < build_at and build_at < deploy_at and deploy_at < start_at,
				"the fresh token must gate the exact config before its PAUSED worker starts")

			calls.deliver_ready()
			helpers.assert_eq(calls.consumer_starts, 1)
			helpers.assert_eq(calls.classifier_refreshes, 1)
			helpers.assert_eq(calls.resume_requests, 1)
			local classifier_at = index_of(calls.order, "classifier")
			local resume_at = index_of(calls.order, "resume:" .. TOKENS[2])
			helpers.assert_true(classifier_at < resume_at,
				"all local consumers and classification must precede RESUME")
			calls.deliver_resumed()

			calls.publish_failed(TOKENS[2])
			assert_delays(calls, { 1.0, 1.0 })
		end)
	end)

	helpers.it("retries a transient recovery timer-arm failure without consuming backoff", function()
		with_remap({ guardian_status = "ready" }, function(_, calls)
			calls.recovery_timer_arm_failures_remaining = 1
			calls.publish_failed(TOKENS[1])
			helpers.assert_eq(calls.recovery_timer_arm_attempts, 2)
			assert_delays(calls, { 1.0 })

			calls.recovery_timers[1]:fire()
			helpers.assert_eq(calls.build_tokens[1], TOKENS[2])
			calls.deliver_ready()
			calls.deliver_resumed()
			helpers.assert_eq(calls.phase, "active")
		end)
	end)

	for _, failure in ipairs({
		{
			label = "pause-state query",
			inject = function(calls) calls.pause_query_failures_remaining = 1 end,
		},
		{
			label = "lease-status query",
			inject = function(calls) calls.status_failures_remaining = 1 end,
		},
		{
			label = "token allocation",
			inject = function(calls) calls.token_failures_remaining = 1 end,
		},
	}) do
		helpers.it("retries after a transient recovery " .. failure.label .. " failure", function()
			with_remap({ guardian_status = "ready" }, function(_, calls)
				calls.publish_failed(TOKENS[1])
				failure.inject(calls)
				calls.recovery_timers[1]:fire()
				helpers.assert_eq(calls.builds, 0,
					"unknown pause/status/token state must not reach config generation")
				assert_delays(calls, { 1.0, 10.0 })

				calls.recovery_timers[2]:fire()
				helpers.assert_eq(calls.build_tokens[1], TOKENS[2])
				calls.deliver_ready()
				calls.deliver_resumed()
				helpers.assert_eq(calls.phase, "active")
			end)
		end)
	end

	helpers.it("retains recovery until the ACTIVE callback proves the exact token", function()
		with_remap({ guardian_status = "ready" }, function(_, calls)
			calls.publish_failed(TOKENS[1])
			calls.recovery_timers[1]:fire()
			calls.deliver_ready()
			calls.status_failures_remaining = 1
			calls.deliver_resumed()

			helpers.assert_eq(calls.phase, "idle",
				"an unprovable ACTIVE callback must fence its exact generation")
			assert_delays(calls, { 1.0, 10.0 })
			calls.recovery_timers[2]:fire()
			helpers.assert_eq(calls.build_tokens[2], TOKENS[3])
			calls.deliver_ready()
			calls.deliver_resumed()
			helpers.assert_eq(calls.phase, "active")
		end)
	end)

	helpers.it("retains an owned-token retry through a manual activation callback", function()
		with_remap({ guardian_status = "ready" }, function(remap, calls)
			calls.publish_failed(TOKENS[1])
			calls.build_failures_remaining = 1
			calls.recovery_timers[1]:fire()
			helpers.assert_eq(calls.phase, "prepared")
			assert_delays(calls, { 1.0, 10.0 })

			helpers.assert_true(remap.regenerate())
			calls.deliver_ready()
			calls.status_failures_remaining = 1
			calls.deliver_resumed()
			helpers.assert_eq(calls.phase, "idle")
			calls.recovery_timers[2]:fire()
			helpers.assert_eq(calls.build_tokens[3], TOKENS[3])
		end)
	end)

	helpers.it("starts a new series after exhausted owned-token manual recovery is lost", function()
		with_remap({ guardian_status = "ready", build_failures = 3 }, function(remap, calls)
			calls.publish_failed(TOKENS[1])
			for attempt = 1, 3 do calls.recovery_timers[attempt]:fire() end
			helpers.assert_eq(calls.phase, "prepared")
			helpers.assert_true(helpers.deep_equal(calls.build_tokens, {
				TOKENS[2], TOKENS[2], TOKENS[2],
			}), "all exhausted pre-publication attempts must retain the exact owned token")
			assert_delays(calls, { 1.0, 10.0, 30.0 })

			helpers.assert_true(remap.regenerate())
			calls.deliver_ready()
			calls.deliver_resumed()
			helpers.assert_eq(calls.phase, "active")
			calls.publish_failed(TOKENS[2])

			assert_delays(calls, { 1.0, 10.0, 30.0, 1.0 })
		end)
	end)

	helpers.it("settles recovery even when the ACTIVE notification raises", function()
		with_remap({ guardian_status = "ready" }, function(_, calls)
			calls.publish_failed(TOKENS[1])
			calls.recovery_timers[1]:fire()
			calls.deliver_ready()
			calls.notify_failures_remaining = 1
			calls.deliver_resumed()
			helpers.assert_eq(calls.phase, "active")
			helpers.assert_true(has_log(calls, "synthetic-ready-notification-failure"))

			calls.publish_failed(TOKENS[2])
			assert_delays(calls, { 1.0, 1.0 })
		end)
	end)

	helpers.it("uses exactly 1, 10, and 30 seconds across replacement-token failures", function()
		with_remap({ guardian_status = "ready" }, function(_, calls)
			calls.publish_failed(TOKENS[1])
			for attempt = 1, 3 do
				calls.recovery_timers[attempt]:fire()
				helpers.assert_eq(calls.build_tokens[attempt], TOKENS[attempt + 1])
				calls.fail_start("synthetic-worker-loss-" .. attempt)
			end
			assert_delays(calls, { 1.0, 10.0, 30.0 })
			helpers.assert_eq(calls.builds, 3)
			helpers.assert_eq(calls.starts_paused, 3)
			calls.publish_failed(TOKENS[4])
			helpers.assert_eq(#calls.recovery_timers, 3,
				"an exhausted series must not restart from a duplicate/new failed token")
			helpers.assert_eq(calls.builds, 3, "there must be no fourth automatic attempt")
		end)
	end)

	helpers.it("retries the exact owned PREPARED token after a transient build failure", function()
		with_remap({ guardian_status = "ready", build_failures = 1 }, function(_, calls)
			calls.publish_failed(TOKENS[1])
			calls.recovery_timers[1]:fire()
			helpers.assert_eq(calls.phase, "prepared")
			helpers.assert_eq(calls.build_tokens[1], TOKENS[2])
			assert_delays(calls, { 1.0, 10.0 })

			calls.recovery_timers[2]:fire()
			helpers.assert_eq(calls.build_tokens[2], TOKENS[2],
				"a safe PREPARED token is retried instead of discarded or confused with a manual token")
			helpers.assert_eq(calls.starts_paused, 1)
			calls.deliver_ready()
			calls.deliver_resumed()
		end)
	end)

	for _, failure in ipairs({
		{ label = "deploy", option = "deploy_failures", phase = "prepared" },
		{ label = "input bind", option = "bind_failures", phase = "idle" },
		{ label = "classifier", option = "classifier_failures", phase = "idle" },
	}) do
		helpers.it("continues after a transient " .. failure.label .. " failure", function()
			local options = { guardian_status = "ready" }
			options[failure.option] = 1
			with_remap(options, function(_, calls)
				calls.publish_failed(TOKENS[1])
				calls.recovery_timers[1]:fire()
				if failure.label ~= "deploy" then calls.deliver_ready() end
				helpers.assert_eq(calls.phase, failure.phase,
					"the harness must model the production terminal phase for this failure stage")
				assert_delays(calls, { 1.0, 10.0 })
				calls.recovery_timers[2]:fire()
				local expected_token = failure.label == "deploy" and TOKENS[2] or TOKENS[3]
				helpers.assert_eq(calls.build_tokens[2], expected_token)
				helpers.assert_eq(calls.starts_paused, failure.label == "deploy" and 1 or 2)
				calls.deliver_ready()
				calls.deliver_resumed()
				helpers.assert_eq(calls.phase, "active")
			end)
		end)
	end

	helpers.it("refunds a retry that fires while the exact failure fence is pending", function()
		with_remap({ guardian_status = "ready" }, function(_, calls)
			calls.publish_failed(TOKENS[1])
			calls.recovery_timers[1]:fire()
			calls.defer_stop_exact = true
			calls.bind_failures_remaining = 1
			calls.deliver_ready()
			helpers.assert_eq(calls.phase, "stopping")
			assert_delays(calls, { 1.0, 10.0 })

			calls.recovery_timers[2]:fire()
			helpers.assert_eq(calls.builds, 1,
				"a retry must not allocate or build while the old token is still retiring")
			calls.complete_stop_exact()
			assert_delays(calls, { 1.0, 10.0, 10.0 })
			calls.recovery_timers[3]:fire()
			helpers.assert_eq(calls.build_tokens[2], TOKENS[3])
			calls.deliver_ready()
			calls.deliver_resumed()
			helpers.assert_eq(calls.phase, "active")
		end)
	end)
end)
