--- tests/unit/modules/keymap/test_llm_bridge_rearm_when_chain_off.lua

--- ==============================================================================
--- MODULE: Regression — update_preview re-arms the inactivity timer when chain is off
--- DESCRIPTION:
--- Audit finding F-L9. update_preview stops the LLM inactivity timer at the top,
--- then in the hotstring-match branch only re-arms via the chain timer, gated on
--- fire_llm_after_hotstring. With chain-after-hotstring OFF (and the LLM on), the
--- match branch re-armed NOTHING — so AI predictions silently stopped on any
--- keystroke whose buffer tail matched a hotstring trigger. Fix: an `elseif llm_on`
--- re-arms the inactivity timer (start_timer / start_timer_word_end) just like the
--- no-match branch. update_preview needs the full registry/engine/tooltip stack to
--- drive end-to-end, so the re-arm is pinned at source.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("llm_bridge update_preview re-arms inactivity timer when chain is off", function()
	helpers.it("the hotstring-match branch re-arms the inactivity timer for llm_on with chain off", function()
		-- Selected by a declaration unique to modules/keymap/llm_bridge.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function invalidate_pending_preview")
		helpers.assert_true(src ~= nil, "modules/keymap/llm_bridge.lua source must be locatable")

		-- Find the chain block; immediately after it there must be an `elseif llm_on`
		-- that re-arms the inactivity timer (start_timer / start_timer_word_end).
		local chain = src:find("if fire_llm_after_hotstring and llm_on then", 1, true)
		helpers.assert_true(chain ~= nil, "could not find the chain-after-hotstring block")
		local region = src:sub(chain, chain + 1600)
		helpers.assert_true(region:find("elseif llm_on then", 1, true) ~= nil,
			"the match branch must have an `elseif llm_on` re-arm when chain is off")
		helpers.assert_true(region:find("start_timer_word_end", 1, true) ~= nil
			and region:find("engine.start_timer(", 1, true) ~= nil,
			"the elseif must re-arm via start_timer_word_end / start_timer")
	end)
end)
