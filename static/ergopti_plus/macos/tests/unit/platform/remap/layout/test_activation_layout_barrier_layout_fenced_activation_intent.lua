--- tests/unit/platform/remap/layout/test_activation_layout_barrier_layout_fenced_activation_intent.lua

--- ==============================================================================
--- MODULE: Exact-Lease Activation Layout Barrier Regression Tests
--- DESCRIPTION:
--- Drives the real remap orchestrator with a token-aware lease double. Proves
--- that a layout notification observed after a config build invalidates that
--- exact generation at both asynchronous activation boundaries: before READY
--- and after RESUME but before RESUMED. The originating resume, enable, or
--- failed-disable rollback intent must survive the fence and complete exactly
--- once with a fresh token built from the post-TIS layout.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.platform.remap.layout.activation_layout_barrier_fixture"] = nil
local Fixture = require("tests.support.platform.remap.layout.activation_layout_barrier_fixture")
local complete_replacement = Fixture.complete_replacement
local contains = Fixture.contains
local count_value = Fixture.count_value
local race_before_ready = Fixture.race_before_ready
local with_remap = Fixture.with_remap





-- ===============================================================
-- ===============================================================
-- ======= 1/ Layout-Fenced Activation Intent Preservation =======
-- ===============================================================
-- ===============================================================

