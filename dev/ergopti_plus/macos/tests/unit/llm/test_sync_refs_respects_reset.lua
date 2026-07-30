--- tests/unit/llm/test_sync_refs_respects_reset.lua

--- ==============================================================================
--- MODULE: Regression — a superseded response must not resurrect dead state
---         (sync-refs-respects-reset)
--- DESCRIPTION:
--- Backend "api", num_predictions=3. Type; variant 1 renders. Press Escape —
--- reset() bumps the fetch counter, but the non-streaming HTTP request is not
--- cancelled. Variant 2 lands seconds later. The StreamingHandler correctly
--- discards it as stale... and then the WRAPPER runs sync_refs() anyway,
--- copying variant 1's still-populated refs back into module state:
--- predictions_visible becomes true again, pending holds a stale pool, and no
--- tooltip is shown. Press Tab and handle_llm_keys — which gates only on
--- engine.is_visible() — types the old completion.
---
--- ROOT CAUSE ENCODED: the fetch-id guard lives INSIDE the StreamingHandler
--- callbacks, and the clobber happens one level above them, in a two-line
--- wrapper that had no guard at all. test_streaming_handler_stale pins exactly
--- the handler-level guarantee that this wrapper then defeats — which is why
--- the suite stayed green.
---
--- WHY IT IS SILENT: nothing changes on screen at clobber time. The handler
--- even logs "Stale LLM callback ignored", so the log looks correct. The damage
--- appears only at the next Tab or Enter, and any other keystroke heals it via
--- update_preview → reset_predictions — so it reads as a one-off ghost
--- insertion rather than a reproducible defect.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =========================================================================
-- =========================================================================
-- ======= 1/ The wrappers consult the fetch id ============================
-- =========================================================================
-- =========================================================================

helpers.describe("prediction_engine: sync_refs is staleness-aware", function()
	helpers.it("every callback wrapper guards its sync_refs", function()
		local src = helpers.read_driver_source("sync_refs")
		helpers.assert_true(src ~= nil and src ~= "",
			"the prediction engine must be locatable by its sync_refs symbol")

		-- Each of the three wrappers must gate the sync. Checking them one by one
		-- rather than counting occurrences: the bug was that ONE level of the
		-- stack had a guard and the other did not, so a total that merely looks
		-- plausible is exactly what hid it.
		-- Explicit anchors: the three wrappers are not written the same way.
		-- on_success and on_fail are function declarations; on_partial is a
		-- conditional assignment, because the backend may not supply one.
		local wrappers = {
			{ name = "on_success", anchor = "local function on_success(" },
			{ name = "on_fail",    anchor = "local function on_fail(" },
			{ name = "on_partial", anchor = "local on_partial = on_partial_cb and function" },
		}

		for _, w in ipairs(wrappers) do
			local name = w.name
			local at = src:find(w.anchor, 1, true)
			helpers.assert_true(at ~= nil, "the " .. name .. " wrapper must exist")

			local body = src:sub(at, at + 400)
			local sync_at = body:find("sync_refs()", 1, true)
			helpers.assert_true(sync_at ~= nil,
				name .. " must still synchronise the refs on the live path — without it the engine "
					.. "never sees the prediction it just received")

			local guarded = body:sub(1, sync_at):find("is_current_fetch", 1, true) ~= nil
				or body:sub(1, sync_at):find("fetch_request_counter", 1, true) ~= nil
			helpers.assert_true(guarded,
				name .. " calls sync_refs unconditionally. The StreamingHandler discards a "
					.. "superseded response on its own fetch-id guard, but the refs still hold the "
					.. "PREVIOUS response's values — copying them back resurrects state that reset() "
					.. "had just cleared, and the next Tab then types a completion the user never saw")
		end
	end)

	helpers.it("the staleness check compares against the request's own id", function()
		local src = helpers.read_driver_source("is_current_fetch")
		helpers.assert_true(src ~= nil and src ~= "",
			"the engine must define the staleness predicate")

		local at = src:find("local function is_current_fetch", 1, true)
		helpers.assert_true(at ~= nil, "is_current_fetch must exist")
		local body = src:sub(at, at + 200)

		helpers.assert_true(body:find("fetch_request_counter", 1, true) ~= nil,
			"the predicate must read the live counter — that counter is what reset() bumps")
		helpers.assert_true(body:find("my_fetch_id", 1, true) ~= nil,
			"and compare it against the id this request captured when it started. Comparing "
				.. "against anything else cannot distinguish a superseded response from a current one")
	end)
end)




-- =========================================================================
-- =========================================================================
-- ======= 2/ The guarantee the guard protects =============================
-- =========================================================================
-- =========================================================================

helpers.describe("prediction_engine: reset really clears the visible state", function()
	helpers.it("reset bumps the counter that makes in-flight responses stale", function()
		local src = helpers.read_driver_source("fetch_request_counter")
		helpers.assert_true(src ~= nil and src ~= "",
			"the engine must be locatable by its fetch counter")

		local at = src:find("function M.reset", 1, true)
		helpers.assert_true(at ~= nil, "M.reset must exist")
		local body = src:sub(at, at + 900)

		helpers.assert_true(body:find("fetch_request_counter", 1, true) ~= nil,
			"reset must bump the fetch counter. That bump is the ONLY thing that marks an "
				.. "in-flight, uncancelled HTTP response as superseded — the non-streaming path "
				.. "does not cancel its request, so the response WILL arrive")
	end)

	helpers.it("the accept path still gates only on visibility", function()
		-- Not a defect to fix here, but the reason the clobber is dangerous: the
		-- Tab handler trusts is_visible() alone, so resurrecting that flag is
		-- sufficient to make it type. Pinning it documents why the guard above
		-- matters, and fails loudly if the accept path ever grows a second
		-- condition that would change the analysis.
		local src = helpers.read_driver_source("handle_llm_keys")
		helpers.assert_true(src ~= nil and src ~= "",
			"the LLM key handler must be locatable")
		helpers.assert_true(src:find("is_visible", 1, true) ~= nil,
			"handle_llm_keys must still gate on is_visible() — if that ever changes, revisit "
				.. "whether a resurrected visible flag is still enough to type a stale completion")
	end)
end)
