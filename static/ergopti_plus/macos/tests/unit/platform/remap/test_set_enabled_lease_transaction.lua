--- tests/unit/platform/remap/test_set_enabled_lease_transaction.lua

--- ==============================================================================
--- MODULE: Remap Transaction Regression
--- DESCRIPTION:
--- Preserves exact lifecycle and persistence guarantees inside one fixture scope.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.remap_transaction_fixture")

helpers.describe("karabiner enable state is committed only after READY", function()
	helpers.it("coalesces enable clicks and leaves state/preferences false until READY", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({ initially_enabled = false })
			local first_result, second_result = nil, nil

			helpers.assert_true(remap.set_enabled(true, function(ok) first_result = ok end))
			helpers.assert_true(remap.set_enabled(true, function(ok) second_result = ok end))
			helpers.assert_eq(remap.get_enabled(), false,
				"deploy/start acceptance is not a committed enabled state")
			helpers.assert_eq(calls.save, 0, "enabled preference must not persist before READY")
			helpers.assert_eq(calls.build, 1)
			helpers.assert_eq(calls.deploy, 1)
			helpers.assert_eq(calls.start, 0, "fresh mode=ACTIVE must be unreachable")
			helpers.assert_eq(calls.start_paused, 1, "repeated enable clicks must join one paused start")
			helpers.assert_nil(first_result)
			helpers.assert_nil(second_result)

			calls.deliver_ready()
			helpers.assert_eq(remap.get_enabled(), true)
			helpers.assert_eq(calls.save, 1)
			helpers.assert_true(calls.saved_enabled[1] == true)
			helpers.assert_eq(calls.lease_bound_starts, 1)
			helpers.assert_eq(calls.hotkey_attempts, 4)
			helpers.assert_eq(calls.classifier_refreshes, 1)
			helpers.assert_eq(calls.resume_prepared, 1)
			helpers.assert_nil(first_result, "PAUSED READY is not an activation commit")
			calls.deliver_resumed()
			helpers.assert_true(first_result == true and second_result == true,
				"all joined callers must settle from the same RESUMED commit")
		end)
	end)

	helpers.it("keeps disabled and revokes the exact generation after every pre-READY failure", function()
		with_fixture(function(fixture)
			local cases = {
				{ label = "build", options = { build_succeeds = false } },
				{ label = "deploy", options = { deploy_succeeds = false } },
				{ label = "start", options = { start_requested = false } },
				{ label = "READY", options = {}, fail_ready = true },
			}
			for _, case in ipairs(cases) do
				case.options.initially_enabled = false
				local remap, calls = fixture.load_enabled_remap(case.options)
				local result = nil

				local accepted = remap.set_enabled(true, function(ok) result = ok end)
				if case.fail_ready then calls.deliver_ready(false, "ready-failed") end

				helpers.assert_eq(remap.get_enabled(), false, case.label .. " failure must not commit enabled")
				helpers.assert_eq(calls.save, 0, case.label .. " failure must not persist enabled=true")
				helpers.assert_eq(calls.stop, 1, case.label .. " failure must revoke its exact prepared/live token")
				helpers.assert_eq(calls.execute, 0, case.label .. " failure must not touch stock Karabiner")
				helpers.assert_true(accepted,
					"the public request remains accepted while exact failure teardown is pending: " .. case.label)
				helpers.assert_nil(result, "public failure waits for exact teardown: " .. case.label)
				calls.finish_stop(true, "stopped")
				helpers.assert_true(result == false, "failed enable must settle false: " .. case.label)
			end
		end)
	end)

	helpers.it("revokes READY when enabled preference persistence fails", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({ initially_enabled = false, save_succeeds = false })
			local result = nil
			remap.set_enabled(true, function(ok) result = ok end)

			calls.deliver_ready()
			helpers.assert_eq(remap.get_enabled(), false,
				"READY cannot commit when enabled=true was not durably saved")
			helpers.assert_eq(calls.save, 1)
			helpers.assert_eq(calls.stop_exact, 1,
				"the prepared token must be fenced after the persistence commit fails")
			helpers.assert_eq(calls.stop, 1,
				"the joined enable transaction must await exact failure teardown")
			helpers.assert_eq(calls.lease_bound_starts, 1,
				"required inputs are proven before attempting the preference commit")
			helpers.assert_eq(calls.resume_prepared or 0, 0,
				"persistence failure must send no RESUME")
			helpers.assert_nil(result)

			calls.finish_stop(true, "stopped")
			helpers.assert_true(result == false)
		end)
	end)

	helpers.it("keeps enable uncommitted when a required lease input fails", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({
				initially_enabled = false,
				hotkey_failure_index = 2,
			})
			local result = nil
			remap.set_enabled(true, function(ok) result = ok end)

			calls.deliver_ready()
			helpers.assert_eq(remap.get_enabled(), false,
				"a failed required input mount must never commit enabled state")
			helpers.assert_true(helpers.deep_equal(calls.saved_enabled, {}),
				"no compensating write is needed when prerequisites precede commit")
			helpers.assert_true(helpers.deep_equal(calls.stop_reasons, {
				"lease_input_bind_failed",
				"integration_enable_failed",
			}), "the exact failure fence must precede the joined enable-abort teardown")
			helpers.assert_nil(result, "the caller must wait for exact fencing before failure settlement")
			calls.finish_stop(true, "stopped")
			helpers.assert_true(result == false)
			helpers.assert_eq(calls.execute, 0, "input rollback must never act on stock Karabiner")
		end)
	end)

	helpers.it("enables atomically paused without exposing normal rules", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({ initially_enabled = false, paused = true })
			local result = nil

			remap.set_enabled(true, function(ok) result = ok end)
			helpers.assert_eq(calls.start, 0)
			helpers.assert_eq(calls.start_paused, 1,
				"a paused enable must put atomic mode=2 in the helper's first write")
			helpers.assert_eq(remap.get_enabled(), false)
			calls.deliver_ready()

			helpers.assert_eq(remap.get_enabled(), true)
			helpers.assert_true(result == true)
			helpers.assert_eq(calls.lease_bound_starts, 0,
				"paused READY must not start lease-bound gesture or keylogger resources")
			helpers.assert_eq(calls.classifier_refreshes, 0)
			helpers.assert_eq(calls.resume_prepared or 0, 0)
		end)
	end)

	helpers.it("re-reads pause state at READY before choosing whether to activate", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({ initially_enabled = false, paused = true })
			local result = nil

			remap.set_enabled(true, function(ok) result = ok end)
			calls.set_paused(false)
			calls.deliver_ready()

			helpers.assert_eq(calls.lease_bound_starts, 1)
			helpers.assert_eq(calls.hotkey_attempts, 4)
			helpers.assert_eq(calls.classifier_refreshes, 1)
			helpers.assert_eq(calls.resume_prepared, 1)
			helpers.assert_nil(result)
			calls.deliver_resumed()
			helpers.assert_true(result == true)
		end)
	end)

	helpers.it("retains F17 consumers until STOPPED when RESUME fails after commit", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({ initially_enabled = false })
			local result = nil
			remap.set_enabled(true, function(ok) result = ok end)
			calls.deliver_ready()
			helpers.assert_eq(remap.get_enabled(), true,
				"the enabled preference is committed immediately before RESUME")
			helpers.assert_eq(calls.hotkey_attempts, 4)
			local clears_before_failure = calls.classifier_clears
			local unbound_before_failure = calls.unbound

			-- Reproduce quit/disable winning while RESUME is in flight. The real
			-- controller publishes STOPPING and rejects the queued RESUME callback.
			calls.lease_phase = "stopping"
			calls.phase_listener("stopping")
			local callbacks = calls.resume_callbacks
			calls.resume_callbacks = {}
			for _, callback in ipairs(callbacks) do callback(false, "lease-stopping") end

			helpers.assert_eq(calls.stop, 1)
			helpers.assert_eq(calls.unbound, unbound_before_failure,
				"managed rules may still emit until the exact stop fence settles")
			helpers.assert_eq(calls.classifier_clears, clears_before_failure,
				"classification must remain live beside the retained F17 consumers")
			helpers.assert_nil(result)

			calls.finish_stop(true, "stopped")
			helpers.assert_true(result == false)
			helpers.assert_true(calls.unbound >= 4)
		end)
	end)
end)
