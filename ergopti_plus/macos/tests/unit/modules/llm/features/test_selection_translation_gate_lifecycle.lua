--- tests/unit/modules/llm/features/test_selection_translation_gate_lifecycle.lua

--- ==============================================================================
--- MODULE: Selection Translation Request Authority
--- DESCRIPTION:
--- Runs real translation, prediction, backend and clipboard actions over explicit
--- native fixture boundaries. Captured HTTP dispatch is not physical networking.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.modules.llm.selection_translation_fixture")
local SOURCE, RESULT = "Synthetic selection", "Synthetic translation"

--- Starts a copy without delivering its native timer.
--- @param world table Pipeline fixture.
local function start_pending(world)
	helpers.assert_true(world.flow.run("en"))
	helpers.assert_eq(#world.posts, 0, "copy still precedes HTTP dispatch")
	helpers.assert_eq(world.loadings, 0, "copy still precedes answer surface acquisition")
end

--- Proves a retired copy acquired neither a tooltip nor an HTTP request.
--- @param world table Pipeline fixture.
local function assert_retired(world)
	Fixture.settle(world)
	helpers.assert_eq(world.loadings, 0, "a retired copy cannot open a new answer surface")
	helpers.assert_eq(#world.posts, 0, "a retired copy cannot dispatch to HTTP")
	helpers.assert_eq(#world.document, 0)
	helpers.assert_eq(world.clipboard, Fixture.USER_CLIPBOARD)
end

--- Follows the bridge's consume, reset, then owner callback protocol exactly.
--- @param world table Pipeline fixture; native keymap bridge is not loaded here.
--- @return boolean admitted
local function accept_after_bridge_cleanup(world)
	local candidate = world.engine.consume(1)
	helpers.assert_not_nil(candidate)
	helpers.assert_true(world.engine.reset())
	return candidate.on_accept(candidate.to_type)
end

helpers.describe("selection translation retains its admitted engine revision", function()
	for _, transition in ipairs({ "off", "off-on", "reset" }) do
		helpers.it("retires pending copy across " .. transition .. " (translation-gate-copy)", function()
			Fixture.with_world(SOURCE, "fr", function(world)
				start_pending(world)
				if transition == "reset" then
					world.engine.reset()
				else
					world.engine.set_llm_enabled(false)
					if transition == "off-on" then world.engine.set_llm_enabled(true) end
				end
				assert_retired(world)
			end)
		end)
	end

	helpers.it("hands its own surface revision through acceptance (translation-gate-owned)", function()
		Fixture.with_world(SOURCE, "fr", function(world)
			local admitted = world.engine.current_request_revision()
			start_pending(world)
			Fixture.settle(world)
			helpers.assert_true(world.engine.current_request_revision() > admitted)
			helpers.assert_eq(world.loadings, 1)
			helpers.assert_eq(#world.posts, 1)
			Fixture.answer(world.posts[1], "TRANSLATION: " .. RESULT)
			helpers.assert_true(accept_after_bridge_cleanup(world))
			Fixture.settle(world)
			helpers.assert_eq(#world.document, 1)
			helpers.assert_eq(world.document[1], RESULT)
			helpers.assert_eq(world.selection, RESULT)
			helpers.assert_eq(world.clipboard, Fixture.USER_CLIPBOARD)
		end)
	end)

	helpers.it("admits fresh selection after off-on retirement (translation-gate-fresh)", function()
		Fixture.with_world(SOURCE, "fr", function(world)
			start_pending(world)
			world.engine.set_llm_enabled(false)
			world.engine.set_llm_enabled(true)
			assert_retired(world)
			helpers.assert_true(world.flow.run("en"))
			Fixture.settle(world)
			helpers.assert_eq(world.loadings, 1)
			helpers.assert_eq(#world.posts, 1)
			Fixture.answer(world.posts[1], "TRANSLATION: " .. RESULT)
			helpers.assert_true(accept_after_bridge_cleanup(world))
			Fixture.settle(world)
			helpers.assert_eq(world.document[1], RESULT)
		end)
	end)

	helpers.it("preserves a newer surface after pending copy (translation-gate-superseded)", function()
		Fixture.with_world(SOURCE, "fr", function(world)
			start_pending(world)
			local successor = world.engine.open_answer_surface("Synthetic newer action")
			helpers.assert_not_nil(successor)
			Fixture.settle(world)
			helpers.assert_eq(world.engine.current_request_revision(), successor)
			helpers.assert_eq(world.loadings, 1)
			helpers.assert_eq(#world.posts, 0)
			helpers.assert_eq(world.clipboard, Fixture.USER_CLIPBOARD)
		end)
	end)

	helpers.it("retires accepted clipboard work across off-on (translation-gate-replacement)", function()
		Fixture.with_world(SOURCE, "fr", function(world)
			start_pending(world)
			Fixture.settle(world)
			Fixture.answer(world.posts[1], "TRANSLATION: " .. RESULT)
			helpers.assert_true(accept_after_bridge_cleanup(world))
			world.engine.set_llm_enabled(false)
			world.engine.set_llm_enabled(true)
			Fixture.settle(world)
			helpers.assert_eq(#world.document, 0)
			helpers.assert_eq(world.selection, SOURCE)
			helpers.assert_eq(world.clipboard, Fixture.USER_CLIPBOARD)
		end)
	end)

	helpers.it("rejects late answers after off-on (translation-gate-answer)", function()
		Fixture.with_world(SOURCE, "fr", function(world)
			start_pending(world)
			Fixture.settle(world)
			helpers.assert_eq(#world.posts, 1)
			world.engine.set_llm_enabled(false)
			world.engine.set_llm_enabled(true)
			local renders = #world.renders
			Fixture.answer(world.posts[1], "TRANSLATION: " .. RESULT)
			helpers.assert_eq(#world.renders, renders)
			helpers.assert_eq(#world.engine.get_predictions(), 0)
			helpers.assert_eq(#world.document, 0)
		end)
	end)
end)
