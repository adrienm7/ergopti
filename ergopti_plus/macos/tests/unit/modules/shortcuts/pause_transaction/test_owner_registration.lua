--- tests/unit/modules/shortcuts/pause_transaction/test_owner_registration.lua

--- ==============================================================================
--- MODULE: Script-Control Owner Registration Tests
--- DESCRIPTION:
--- Exercises transaction ownership through the shared isolated pause fixture.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_context = require("tests.support.pause_transaction_fixture").with_context
local Assertions = require("tests.support.pause_transaction_assertions")
local count_notifications = Assertions.count_notifications

helpers.describe("script-control resume transaction is atomic", function()
	helpers.it("tracks a late pause-owner registration whose inverse also refuses", function()
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			with_context({ no_integration = true }, function(script_control)
				helpers.assert_true(script_control.pause_all())
				local pause_mode = mode
				local resume_mode = mode
				local pause_calls = 0
				local resume_calls = 0
				local function result_for(current, label)
					if current == "throw" then error(label .. " exploded") end
					if current == "false" then return false end
					if current == "nil" then return nil end
					return true
				end
				local owner = {
					pause = function()
						pause_calls = pause_calls + 1
						return result_for(pause_mode, "late owner pause")
					end,
					resume = function()
						resume_calls = resume_calls + 1
						return result_for(resume_mode, "late owner resume")
					end,
				}

				helpers.assert_true(script_control.register_pause_owner("llm_activation", owner),
					"failed registration rollback must remain globally owned")
				helpers.assert_eq(pause_calls, 1)
				helpers.assert_eq(resume_calls, 1)
				helpers.assert_true(script_control.is_pause_transition_pending())
				helpers.assert_eq(script_control.pause_all(), false)
				helpers.assert_eq(pause_calls, 2)
				helpers.assert_eq(resume_calls, 1,
					"same-state debt retry may not activate the late owner")

				pause_mode = "true"
				helpers.assert_true(script_control.pause_all())
				helpers.assert_eq(pause_calls, 3)
				helpers.assert_eq(script_control.is_pause_transition_pending(), false)
				resume_mode = "true"
				helpers.assert_true(script_control.resume_all())
				helpers.assert_eq(resume_calls, 2)
				helpers.assert_eq(script_control.is_paused(), false)
				helpers.assert_true(script_control.stop())
			end)
		end
	end)

	helpers.it("rejects a PAUSE snapshot when a callback registers a new owner", function()
		with_context({ no_integration = true }, function(script_control, ctx)
			local active = true
			local pause_calls = 0
			local resume_calls = 0
			local owner = {
				pause = function()
					pause_calls = pause_calls + 1
					active = false
					return true
				end,
				resume = function()
					resume_calls = resume_calls + 1
					active = true
					return true
				end,
			}
			ctx.hooks.keymap_pause = function()
				ctx.hooks.keymap_pause = nil
				helpers.assert_true(script_control.register_pause_owner("llm_activation", owner))
			end

			helpers.assert_true(script_control.pause_all(),
				"the public request reports accepted input-drain ownership")
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_eq(count_notifications(ctx, "script_control.pause_failed", "error"), 1,
				"the synchronously refused local commit must still be reported")
			helpers.assert_eq(pause_calls, 0,
				"registration while still ACTIVE must not pretend the new owner was paused")
			helpers.assert_eq(resume_calls, 0)
			helpers.assert_eq(active, true)
			helpers.assert_eq(ctx.calls.keymap_pause, 1)
			helpers.assert_eq(ctx.calls.keymap_resume, 1,
				"the stale PAUSE snapshot must roll its exact applied mutation back")

			helpers.assert_true(script_control.pause_all(),
				"the next PAUSE must inventory and quiesce the retained owner")
			helpers.assert_eq(script_control.is_paused(), true)
			helpers.assert_eq(pause_calls, 1)
			helpers.assert_eq(active, false)
			helpers.assert_true(script_control.resume_all())
			helpers.assert_eq(resume_calls, 1)
			helpers.assert_eq(active, true)
			helpers.assert_true(script_control.stop())
		end)
	end)

	helpers.it("rejects a RESUME snapshot when a callback registers a paused owner", function()
		with_context({ no_integration = true }, function(script_control, ctx)
			helpers.assert_true(script_control.pause_all())
			local active = true
			local pause_calls = 0
			local resume_calls = 0
			local owner = {
				pause = function()
					pause_calls = pause_calls + 1
					active = false
					return true
				end,
				resume = function()
					resume_calls = resume_calls + 1
					active = true
					return true
				end,
			}
			ctx.hooks.keymap_resume = function()
				ctx.hooks.keymap_resume = nil
				helpers.assert_true(script_control.register_pause_owner("llm_activation", owner))
			end

			helpers.assert_eq(script_control.resume_all(), false,
				"a RESUME may not clear a ledger that grew inside an owner callback")
			helpers.assert_eq(script_control.is_paused(), true)
			helpers.assert_eq(pause_calls, 1,
				"registration under PAUSED must quiesce the new owner immediately")
			helpers.assert_eq(resume_calls, 0,
				"the omitted owner may not be activated by the stale snapshot")
			helpers.assert_eq(active, false)
			helpers.assert_eq(ctx.calls.keymap_resume, 1)
			helpers.assert_eq(ctx.calls.keymap_pause, 2,
				"the already applied resume step must be rolled back exactly")

			helpers.assert_true(script_control.resume_all(),
				"the next RESUME must include the newly appended owner")
			helpers.assert_eq(resume_calls, 1)
			helpers.assert_eq(active, true)
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_true(script_control.stop())
		end)
	end)

	helpers.it("retains every resumed owner when admission and exact re-pause refuse", function()
		for _, release_mode in ipairs({ "false", "throw" }) do
			for _, pause_mode in ipairs({ "false", "nil", "throw" }) do
				local options = release_mode == "false"
					and { admission_release_failures = 1 }
					or { admission_release_throws = 1 }
				with_context(options, function(script_control, ctx)
					helpers.assert_true(script_control.pause_all())
					ctx.fire_deferred()
					ctx.pause_callbacks[1](true, "paused")
					local exact_fence = ctx.admission_fence

					ctx.pause_failure = { step = "shortcuts_pause", mode = pause_mode }
					helpers.assert_true(script_control.resume_all())
					ctx.fire_deferred()
					ctx.resume_callbacks[1](true, "native-resumed")
					helpers.assert_eq(script_control.is_paused(), true)
					helpers.assert_true(script_control.is_pause_transition_pending(),
						"native rollback and local re-pause debt must remain observable")
					helpers.assert_true(ctx.admission_fence == exact_fence)
					helpers.assert_eq(ctx.calls.shortcuts_pause, 2,
						"fallback must target the same owner that committed the original PAUSE")
					helpers.assert_eq(ctx.calls.shortcuts_resume, 1,
						"re-pause debt may not reacquire an activation successor")
					helpers.assert_eq(ctx.calls.karabiner_pause, 2)

					ctx.pause_callbacks[2](true, "native-repaused")
					helpers.assert_true(script_control.is_pause_transition_pending(),
						"terminal native re-pause may not consume unresolved local ownership")
					helpers.assert_eq(script_control.pause_all(), false,
						"same-state PAUSE must retry the retained owner without a successor")
					helpers.assert_eq(ctx.calls.shortcuts_pause, 3)
					helpers.assert_eq(ctx.calls.shortcuts_resume, 1)
					helpers.assert_eq(ctx.calls.karabiner_pause, 2,
						"local debt recovery must not publish a redundant native request")

					ctx.pause_failure = nil
					helpers.assert_true(script_control.pause_all())
					helpers.assert_eq(ctx.calls.shortcuts_pause, 4)
					helpers.assert_eq(script_control.is_pause_transition_pending(), false)
					helpers.assert_true(script_control.resume_all())
					ctx.fire_deferred()
					ctx.resume_callbacks[2](true, "retry-resumed")
					helpers.assert_eq(script_control.is_paused(), false)
					helpers.assert_nil(ctx.admission_fence)
					helpers.assert_true(ctx.admission_release_tokens[1] == exact_fence)
					helpers.assert_true(ctx.admission_release_tokens[2] == exact_fence)
					helpers.assert_true(script_control.stop())
				end)
			end
		end
	end)

end)
