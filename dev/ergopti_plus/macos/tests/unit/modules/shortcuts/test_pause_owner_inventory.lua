--- tests/unit/modules/shortcuts/test_pause_owner_inventory.lua

--- ==============================================================================
--- MODULE: Pause Owner inventory Regressions
--- DESCRIPTION:
--- Preserves the behavioral pause-owner regression scenarios with a focused
--- fixture boundary. Shared fixtures create fresh runtime state per invocation.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixtures = require("tests.unit.modules.shortcuts.pause_owners.fixtures")
local OWNER_IDS = fixtures.OWNER_IDS
local REVERSIBLE_OWNER_IDS = fixtures.REVERSIBLE_OWNER_IDS
local load_inventory_context = fixtures.load_inventory_context

helpers.describe("HS-012 pause-owner class-wide settlement matrix", function()
	helpers.it("reports synthetic drain and native rollback from the exact transition owner", function()
		local pending_drain = nil
		local script_control = load_inventory_context({
			when_idle = function(callback)
				pending_drain = callback
				return true
			end,
		})
		helpers.assert_eq(script_control.is_pause_transition_pending(), false)
		helpers.assert_true(script_control.pause_all())
		helpers.assert_true(script_control.is_pause_transition_pending(),
			"synthetic-input drain must own the unpublished pause boundary")
		helpers.assert_not_nil(pending_drain)
		pending_drain()
		helpers.assert_eq(script_control.is_pause_transition_pending(), false)
		helpers.assert_true(script_control.is_paused())
		helpers.assert_true(script_control.resume_all())
		script_control.stop()

		local native_callbacks = { pause = {}, resume = {} }
		local karabiner = {
			get_enabled = function() return true end,
			pause = function(callback)
				native_callbacks.pause[#native_callbacks.pause + 1] = callback
				return true
			end,
			resume = function(callback)
				native_callbacks.resume[#native_callbacks.resume + 1] = callback
				return true
			end,
		}
		local native_control, ctx = load_inventory_context({ karabiner = karabiner })
		helpers.assert_true(native_control.pause_all())
		helpers.assert_true(native_control.is_pause_transition_pending(),
			"the scheduled native candidate must keep the transition owned")
		local pause_timer = _G.hs.timer.__timers[#_G.hs.timer.__timers]
		pause_timer:fire()
		helpers.assert_true(native_control.is_pause_transition_pending())
		helpers.assert_not_nil(native_callbacks.pause[1])
		native_callbacks.pause[1](true)
		helpers.assert_true(native_control.is_paused())
		helpers.assert_eq(native_control.is_pause_transition_pending(), false)

		ctx.fail_owner = "remote_warmup"
		ctx.fail_direction = "resume"
		ctx.fail_mode = "false"
		ctx.failures_left = 1
		helpers.assert_true(native_control.resume_all())
		local resume_timer = _G.hs.timer.__timers[#_G.hs.timer.__timers]
		resume_timer:fire()
		helpers.assert_not_nil(native_callbacks.resume[1])
		native_callbacks.resume[1](true)
		helpers.assert_true(native_control.is_pause_transition_pending(),
			"native re-pause rollback must retain the same transaction owner")
		helpers.assert_not_nil(native_callbacks.pause[2])
		native_callbacks.pause[2](true)
		helpers.assert_true(native_control.is_paused())
		helpers.assert_eq(native_control.is_pause_transition_pending(), false)
		native_control.stop()
	end)

	helpers.it("reports an admission fence retained after a failed pause rollback", function()
		local release_mode = "false"
		local script_control = load_inventory_context({
			fail_owner = "remote_warmup",
			fail_mode = "false",
			release_admission_fence = function(token, ctx)
				if release_mode ~= "true" then return false end
				token.active = false
				ctx.fence = nil
				return true
			end,
		})
		script_control.pause_all()
		helpers.assert_eq(script_control.is_paused(), false)
		helpers.assert_true(script_control.is_pause_transition_pending(),
			"a retained admission capability is exact unpublished transition debt")
		helpers.assert_true(script_control.pause_all(),
			"the next pause must reuse and commit the retained admission fence")
		helpers.assert_true(script_control.is_paused())
		helpers.assert_eq(script_control.is_pause_transition_pending(), false,
			"the same fence is stable ownership, not debt, after PAUSED commits")
		release_mode = "true"
		helpers.assert_true(script_control.resume_all())
		script_control.stop()
	end)

	helpers.it("exports the complete fixed owner inventory", function()
		local script_control, _ = load_inventory_context()
		helpers.assert_true(helpers.deep_equal(script_control.PAUSE_OWNER_IDS, OWNER_IDS),
			"the public inventory must enumerate every producer covered by pause")
		script_control.stop()
	end)

	helpers.it("selects the no-deferral prediction boundary for global pause", function()
		local generic_calls, pause_calls = 0, 0
		local script_control = load_inventory_context({
			keymap = {
				pause_processing = function() return true end,
				resume_processing = function() return true end,
				reset_predictions = function()
					generic_calls = generic_calls + 1
					return true
				end,
				reset_predictions_for_pause = function()
					pause_calls = pause_calls + 1
					return true
				end,
			},
		})
		helpers.assert_true(script_control.pause_all())
		helpers.assert_eq(pause_calls, 1)
		helpers.assert_eq(generic_calls, 0,
			"pause may not arm ordinary dismissal telemetry")
		helpers.assert_true(script_control.resume_all())
		script_control.stop()
	end)

	for _, owner in ipairs(OWNER_IDS) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it(owner .. " rejects " .. mode .. " settlement before PAUSED", function()
				local script_control, ctx = load_inventory_context({
					fail_owner = owner,
					fail_mode = mode,
				})
				ctx.fire_every_late_callback()
				for _, candidate in ipairs(OWNER_IDS) do
					helpers.assert_eq(ctx.late_effects[candidate], 1,
						"positive-control callback must be live before pause")
				end

				script_control.pause_all()
				helpers.assert_eq(script_control.is_paused(), false,
					mode .. " from " .. owner .. " must not publish PAUSED")
				helpers.assert_true(helpers.deep_equal(ctx.listeners, {}))
				ctx.fire_every_late_callback()
				local post_failure_counts = {}
				for _, candidate in ipairs(OWNER_IDS) do
					local expected = ctx.active[candidate] == true and 2 or 1
					helpers.assert_eq(ctx.late_effects[candidate], expected,
						"failed pause must either restore or keep the callback fenced deterministically")
					post_failure_counts[candidate] = expected
				end

				helpers.assert_true(script_control.pause_all(),
					"the exact owner must remain retryable after " .. mode)
				helpers.assert_true(script_control.is_paused())
				ctx.fire_every_late_callback()
				for _, candidate in ipairs(OWNER_IDS) do
					helpers.assert_eq(ctx.late_effects[candidate], post_failure_counts[candidate],
						"no owner callback may publish while PAUSED")
				end
				helpers.assert_true(script_control.resume_all())
				helpers.assert_eq(script_control.is_paused(), false)
				helpers.assert_true(helpers.deep_equal(ctx.listeners, { true, false }))
				script_control.stop()
			end)
		end
	end

	for _, owner in ipairs(REVERSIBLE_OWNER_IDS) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it(owner .. " rejects " .. mode .. " settlement before RESUMED", function()
				local script_control, ctx = load_inventory_context({
					fail_owner = owner,
					fail_mode = mode,
					fail_direction = "resume",
				})
				helpers.assert_true(script_control.pause_all())
				helpers.assert_true(script_control.is_paused())
				ctx.fire_every_late_callback()
				for _, candidate in ipairs(OWNER_IDS) do
					helpers.assert_eq(ctx.late_effects[candidate], 0,
						"positive paused control must fence every owner")
				end

				script_control.resume_all()
				helpers.assert_true(script_control.is_paused(),
					mode .. " from " .. owner .. " must not publish RESUMED")
				helpers.assert_true(helpers.deep_equal(ctx.listeners, { true }))
				ctx.fire_every_late_callback()
				for _, candidate in ipairs(OWNER_IDS) do
					helpers.assert_eq(ctx.late_effects[candidate], 0,
						"failed resume rollback must re-fence every mutated owner")
				end

				helpers.assert_true(script_control.resume_all(),
					"the exact activation owner must remain retryable after " .. mode)
				helpers.assert_eq(script_control.is_paused(), false)
				helpers.assert_true(helpers.deep_equal(ctx.listeners, { true, false }))
				script_control.stop()
			end)
		end
	end

	helpers.it("retains the real gesture fence when resume rollback cleanup refuses", function()
		local cleanup_calls = 0
		local function permissive(overrides)
			return setmetatable(overrides, {
				__index = function() return function() return true end end,
			})
		end
		package.loaded["modules.gestures.engine"] = permissive({
			unblock_scroll = function() return true end,
		})
		package.loaded["modules.gestures.actions"] = permissive({
			force_cleanup = function()
				cleanup_calls = cleanup_calls + 1
				return cleanup_calls ~= 2
			end,
		})
		package.loaded["modules.gestures"] = nil
		local real_gestures = helpers.load_with_stubs("modules.gestures")
		local script_control = load_inventory_context({
			gestures = real_gestures,
			fail_owner = "remote_warmup",
			fail_mode = "false",
			fail_direction = "resume",
		})
		helpers.assert_true(script_control.pause_all())
		helpers.assert_true(real_gestures.is_suspended())

		helpers.assert_eq(script_control.resume_all(), false)
		helpers.assert_true(script_control.is_paused())
		helpers.assert_true(real_gestures.is_suspended(),
			"a native cleanup refusal may not reopen gestures under PAUSED")
		helpers.assert_eq(cleanup_calls, 2,
			"positive control proves the rollback crossed the real cleanup boundary")

		helpers.assert_true(script_control.resume_all())
		helpers.assert_eq(real_gestures.is_suspended(), false)
		script_control.stop()
		package.loaded["modules.gestures"] = nil
		package.loaded["modules.gestures.engine"] = nil
		package.loaded["modules.gestures.actions"] = nil
	end)

	for _, owner in ipairs(OWNER_IDS) do
		helpers.it("does not resurrect inactive owner " .. owner, function()
			local script_control, ctx = load_inventory_context({ inactive_owner = owner })
			helpers.assert_true(script_control.pause_all())
			helpers.assert_true(script_control.resume_all())
			helpers.assert_eq(ctx.active[owner], false,
				"resume may only restore an owner that was active before pause")
			if owner == "wpm_menubar" or owner == "wpm_widget"
				or owner == "shortcut_bindings" then
				helpers.assert_eq(ctx.calls[owner].resume, 0,
					"snapshot-gated owner must not even receive a resume call")
			end
			script_control.stop()
		end)
	end

	helpers.it("carries a refused inverse across snapshot-gated pause retry", function()
		local script_control, ctx = load_inventory_context({
			fail_owner = "remote_warmup",
			fail_mode = "false",
			rollback_fail_owner = "shortcut_bindings",
			rollback_fail_mode = "false",
		})
		script_control.pause_all()
		helpers.assert_eq(script_control.is_paused(), false)
		helpers.assert_true(script_control.is_pause_transition_pending(),
			"a refused inverse must keep the exact transition debt observable")
		helpers.assert_eq(ctx.active.shortcut_bindings, false,
			"the refused inverse must leave the snapshot-gated owner visibly inactive")
		helpers.assert_true(script_control.pause_all(),
			"the retained inverse debt must rejoin the next pause inventory")
		helpers.assert_eq(script_control.is_pause_transition_pending(), false,
			"the debt query must clear only after its exact owner settles")
		helpers.assert_true(script_control.resume_all())
		helpers.assert_eq(ctx.active.shortcut_bindings, true,
			"the final committed resume must restore the original active intent")
		helpers.assert_eq(ctx.calls.shortcut_bindings.pause, 2,
			"retry must quiesce the exact retained owner even when its snapshot is false")
		helpers.assert_eq(ctx.calls.shortcut_bindings.resume, 2,
			"one refused rollback plus one final restore must both be observable")
		script_control.stop()
	end)

	helpers.it("preserves an unvisited rollback debt across three pause attempts", function()
		local script_control, ctx = load_inventory_context({
			fail_owner = "remote_warmup",
			fail_mode = "false",
			rollback_fail_owner = "shortcut_bindings",
			rollback_fail_mode = "false",
		})
		script_control.pause_all()
		helpers.assert_eq(ctx.active.shortcut_bindings, false)

		ctx.fail_owner = "keymap_processing"
		ctx.fail_mode = "false"
		ctx.fail_direction = "pause"
		ctx.failures_left = 1
		script_control.pause_all()
		helpers.assert_eq(script_control.is_paused(), false)
		helpers.assert_eq(ctx.calls.shortcut_bindings.pause, 1,
			"the earlier owner failure must occur before the retained shortcut debt")

		ctx.failures_left = 0
		helpers.assert_true(script_control.pause_all())
		helpers.assert_true(script_control.resume_all())
		helpers.assert_eq(ctx.active.shortcut_bindings, true,
			"an unvisited debt may only be consumed after its own exact settlement")
		helpers.assert_eq(ctx.calls.shortcut_bindings.pause, 2)
		helpers.assert_eq(ctx.calls.shortcut_bindings.resume, 2)
		script_control.stop()
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("compensates late owner registration after " .. mode, function()
			local script_control, ctx = load_inventory_context({
				skip_dynamic_owner = "llm_startup",
				inactive_owner = "llm_startup",
			})
			helpers.assert_true(script_control.pause_all())
			local pause_calls = 0
			local resume_calls = 0
			local active = true
			local registered = script_control.register_pause_owner("llm_startup", {
				pause = function()
					pause_calls = pause_calls + 1
					active = false
					if mode == "false" then return false end
					if mode == "nil" then return nil end
					error("late pause exploded")
				end,
				resume = function()
					resume_calls = resume_calls + 1
					active = true
					return true
				end,
			})
			helpers.assert_eq(registered, false)
			helpers.assert_eq(active, true,
				"failed late registration must run its inverse after mutation")
			helpers.assert_eq(pause_calls, 1)
			helpers.assert_eq(resume_calls, 1)
			helpers.assert_true(script_control.resume_all())
			helpers.assert_eq(resume_calls, 1,
				"a settled registration rollback must not leak into the resume ledger")
			script_control.stop()
		end)
	end

	helpers.it("retains late-registration inverse debt until a later resume", function()
		local script_control, _ = load_inventory_context({
			skip_dynamic_owner = "llm_startup",
			inactive_owner = "llm_startup",
		})
		helpers.assert_true(script_control.pause_all())
		local active = true
		local pause_calls = 0
		local resume_calls = 0
		local pause_settles = false
		helpers.assert_true(script_control.register_pause_owner("llm_startup", {
			pause = function()
				pause_calls = pause_calls + 1
				active = false
				return pause_settles
			end,
			resume = function()
				resume_calls = resume_calls + 1
				if resume_calls == 1 then return false end
				active = true
				return true
			end,
		}))
		helpers.assert_eq(active, false)
		helpers.assert_true(script_control.is_pause_transition_pending())
		helpers.assert_eq(script_control.resume_all(), false,
			"resume must first re-pause the exact owner whose registration inverse refused")
		helpers.assert_eq(pause_calls, 2)
		helpers.assert_eq(resume_calls, 1,
			"no activation successor may run over retained re-pause debt")

		pause_settles = true
		helpers.assert_true(script_control.resume_all())
		helpers.assert_eq(active, true)
		helpers.assert_eq(pause_calls, 3,
			"the settled retry must target the same retained pause owner")
		helpers.assert_eq(resume_calls, 2,
			"the exact late owner must remain in the resume ledger after refusal")
		script_control.stop()
	end)
end)
