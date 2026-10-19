--- tests/unit/modules/llm/features/test_selection_translation_end_to_end.lua

--- ==============================================================================
--- MODULE: Translation of the Selection End to End (llm_translate_selection)
--- DESCRIPTION:
--- Runs the llm_translate_selection action without a model: the real gesture
--- action registry and parameter validator, translation module, prediction
--- engine refusals and tooltip surface, LLM core dispatcher, remote backend
--- (Cerebras, OpenAI dialect) and clipboard text pipeline. Only the boundaries
--- are faked: the HTTP transport (requests are captured and answered with
--- canned bodies), the pasteboard and the synthetic key emitter (a small
--- document model: Cmd+C copies the selection, Cmd+V replaces it, the
--- reselection batch selects the pasted text), the native timers (fired in
--- order), the focused window and the tooltip canvas. The acceptance runs the
--- candidate's own acceptance as the keymap bridge does (the bridge's routing
--- is pinned by test_apply_prediction_own_acceptance.lua).
---
--- ROOT CAUSE ENCODED:
--- No action translated the selection. It only works when every layer agrees:
--- nothing is read before the refusals, the request carries the translate.json
--- prompt naming the target language natively and the selection as TEXT, the
--- tooltip offers exactly one candidate, and accepting it replaces the
--- selection, which stays selected, while Escape leaves the text untouched.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.modules.llm.selection_translation_fixture")
local SELECTION, TRANSLATION = Fixture.SELECTION, Fixture.TRANSLATION
local USER_CLIPBOARD, NAMES = Fixture.USER_CLIPBOARD, Fixture.NAMES
local with_world, settle = Fixture.with_world, Fixture.settle
local trigger, answer, accept = Fixture.trigger, Fixture.answer, Fixture.accept
local assert_request = Fixture.assert_request

