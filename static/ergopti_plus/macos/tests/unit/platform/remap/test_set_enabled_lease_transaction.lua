--- tests/unit/platform/remap/test_set_enabled_lease_transaction.lua

--- ==============================================================================
--- MODULE: Remap Transaction Regression
--- DESCRIPTION:
--- Preserves exact lifecycle and persistence guarantees inside one fixture scope.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.remap_transaction_fixture")

helpers.describe("karabiner disable owns guardian retirement", function()
	helpers.it("does not commit OFF or admit re-enable before guardian acknowledgement", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({ initially_enabled = true, unregister_mode = "async" })
			local result
			helpers.assert_true(remap.set_enabled(false, function(ok) result = ok end))
			helpers.assert_nil(calls.unregister_guardian)
			calls.finish_stop(true)
			helpers.assert_eq(calls.unregister_guardian, 1)
			helpers.assert_true(remap.get_enabled())
			helpers.assert_eq(calls.save, 0)
			helpers.assert_nil(result)
			local opposite
			helpers.assert_eq(remap.set_enabled(true, function(ok) opposite = ok end), false)
			helpers.assert_eq(opposite, false)
			calls.unregister_callback(true, "unregistered")
			helpers.assert_eq(remap.get_enabled(), false)
			helpers.assert_true(result)
			helpers.assert_true(helpers.deep_equal(calls.saved_enabled, { false }))
		end)
	end)

	helpers.it("recovers a fresh READY lease after partial guardian removal refusal", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({ initially_enabled = true, unregister_mode = "async" })
			local result
			remap.set_enabled(false, function(ok) result = ok end)
			calls.finish_stop(true)
			calls.unregister_callback(false, "partial-native-removal")
			helpers.assert_true(remap.get_enabled())
			helpers.assert_eq(calls.save, 0)
			helpers.assert_nil(result)
			helpers.assert_eq(calls.start_paused, 1)
			calls.deliver_ready()
			calls.deliver_resumed()
			helpers.assert_eq(result, false)
			helpers.assert_true(remap.get_enabled())
		end)
	end)

	helpers.it("uses the same retirement owner when removal starts with the switch already OFF", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({ initially_enabled = false, unregister_mode = "async" })
			local result
			helpers.assert_true(remap.remove_from_karabiner(function(ok) result = ok end))
			calls.finish_stop(true)
			helpers.assert_eq(calls.unregister_guardian, 1)
			helpers.assert_nil(result)
			calls.unregister_callback(false, "native-refusal")
			helpers.assert_eq(result, false)
			helpers.assert_eq(remap.get_enabled(), false)
			helpers.assert_eq(calls.start_paused, 0)
			helpers.assert_eq(calls.save, 0)
		end)
	end)
end)

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


