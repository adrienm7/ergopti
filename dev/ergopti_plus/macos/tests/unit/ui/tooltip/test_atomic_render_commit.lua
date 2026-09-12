--- tests/unit/ui/tooltip/test_atomic_render_commit.lua

--- ==============================================================================
--- MODULE: Tooltip Atomic Render Commit Regression
--- DESCRIPTION:
--- Exercises real tooltip ownership while keeping native fixtures scoped per case.
--- ==============================================================================

local helpers = require("tests.helpers")
local support = require("tests.support.tooltip_watcher_fixture")
local with_fixture = support.with_fixture
local CASES = support.CASES
local running_timers = support.running_timers
local hardware_key_event = support.hardware_key_event
local hardware_mouse_event = support.hardware_mouse_event
local drain_deferred_actions = support.drain_deferred_actions

helpers.describe("tooltip rendering is committed atomically", function()
	for _, spec in ipairs(CASES) do
		helpers.it("(tooltip-watcher-reuse) " .. spec.label
			.. " closes logical and physical state when rendering throws", function()
			with_fixture(function(fixture)
				local context = fixture.load_tooltip(spec, { render_throw = true })
				local cancel_calls = 0
				if spec.label == "LLM" then
					context.tooltip.set_cancel_callback(function() cancel_calls = cancel_calls + 1; return true end)
				end

				local render_result = spec.render(context.tooltip)
				helpers.assert_eq(render_result, false,
					"a renderer exception must be reported to the caller")
				helpers.assert_true(not context.tooltip.is_visible(),
					"a renderer exception must clear logical visibility")
				helpers.assert_true(context.renderer.hide_calls >= 1,
					"a renderer exception must hide the physical canvas")
				helpers.assert_eq(#context.created, 0,
					"a renderer exception before commit must not create eventtaps")
				helpers.assert_eq(#running_timers(context.timers), 0,
					"a renderer exception before commit must not arm an idle timer")
				if spec.label == "LLM" then
					helpers.assert_eq(cancel_calls, 1,
						"an LLM renderer exception must release engine ownership exactly once")
				end
			end)
		end)

		helpers.it("(tooltip-watcher-reuse) " .. spec.label
			.. " fail-closes an unexpected watcher callback crash", function()
			with_fixture(function(fixture)
				local context = fixture.load_tooltip(spec)
				local cancel_calls = 0
				if spec.label == "LLM" then
					context.tooltip.set_cancel_callback(function() cancel_calls = cancel_calls + 1; return true end)
				end
				local saved_event_types = hs.eventtap.event.types
				hs.eventtap.event.types = nil
				local call_ok, render_result = pcall(spec.render, context.tooltip)
				hs.eventtap.event.types = saved_event_types

				helpers.assert_true(call_ok,
					"watcher setup exceptions must not escape the renderer boundary")
				helpers.assert_eq(render_result, false,
					"watcher setup exceptions must be reported to the caller")
				helpers.assert_true(not context.tooltip.is_visible(),
					"watcher setup exceptions must clear logical visibility")
				helpers.assert_true(context.renderer.hide_calls >= 1,
					"watcher setup exceptions must hide the physical canvas")
				helpers.assert_eq(#running_timers(context.timers), 0,
					"watcher setup exceptions must revoke the already-armed idle deadline")
				if spec.label == "LLM" then
					helpers.assert_eq(cancel_calls, 1,
						"watcher setup exceptions must cancel LLM ownership exactly once")
				end
			end)
		end)
	end

	helpers.it("(tooltip-watcher-reuse) a failed LLM refresh cannot expose new state behind old pixels", function()
		with_fixture(function(fixture)
			local context = fixture.load_tooltip(CASES[1])
			local cancel_calls = 0
			context.tooltip.set_cancel_callback(function() cancel_calls = cancel_calls + 1; return true end)
			helpers.assert_eq(context.tooltip.show_predictions({ "old" }, 1, true), true)
			context.renderer.render = function() error("simulated streaming repaint failure") end

			local refresh_result = context.tooltip.show_predictions({ "unseen new text" }, 1, true)
			helpers.assert_eq(refresh_result, false,
				"a failed streaming repaint must report failure")
			helpers.assert_true(not context.tooltip.is_visible(),
				"old pixels must not remain actionable after a failed refresh")
			helpers.assert_eq(cancel_calls, 1,
				"a failed refresh must release prediction-engine ownership")
			for _, watcher in ipairs(context.created) do
				helpers.assert_true(not watcher:isEnabled(),
					"a failed refresh must tear down the prior dismissal set")
			end
			helpers.assert_eq(#running_timers(context.timers), 0,
				"a failed refresh must cancel the prior idle deadline")
		end)
	end)

	helpers.it("(tooltip-watcher-reuse) failed LLM navigation cannot diverge selection from pixels", function()
		with_fixture(function(fixture)
			local context = fixture.load_tooltip(CASES[1])
			local cancel_calls = 0
			context.tooltip.set_cancel_callback(function() cancel_calls = cancel_calls + 1; return true end)
			helpers.assert_eq(context.tooltip.show_predictions({ "first", "second" }, 1, true), true)
			context.renderer.render = function() error("simulated navigation repaint failure") end

			local navigate_result = context.tooltip.navigate(1)
			helpers.assert_eq(navigate_result, false,
				"a failed navigation repaint must report failure")
			helpers.assert_true(not context.tooltip.is_visible(),
				"a failed navigation repaint must close the stale selection UI")
			helpers.assert_eq(context.tooltip.get_current_index(), 1,
				"fail-close must reset the unseen logical selection")
			helpers.assert_eq(cancel_calls, 1,
				"failed navigation must release engine ownership exactly once")
		end)
	end)

	helpers.it("(tooltip-watcher-reuse) loading paint reports disabled, empty, and renderer failures", function()
		with_fixture(function(fixture)
			local context = fixture.load_tooltip(CASES[2])
			helpers.assert_eq(context.tooltip.show_loading("loading", false), false,
				"a disabled loading indicator must not report a successful paint")
			helpers.assert_eq(context.tooltip.show_loading("", true), false,
				"an empty loading indicator must not report a successful paint")
			context.renderer.render = function() error("simulated loading repaint failure") end
			helpers.assert_eq(context.tooltip.show_loading("loading", true), false,
				"a loading renderer exception must be reported")
			helpers.assert_true(not context.tooltip.is_visible(),
				"a failed loading paint must clear logical visibility")
			helpers.assert_true(context.renderer.hide_calls >= 1,
				"a failed loading paint must hide the physical canvas")

			local swallowed = fixture.load_tooltip(CASES[2], { render_skip_callback = true })
			helpers.assert_eq(swallowed.tooltip.show_loading("loading", true), false,
				"a loading renderer that swallows failure must still report no commit")
			helpers.assert_true(not swallowed.tooltip.is_visible(),
				"swallowed loading failure must clear logical visibility")
		end)
	end)

	for _, spec in ipairs(CASES) do
		local tooltip_spec = spec
		helpers.it("(tooltip-native-commit-propagation) " .. tooltip_spec.label
			.. " rejects a renderer false even when its callback ran", function()
			with_fixture(function(fixture)
				local context = fixture.load_tooltip(tooltip_spec, { render_result = false })

				local render_result = tooltip_spec.render(context.tooltip)

				helpers.assert_eq(render_result, false,
					"owner success must require the renderer's strict commit result")
				helpers.assert_true(not context.tooltip.is_visible(),
					"a rejected native paint must not publish logical visibility")
				helpers.assert_true(context.renderer.hide_calls >= 1,
					"a callback that ran before a rejected commit must be torn down")
				for _, watcher in ipairs(context.created) do
					helpers.assert_true(not watcher:isEnabled(),
						"a rejected render must revoke every watcher it tentatively armed")
				end
			end)
		end)

		helpers.it("(tooltip-native-commit-propagation) " .. tooltip_spec.label
			.. " preserves logical ownership when native hide is refused", function()
			with_fixture(function(fixture)
				local faults = {}
				local context = fixture.load_tooltip(tooltip_spec, faults)
				helpers.assert_eq(tooltip_spec.render(context.tooltip), true)
				faults.hide_result = false

				local hidden = context.tooltip.hide()

				helpers.assert_eq(hidden, false,
					"native hide refusal must propagate to the public owner")
				helpers.assert_true(context.tooltip.is_visible(),
					"logical visibility must keep describing the still-visible canvas")
				helpers.assert_true(context.renderer.visible,
					"the fixture must prove the native canvas really refused the hide")

				faults.hide_result = true
				helpers.assert_eq(context.tooltip.hide(), true,
					"a later authoritative retry must be able to complete teardown")
				helpers.assert_true(not context.tooltip.is_visible())
			end)
		end)
	end

	helpers.it("(tooltip-native-commit-propagation) stacked native refusal cannot publish or clear hotstring visibility", function()
		with_fixture(function(fixture)
			local faults = { stacked_render_result = false }
			local context = fixture.load_tooltip(CASES[2], faults)

			helpers.assert_eq(context.tooltip.show_stacked({ { text = "preview" } }, true), false,
				"a stacked renderer false must reject the logical show")
			helpers.assert_true(not context.tooltip.is_visible())

			faults.stacked_render_result = true
			helpers.assert_eq(context.tooltip.show_stacked({ { text = "preview" } }, true), true)
			faults.hide_stacked_result = false
			helpers.assert_eq(context.tooltip.hide_forced(), false,
				"a stacked native hide refusal must propagate")
			helpers.assert_true(context.tooltip.is_visible(),
				"the owner must remain logically visible while stacked pixels remain")
			helpers.assert_true(context.renderer.stacked_visible)
		end)
	end)

	helpers.it("(tooltip-native-commit-propagation) LLM timing completion requires the native partial write", function()
		with_fixture(function(fixture)
			local faults = { partial_render_result = false }
			local context = fixture.load_tooltip(CASES[1], faults)

			helpers.assert_eq(context.tooltip.set_timing(10, 20), false,
				"a refused info-zone write must not report a timing commit")
			helpers.assert_eq(context.tooltip.set_chain_start(hs.timer.secondsSinceEpoch() - 1), true)
			helpers.assert_eq(context.tooltip.mark_chain_complete(), false,
				"chain completion must propagate the refused timing write")
			helpers.assert_eq(context.renderer.partial_render_calls, 2,
				"both public paths must reach the same strict renderer boundary")
		end)
	end)

	helpers.it("(tooltip-watcher-reuse) stale LLM acceptance cannot target a streaming repaint", function()
		with_fixture(function(fixture)
			local context = fixture.load_tooltip(CASES[1])
			local accepts = 0
			local synthetic = require("adapters.synthetic_input")
			local logger = require("infra.logger")
			local previous_error = logger.error
			local invalidation_logs = 0
			context.tooltip.set_accept_callback(function() accepts = accepts + 1; return true end)
			helpers.assert_eq(context.tooltip.show_predictions({ "visible A" }, 1, true), true)
			local key_watcher = context.created[CASES[1].watcher_count]
			helpers.assert_eq(key_watcher.fn(hardware_key_event(48, {}, "\t")), true,
				"positive control: visible A must own the physical Tab")
			helpers.assert_eq(synthetic.stats().pending_post_callback_actions, 1,
				"the A acceptance must really be queued before B repaints")

			helpers.assert_eq(context.tooltip.show_predictions({ "visible B" }, 1, true), true,
				"the streaming repaint must commit before the old deferred action drains")
			logger.error = function(component, format, ...)
				if component == "tooltip_llm"
					and tostring(format):find("Consumed input action", 1, true) then
					invalidation_logs = invalidation_logs + 1
				end
				return previous_error(component, format, ...)
			end
			local drained, drain_error = xpcall(function()
				drain_deferred_actions(context.timers)
			end, debug.traceback)
			logger.error = previous_error
			if not drained then error(drain_error, 0) end
			helpers.assert_eq(synthetic.stats().pending_post_callback_actions, 0,
				"the stale A action must be drained rather than left unexecuted")
			helpers.assert_eq(accepts, 0,
				"a Tab classified against A must not accept the B prediction pool")
			helpers.assert_eq(invalidation_logs, 1,
				"an unsafe stale key cannot disappear without an actionable diagnostic")
			helpers.assert_true(context.tooltip.is_visible(),
				"discarding stale A work must leave visible B intact")
		end)
	end)

	helpers.it("(tooltip-watcher-reuse) stale hotstring dismissal cannot hide a replacement", function()
		with_fixture(function(fixture)
			local context = fixture.load_tooltip(CASES[2])
			local synthetic = require("adapters.synthetic_input")
			helpers.assert_eq(context.tooltip.show("visible A", false, true), true)
			local key_watcher = context.created[CASES[2].watcher_count]
			helpers.assert_eq(key_watcher.fn(hardware_key_event(0, {}, "a")), false,
				"hotstring dismissal observes but never consumes the physical key")
			helpers.assert_eq(synthetic.stats().pending_post_callback_actions, 1,
				"the A dismissal must really be queued before B replaces it")

			helpers.assert_eq(context.tooltip.show("visible B", false, true), true,
				"the replacement must commit before the old deferred dismissal drains")
			drain_deferred_actions(context.timers)
			helpers.assert_eq(synthetic.stats().pending_post_callback_actions, 0,
				"the stale A dismissal must be drained rather than left unexecuted")
			helpers.assert_true(context.tooltip.is_visible(),
				"a dismissal classified against A must not hide visible B")
		end)
	end)

	helpers.it("(tooltip-watcher-reuse) same-generation deferred acceptance still executes", function()
		with_fixture(function(fixture)
			local context = fixture.load_tooltip(CASES[1])
			local accepts = 0
			local synthetic = require("adapters.synthetic_input")
			context.tooltip.set_accept_callback(function() accepts = accepts + 1; return true end)
			helpers.assert_eq(context.tooltip.show_predictions({ "visible" }, 1, true), true)
			local key_watcher = context.created[CASES[1].watcher_count]
			helpers.assert_eq(key_watcher.fn(hardware_key_event(48, {}, "\t")), true)
			helpers.assert_eq(synthetic.stats().pending_post_callback_actions, 1)

			drain_deferred_actions(context.timers)
			helpers.assert_eq(synthetic.stats().pending_post_callback_actions, 0,
				"the positive-control dispatcher must actually drain")
			helpers.assert_eq(accepts, 1,
				"generation fencing must not discard current-render acceptance")
		end)
	end)

	helpers.it("(HS-059) refused Tab scheduling preserves the selected fallback row", function()
		with_fixture(function(fixture)
			local context = fixture.load_tooltip(CASES[1])
			local synthetic = require("adapters.synthetic_input")
			local original_defer = synthetic.defer_consumed_input_action
			local accepted = {}
			local ok, err = xpcall(function()
				context.tooltip.set_accept_callback(function(index)
					accepted[#accepted + 1] = index
					return true
				end)
				helpers.assert_eq(context.tooltip.show_predictions(
					{ "first", "second", "third" }, 1, true), true)
				helpers.assert_eq(context.tooltip.navigate(2), true)
				helpers.assert_eq(context.tooltip.get_current_index(), 3,
					"the fixture must visibly select row three before Tab")

				synthetic.defer_consumed_input_action = function() return false end
				local key_watcher = context.created[CASES[1].watcher_count]
				helpers.assert_eq(key_watcher.fn(hardware_key_event(48, {}, "\t")), false,
					"a refused tooltip action must pass Tab to the keymap fallback")
				helpers.assert_eq(accepted, {},
					"the refused tooltip owner must not invoke its acceptance callback")
				helpers.assert_eq(context.tooltip.get_current_index(), 3,
					"falling through must preserve the row that keymap will accept")
				helpers.assert_eq(synthetic.stats().pending_ordered_input_actions, 0,
					"a refused schedule must leave no deferred action for a later key")
			end, debug.traceback)
			synthetic.defer_consumed_input_action = original_defer
			if not ok then error(err, 0) end
		end)
	end)

	for _, action in ipairs({
		{ label = "Tab", keycode = 48, characters = "\t" },
		{ label = "Enter", keycode = 36, characters = "\r", enter_validates = true },
	}) do
		helpers.it("(HS-048) preserves consumed " .. action.label
			.. " ahead of a physical click", function()
			with_fixture(function(fixture)
				local context = fixture.load_tooltip(CASES[1])
				local synthetic = require("adapters.synthetic_input")
				local runtime_open = true
				local accepts = 0
				local replay_posts = 0
				context.tooltip.set_runtime_guard(function() return runtime_open end)
				context.tooltip.set_accept_callback(function()
					accepts = accepts + 1
					return true
				end)
				helpers.assert_eq(context.tooltip.show_predictions(
					{ "prediction" }, 1, true, nil, nil, nil, nil, nil, nil,
					nil, "request-a"), true)
				context.tooltip.set_enter_validates(action.enter_validates == true)
				local mouse_watcher = context.created[1]
				local key_watcher = context.created[CASES[1].watcher_count]

				helpers.assert_eq(key_watcher.fn(hardware_key_event(
					action.keycode, {}, action.characters)), true,
					action.label .. " must be owned before its deferred action runs")
				helpers.assert_eq(accepts, 0,
					"acceptance must remain outside the keyboard eventtap")
				helpers.assert_eq(synthetic.stats().pending_ordered_input_actions, 1,
					"the consumed key must retain one ordered lifecycle owner")

				local click = hardware_mouse_event()
				click.on_replay = function(replay)
					replay_posts = replay_posts + 1
					helpers.assert_eq(mouse_watcher.fn(replay), false,
						"the tagged replay must re-enter as the original physical click")
					runtime_open = false
				end
				local click_consumed = mouse_watcher.fn(click)
				if click_consumed ~= true then runtime_open = false end
				helpers.assert_eq(click_consumed, true,
					"the later click must wait behind the consumed keyboard action")
				helpers.assert_eq(synthetic.stats().pending_ordered_physical_replays, 1,
					"the consumed click must retain one exact replay owner")

				drain_deferred_actions(context.timers)
				helpers.assert_eq(accepts, 1,
					"the consumed keyboard action must commit before the click can invalidate runtime")
				helpers.assert_eq(replay_posts, 0,
					"the click cannot overtake the accepted action")

				local periodic_fired = false
				for _, timer in ipairs(context.timers) do
					if timer.running and timer.delay == synthetic.PERIODIC_OWNER_TICK_SEC then
						periodic_fired = true
						timer:fire()
						if timer.running then timer:fire() end
					end
				end
				helpers.assert_true(periodic_fired,
					"the retained physical replay owner must drive the delayed click")
				helpers.assert_eq(replay_posts, 1)
				helpers.assert_eq(runtime_open, false,
					"the replayed click may close runtime only after acceptance")
				helpers.assert_eq(click.replay.post_calls, 1)
				helpers.assert_eq(synthetic.stats().pending_ordered_input_actions, 0)
				helpers.assert_eq(synthetic.stats().pending_ordered_physical_replays, 0)
			end)
		end)
	end

	helpers.it("(HS-049) passes through a shortcut beyond the live prediction pool", function()
		with_fixture(function(fixture)
			local context = fixture.load_tooltip(CASES[1])
			local synthetic = require("adapters.synthetic_input")
			local accepts = 0
			context.tooltip.set_accept_callback(function()
				accepts = accepts + 1
				return true
			end)
			helpers.assert_eq(context.tooltip.show_predictions(
				{ "one", "two", "three" }, 1, true, nil, "alt", nil, nil, nil, nil, 5), true)
			local key_watcher = context.created[CASES[1].watcher_count]

			helpers.assert_eq(key_watcher.fn(hardware_key_event(21, { alt = true }, "4")), false,
				"Alt+4 must remain available to the application while only three predictions exist")
			helpers.assert_eq(accepts, 0)
			helpers.assert_eq(synthetic.stats().pending_ordered_input_actions, 0,
				"an unavailable slot must not acquire deferred input ownership")
			helpers.assert_true(context.tooltip.is_visible(),
				"a missing streaming slot need not dismiss the live prediction pool")
		end)
	end)

	for _, spec in ipairs(CASES) do
		helpers.it("(tooltip-watcher-reuse) " .. spec.label
			.. " rejects an old CG callback delivered during a new watcher epoch", function()
			with_fixture(function(fixture)
				local context = fixture.load_tooltip(spec)
				local synthetic = require("adapters.synthetic_input")
				helpers.assert_eq(spec.render(context.tooltip), true)
				local old_key_callback = context.created[spec.watcher_count].fn
				if spec.label == "LLM" then
					helpers.assert_eq(context.tooltip.hide(), true)
				else
					helpers.assert_eq(context.tooltip.hide_forced(), true)
				end
				helpers.assert_eq(spec.render(context.tooltip), true)
				helpers.assert_eq(synthetic.stats().pending_post_callback_actions, 0)

				local consumed = old_key_callback(hardware_key_event(48, {}, "\t"))
				helpers.assert_eq(consumed, false,
					"a callback owned by A must pass input after B mounts new taps")
				helpers.assert_eq(synthetic.stats().pending_post_callback_actions, 0,
					"an old CG callback must not enqueue work under B's live generation")
				helpers.assert_true(context.tooltip.is_visible(),
					"old callback delivery must leave B visible")
			end)
		end)
	end
end)
