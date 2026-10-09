--- tests/unit/ui/menu/test_keymap_publication_commit_gate.lua

--- ==============================================================================
--- MODULE: Keymap Menu Publication Commitment
--- DESCRIPTION:
--- Runs the real preference transaction after a successful runtime mutation.
--- A writer refusal must restore its acknowledged state and reach the menu's
--- failure result, rather than being mistaken for successful publication.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Runs an action with a real save/rollback owner and an inspectable writer.
--- @param outcome string Writer result or thrown error.
--- @return boolean committed
--- @return table state
--- @return table runtime
--- @return table calls
local function run_publication(outcome)
	local notices = 0
	local previous = package.loaded["infra.notifications"]
	package.loaded["infra.notifications"] = {
		notify = function(_, _, kind)
			helpers.assert_eq(kind, "error", "a refused save needs an error notice")
			notices = notices + 1
		end,
	}
	local lifecycle = helpers.load_with_stubs("ui.menu.keymap_lifecycle")
	local transaction = require("ui.menu.preferences_transaction")
	local state = { hotstrings = { alpha = true, untouched = false } }
	local runtime = { alpha = true }
	local calls = { writes = 0, rollbacks = 0, cache_updates = 0 }
	local save = transaction.bind({
		save = function()
			calls.writes = calls.writes + 1
			if outcome == "throw" then error("injected writer refusal") end
			if outcome == "nil" then return nil end
			if outcome == "false" then return false end
			return true, { alpha = false }
		end,
	}, {
		path = "owned-fixture-config", state = state,
		initial_state = state, initial_preferences = runtime,
		restore_runtime = function(snapshot)
			calls.rollbacks = calls.rollbacks + 1
			runtime.alpha = snapshot.alpha
			return true
		end,
		builder = { invalidate_cache = function() calls.cache_updates = calls.cache_updates + 1 end },
	})
	local committed = lifecycle.commit_mutation({ state = state }, "hotstring publication", function()
		state.hotstrings.alpha, runtime.alpha = false, false
		return true
	end, save)
	package.loaded["infra.notifications"] = previous
	package.loaded["ui.menu.keymap_lifecycle"] = nil
	calls.notices = notices
	return committed, state, runtime, calls
end


helpers.describe("keymap publication respects the preference owner", function()
	for _, outcome in ipairs({ "false", "nil", "throw" }) do
		helpers.it("refuses acknowledgement after a " .. outcome .. " writer result", function()
			local committed, state, runtime, calls = run_publication(outcome)
			helpers.assert_eq(committed, false, "a rolled-back action must not be acknowledged")
			helpers.assert_eq(state.hotstrings.alpha, true, "the same state table sees rollback")
			helpers.assert_eq(state.hotstrings.untouched, false, "another choice is retained")
			helpers.assert_eq(runtime.alpha, true, "the real owner restores runtime")
			helpers.assert_eq(calls.writes, 1)
			helpers.assert_eq(calls.rollbacks, 1)
			helpers.assert_eq(calls.cache_updates, 0)
			helpers.assert_eq(calls.notices, 1, "the caller can see why the action failed")
		end)
	end

	helpers.it("acknowledges the save owner's exact success", function()
		local committed, state, runtime, calls = run_publication("true")
		helpers.assert_eq(committed, true)
		helpers.assert_eq(state.hotstrings.alpha, false)
		helpers.assert_eq(runtime.alpha, false)
		helpers.assert_eq(calls.writes, 1)
		helpers.assert_eq(calls.rollbacks, 0)
		helpers.assert_eq(calls.cache_updates, 1)
		helpers.assert_eq(calls.notices, 0)
	end)

	helpers.it("keeps a void UI publication valid when it has no save result", function()
		local lifecycle = helpers.load_with_stubs("ui.menu.keymap_lifecycle")
		local updates = 0
		local committed = lifecycle.commit_mutation({}, "UI-only refresh", function() return true end,
			function() updates = updates + 1 end)
		helpers.assert_eq(committed, true)
		helpers.assert_eq(updates, 1)
	end)
end)