-- This fixture models accepted requests only; it never supplies a native PONG.
helpers.describe("transaction fixture serialized liveness port", function()
	helpers.it("observes a paused refresh only after actual fresh READY and before enable publication", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({ initially_enabled = false, paused = true })
			local controller = package.loaded["platform.remap.lease_controller"]
			helpers.assert_eq(type(controller.refresh_liveness), "function")
			helpers.assert_eq(controller.refresh_liveness(), false)
			local published
			remap.set_enabled(true, function(ok)
				local requests = calls.liveness_requests
				local request = requests[#requests]
				published = { ok = ok, count = #requests, phase = request.phase,
					accepted = request.accepted, token = request.token, start_paused = request.start_paused }
			end)
			helpers.assert_eq(calls.start_paused, 1)
			helpers.assert_eq(controller.refresh_liveness(), false)
			helpers.assert_nil(published)
			calls.deliver_ready()
			helpers.assert_true(published.ok == true)
			helpers.assert_eq(published.count, 3)
			helpers.assert_eq(published.phase, "paused")
			helpers.assert_eq(published.accepted, true)
			helpers.assert_eq(published.token, controller.token())
			helpers.assert_eq(published.start_paused, 1)
			helpers.assert_eq(calls.liveness_requests[1].phase, "prepared")
			helpers.assert_eq(calls.liveness_requests[1].accepted, false)
			helpers.assert_eq(calls.liveness_requests[2].phase, "starting")
			helpers.assert_eq(calls.liveness_requests[2].accepted, false)
			helpers.assert_eq(calls.liveness_requests[3].initialized, true)
			helpers.assert_eq(calls.lease_bound_starts, 0)
			helpers.assert_eq(calls.resume_prepared or 0, 0)
		end)
	end)

	helpers.it("refuses an uninitialized or failed and stopping fixture owner", function()
		with_fixture(function(fixture)
			local _, calls = fixture.load_enabled_remap({ paused = true, skip_init = true })
			local controller = package.loaded["platform.remap.lease_controller"]
			helpers.assert_eq(type(controller.refresh_liveness), "function")
			helpers.assert_eq(controller.refresh_liveness(), false)
			helpers.assert_eq(calls.liveness_requests[1].initialized, false)
		end)
		with_fixture(function(fixture)
			local _, calls = fixture.load_enabled_remap({ paused = true })
			local controller = package.loaded["platform.remap.lease_controller"]
			helpers.assert_eq(type(controller.refresh_liveness), "function")
			helpers.assert_eq(controller.refresh_liveness(), true)
			calls.deliver_ready(false)
			helpers.assert_eq(controller.refresh_liveness(), false)
			helpers.assert_eq(calls.liveness_requests[2].phase, "failed")
			controller.stop_exact(controller.token(), "controlled-fixture-retirement")
			helpers.assert_eq(controller.refresh_liveness(), false)
			helpers.assert_eq(calls.liveness_requests[3].phase, "stopping")
			calls.finish_stop(true)
			helpers.assert_eq(controller.refresh_liveness(), false)
			helpers.assert_eq(calls.liveness_requests[4].phase, "idle")
		end)
	end)

	helpers.it("retains a controlled refresh refusal without committing paused enable", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({
				initially_enabled = false, paused = true, refresh_requested = false,
			})
			local result
			remap.set_enabled(true, function(ok) result = ok end)
			calls.deliver_ready()
			helpers.assert_eq(#calls.liveness_requests, 1)
			helpers.assert_eq(calls.liveness_requests[1].phase, "paused")
			helpers.assert_eq(calls.liveness_requests[1].accepted, false)
			helpers.assert_eq(remap.get_enabled(), false)
			helpers.assert_eq(calls.save, 0)
			helpers.assert_eq(calls.stop_exact, 1)
			helpers.assert_nil(result, "failed enable still waits for its original exact teardown")
			calls.finish_stop(true)
			helpers.assert_true(result == false)
			helpers.assert_eq(calls.lease_bound_starts, 0)
			helpers.assert_eq(calls.resume_prepared or 0, 0)
		end)
	end)
end)


helpers.describe("retained PAUSED precommit probe ownership", function()
	helpers.it("refuses a commit-hook owner loss before cleanup and retained success", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({ initially_enabled = false, paused = true })
			local controller = package.loaded["platform.remap.lease_controller"]
			local config = package.loaded["platform.remap.config"]
			local save = config.save_user_config
			local held, result
			config.save_user_config = function(...)
				if held == nil then
					local requests = calls.liveness_requests or {}
					local request = requests[#requests]
					held = { request_count = #requests, phase = request and request.phase,
						accepted = request and request.accepted, token = controller.token() }
					controller.stop_exact(held.token, "controlled-commit-hook-owner-loss")
					-- Native-phase listener work belongs to this exact callback; subsequent
					-- activation cleanup must not run after its owner has been lost.
					held.classifier_clears = calls.classifier_clears
				end
				return save(...)
			end
			remap.set_enabled(true, function(ok) result = ok end)
			calls.deliver_ready()
			helpers.assert_true(held ~= nil)
			helpers.assert_eq(held.request_count, 1)
			helpers.assert_eq(held.phase, "paused")
			helpers.assert_eq(held.accepted, true)
			helpers.assert_eq(calls.classifier_clears, held.classifier_clears)
			helpers.assert_eq(remap.get_enabled(), false)
			helpers.assert_true(helpers.deep_equal(calls.saved_enabled, { true, false }),
				"a completed ON write still requires the original compensating OFF on owner loss")
			helpers.assert_nil(result, "owner loss still waits for original exact abort teardown")
			calls.finish_stop(true)
			helpers.assert_true(result == false)
			helpers.assert_eq(calls.lease_bound_starts, 0)
			helpers.assert_eq(calls.resume_prepared or 0, 0)
		end)
	end)
end)