helpers.describe("Karabiner activation layout barrier", function()
	helpers.it("retries Resume when layout changes between build and READY", function()
		with_remap({ enabled = true, paused = true, initial_phase = "prepared" }, function(remap, calls)
			local results = {}
			helpers.assert_true(remap.resume(function(ok, reason)
				results[#results + 1] = { ok = ok, reason = reason }
			end))
			race_before_ready(calls, results, true)
		end)
	end)

	helpers.it("preserves every joined Resume callback across the same layout fence", function()
		with_remap({ enabled = true, paused = true, initial_phase = "prepared" }, function(remap, calls)
			local first_results = {}
			local second_results = {}
			helpers.assert_true(remap.resume(function(ok, reason)
				first_results[#first_results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_true(remap.resume(function(ok, reason)
				second_results[#second_results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_eq(#calls.builds, 2,
				"the fixture must join two regenerations at the shared READY boundary")
			local stale = calls.builds[1]

			calls.change_layout("layout-b")
			if calls.phase == "starting" then
				helpers.assert_true(calls.deliver_ready(stale.token))
			end
			helpers.assert_eq(#first_results, 0,
				"the first joined caller must remain pending behind the internal fence")
			helpers.assert_eq(#second_results, 0,
				"the second joined caller must remain pending behind the internal fence")
			calls.force_stale_successes()
			helpers.assert_eq(#first_results, 0)
			helpers.assert_eq(#second_results, 0)

			helpers.assert_true(calls.drain_until(function() return #calls.builds >= 3 end),
				"joined callers must share one automatic post-TIS replacement")
			local replacement = calls.builds[#calls.builds]
			helpers.assert_true(replacement.token ~= stale.token)
			helpers.assert_eq(replacement.layout, "layout-b")
			helpers.assert_true(calls.deliver_ready(replacement.token))
			helpers.assert_true(calls.deliver_resumed(replacement.token))
			helpers.assert_eq(#first_results, 1)
			helpers.assert_true(first_results[1].ok)
			helpers.assert_eq(#second_results, 1)
			helpers.assert_true(second_results[1].ok)
			helpers.assert_eq(#calls.builds, 3,
				"the shared retry must not duplicate the replacement build")
		end)
	end)

	helpers.it("preserves joined Resume callbacks when layout changes during RESUMING", function()
		with_remap({ enabled = true, paused = true, initial_phase = "prepared" }, function(remap, calls)
			local first_results = {}
			local second_results = {}
			helpers.assert_true(remap.resume(function(ok, reason)
				first_results[#first_results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_true(remap.resume(function(ok, reason)
				second_results[#second_results + 1] = { ok = ok, reason = reason }
			end))
			local stale = calls.builds[1]
			helpers.assert_true(calls.deliver_all_ready(stale.token),
				"both start callbacks must join one activation transaction")
			helpers.assert_eq(count_value(calls.resume_tokens, stale.token), 1,
				"joined READY callers must share exactly one RESUME")
			helpers.assert_eq(calls.phase, "resuming")

			calls.change_layout("layout-b")
			helpers.assert_true(contains(calls.stop_exact_tokens, stale.token))
			helpers.assert_eq(#first_results, 0)
			helpers.assert_eq(#second_results, 0,
				"every joined activation callback must remain behind the layout fence")
			calls.force_stale_successes()
			helpers.assert_eq(#first_results, 0)
			helpers.assert_eq(#second_results, 0)

			helpers.assert_true(calls.drain_until(function() return #calls.builds >= 3 end))
			local replacement = calls.builds[#calls.builds]
			helpers.assert_eq(replacement.layout, "layout-b")
			helpers.assert_true(replacement.token ~= stale.token)
			helpers.assert_true(calls.deliver_all_ready(replacement.token))
			helpers.assert_true(calls.deliver_resumed(replacement.token))
			helpers.assert_eq(#first_results, 1)
			helpers.assert_true(first_results[1].ok)
			helpers.assert_eq(#second_results, 1)
			helpers.assert_true(second_results[1].ok)
			helpers.assert_eq(count_value(calls.resume_tokens, replacement.token), 1)
		end)
	end)

	helpers.it("preserves compatible public and Resume intents across one layout fence", function()
		with_remap({ enabled = true, paused = false, initial_phase = "prepared" }, function(remap, calls)
			local public_results = {}
			local resume_results = {}
			helpers.assert_true(remap.regenerate(function(ok, reason)
				public_results[#public_results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_true(remap.resume(function(ok, reason)
				resume_results[#resume_results + 1] = { ok = ok, reason = reason }
			end))
			local stale = calls.builds[1]
			helpers.assert_true(calls.deliver_all_ready(stale.token))
			helpers.assert_eq(count_value(calls.resume_tokens, stale.token), 1)

			calls.change_layout("layout-b")
			helpers.assert_true(contains(calls.stop_exact_tokens, stale.token))
			helpers.assert_eq(#public_results, 0)
			helpers.assert_eq(#resume_results, 0,
				"compatible ACTIVE intents must share the retained replacement")
			calls.force_stale_successes()
			helpers.assert_eq(#public_results, 0)
			helpers.assert_eq(#resume_results, 0)

			helpers.assert_true(calls.drain_until(function() return #calls.builds >= 3 end))
			local replacement = calls.builds[#calls.builds]
			helpers.assert_eq(replacement.layout, "layout-b")
			helpers.assert_true(replacement.token ~= stale.token)
			helpers.assert_true(calls.deliver_all_ready(replacement.token))
			helpers.assert_true(calls.deliver_resumed(replacement.token))
			helpers.assert_eq(#public_results, 1)
			helpers.assert_true(public_results[1].ok)
			helpers.assert_eq(#resume_results, 1)
			helpers.assert_true(resume_results[1].ok)
		end)
	end)

	helpers.it("revalidates each joined success after a callback changes layout", function()
		with_remap({ enabled = true, paused = false, initial_phase = "prepared" }, function(remap, calls)
			local first_results = {}
			local second_results = {}
			helpers.assert_true(remap.regenerate(function(ok, reason)
				first_results[#first_results + 1] = { ok = ok, reason = reason }
				if ok then calls.change_layout("layout-b") end
			end))
			helpers.assert_true(remap.regenerate(function(ok, reason)
				second_results[#second_results + 1] = { ok = ok, reason = reason }
			end))
			local stale = calls.builds[1]
			helpers.assert_true(calls.deliver_all_ready(stale.token))
			helpers.assert_eq(count_value(calls.resume_tokens, stale.token), 1)
			helpers.assert_true(calls.deliver_resumed(stale.token))

			helpers.assert_eq(#first_results, 1)
			helpers.assert_true(first_results[1].ok,
				"the first callback observed a valid ACTIVE token before changing layout")
			helpers.assert_eq(#second_results, 0,
				"a captured success must be revalidated after an earlier callback changes layout")
			helpers.assert_true(contains(calls.stop_exact_tokens, stale.token))
			helpers.assert_eq(calls.phase, "idle")
			calls.force_stale_successes()
			helpers.assert_eq(#second_results, 0)

			helpers.assert_true(calls.drain_until(function() return #calls.builds >= 3 end))
			local replacement = calls.builds[#calls.builds]
			helpers.assert_eq(replacement.layout, "layout-b")
			helpers.assert_true(replacement.token ~= stale.token)
			helpers.assert_true(calls.deliver_all_ready(replacement.token))
			helpers.assert_true(calls.deliver_resumed(replacement.token))
			helpers.assert_eq(#first_results, 1)
			helpers.assert_eq(#second_results, 1)
			helpers.assert_true(second_results[1].ok)
			helpers.assert_eq(calls.phase, "active")
		end)
	end)

	helpers.it("fences Resume when layout changes between RESUME and RESUMED", function()
		with_remap({ enabled = true, paused = true, initial_phase = "paused" }, function(remap, calls)
			local results = {}
			helpers.assert_true(remap.resume(function(ok, reason)
				results[#results + 1] = { ok = ok, reason = reason }
			end))
			local stale = calls.builds[#calls.builds]
			helpers.assert_eq(stale.layout, "layout-a")
			helpers.assert_eq(count_value(calls.resume_tokens, stale.token), 1,
				"fixture must reach the RESUMING boundary")

			calls.change_layout("layout-b")
			helpers.assert_true(contains(calls.stop_exact_tokens, stale.token),
				"a layout event during RESUMING must fence that exact token immediately")
			helpers.assert_eq(#results, 0,
				"the internal fence must preserve the public Resume intent")
			calls.force_stale_successes()
			helpers.assert_eq(#results, 0,
				"late RESUMED from token A must not publish success")
			complete_replacement(calls, stale.token, "layout-b", results, true)
		end)
	end)

	helpers.it("waits for asynchronous STOPPED before rebuilding the settled layout", function()
		with_remap({
			enabled = true,
			paused = true,
			initial_phase = "paused",
			defer_exact_stop = true,
		}, function(remap, calls)
			local results = {}
			helpers.assert_true(remap.resume(function(ok, reason)
				results[#results + 1] = { ok = ok, reason = reason }
			end))
			local stale = calls.builds[1]
			calls.change_layout("layout-b")
			helpers.assert_eq(calls.phase, "stopping",
				"an accepted exact STOP is not yet proof that the old token is fenced")
			helpers.assert_eq(#results, 0)

			helpers.assert_true(calls.fire_next_async_timer(),
				"the post-TIS barrier timer must be observable while STOPPED is pending")
			helpers.assert_eq(#calls.builds, 1,
				"the replacement must not build while the invalidated token may still emit")
			calls.force_stale_successes()
			helpers.assert_eq(#results, 0)

			calls.deliver_exact_stopped()
			complete_replacement(calls, stale.token, "layout-b", results, true)
		end)
	end)

	helpers.it("defers an ACTIVE public regeneration until TIS settles", function()
		with_remap({ enabled = true, paused = false, initial_phase = "prepared" }, function(remap, calls)
			local results = {}
			helpers.assert_true(remap.regenerate())
			local active_token = calls.builds[1].token
			helpers.assert_true(calls.deliver_all_ready(active_token))
			helpers.assert_true(calls.deliver_resumed(active_token))
			calls.resolve_count = 0
			calls.builds = {}
			calls.deploy_tokens = {}
			calls.change_layout("layout-b")
			local settle_timer = calls.hs_timers[#calls.hs_timers]
			helpers.assert_true(remap.regenerate(function(ok, reason)
				results[#results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_eq(calls.resolve_count, 0,
				"a pre-settle public request must not read the old TIS map")
			helpers.assert_eq(#calls.builds, 0)
			helpers.assert_eq(#calls.deploy_tokens, 0)
			helpers.assert_eq(#results, 0)

			settle_timer:fire()
			helpers.assert_eq(calls.resolve_count, 1)
			helpers.assert_eq(#calls.builds, 1)
			helpers.assert_eq(calls.builds[1].layout, "layout-b")
			helpers.assert_eq(#calls.deploy_tokens, 1)
			helpers.assert_eq(#results, 1)
			helpers.assert_true(results[1].ok, tostring(results[1].reason))
			for _ = 1, 10 do
				if not calls.fire_next_async_timer() then break end
			end
			helpers.assert_eq(#calls.builds, 1,
				"consuming the retained layout record must not redeploy the same serial")
			helpers.assert_eq(#results, 1)
		end)
	end)

	helpers.it("defers a PREPARED cold-start regeneration until TIS settles", function()
		with_remap({ enabled = true, paused = false, initial_phase = "prepared" }, function(remap, calls)
			local results = {}
			calls.change_layout("layout-b")
			helpers.assert_true(remap.regenerate(function(ok, reason)
				results[#results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_eq(calls.resolve_count, 0)
			helpers.assert_eq(#calls.builds, 0)
			helpers.assert_eq(#calls.deploy_tokens, 0)
			helpers.assert_eq(#results, 0)

			helpers.assert_true(calls.drain_until(function() return #calls.builds == 1 end))
			local replacement = calls.builds[1]
			helpers.assert_eq(replacement.layout, "layout-b")
			helpers.assert_eq(calls.resolve_count, 1)
			helpers.assert_true(calls.deliver_all_ready(replacement.token))
			helpers.assert_true(calls.deliver_resumed(replacement.token))
			helpers.assert_eq(#results, 1)
			helpers.assert_true(results[1].ok)
		end)
	end)

	helpers.it("keeps PREPARED fail-closed after the layout timer budget exhausts", function()
		with_remap({
			enabled = true,
			paused = false,
			initial_phase = "prepared",
			layout_timer_failures = 4,
		}, function(remap, calls)
			local exhausted_results = {}
			calls.change_layout("layout-b")
			helpers.assert_eq(calls.layout_timer_arm_attempts, 4,
				"the initial arm and three bounded retries must all fail")
			helpers.assert_true(not remap.regenerate(function(ok, reason)
				exhausted_results[#exhausted_results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_eq(#exhausted_results, 1)
			helpers.assert_true(exhausted_results[1].ok == false)
			helpers.assert_eq(exhausted_results[1].reason, "layout-refresh-exhausted")
			helpers.assert_eq(calls.resolve_count, 0)
			helpers.assert_eq(#calls.builds, 0)
			helpers.assert_eq(#calls.deploy_tokens, 0)

			local recovered_results = {}
			calls.change_layout("layout-c")
			helpers.assert_true(remap.regenerate(function(ok, reason)
				recovered_results[#recovered_results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_eq(#calls.builds, 0)
			helpers.assert_true(calls.drain_until(function() return #calls.builds == 1 end))
			local replacement = calls.builds[1]
			helpers.assert_eq(replacement.layout, "layout-c")
			helpers.assert_true(calls.deliver_all_ready(replacement.token))
			helpers.assert_true(calls.deliver_resumed(replacement.token))
			helpers.assert_eq(#recovered_results, 1)
			helpers.assert_true(recovered_results[1].ok)
			helpers.assert_eq(#exhausted_results, 1)
		end)
	end)

	helpers.it("keeps ACTIVE fail-closed after the layout timer budget exhausts", function()
		with_remap({
			enabled = true,
			paused = false,
			initial_phase = "prepared",
			layout_timer_failures = 4,
		}, function(remap, calls)
			helpers.assert_true(remap.regenerate())
			local active_token = calls.builds[1].token
			helpers.assert_true(calls.deliver_all_ready(active_token))
			helpers.assert_true(calls.deliver_resumed(active_token))
			calls.resolve_count = 0
			calls.builds = {}
			calls.deploy_tokens = {}

			local exhausted_results = {}
			calls.change_layout("layout-b")
			helpers.assert_eq(calls.layout_timer_arm_attempts, 4)
			helpers.assert_true(not remap.regenerate(function(ok, reason)
				exhausted_results[#exhausted_results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_eq(#exhausted_results, 1)
			helpers.assert_eq(exhausted_results[1].reason, "layout-refresh-exhausted")
			helpers.assert_eq(calls.resolve_count, 0)
			helpers.assert_eq(#calls.builds, 0)
			helpers.assert_eq(#calls.deploy_tokens, 0)

			local recovered_results = {}
			calls.change_layout("layout-c")
			helpers.assert_true(remap.regenerate(function(ok, reason)
				recovered_results[#recovered_results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_true(calls.drain_until(function() return #calls.builds == 1 end))
			helpers.assert_eq(calls.builds[1].layout, "layout-c")
			helpers.assert_eq(#recovered_results, 1)
			helpers.assert_true(recovered_results[1].ok)
			helpers.assert_eq(#exhausted_results, 1)
		end)
	end)

	helpers.it("retries Enable when layout changes before READY", function()
		with_remap({ enabled = false, paused = false, initial_phase = "prepared" }, function(remap, calls)
			local results = {}
			helpers.assert_true(remap.set_enabled(true, function(ok, reason)
				results[#results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_true(remap.get_enabled() == false,
				"Enable must not commit before a layout-current ACTIVE token exists")
			race_before_ready(calls, results, true)
			helpers.assert_true(remap.get_enabled(),
				"the preserved Enable intent must commit after the fresh token activates")
		end)
	end)

	helpers.it("retries failed-Disable rollback when layout changes before READY", function()
		with_remap({
			enabled = true,
			paused = false,
			initial_phase = "active",
			defer_disable_stop = true,
		}, function(remap, calls)
			local results = {}
			helpers.assert_true(remap.set_enabled(false, function(ok, reason)
				results[#results + 1] = { ok = ok, reason = reason }
			end))
			calls.fail_disable_stop("synthetic-disable-stop-failure")
			helpers.assert_eq(#calls.builds, 1,
				"failed Disable must start exactly one rollback generation before the race")
			race_before_ready(calls, results, false)
			helpers.assert_true(remap.get_enabled(),
				"failed Disable rollback must restore the enabled intent on the fresh token")
		end)
	end)

	helpers.it("coalesces retained layout B into C and deploys only the newest event", function()
		with_remap({ enabled = true, paused = true, initial_phase = "paused" }, function(remap, calls)
			local results = {}
			helpers.assert_true(remap.resume(function(ok, reason)
				results[#results + 1] = { ok = ok, reason = reason }
			end))
			local stale = calls.builds[1]
			helpers.assert_eq(stale.layout, "layout-a")

			calls.change_layout("layout-b")
			helpers.assert_true(contains(calls.stop_exact_tokens, stale.token),
				"the first physical event must retain the intent behind an exact fence")
			helpers.assert_eq(#results, 0)
			local layout_b_timer = calls.hs_timers[#calls.hs_timers]
			helpers.assert_type(layout_b_timer, "table")
			helpers.assert_true(layout_b_timer.running)

			calls.change_layout("layout-c")
			local layout_c_timer = calls.hs_timers[#calls.hs_timers]
			helpers.assert_true(layout_c_timer ~= layout_b_timer,
				"the second physical event must replace the retained B timer")
			helpers.assert_true(not layout_b_timer.running,
				"the superseded B timer must be cancelled before C can settle")
			layout_b_timer:fire(true)
			helpers.assert_eq(#calls.builds, 1,
				"a forcibly delivered stale B callback must not build layout B")
			helpers.assert_eq(#calls.deploy_tokens, 1,
				"a forcibly delivered stale B callback must not deploy layout B")
			calls.force_stale_successes()
			helpers.assert_eq(#results, 0,
				"late token-A success must not settle the retained Resume intent")

			local replacement = complete_replacement(
				calls,
				stale.token,
				"layout-c",
				results,
				true
			)
			helpers.assert_eq(#calls.builds, 2,
				"coalesced physical events must produce only the original and newest builds")
			for _, build in ipairs(calls.builds) do
				helpers.assert_true(build.layout ~= "layout-b",
					"superseded layout B must never reach the generator")
			end
			helpers.assert_eq(#calls.deploy_tokens, 2)
			helpers.assert_eq(calls.deploy_tokens[1], stale.token)
			helpers.assert_eq(calls.deploy_tokens[2], replacement.token,
				"only the layout-C replacement token may be deployed after the race")

			for _ = 1, 10 do
				if not calls.fire_next_async_timer() then break end
			end
			helpers.assert_eq(#calls.builds, 2,
				"final replay must consume C without a duplicate regeneration")
			helpers.assert_eq(#calls.deploy_tokens, 2)
			helpers.assert_eq(#results, 1,
				"coalescing and final replay must settle the public callback exactly once")
		end)
	end)

	helpers.it("cancels a retained Resume exactly once when the user pauses", function()
		with_remap({ enabled = true, paused = true, initial_phase = "paused" }, function(remap, calls)
			local resume_results = {}
			local pause_results = {}
			helpers.assert_true(remap.resume(function(ok, reason)
				resume_results[#resume_results + 1] = { ok = ok, reason = reason }
			end))
			local stale = calls.builds[1]

			calls.change_layout("layout-b")
			helpers.assert_true(contains(calls.stop_exact_tokens, stale.token))
			helpers.assert_eq(#resume_results, 0,
				"the layout fence itself must retain rather than fail Resume")
			helpers.assert_true(remap.pause(function(ok, reason)
				pause_results[#pause_results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_eq(#resume_results, 1,
				"the explicit Pause must cancel the retained Resume exactly once")
			helpers.assert_true(resume_results[1].ok == false)
			helpers.assert_eq(resume_results[1].reason, "script-pause-requested")
			helpers.assert_eq(#pause_results, 1)
			helpers.assert_true(pause_results[1].ok)
			helpers.assert_eq(calls.phase, "idle")

			calls.force_stale_successes()
			for _ = 1, 10 do
				if not calls.fire_next_async_timer() then break end
			end
			calls.force_stale_successes()
			helpers.assert_eq(#resume_results, 1,
				"late callbacks and settled layout replay must not resettle cancelled Resume")
			helpers.assert_eq(#calls.builds, 1,
				"Pause cancellation must prevent every post-layout activation retry")
			helpers.assert_eq(#calls.deploy_tokens, 1,
				"Pause cancellation must not deploy a replacement generation")
			helpers.assert_eq(calls.token_index, 1,
				"Pause cancellation must not allocate a replacement lease token")
		end)
	end)

	helpers.it("lets Pause cancel a layout-invalidated Resume before READY", function()
		with_remap({ enabled = true, paused = true, initial_phase = "prepared" }, function(remap, calls)
			local resume_results = {}
			local pause_results = {}
			helpers.assert_true(remap.resume(function(ok, reason)
				resume_results[#resume_results + 1] = { ok = ok, reason = reason }
			end))
			local stale = calls.builds[1]
			helpers.assert_eq(calls.phase, "starting")

			calls.change_layout("layout-b")
			helpers.assert_true(contains(calls.stop_exact_tokens, stale.token),
				"the STARTING generation must be retained and fenced before READY")
			helpers.assert_eq(#resume_results, 0)
			helpers.assert_true(remap.pause(function(ok, reason)
				pause_results[#pause_results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_eq(#resume_results, 1)
			helpers.assert_true(resume_results[1].ok == false)
			helpers.assert_eq(resume_results[1].reason, "script-pause-requested")
			helpers.assert_eq(#pause_results, 1)
			helpers.assert_true(pause_results[1].ok)

			calls.force_stale_successes()
			for _ = 1, 10 do
				if not calls.fire_next_async_timer() then break end
			end
			calls.force_stale_successes()
			helpers.assert_eq(#resume_results, 1)
			helpers.assert_eq(#calls.builds, 1,
				"the older Resume intent must never rebuild after the newer Pause")
			helpers.assert_eq(#calls.deploy_tokens, 1)
			helpers.assert_eq(calls.token_index, 1)
		end)
	end)
end)
