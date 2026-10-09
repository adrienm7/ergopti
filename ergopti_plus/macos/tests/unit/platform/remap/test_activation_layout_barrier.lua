--- tests/unit/platform/remap/test_activation_layout_barrier.lua

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
local with_remap = require("tests.support.activation_layout_fixture").with_remap

--- Returns whether a flat list contains one exact value.
--- @param values table Values to scan.
--- @param expected any Exact value to find.
--- @return boolean found
local function contains(values, expected)
	for _, value in ipairs(values) do
		if value == expected then return true end
	end
	return false
end


--- Counts exact occurrences in a flat list.
--- @param values table Values to scan.
--- @param expected any Exact value to count.
--- @return integer count
local function count_value(values, expected)
	local count = 0
	for _, value in ipairs(values) do
		if value == expected then count = count + 1 end
	end
	return count
end


--- Completes the fresh post-layout generation and proves one final result.
--- @param calls table Harness observations and drivers.
--- @param stale_token string Exact invalidated token.
--- @param expected_layout string Settled layout revision.
--- @param results table Public callback results.
--- @param expected_ok boolean Expected public result after recovery.
--- @return table replacement Fresh build descriptor.
local function complete_replacement(calls, stale_token, expected_layout, results, expected_ok)
	local built = calls.drain_until(function() return #calls.builds >= 2 end)
	helpers.assert_true(built,
		"the retained activation intent must rebuild automatically after TIS settles")
	local replacement = calls.builds[#calls.builds]
	helpers.assert_true(replacement.token ~= stale_token,
		"a layout-invalidated generation must never reuse its fenced token")
	helpers.assert_eq(replacement.layout, expected_layout,
		"the replacement must consume the post-TIS layout")

	if calls.phase == "starting" then
		helpers.assert_true(calls.deliver_ready(replacement.token),
			"the fresh worker must retain a READY callback")
	end
	helpers.assert_eq(count_value(calls.resume_tokens, replacement.token), 1,
		"the fresh token must receive exactly one RESUME")
	helpers.assert_true(calls.deliver_resumed(replacement.token),
		"the fresh token must retain its RESUMED callback")
	helpers.assert_eq(#results, 1, "the originating user intent must settle exactly once")
	helpers.assert_eq(results[1].ok, expected_ok)
	helpers.assert_eq(calls.phase, "active")
	helpers.assert_eq(calls.status_token, replacement.token)
	return replacement
end


--- Activates the fixture's initial generation and returns its exact token.
--- @param remap table Real remap orchestrator under test.
--- @param calls table Harness observations and drivers.
--- @return string token
local function activate_initial_generation(remap, calls)
	helpers.assert_true(remap.regenerate())
	helpers.assert_eq(calls.guardian_probe_calls, 1,
		"bundled regeneration must cross one fresh guardian-ready proof")
	local initial = calls.builds[#calls.builds]
	helpers.assert_type(initial, "table")
	helpers.assert_true(calls.deliver_all_ready(initial.token))
	helpers.assert_true(calls.deliver_resumed(initial.token))
	helpers.assert_eq(calls.phase, "active")
	return initial.token
end


--- Completes one background safety recovery with a fresh exact token.
--- @param calls table Harness observations and drivers.
--- @param stale_token string Token fenced by the failed maintenance attempt.
--- @param expected_layout string Layout that the replacement must consume.
--- @return table replacement Fresh build descriptor.
local function complete_failure_recovery(calls, stale_token, expected_layout)
	local started = calls.drain_until(function()
		return calls.phase == "starting" and calls.current_token ~= stale_token
	end)
	helpers.assert_true(started,
		"a proven failure fence must launch one bounded fresh-token recovery")
	local replacement = calls.builds[#calls.builds]
	helpers.assert_type(replacement, "table")
	helpers.assert_true(replacement.token ~= stale_token,
		"failure recovery must never reuse the fenced generation")
	helpers.assert_eq(replacement.layout, expected_layout,
		"failure recovery must build from the current settled layout")
	helpers.assert_true(calls.deliver_all_ready(replacement.token))
	helpers.assert_true(calls.deliver_resumed(replacement.token))
	helpers.assert_eq(calls.phase, "active")
	helpers.assert_eq(calls.status_token, replacement.token)
	local build_count = #calls.builds
	local token_index = calls.token_index
	for _ = 1, 20 do
		if not calls.fire_next_async_timer() then break end
	end
	calls.force_stale_successes()
	helpers.assert_eq(#calls.builds, build_count,
		"stale layout/fence callbacks must not launch a duplicate recovery")
	helpers.assert_eq(calls.token_index, token_index,
		"one proven fence must allocate exactly one replacement token")
	helpers.assert_eq(calls.phase, "active")
	return replacement
end


--- Drives an event arriving after build but before READY.
--- @param calls table Harness observations and drivers.
--- @param results table Public callback results.
--- @param expected_ok boolean Expected final public result.
--- @return table replacement Fresh build descriptor.
local function race_before_ready(calls, results, expected_ok)
	helpers.assert_true(#calls.builds >= 1, "the activation must build layout A before the race")
	local stale = calls.builds[#calls.builds]
	helpers.assert_eq(stale.layout, "layout-a")
	calls.change_layout("layout-b")

	-- A correct implementation may fence immediately at notification time or at
	-- READY. Drive READY only when the old worker still owns that boundary.
	if calls.phase == "starting" then
		helpers.assert_true(calls.deliver_ready(stale.token),
			"the stale worker must retain its READY callback until fenced")
	end
	helpers.assert_eq(count_value(calls.resume_tokens, stale.token), 0,
		"layout A must never receive RESUME after layout B was observed")
	helpers.assert_true(contains(calls.stop_exact_tokens, stale.token),
		"the exact layout-A token must be fenced before retry")
	helpers.assert_eq(#results, 0,
		"fencing an internal stale attempt must not fail the originating user intent")
	calls.force_stale_successes()
	helpers.assert_eq(#results, 0,
		"a forced late callback from token A must remain unable to settle the intent")
	return complete_replacement(calls, stale.token, "layout-b", results, expected_ok)
end





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





-- ====================================================================
-- ====================================================================
-- ======= 2/ Failure-Driven ACTIVE Lease Recovery After Layout =======
-- ====================================================================
-- ====================================================================

helpers.describe("Karabiner active layout maintenance failure recovery", function()
	helpers.it("settles public regeneration fail-closed when pause state raises", function()
		with_remap({ enabled = true, paused = false, initial_phase = "prepared" },
			function(remap, calls)
				local results = {}
				calls.pause_queries_until_failure = 1

				local call_ok, accepted = pcall(remap.regenerate, function(ok, reason)
					results[#results + 1] = { ok = ok, reason = reason }
				end)

				helpers.assert_true(call_ok,
					"a public regeneration must contain a pause-state exception")
				helpers.assert_true(accepted == false,
					"unavailable pause state must reject regeneration fail-closed")
				helpers.assert_eq(#results, 1,
					"the public callback must settle exactly once")
				helpers.assert_true(results[1].ok == false)
				helpers.assert_eq(results[1].reason, "pause-state-unavailable")
				helpers.assert_eq(#calls.builds, 0,
					"unknown pause intent must block config generation")
				helpers.assert_eq(#calls.deploy_tokens, 0,
					"unknown pause intent must block config publication")
				helpers.assert_eq(calls.classifier_refreshes, 0,
					"unknown pause intent must not mount lease-bound input state")
			end)
	end)

	helpers.it("fences stale layout rules when regeneration rejects unavailable pause state", function()
		with_remap({ enabled = true, paused = false, initial_phase = "prepared" },
			function(remap, calls)
				local stale_token = activate_initial_generation(remap, calls)
				calls.builds = {}
				calls.deploy_tokens = {}
				calls.stop_exact_tokens = {}
				-- The settled pipeline consumes the first query. The strict public
				-- API contains the second failure and settles its callback false.
				calls.pause_queries_until_failure = 2

				calls.change_layout("layout-b")
				helpers.assert_true(calls.fire_next_async_timer())
				helpers.assert_eq(#calls.builds, 0,
					"the unavailable pause state must reject before generation")
				helpers.assert_eq(#calls.deploy_tokens, 0)
				helpers.assert_eq(count_value(calls.stop_exact_tokens, stale_token), 1,
					"the callback failure branch must fence old-layout ACTIVE rules")

				local replacement = complete_failure_recovery(
					calls, stale_token, "layout-b"
				)
				helpers.assert_eq(#calls.builds, 1)
				helpers.assert_eq(#calls.deploy_tokens, 1)
				helpers.assert_eq(calls.deploy_tokens[1], replacement.token)
			end)
	end)

	helpers.it("fences stale layout rules when regeneration raises before its callback", function()
		with_remap({ enabled = true, paused = false, initial_phase = "prepared" },
			function(remap, calls)
				local stale_token = activate_initial_generation(remap, calls)
				calls.builds = {}
				calls.deploy_tokens = {}
				calls.stop_exact_tokens = {}
				local real_regenerate = remap.regenerate
				local raise_before_callback = true
				remap.regenerate = function(...)
					if raise_before_callback then
						raise_before_callback = false
						error("synthetic public regeneration boundary failure")
					end
					return real_regenerate(...)
				end

				calls.change_layout("layout-b")
				helpers.assert_true(calls.fire_next_async_timer())
				helpers.assert_eq(#calls.builds, 0,
					"the injected public-boundary exception must happen before generation")
				helpers.assert_eq(#calls.deploy_tokens, 0)
				helpers.assert_eq(count_value(calls.stop_exact_tokens, stale_token), 1,
					"the no-callback exception branch must fence old-layout ACTIVE rules")

				local replacement = complete_failure_recovery(
					calls, stale_token, "layout-b"
				)
				helpers.assert_eq(#calls.builds, 1)
				helpers.assert_eq(#calls.deploy_tokens, 1)
				helpers.assert_eq(calls.deploy_tokens[1], replacement.token)
			end)
	end)

	for _, mode in ipairs({ "false", "throw" }) do
		helpers.it("fences and replaces stale layout rules after generation " .. mode, function()
			with_remap({ enabled = true, paused = false, initial_phase = "prepared" },
				function(remap, calls)
					local stale_token = activate_initial_generation(remap, calls)
					calls.builds = {}
					calls.deploy_tokens = {}
					calls.stop_exact_tokens = {}
					calls.next_build_failure = mode

					calls.change_layout("layout-b")
					helpers.assert_true(calls.fire_next_async_timer(),
						"the post-TIS layout maintenance callback must run")
					helpers.assert_eq(#calls.builds, 1,
						"the injected failure must occur on the first layout-B build")
					helpers.assert_eq(calls.builds[1].layout, "layout-b")
					helpers.assert_eq(#calls.deploy_tokens, 0,
						"a generation failure must happen before config publication")
					helpers.assert_eq(count_value(calls.stop_exact_tokens, stale_token), 1,
						"old-layout ACTIVE rules must be exact-fenced after generation failure")

					local replacement = complete_failure_recovery(
						calls, stale_token, "layout-b"
					)
					helpers.assert_eq(#calls.builds, 2,
						"one failed build must produce exactly one fresh replacement build")
					helpers.assert_eq(#calls.deploy_tokens, 1)
					helpers.assert_eq(calls.deploy_tokens[1], replacement.token)
				end)
		end)

		helpers.it("recovers a clean IDLE fence after deploy " .. mode, function()
			with_remap({ enabled = true, paused = false, initial_phase = "prepared" },
				function(remap, calls)
					local stale_token = activate_initial_generation(remap, calls)
					calls.builds = {}
					calls.deploy_tokens = {}
					calls.stop_exact_tokens = {}
					calls.next_deploy_failure = mode

					calls.change_layout("layout-b")
					helpers.assert_true(calls.fire_next_async_timer())
					helpers.assert_eq(calls.phase, "idle",
						"the fixture must publish the clean STOPPED path that used to lose ownership")
					helpers.assert_eq(calls.current_token, nil)
					helpers.assert_eq(count_value(calls.stop_exact_tokens, stale_token), 1)

					local replacement = complete_failure_recovery(
						calls, stale_token, "layout-b"
					)
					helpers.assert_eq(#calls.builds, 2)
					helpers.assert_eq(#calls.deploy_tokens, 2,
						"the ambiguous attempt and one replacement are the only publications")
					helpers.assert_eq(calls.deploy_tokens[1], stale_token)
					helpers.assert_eq(calls.deploy_tokens[2], replacement.token)
				end)
		end)
	end

	helpers.it("waits for the exact STOPPED callback before recovering a failed deploy", function()
		with_remap({
			enabled = true,
			paused = false,
			initial_phase = "prepared",
			defer_exact_stop = true,
		}, function(remap, calls)
			local stale_token = activate_initial_generation(remap, calls)
			calls.builds = {}
			calls.deploy_tokens = {}
			calls.stop_exact_tokens = {}
			calls.next_deploy_failure = "false"

			calls.change_layout("layout-b")
			helpers.assert_true(calls.fire_next_async_timer())
			helpers.assert_eq(calls.phase, "stopping")
			for _ = 1, 5 do
				if not calls.fire_next_async_timer() then break end
			end
			helpers.assert_eq(calls.token_index, 1,
				"accepted STOPPING is not proof that a fresh token is safe to allocate")
			helpers.assert_eq(#calls.builds, 1)

			local duplicate_completion = calls.exact_stop_deferred.callback
			calls.deliver_exact_stopped()
			duplicate_completion(true, "duplicate-stopped")
			complete_failure_recovery(calls, stale_token, "layout-b")
		end)
	end)

	helpers.it("coalesces a newer layout before the failed generation reaches STOPPED", function()
		with_remap({
			enabled = true,
			paused = false,
			initial_phase = "prepared",
			defer_exact_stop = true,
		}, function(remap, calls)
			local stale_token = activate_initial_generation(remap, calls)
			calls.builds = {}
			calls.deploy_tokens = {}
			calls.stop_exact_tokens = {}
			calls.next_deploy_failure = "false"

			calls.change_layout("layout-b")
			helpers.assert_true(calls.fire_next_async_timer())
			helpers.assert_eq(calls.phase, "stopping")
			calls.change_layout("layout-c")
			calls.deliver_exact_stopped()

			local replacement = complete_failure_recovery(calls, stale_token, "layout-c")
			helpers.assert_eq(#calls.builds, 2,
				"the failed B attempt and successful C replacement are the only builds")
			helpers.assert_eq(calls.builds[1].layout, "layout-b")
			helpers.assert_eq(calls.builds[2].layout, "layout-c")
			helpers.assert_eq(calls.deploy_tokens[#calls.deploy_tokens], replacement.token)
		end)
	end)

	helpers.it("lets a newer Pause cancel recovery before the exact fence completes", function()
		with_remap({
			enabled = true,
			paused = false,
			initial_phase = "prepared",
			defer_exact_stop = true,
		}, function(remap, calls)
			local stale_token = activate_initial_generation(remap, calls)
			calls.builds = {}
			calls.deploy_tokens = {}
			calls.next_deploy_failure = "false"

			calls.change_layout("layout-b")
			helpers.assert_true(calls.fire_next_async_timer())
			helpers.assert_eq(calls.phase, "stopping")
			-- script_control commits this state only after its joined native fence;
			-- setting it before completion models the authoritative newer intent.
			calls.script_paused = true
			calls.deliver_exact_stopped()
			for _ = 1, 20 do
				if not calls.fire_next_async_timer() then break end
			end
			helpers.assert_eq(calls.token_index, 1,
				"a late failure callback must not override the newer Pause intent")
			helpers.assert_eq(#calls.builds, 1)
			helpers.assert_eq(calls.phase, "idle")
		end)
	end)

	helpers.it("lets an explicit menu Stop defeat a pending failure recovery", function()
		with_remap({
			enabled = true,
			paused = false,
			initial_phase = "prepared",
			defer_exact_stop = true,
		}, function(remap, calls)
			activate_initial_generation(remap, calls)
			calls.builds = {}
			calls.deploy_tokens = {}
			calls.next_deploy_failure = "false"

			calls.change_layout("layout-b")
			helpers.assert_true(calls.fire_next_async_timer())
			helpers.assert_eq(calls.phase, "stopping")
			local stop_results = {}
			helpers.assert_true(remap.stop_lease(function(ok, reason)
				stop_results[#stop_results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_eq(#stop_results, 0,
				"explicit Stop must join rather than outrun the existing exact fence")

			calls.deliver_exact_stopped()
			helpers.assert_eq(#stop_results, 1)
			helpers.assert_true(stop_results[1].ok)
			for _ = 1, 20 do
				if not calls.fire_next_async_timer() then break end
			end
			helpers.assert_eq(calls.token_index, 1,
				"a late failure callback must not undo the user's explicit Stop")
			helpers.assert_eq(#calls.builds, 1)
			helpers.assert_eq(calls.phase, "idle")
		end)
	end)

	helpers.it("cancels an armed failure-recovery timer on explicit menu Stop", function()
		with_remap({ enabled = true, paused = false, initial_phase = "prepared" },
			function(remap, calls)
				activate_initial_generation(remap, calls)
				calls.builds = {}
				calls.deploy_tokens = {}
				calls.next_deploy_failure = "false"

				calls.change_layout("layout-b")
				helpers.assert_true(calls.fire_next_async_timer())
				helpers.assert_eq(calls.phase, "idle")
				helpers.assert_true(calls.fire_next_async_timer(),
					"the inactive layout replay must consume B and arm recovery")
				helpers.assert_eq(calls.token_index, 1,
					"the recovery delay must not allocate a token yet")

				local stop_results = {}
				helpers.assert_true(remap.stop_lease(function(ok, reason)
					stop_results[#stop_results + 1] = { ok = ok, reason = reason }
				end))
				helpers.assert_eq(#stop_results, 1)
				helpers.assert_true(stop_results[1].ok)
				for _ = 1, 20 do
					if not calls.fire_next_async_timer() then break end
				end
				helpers.assert_eq(calls.token_index, 1,
					"explicit Stop must cancel an already-armed background recovery")
				helpers.assert_eq(#calls.builds, 1)
				helpers.assert_eq(calls.phase, "idle")
			end)
	end)

	helpers.it("epoch-fences a failure callback after explicit revocation", function()
		with_remap({
			enabled = true,
			paused = false,
			initial_phase = "prepared",
			defer_exact_stop = true,
		}, function(remap, calls)
			activate_initial_generation(remap, calls)
			calls.builds = {}
			calls.deploy_tokens = {}
			calls.next_deploy_failure = "false"

			calls.change_layout("layout-b")
			helpers.assert_true(calls.fire_next_async_timer())
			helpers.assert_eq(calls.phase, "stopping")
			local revoke_results = {}
			helpers.assert_true(remap.revoke("test-explicit-revoke", function(ok, reason)
				revoke_results[#revoke_results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_eq(#revoke_results, 0,
				"revocation must join rather than outrun the existing exact fence")

			calls.deliver_exact_stopped()
			helpers.assert_eq(#revoke_results, 1)
			helpers.assert_true(revoke_results[1].ok)
			for _ = 1, 20 do
				if not calls.fire_next_async_timer() then break end
			end
			helpers.assert_eq(calls.token_index, 1,
				"a pre-revocation failure callback must be inert in the newer lifecycle")
			helpers.assert_eq(#calls.builds, 1)
			helpers.assert_eq(calls.phase, "idle")
		end)
	end)

	helpers.it("keeps a failed public deploy separate from its safety recovery", function()
		with_remap({ enabled = true, paused = false, initial_phase = "prepared" },
			function(remap, calls)
				local stale_token = activate_initial_generation(remap, calls)
				calls.builds = {}
				calls.deploy_tokens = {}
				calls.stop_exact_tokens = {}
				calls.next_deploy_failure = "false"
				local results = {}

				remap.regenerate(function(ok, reason)
					results[#results + 1] = { ok = ok, reason = reason }
				end)
				helpers.assert_eq(#results, 1)
				helpers.assert_true(results[1].ok == false)
				helpers.assert_eq(results[1].reason, "deploy-failed")
				helpers.assert_eq(count_value(calls.stop_exact_tokens, stale_token), 1)

				complete_failure_recovery(calls, stale_token, "layout-a")
				helpers.assert_eq(#results, 1,
					"background recovery must never rewrite the failed public result")
				helpers.assert_true(results[1].ok == false)
			end)
	end)

	for _, mode in ipairs({ "false", "throw" }) do
		helpers.it("recovers an ACTIVE classifier " .. mode .. " outside layout maintenance",
			function()
				with_remap({ enabled = true, paused = false, initial_phase = "prepared" },
					function(remap, calls)
						local stale_token = activate_initial_generation(remap, calls)
						calls.builds = {}
						calls.deploy_tokens = {}
						calls.stop_exact_tokens = {}
						calls.next_classifier_failure = mode
						local results = {}

						remap.regenerate(function(ok, reason)
							results[#results + 1] = { ok = ok, reason = reason }
						end)
						helpers.assert_eq(#results, 1)
						helpers.assert_true(results[1].ok == false,
							"the failed public operation must remain honestly failed")
						helpers.assert_eq(results[1].reason, "lease-input-start-failed")
						helpers.assert_eq(count_value(calls.stop_exact_tokens, stale_token), 1)
						helpers.assert_eq(calls.phase, "idle")

						local replacement = complete_failure_recovery(
							calls, stale_token, "layout-a"
						)
						helpers.assert_eq(#results, 1,
							"background safety recovery must not resettle the failed public callback")
						helpers.assert_true(results[1].ok == false)
						helpers.assert_eq(#calls.builds, 2)
						helpers.assert_eq(calls.deploy_tokens[#calls.deploy_tokens], replacement.token)
					end)
			end)
	end
end)
