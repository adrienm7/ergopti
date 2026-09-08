--- tests/unit/ui/tooltip/test_facade_ownership.lua

--- ==============================================================================
--- MODULE: Tooltip Facade Ownership Regression
--- DESCRIPTION:
--- Exercises real tooltip ownership while keeping native fixtures scoped per case.
--- ==============================================================================

local helpers = require("tests.helpers")
local support = require("tests.support.tooltip_watcher_fixture")
local with_fixture = support.with_fixture
local CASES = support.CASES
local hardware_key_event = support.hardware_key_event
local drain_deferred_actions = support.drain_deferred_actions

helpers.describe("tooltip facade propagates watcher ownership", function()
	helpers.it("(tooltip-watcher-reuse) facade reports low-level mount failures and suppresses show callbacks", function()
		with_fixture(function(fixture)
			local results = { hotstring = false, stacked = false, loading = false, llm = false }
			local cleanup = { llm = true, hotstring = true, llm_calls = 0, hotstring_calls = 0 }

			package.loaded["ui.tooltip.tooltip_llm"] = {
				hide = function()
					cleanup.llm_calls = cleanup.llm_calls + 1
					return cleanup.llm
				end,
				hide_silent = function()
					cleanup.llm_calls = cleanup.llm_calls + 1
					return cleanup.llm
				end,
				show_predictions = function() return results.llm end,
			}
			package.loaded["ui.tooltip.tooltip_hotstring"] = {
				dismiss_silent = function() return true end,
				hide = function()
					cleanup.hotstring_calls = cleanup.hotstring_calls + 1
					return cleanup.hotstring
				end,
				hide_forced = function()
					cleanup.hotstring_calls = cleanup.hotstring_calls + 1
					return cleanup.hotstring
				end,
				show = function() return results.hotstring end,
				show_stacked = function() return results.stacked end,
				show_loading = function() return results.loading end,
			}
			package.loaded["ui.tooltip.init"] = nil
			local facade = require("ui.tooltip.init")
			local show_calls = 0
			facade.set_on_show_callback(function() show_calls = show_calls + 1; return true end)

			helpers.assert_eq(facade.show("preview", false, true), false,
				"the facade must propagate a hotstring watcher failure")
			helpers.assert_eq(facade.show_stacked({ { text = "preview" } }, true), false,
				"the facade must propagate a stacked watcher failure")
			helpers.assert_eq(facade.show_loading("loading", true), false,
				"the facade must propagate a loading paint failure")
			helpers.assert_eq(facade.show_predictions({ "prediction" }, 1, true), false,
				"the facade must propagate an LLM watcher failure")
			helpers.assert_eq(show_calls, 0,
				"failed low-level renders must not emit a successful show notification")

			results.hotstring = true
			results.stacked = true
			results.loading = true
			results.llm = true
			helpers.assert_eq(facade.show("preview", false, true), true,
				"the facade must preserve hotstring render success")
			helpers.assert_eq(facade.show_stacked({ { text = "preview" } }, true), true,
				"the facade must preserve stacked render success")
			helpers.assert_eq(facade.show_loading("loading", true), true,
				"the facade must preserve loading paint success")
			helpers.assert_eq(facade.show_predictions({ "prediction" }, 1, true), true,
				"the facade must preserve LLM render success")
			helpers.assert_eq(show_calls, 4,
				"only successful low-level renders may emit show notifications")

			helpers.assert_eq(facade.hide(), true,
				"facade hide must report verified cleanup from both owners")
			cleanup.llm = false
			local llm_calls_before = cleanup.llm_calls
			local hotstring_calls_before = cleanup.hotstring_calls
			helpers.assert_eq(facade.hide_forced(), false,
				"facade cleanup must propagate either owner's revocation failure")
			helpers.assert_eq(cleanup.llm_calls, llm_calls_before + 1)
			helpers.assert_eq(cleanup.hotstring_calls, hotstring_calls_before + 1,
				"cleanup must still reach hotstring ownership after an LLM failure")
			helpers.assert_eq(facade.hide_forced_silent(), false,
				"the hot-path cleanup variant must preserve the same ownership contract")

		end)
	end)
end)

