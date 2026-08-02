--- tests/unit/modules/keymap/test_update_preview_early_out.lua

--- ==============================================================================
--- MODULE: Regression — update_preview early-out when everything is off
--- DESCRIPTION:
--- update_preview runs full provider iteration, star-bucket scan, and autocorrect
--- tail-bucket scan on every keystroke — even when LLM is disabled and both
--- hotstring preview toggles (star + autocorrect) are off. In that state no
--- tooltip can ever surface and no inactivity timer needs arming, so all the
--- per-keystroke work is pure waste on the latency-critical keymap event tap.
--- The fix adds an early guard after the empty-buffer check:
--- `if not llm_on and not is_star_preview_enabled and not is_autocorrect_preview_enabled`
--- that calls reset_predictions() and returns immediately, skipping all scans.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("update_preview early-out when LLM and both previews are off", function()
	helpers.it("the early-out guard appears before last_word and scans when everything is off", function()
		-- Selected by a declaration unique to modules/keymap/llm_bridge.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function invalidate_pending_preview")
		helpers.assert_true(src ~= nil, "modules/keymap/llm_bridge.lua source must be locatable")

		-- Locate the early-out guard after the empty-buffer early-return.
		local empty_buf = src:find('if not buf or #buf == 0 then', 1, true)
		helpers.assert_true(empty_buf ~= nil, "could not find empty-buffer check")

		-- The early-out guard must appear between the empty-buffer block and the
		-- `last_word` computation, so the last_word match plus all provider/bucket
		-- scans are skipped when everything is off.
		local last_word = src:find('local last_word = buf:match', empty_buf, true)
		helpers.assert_true(last_word ~= nil, "could not find last_word computation after empty-buffer block")

		local region = src:sub(empty_buf, last_word)

		-- Verify the guard references all three toggles.
		helpers.assert_true(region:find("not llm_on", 1, true) ~= nil,
			"early-out must check llm_on")
		helpers.assert_true(region:find("not is_star_preview_enabled", 1, true) ~= nil,
			"early-out must check is_star_preview_enabled")
		helpers.assert_true(region:find("not is_autocorrect_preview_enabled", 1, true) ~= nil,
			"early-out must check is_autocorrect_preview_enabled")

		-- The guard must call reset_predictions so stale state is cleaned up.
		helpers.assert_true(region:find("M.reset_predictions()", 1, true) ~= nil,
			"early-out must call M.reset_predictions()")

		-- The guard must return, not fall through to the scans.
		helpers.assert_true(region:find("return", 1, true) ~= nil,
			"early-out must return")
	end)

	helpers.it("provider iteration, star bucket, and tail bucket are all AFTER the early-out guard", function()
		-- Selected by a declaration unique to modules/keymap/llm_bridge.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function invalidate_pending_preview")
		helpers.assert_true(src ~= nil, "modules/keymap/llm_bridge.lua source must be locatable")

		-- Find the early-out guard block.
		local guard = src:find("not llm_on and not is_star_preview_enabled and not is_autocorrect_preview_enabled", 1, true)
		helpers.assert_true(guard ~= nil, "could not find the three-condition early-out guard")

		-- Everything that follows the guard (provider loop, star bucket,
		-- tail bucket) must appear AFTER it in the source.
		local after_guard = src:sub(guard)

		-- Provider iteration must be AFTER the guard.
		local prov = after_guard:find("for _, provider in ipairs(_state.preview_providers)", 1, true)
		helpers.assert_true(prov ~= nil, "provider iteration must appear after the guard")

		-- Star bucket lookup must be AFTER the guard.
		local star = after_guard:find("Registry.mappings_for_star_tail", 1, true)
		helpers.assert_true(star ~= nil, "star bucket lookup must appear after the guard")

		-- Tail bucket lookup must be AFTER the guard.
		local tail = after_guard:find("Registry.mappings_for_tail(buf_tail_char)", 1, true)
		helpers.assert_true(tail ~= nil, "tail bucket lookup must appear after the guard")
	end)

	helpers.it("source-level: the guard short-circuits before any per-keystroke allocation", function()
		-- Selected by a declaration unique to modules/keymap/llm_bridge.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function invalidate_pending_preview")
		helpers.assert_true(src ~= nil, "modules/keymap/llm_bridge.lua source must be locatable")

		-- The `llm_on` variable is declared before the early-out so it can be checked.
		local llm_on_line = src:find("local llm_on =", 1, true)
		helpers.assert_true(llm_on_line ~= nil, "could not find llm_on declaration")

		local guard = src:find("not llm_on and not is_star_preview_enabled", 1, true)
		helpers.assert_true(guard ~= nil, "could not find early-out guard")

		-- Guard must appear after llm_on declaration (needs its value) and
		-- before the last_word allocation.
		helpers.assert_true(guard > llm_on_line,
			"early-out guard must appear after llm_on declaration")
	end)
end)
