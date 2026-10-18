--- tests/unit/modules/llm/features/test_tone_rewrite_focus_lifecycle.lua

--- ==============================================================================
--- MODULE: Tone Rewrite Focus Lifecycle
--- DESCRIPTION:
--- Composes the real tone flow, Text, prediction/backend modules, classified
--- native destination tracker and Quartz FIFO. Window changes and revoked tone
--- generations cannot transfer a copied selection or queued rewrite to a new
--- owner. Boundary payloads are the independently observed document mutations.
--- ==============================================================================

local helpers = require("tests.helpers")
local FIFO = require("tests.support.modules.llm.selection_translation_fifo")
local Response = require("tests.support.modules.llm.selection_translation_fixture")
local Tone = require("llm.tone")
local RESULT = "A formal rewrite"
local function seconds(key) return require("infra.timings").sec("debounce", key) end

--- Owns the tone module in addition to the common real-pipeline fixture scope.
--- @param scenario function Complete callback and timer scenario.
local function with_world(scenario)
	return helpers.with_fresh_modules({
		"modules.llm.tone_rewrite", "tests.support.modules.llm.selection_translation_scope",
		"tests.support.modules.llm.selection_translation_destination",
	}, function()
		return FIFO.with_world(function(world)
			world.tone = require("modules.llm.tone_rewrite")
			return scenario(world)
		end)
	end)
end