helpers.describe("tooltip facade serializes cross-owner transitions", function()
	helpers.it("(tooltip-watcher-reuse) failed LLM successor hides prior shared-canvas pixels", function()
		with_fixture(function(fixture)
			local context = fixture.load_tooltip(CASES[2])
			package.loaded["ui.tooltip.tooltip_llm"] = nil
			require("ui.tooltip.tooltip_llm")
			package.loaded["ui.tooltip.init"] = nil
			local facade = require("ui.tooltip.init")

			helpers.assert_eq(facade.show("old hotstring", false, true), true)
			helpers.assert_true(context.renderer.visible,
				"positive control: old hotstring pixels must be on the shared canvas")
			helpers.assert_eq(facade.show_predictions({ "disabled" }, 1, false), false)
			helpers.assert_true(not context.renderer.visible,
				"a disabled or failed LLM successor must hide the old shared canvas")
		end)
	end)

	helpers.it("(tooltip-watcher-reuse) hotstring orphan blocks LLM mount until verified cleanup", function()
		with_fixture(function(fixture)
			local context = fixture.load_tooltip(CASES[2])
			package.loaded["ui.tooltip.tooltip_llm"] = nil
			local llm = require("ui.tooltip.tooltip_llm")
			package.loaded["ui.tooltip.init"] = nil
			local facade = require("ui.tooltip.init")

			helpers.assert_eq(facade.show("hot", false, true), true)
			local orphan = context.created[CASES[2].watcher_count]
			orphan.stop = function(self)
				self.stopped = self.stopped + 1
				error("simulated hotstring transition stop failure")
			end
			helpers.assert_eq(facade.show_predictions({ "llm" }, 1, true), false,
				"LLM mount must abort while hotstring watcher cleanup is unverified")
			helpers.assert_eq(#context.created, CASES[2].watcher_count,
				"failed hotstring cleanup must prevent every LLM eventtap creation")
			helpers.assert_true(not context.renderer.visible,
				"an aborted LLM transition must not leave stale hotstring pixels")
			helpers.assert_eq(orphan.fn({}), false,
				"the retained hotstring key tap must be passive while transition is blocked")
			helpers.assert_true(not llm.is_visible(),
				"the LLM must not claim visibility after a blocked transition")

			orphan.stop = function(self) self.enabled = false; return self end
			helpers.assert_eq(facade.show_predictions({ "llm" }, 1, true), true,
				"LLM mount must recover after hotstring cleanup succeeds")
			helpers.assert_eq(#context.created,
				CASES[2].watcher_count + CASES[1].watcher_count,
				"recovery must create exactly one LLM watcher set")
		end)
	end)

	helpers.it("(tooltip-watcher-reuse) LLM orphan blocks hotstring mount until verified cleanup", function()
		with_fixture(function(fixture)
			local context = fixture.load_tooltip(CASES[1])
			package.loaded["ui.tooltip.tooltip_hotstring"] = nil
			local hotstring = require("ui.tooltip.tooltip_hotstring")
			package.loaded["ui.tooltip.init"] = nil
			local facade = require("ui.tooltip.init")

			helpers.assert_eq(facade.show_predictions({ "llm" }, 1, true), true)
			local orphan = context.created[CASES[1].watcher_count]
			orphan.stop = function(self)
				self.stopped = self.stopped + 1
				error("simulated LLM transition stop failure")
			end
			helpers.assert_eq(facade.show("hot", false, true), false,
				"hotstring mount must abort while LLM watcher cleanup is unverified")
			helpers.assert_eq(#context.created, CASES[1].watcher_count,
				"failed LLM cleanup must prevent every hotstring eventtap creation")
			helpers.assert_eq(orphan.fn({}), false,
				"the retained LLM key tap must pass input while transition is blocked")
			helpers.assert_true(not hotstring.is_visible(),
				"the hotstring tooltip must not claim visibility after a blocked transition")

			orphan.stop = function(self) self.enabled = false; return self end
			helpers.assert_eq(facade.show("hot", false, true), true,
				"hotstring mount must recover after LLM cleanup succeeds")
			helpers.assert_eq(#context.created,
				CASES[1].watcher_count + CASES[2].watcher_count,
				"recovery must create exactly one hotstring watcher set")
		end)
	end)

	helpers.it("(llm-stream-navigation-session) same-request repaint preserves Enter semantics", function()
		with_fixture(function(fixture)
			local context = fixture.load_tooltip(CASES[1])
			local accepted = {}
			context.tooltip.set_accept_callback(function(index)
				accepted[#accepted + 1] = index
				return true
			end)
			local function stream_repaint(predictions, request_id, producer_index)
				local display_index = producer_index or context.tooltip.get_current_index() or 1
				return context.tooltip.show_predictions(
					predictions, display_index, true, nil, nil, nil, nil, nil, nil, nil,
					request_id)
			end
			helpers.assert_eq(stream_repaint({ "first", "second" }, "request-a"), true)
			local key_watcher = context.created[CASES[1].watcher_count]
			helpers.assert_eq(key_watcher.fn(hardware_key_event(125, {}, "")), true)
			helpers.assert_eq(context.tooltip.get_current_index(), 2)

			-- A token repaint can race after the physical arrow but before its deferred
			-- semantic callback. Even if its producer still carries row one, it must not
			-- undo the synchronously committed cursor or its Enter semantics.
			helpers.assert_eq(stream_repaint(
				{ "first updated", "second updated" }, "request-a", 1), true)
			helpers.assert_eq(context.tooltip.get_current_index(), 2,
				"same-stream rendering must not overwrite a newer physical navigation")
			key_watcher = context.created[CASES[1].watcher_count]
			helpers.assert_eq(key_watcher.fn(hardware_key_event(36, {}, "\r")), true,
				"Enter must remain owned after a same-request streaming repaint")
			drain_deferred_actions(context.timers)
			helpers.assert_eq(accepted, { 2 },
				"the row still highlighted on screen must be accepted exactly once")

			helpers.assert_eq(context.tooltip.show_predictions(
				{ "new first", "new second" }, 1, true, nil, nil, nil, nil, nil, nil,
				nil, "request-b"), true)
			key_watcher = context.created[CASES[1].watcher_count]
			helpers.assert_eq(key_watcher.fn(hardware_key_event(36, {}, "\r")), false,
				"a genuinely new request must reset navigation engagement")
		end)
	end)

	helpers.it("(llm-navigation-enter-order) commits the arrow index before deferred repaint", function()
		with_fixture(function(fixture)
			local context = fixture.load_tooltip(CASES[1])
			local accepted = {}
			context.tooltip.set_accept_callback(function(index)
				accepted[#accepted + 1] = index
				return true
			end)
			helpers.assert_eq(context.tooltip.show_predictions(
				{ "first", "second" }, 1, true, nil, nil, nil, {}, nil, nil, nil,
				"request-a"), true)
			local key_watcher = context.created[CASES[1].watcher_count]

			helpers.assert_eq(key_watcher.fn(hardware_key_event(125, {}, "")), true,
				"Down must be consumed as tooltip navigation")
			helpers.assert_eq(context.tooltip.get_current_index(), 2,
				"the O(1) selection state must commit before the run-loop repaint")
			helpers.assert_eq(key_watcher.fn(hardware_key_event(36, {}, "\r")), true,
				"immediate Enter must observe and own the newly selected row")
			helpers.assert_eq(accepted, {},
				"acceptance must remain deferred outside the eventtap callback")
			drain_deferred_actions(context.timers)
			helpers.assert_eq(accepted, { 2 },
				"Down then Enter must accept row two exactly once in physical event order")
		end)
	end)

	helpers.it("(HS-060) samples a held right Shift before the first Shift-Tab", function()
		with_fixture(function(fixture)
			local original_check
			local original_masks
			local ok, err = xpcall(function()
				local context = fixture.load_tooltip(CASES[1])
				original_check = hs.eventtap.checkKeyboardModifiers
				original_masks = hs.eventtap.event.rawFlagMasks
				local masks = {
					deviceLeftShift = 0x40,
					deviceRightShift = 0x80,
				}
				hs.eventtap.event.rawFlagMasks = masks
				hs.eventtap.checkKeyboardModifiers = function(raw)
					helpers.assert_eq(raw, true,
						"watcher activation must request device-specific modifier state")
					return { shift = true, _raw = masks.deviceRightShift }
				end

				helpers.assert_eq(context.tooltip.show_predictions(
					{ "first", "second", "third" }, 1, true), true)
				local key_watcher = context.created[CASES[1].watcher_count]

				-- Deliberately do not deliver a flagsChanged event. Right Shift was held
				-- before the tooltip painted, so activation must have sampled it already.
				helpers.assert_eq(key_watcher.fn(
					hardware_key_event(48, { shift = true }, "\t")), true)
				helpers.assert_eq(context.tooltip.get_current_index(), 2,
					"right Shift-Tab must follow the advertised forward direction")
			end, debug.traceback)
			hs.eventtap.checkKeyboardModifiers = original_check
			hs.eventtap.event.rawFlagMasks = original_masks
			package.loaded["adapters.key_state"] = nil
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("(llm-navigation-action-order) a later arrow cannot cancel an earlier accepted Tab", function()
		with_fixture(function(fixture)
			local context = fixture.load_tooltip(CASES[1])
			local accepted = {}
			context.tooltip.set_accept_callback(function(index)
				accepted[#accepted + 1] = index
				return true
			end)
			helpers.assert_eq(context.tooltip.show_predictions(
				{ "first", "second" }, 1, true, nil, nil, nil, {}, nil, nil, nil,
				"request-a"), true)
			local key_watcher = context.created[CASES[1].watcher_count]

			helpers.assert_eq(key_watcher.fn(hardware_key_event(48, {}, "\t")), true,
				"Tab must consume and enqueue acceptance of row one")
			helpers.assert_eq(key_watcher.fn(hardware_key_event(125, {}, "")), true,
				"the later Down event is classified against the still-visible tooltip")
			drain_deferred_actions(context.timers)
			helpers.assert_eq(accepted, { 1 },
				"a later navigation classification must not invalidate an earlier consumed action")
		end)
	end)

	helpers.it("(llm-stream-action-order) a token repaint cannot cancel an accepted Enter", function()
		with_fixture(function(fixture)
			local context = fixture.load_tooltip(CASES[1])
			local accepted = {}
			context.tooltip.set_accept_callback(function(index)
				accepted[#accepted + 1] = index
				return true
			end)
			local function stream_repaint(predictions)
				return context.tooltip.show_predictions(
					predictions, context.tooltip.get_current_index() or 1, true,
					nil, nil, nil, {}, nil, nil, nil, "request-a")
			end
			helpers.assert_eq(stream_repaint({ "first", "second" }), true)
			helpers.assert_eq(context.tooltip.navigate(1), true)
			local key_watcher = context.created[CASES[1].watcher_count]
			helpers.assert_eq(key_watcher.fn(hardware_key_event(36, {}, "\r")), true)

			-- Simulate a stream token callback winning the run-loop race against the
			-- already queued acceptance callback.
			helpers.assert_eq(stream_repaint({ "first updated", "second updated" }), true)
			drain_deferred_actions(context.timers)
			helpers.assert_eq(accepted, { 2 },
				"same-request rendering must not revoke an earlier consumed action")
		end)
	end)

	helpers.it("(llm-navigation-coalescing) rapid arrows render and notify only their final index", function()
		with_fixture(function(fixture)
			local context = fixture.load_tooltip(CASES[1])
			local navigated = {}
			context.tooltip.set_navigate_callback(function(index)
				navigated[#navigated + 1] = index
				return true
			end)
			helpers.assert_eq(context.tooltip.show_predictions(
				{ "first", "second", "third" }, 1, true,
				nil, nil, nil, {}, nil, nil, nil, "request-a"), true)
			local key_watcher = context.created[CASES[1].watcher_count]

			helpers.assert_eq(key_watcher.fn(hardware_key_event(125, {}, "")), true)
			helpers.assert_eq(key_watcher.fn(hardware_key_event(125, {}, "")), true)
			helpers.assert_eq(context.tooltip.get_current_index(), 3,
				"both O(1) state transitions must commit in physical order")
			helpers.assert_eq(navigated, {}, "semantic callbacks stay outside the eventtap")
			drain_deferred_actions(context.timers)
			helpers.assert_eq(navigated, { 3 },
				"superseded AX renders must coalesce instead of notifying the final row twice")
		end)
	end)
end)
