--- tests/unit/platform/remap/enable_transaction/test_first_run_fence.lua

--- ==============================================================================
--- MODULE: Remap Transaction Regression
--- DESCRIPTION:
--- Preserves exact lifecycle and persistence guarantees inside one fixture scope.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.remap_transaction_fixture")

helpers.describe("HS-011 first-run timer is part of every remap lifecycle fence", function()
	helpers.it("retries a refused first-run timer constructor before publishing its successor", function()
		with_fixture(function(fixture)
			local _, calls = fixture.load_enabled_remap({
				first_run_timer_after_results = { false, true },
			})
			helpers.assert_eq(calls.timer_after_attempts, 2)
			helpers.assert_eq(#calls.first_run_timers, 2)
			helpers.assert_nil(calls.first_run_timers[1].timer,
				"the refused exact wrapper must settle before replacement")
			helpers.assert_not_nil(calls.first_run_timers[2].timer)
			helpers.assert_eq(calls.timer_cancel_attempts, 1)
			helpers.assert_true(calls.fire_first_run_timer(2))
			helpers.assert_eq(calls.wizard_runs, 1,
				"the committed successor must deliver the wizard exactly once")
		end)
	end)

	helpers.it("preserves a nil native timer candidate without inventing cleanup debt", function()
		with_fixture(function(fixture)
			local _, calls = fixture.load_enabled_remap({
				first_run_timer_after_results = { "nil", true },
				first_run_timer_cancel_results = { false, false, false },
			})
			helpers.assert_eq(calls.timer_after_attempts, 2,
				"a nil native candidate must not block the bounded successor")
			helpers.assert_nil(calls.first_run_timers[1].timer)
			helpers.assert_eq(calls.timer_cancel_attempts, 0,
				"the fixture must not fabricate a cancellable native timer for nil")
			helpers.assert_not_nil(calls.first_run_timers[2].timer)
		end)
	end)

	helpers.it("retries exact first-run cancellation without another lifecycle action", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({
				first_run_timer_cancel_results = { false, true },
			})
			local result = nil
			helpers.assert_true(remap.pause(function(ok) result = ok end))
			helpers.assert_eq(calls.timer_cancel_attempts, 2)
			helpers.assert_nil(calls.first_run_timers[1].timer)
			helpers.assert_eq(#calls.pause_callbacks, 1)
			calls.force_first_run_callback(1)
			helpers.assert_eq(calls.wizard_runs, 0)
			calls.pause_callbacks[1](true, "paused")
			helpers.assert_true(result == true)
		end)
	end)

	for _, entry_point in ipairs({ "pause", "disable", "revoke", "shutdown" }) do
		helpers.it("fences the real first-run timer before " .. entry_point .. " completion", function()
			with_fixture(function(fixture)
				local remap, calls = fixture.load_enabled_remap()
				local result = nil
				local accepted
				if entry_point == "pause" then
					accepted = remap.pause(function(ok) result = ok end)
				elseif entry_point == "disable" then
					accepted = remap.set_enabled(false, function(ok) result = ok end)
				elseif entry_point == "revoke" then
					accepted = remap.revoke("HS-011-first-run", function(ok) result = ok end)
				else
					accepted = remap.shutdown("HS-011-first-run", function(ok) result = ok end)
				end
				helpers.assert_true(accepted)
				helpers.assert_nil(calls.first_run_timers[1].timer,
					entry_point .. " must settle the exact first-run capability first")
				calls.force_first_run_callback(1)
				helpers.assert_eq(calls.wizard_runs, 0,
					"a queued first-run callback must remain inert after " .. entry_point)
				helpers.assert_nil(result)
				if entry_point == "pause" then
					helpers.assert_eq(#calls.pause_callbacks, 1)
					calls.pause_callbacks[1](true, "paused")
				else
					calls.finish_stop(true, "stopped")
				end
				helpers.assert_true(result == true)
			end)
		end)
	end

	for _, refusal in ipairs({ false, "throw" }) do
		for _, entry_point in ipairs({ "pause", "disable", "revoke", "shutdown" }) do
			helpers.it("contains first-run cancel " .. tostring(refusal)
				.. " during " .. entry_point, function()
				with_fixture(function(fixture)
					local remap, calls = fixture.load_enabled_remap({
						first_run_timer_cancel_results = { refusal, refusal, refusal },
					})
					local result, detail = nil, nil
					local accepted
					local function on_done(ok, reason)
						result, detail = ok, reason
					end
					if entry_point == "pause" then
						accepted = remap.pause(on_done)
					elseif entry_point == "disable" then
						accepted = remap.set_enabled(false, on_done)
					elseif entry_point == "revoke" then
						accepted = remap.revoke("HS-011-first-run-refusal", on_done)
					else
						accepted = remap.shutdown("HS-011-first-run-refusal", on_done)
					end
					helpers.assert_eq(calls.timer_cancel_attempts, 3,
						"first-run cancellation must stop at its named retry budget")
					helpers.assert_not_nil(calls.first_run_timers[1].timer,
						"terminal failure must retain the exact cancellation debt")
					calls.force_first_run_callback(1)
					helpers.assert_eq(calls.wizard_runs, 0)
					helpers.assert_eq(calls.onboarding_stop_attempts, 1,
						"timer refusal must not skip independent installer revocation")
					if entry_point == "pause" or entry_point == "disable" then
						helpers.assert_true(accepted == false)
						helpers.assert_true(result == false)
						helpers.assert_eq(calls.stop, 0)
					else
						helpers.assert_true(accepted)
						helpers.assert_nil(result,
							"revoke still has to join the independently accepted lease fence")
						calls.finish_stop(true, "stopped")
						helpers.assert_true(result == false)
						helpers.assert_eq(detail, "first-run-wizard-stop-incomplete")
					end
				end)
			end)
		end
	end

	helpers.it("orders real installer terminal before first-run cancellation failure", function()
		with_fixture(function(fixture)
			local remap, calls, installer = fixture.load_remap_with_real_onboarding({
				first_run_timer_cancel_results = { false, false, false },
			})
			local result = nil
			helpers.assert_true(remap.pause(function(ok)
				installer.order[#installer.order + 1] = "pause"
				result = ok
			end), "the accepted task termination must keep the composed stop joined")
			helpers.assert_nil(result)
			helpers.assert_eq(installer.task.terminate_calls, 1)
			helpers.assert_eq(#calls.pause_callbacks, 0)

			installer.task:complete(1, "", "cancelled")
			helpers.assert_eq(#installer.order, 2)
			helpers.assert_eq(installer.order[1], "installer")
			helpers.assert_eq(installer.order[2], "pause")
			helpers.assert_true(result == false)
			helpers.assert_eq(#calls.pause_callbacks, 0,
				"PAUSED cannot publish after either composed owner failed")
		end)
	end)
end)