helpers.describe("translation of the selection end to end (llm_translate_selection)", function()
	helpers.it("translates into the interface language, offers one candidate and replaces the selection", function()
		with_world(SELECTION, "fr", function(world)
			helpers.assert_eq(trigger(world, "ui"), true)
			helpers.assert_eq(#world.notices, 0, "a ready request shows no refusal: " .. tostring(world.notices[1]))
			helpers.assert_eq(world.clipboard, USER_CLIPBOARD, "reading the selection gives the clipboard back")
			helpers.assert_eq(#world.document, 0, "reading the selection changes nothing")
			helpers.assert_eq(world.loadings, 1, "the loading row shows while the model translates")
			helpers.assert_eq(#world.posts, 1, "one request")
			assert_request(world.posts[1], "Français")

			answer(world.posts[1], "TRANSLATION: " .. TRANSLATION)
			local render = world.renders[#world.renders]
			helpers.assert_eq(#render.texts, 1, "one candidate")
			helpers.assert_eq(render.texts[1], TRANSLATION)
			helpers.assert_nil(render.loading, "no loading row is left")
			helpers.assert_eq(#world.document, 0, "nothing is typed before the user accepts")

			helpers.assert_eq(accept(world, 1), true, "the replacement starts")
			helpers.assert_eq(world.document[1], TRANSLATION, "the selection is replaced by the translation")
			helpers.assert_eq(#world.document, 1)
			helpers.assert_eq(world.selection, TRANSLATION, "and the translation is selected")
			helpers.assert_eq(world.clipboard, USER_CLIPBOARD, "the user's clipboard is restored")
		end)
	end)

	helpers.it("names a fixed target language natively, whatever the interface", function()
		with_world(SELECTION, "fr", function(world)
			trigger(world, "ja")
			assert_request(world.posts[1], "日本語")
		end)
	end)

	helpers.it("follows the interface language when it changes", function()
		with_world(SELECTION, "de", function(world)
			trigger(world, "ui")
			assert_request(world.posts[1], NAMES.locales.de.name)
		end)
	end)

	helpers.it("leaves the text untouched when the candidate is dismissed", function()
		with_world(SELECTION, "fr", function(world)
			trigger(world, "ui")
			answer(world.posts[1], "TRANSLATION: " .. TRANSLATION)
			local before = #world.keys
			world.engine.reset()
			settle(world)
			helpers.assert_eq(#world.engine.get_predictions(), 0, "no candidate is left")
			helpers.assert_eq(#world.keys, before, "no key reaches the document")
			helpers.assert_eq(#world.document, 0)
			helpers.assert_eq(world.selection, SELECTION)
		end)
	end)

	helpers.it("tells the user to select a text first, and sends nothing", function()
		with_world("", "fr", function(world)
			trigger(world, "ui")
			helpers.assert_eq(#world.posts, 0, "no request")
			helpers.assert_eq(world.loadings, 0, "no tooltip")
			helpers.assert_eq(world.notices[1], world.i18n.get("llm.translate.no_selection"))
			helpers.assert_eq(world.clipboard, USER_CLIPBOARD, "the clipboard is restored")
		end)
	end)

	helpers.it("refuses like a manual prediction when the AI is off, before reading the selection", function()
		with_world(SELECTION, "fr", function(world)
			world.engine.set_llm_enabled(false)
			trigger(world, "ui")
			helpers.assert_eq(#world.posts, 0, "no request")
			helpers.assert_eq(#world.keys, 0, "the selection is not even copied")
			helpers.assert_eq(world.notices[1], world.i18n.get("llm.manual_prediction.disabled"))
		end)
	end)

	helpers.it("tells the user when the answer holds no translation, or none came back", function()
		with_world(SELECTION, "fr", function(world)
			trigger(world, "ui")
			answer(world.posts[1], "Sure! See you tomorrow?")
			helpers.assert_eq(world.notices[1], world.i18n.get("llm.translate.failed"))
			helpers.assert_eq(#world.engine.get_predictions(), 0, "no candidate")
			helpers.assert_true(world.hides >= 1, "the loading row is closed")

			trigger(world, "ui")
			world.posts[2].callback({ ok = false, status = 500, body = "{}", headers = {} })
			helpers.assert_eq(world.notices[2], world.i18n.get("llm.translate.failed"))
			helpers.assert_eq(#world.document, 0)
		end)
	end)

	helpers.it("ignores the answer of a superseded translation", function()
		with_world(SELECTION, "fr", function(world)
			trigger(world, "ui")
			trigger(world, "ja")
			helpers.assert_eq(#world.posts, 2)
			answer(world.posts[1], "TRANSLATION: " .. TRANSLATION)
			helpers.assert_eq(#world.renders, 0, "the stale answer shows nothing")
			helpers.assert_eq(#world.notices, 0)
			answer(world.posts[2], "TRANSLATION: 明日会いましょう？")
			helpers.assert_eq(world.renders[#world.renders].texts[1], "明日会いましょう？", "only the current one")
		end)
	end)

	helpers.it("types nothing when the selection changed before the acceptance", function()
		with_world(SELECTION, "fr", function(world)
			trigger(world, "ui")
			answer(world.posts[1], "TRANSLATION: " .. TRANSLATION)
			world.selection = "une autre phrase"
			accept(world, 1)
			helpers.assert_eq(#world.document, 0, "the other selection is not replaced")
			helpers.assert_eq(world.selection, "une autre phrase")
			helpers.assert_eq(world.clipboard, USER_CLIPBOARD)
		end)
	end)

	helpers.it("types nothing when the focus moved before the acceptance", function()
		with_world(SELECTION, "fr", function(world)
			trigger(world, "ui")
			answer(world.posts[1], "TRANSLATION: " .. TRANSLATION)
			world.focus = "8:202"
			local before = #world.keys
			helpers.assert_eq(accept(world, 1), false, "the acceptance is refused")
			helpers.assert_eq(#world.keys, before, "no key reaches the other window")
			helpers.assert_eq(#world.document, 0)
		end)
	end)

	helpers.it("refuses a binding whose language contains an action separator", function()
		with_world(SELECTION, "fr", function(world)
			helpers.assert_eq(world.actions.set_action_parameter("tap_3", "llm_translate_selection", "English|2"), false,
				"the validator refuses it")
			world.actions.execute_single("llm_translate_selection", "tap_3")
			settle(world)
			helpers.assert_eq(#world.keys + #world.posts, 0, "nothing is read or sent")
		end)
	end)
end)

helpers.it("translates a free language name through the existing selection owner", function()
	with_world(SELECTION, "fr", function(world)
		helpers.assert_eq(world.actions.set_action_parameter("tap_3", "llm_translate_selection", "Esperanto"), true)
		world.actions.execute_single("llm_translate_selection", "tap_3")
		settle(world)
		helpers.assert_eq(#world.posts, 1)
		assert_request(world.posts[1], "Esperanto")
	end)
end)