local function requested(world)
	helpers.assert_true(world.tone.step(Tone.MORE_FORMAL, false))
	world.flush()
	helpers.assert_eq(#world.posts, 1, "the real provider must receive the tone request")
end

local function answer(world)
	Response.answer(world.posts[1], "REWRITE: " .. RESULT)
end

--- Stops after the accepted rewrite posted its paste trigger, before delivery.
--- @param world table Real FIFO pipeline.
local function paste_queued(world)
	requested(world)
	answer(world)
	world.post_next()
	world.deliver()
	world.complete_handoff()
	world.fire(seconds("clipboard_copy_settle_ms"))
	world.fire(seconds("clipboard_paste_settle_ms"))
	world.post_next()
	helpers.assert_eq(world.clipboard, RESULT, "the original matched selection prepared this paste")
end

helpers.describe("tone rewrite retains its original native destination", function()
	helpers.it("keeps a healthy tone rewrite working (tone-focus-positive)", function()
		with_world(function(world)
			requested(world)
			answer(world)
			world.flush()
			helpers.assert_eq(world.document[1], RESULT)
			helpers.assert_eq(#world.document, 1)
			helpers.assert_eq(world.paste_focus, "7:101")
			helpers.assert_eq(world.selection, RESULT)
			helpers.assert_eq(world.clipboard, Response.USER_CLIPBOARD)
		end)
	end)

	helpers.it("refuses unknown focus before selection copy (tone-focus-unknown)", function()
		with_world(function(world)
			world.focus = nil
			helpers.assert_eq(world.tone.step(Tone.MORE_FORMAL, false), false)
			helpers.assert_eq(#world.quartz.triggers, 0)
			helpers.assert_eq(world.clipboard, Response.USER_CLIPBOARD)
		end)
	end)

	helpers.it("refuses AI off before selection copy (tone-focus-disabled)", function()
		with_world(function(world)
			world.engine.set_llm_enabled(false)
			helpers.assert_eq(world.tone.step(Tone.MORE_FORMAL, false), false)
			world.flush()
			helpers.assert_eq(#world.quartz.triggers, 0, "a refused action must not copy private selection")
			helpers.assert_eq(#world.posts, 0)
			helpers.assert_eq(world.clipboard, Response.USER_CLIPBOARD)
		end)
	end)

	helpers.it("does not rebind an original copy to a new window (tone-focus-copy)", function()
		with_world(function(world)
			helpers.assert_true(world.tone.step(Tone.MORE_FORMAL, false))
			world.post_next()
			world.deliver()
			world.complete_handoff()
			world.native_destination.change_focus("8:202")
			world.selection = "Another window's text"
			world.flush()
			helpers.assert_eq(#world.posts, 0, "copied text cannot be sent under a different window's ownership")
			helpers.assert_eq(#world.document, 0)
			helpers.assert_eq(world.clipboard, Response.USER_CLIPBOARD)
		end)
	end)

	helpers.it("refuses focus lost during replacement copy (tone-focus-answer-copy)", function()
		with_world(function(world)
			requested(world)
			answer(world)
			world.native_destination.change_focus("8:202")
			world.flush()
			helpers.assert_eq(#world.document, 0)
			helpers.assert_eq(world.selection, "Hello")
			helpers.assert_eq(world.clipboard, Response.USER_CLIPBOARD)
		end)
	end)

	helpers.it("revokes a queued paste when focus changes (tone-focus-queued)", function()
		with_world(function(world)
			paste_queued(world)
			world.native_destination.change_focus("8:202")
			world.deliver()
			helpers.assert_eq(#world.document, 0)
			world.flush()
			helpers.assert_eq(world.clipboard, Response.USER_CLIPBOARD)
		end)
	end)

	helpers.it("revokes a queued paste across tone reset (tone-focus-reset-queued)", function()
		with_world(function(world)
			paste_queued(world)
			world.tone.reset()
			world.deliver()
			helpers.assert_eq(#world.document, 0)
			world.flush()
			helpers.assert_eq(world.tone.get_memory(), nil)
			helpers.assert_eq(world.clipboard, Response.USER_CLIPBOARD)
		end)
	end)

	helpers.it("ignores an answer after tone reset (tone-focus-reset-answer)", function()
		with_world(function(world)
			requested(world)
			world.tone.reset()
			answer(world)
			world.flush()
			helpers.assert_eq(#world.document, 0)
			helpers.assert_eq(world.tone.get_memory(), nil)
		end)
	end)

	helpers.it("does not revive a queued paste after AI off and on (tone-focus-ai-cycle)", function()
		with_world(function(world)
			paste_queued(world)
			world.engine.set_llm_enabled(false)
			world.engine.set_llm_enabled(true)
			world.deliver()
			helpers.assert_eq(#world.document, 0)
			world.flush()
			helpers.assert_eq(world.clipboard, Response.USER_CLIPBOARD)
		end)
	end)

	helpers.it("revokes a queued paste when AI preview is disabled (tone-focus-preview-off)", function()
		with_world(function(world)
			paste_queued(world)
			world.engine.set_preview_ai_enabled(false)
			world.deliver()
			helpers.assert_eq(#world.document, 0)
			world.flush()
			helpers.assert_eq(world.clipboard, Response.USER_CLIPBOARD)
		end)
	end)
	helpers.it("keeps a healthy delayed answer valid across the native TTL (tone-focus-late-positive)", function()
		with_world(function(world)
			requested(world)
			world.elapse(6)
			world.tick_classification()
			answer(world)
			world.flush()
			helpers.assert_eq(world.document[1], RESULT)
			helpers.assert_eq(world.clipboard, Response.USER_CLIPBOARD)
		end)
	end)

	helpers.it("keeps tone copy behind an occupied native FIFO (tone-focus-busy-positive)", function()
		with_world(function(world)
			local input = world.synthetic
			local transaction = input.begin("unit.tone.earlier_action", "action")
			local batch = input.begin_batch(transaction)
			input.keyStroke(batch, {}, "left")
			helpers.assert_true(input.dispatch(batch))
			helpers.assert_true(input.seal(transaction))
			requested(world)
			answer(world)
			world.flush()
			helpers.assert_eq(world.document[1], RESULT)
			helpers.assert_eq(world.clipboard, Response.USER_CLIPBOARD)
		end)
	end)

	helpers.it("drops an older tone when an automatic prediction supersedes its request (tone-focus-automatic)", function()
		with_world(function(world)
			requested(world)
			world.engine_state.buffer = "We will finish this example sentence with enough context"
			world.engine_state.llm_buffer = world.engine_state.buffer
			world.engine.perform_check(false)
			helpers.assert_eq(world.engine.ai_activity(), "automatic", "the real automatic producer must commit")
			helpers.assert_eq(#world.posts, 2)
			answer(world)
			world.flush()
			helpers.assert_eq(#world.document, 0, "an older tone must not overwrite the newer typed context")
			helpers.assert_eq(world.clipboard, Response.USER_CLIPBOARD)
		end)
	end)

	helpers.it("rechecks destination after native AI exclusion reads (tone-focus-request-callback)", function()
		with_world(function(world)
			local app = world.native_destination.windows["7:101"].app
			local bundle_id = app.bundleID
			local moved = false
			app.bundleID = function()
				if not moved then
					moved = true
					world.native_destination.change_focus("8:202")
				end
				return bundle_id()
			end
			helpers.assert_true(world.tone.step(Tone.MORE_FORMAL, false))
			world.flush()
			helpers.assert_true(moved, "the real AppFilter must cross its native application boundary")
			helpers.assert_eq(#world.posts, 0, "a late focus change must revoke selection disclosure before HTTP")
			helpers.assert_eq(#world.document, 0)
			helpers.assert_eq(world.clipboard, Response.USER_CLIPBOARD)
		end)
	end)

	helpers.it("preserves the existing unguarded rewrite request facade (tone-focus-legacy-request)", function()
		with_world(function(world)
			local raw
			helpers.assert_true(world.engine.request_selection_rewrite("tone_formal", "Hello", function(value)
				raw = value
			end, function() error("the healthy legacy request must not fail") end))
			helpers.assert_eq(#world.posts, 1)
			answer(world)
			helpers.assert_eq(raw, "REWRITE: " .. RESULT)
			helpers.assert_eq(#world.document, 0)
		end)
	end)

	helpers.it("refuses a throwing final selection guard before HTTP (tone-focus-guard-error)", function()
		with_world(function(world)
			local checked, errors = false, {}
			require("infra.logger").error = function(_, template, ...)
				errors[#errors + 1] = string.format(template, ...)
			end
			helpers.assert_eq(world.engine.request_selection_rewrite("tone_formal", "Hello", function()
				error("a revoked selection must receive no response")
			end, nil, function()
				checked = true
				error("selection guard boundary refusal")
			end), false)
			helpers.assert_true(checked)
			helpers.assert_eq(#errors, 1)
			helpers.assert_true(errors[1]:find("selection guard boundary refusal", 1, true) ~= nil,
				"the original guard exception must remain observable")
			helpers.assert_eq(#world.posts, 0)
			helpers.assert_eq(#world.document, 0)
		end)
	end)

	helpers.it("does not revive an old response after text pause and engine reset (tone-focus-pause-resume)", function()
		with_world(function(world)
			requested(world)
			local text = require("modules.shortcuts.actions.text")
			helpers.assert_true(text.pause_text_actions())
			helpers.assert_true(world.engine.reset())
			helpers.assert_true(text.resume_text_actions())
			answer(world)
			world.flush()
			helpers.assert_eq(#world.document, 0, "reopened admission must not revive the response retired by pause")
			helpers.assert_eq(world.clipboard, Response.USER_CLIPBOARD)
		end)
	end)

end)
