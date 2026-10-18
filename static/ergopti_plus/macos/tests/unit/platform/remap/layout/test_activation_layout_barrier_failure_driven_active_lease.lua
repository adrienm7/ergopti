--- tests/unit/platform/remap/layout/test_activation_layout_barrier_failure_driven_active_lease.lua

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
local activate_initial_generation = Fixture.activate_initial_generation
local complete_failure_recovery = Fixture.complete_failure_recovery
local count_value = Fixture.count_value
local with_remap = Fixture.with_remap





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
