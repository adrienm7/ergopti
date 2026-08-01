--- tests/unit/modules/keymap/test_registry_disable_group_tail_idx.lua

--- ==============================================================================
--- MODULE: Registry disable_group Tail-Index Consistency Test
--- DESCRIPTION:
--- Regression test for the "registry-disable-group-stale-tail-index" audit
--- finding in modules/keymap/registry.lua.
---
--- ROOT CAUSE ENCODED:
--- disable_group() purged entries from _state.mappings and rebuilt the lookup
--- table via rebuild_lookup(), but did NOT call rebuild_tail_indexes(). The
--- O(1) hot-path buckets (mappings_by_tail_char / mappings_by_star_tail_char)
--- therefore still pointed at the removed mapping objects. On every subsequent
--- keystroke that matched the disabled trigger's tail character, the expander
--- iterated a stale bucket and fired the disabled hotstring indefinitely —
--- disable_group appeared to do nothing from the user's perspective.
---
--- The fix adds rebuild_tail_indexes() after rebuild_lookup() in disable_group().
--- This test creates a group, adds a mapping, disables the group, and asserts
--- that the tail-char bucket for the disabled trigger is cleared.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

local State    = helpers.load_with_stubs("modules.keymap.state")
local Registry = helpers.load_with_stubs("modules.keymap.registry")

--- Builds a fresh registry with a clean shared state.
--- @return table state, table R
local function fresh_registry()
	package.loaded["modules.keymap.registry"]    = nil
	package.loaded["modules.keymap.terminators"] = nil
	local R     = require("modules.keymap.registry")
	local state = State.new({ trigger_char = "★", expansion_delay = 0.4 }, { autocorrection = 0.3 })
	R.init(state)
	Registry = R
	return state, R
end




-- =====================================================================
-- =====================================================================
-- ======= 1/ disable_group clears the tail-char bucket ================
-- =====================================================================
-- =====================================================================

helpers.describe("Registry.disable_group: tail-index consistency", function()
	helpers.it("mappings_by_tail_char no longer contains entries for a disabled group", function()
		local state = fresh_registry()

		-- Register a group with a real path so the purge branch runs.
		Registry.register_lua_group("audit_grp", "Audit Group", {})
		state.groups.audit_grp.path = "fake_path"

		-- Add a case-sensitive mapping so only one entry is inserted.
		-- Trigger "beta" has tail_char "a" (lowercase of last codepoint).
		Registry.set_group_context("audit_grp")
		Registry.add("beta", "BETA", { is_case_sensitive = true })
		Registry.set_group_context(nil)

		-- Trigger the O(1) tail index build. M.add() only inserts into state.mappings;
		-- sort_mappings() calls rebuild_tail_indexes() which populates
		-- mappings_by_tail_char. This mirrors the normal load_file()/load_group()
		-- completion path that sorts and indexes before the engine goes live.
		Registry.sort_mappings()

		-- Confirm the mapping was registered and the tail bucket is populated.
		local before_count = #state.mappings
		helpers.assert_true(before_count >= 1, "mapping must be registered before disable")
		local bucket_before = state.mappings_by_tail_char["a"]
		helpers.assert_true(bucket_before ~= nil and #bucket_before >= 1,
			"mappings_by_tail_char['a'] must be non-empty before disable_group")

		-- Disable the group.
		Registry.disable_group("audit_grp")

		-- mappings list must be purged.
		local found = false
		for _, m in ipairs(state.mappings) do
			if m.group == "audit_grp" then found = true; break end
		end
		helpers.assert_true(not found, "disable_group must purge all mappings from the group")

		-- CRITICAL: the tail-char bucket must also be cleared.
		-- Before the fix, this bucket still contained the stale mapping pointer,
		-- causing the disabled hotstring to keep firing on every 'a' keystroke.
		local bucket_after = state.mappings_by_tail_char["a"]
		local stale = false
		if bucket_after then
			for _, m in ipairs(bucket_after) do
				if m.group == "audit_grp" then stale = true; break end
			end
		end
		helpers.assert_true(not stale,
			"mappings_by_tail_char must not contain stale entries for disabled group after disable_group (registry-disable-group-stale-tail-index)")
	end)

	helpers.it("disable_group with an unknown group name does not corrupt the tail index", function()
		local state = fresh_registry()
		-- Prime the index with one known mapping.
		Registry.register_lua_group("stable", "Stable", {})
		state.groups.stable.path = "p"
		Registry.set_group_context("stable")
		Registry.add("cat", "CAT", { is_case_sensitive = true })
		Registry.set_group_context(nil)
		local before = state.mappings_by_tail_char["t"] and
			#state.mappings_by_tail_char["t"] or 0

		-- Disabling an unknown group must be a no-op.
		Registry.disable_group("nonexistent_group")

		local after = state.mappings_by_tail_char["t"] and
			#state.mappings_by_tail_char["t"] or 0
		helpers.assert_eq(before, after,
			"tail index must be unchanged after disabling an unknown group")
	end)

	helpers.it("the classify_trigger memo does not survive a group disable", function()
		-- classify_trigger's own comment states the invariant this case enforces:
		-- "the cache is dropped whenever the corpus changes — a memo that outlived a
		-- re-registration would answer for a mapping set that no longer exists".
		-- disable_group changes the corpus and was the one mutation that did not pass
		-- through sort_mappings, which is the single place the memo is dropped. So a
		-- disabled hotstring kept answering `exact = true` forever, and the dynamic
		-- @-collector reads exactly that answer to decide whether a trigger is already
		-- claimed — a stale true silently suppresses collection.
		--
		-- This lives in THIS file because it is the file that documents
		-- disable_group's habit of forgetting one of the structures it invalidates.
		local state = fresh_registry()

		Registry.register_lua_group("memo_grp", "Memo Group", {})
		state.groups.memo_grp.path = "fake_path"
		Registry.set_group_context("memo_grp")
		Registry.add("gamma", "GAMMA", { is_case_sensitive = true })
		Registry.set_group_context(nil)
		Registry.sort_mappings()

		local exact_before = Registry.classify_trigger("gamma")
		helpers.assert_true(exact_before,
			"the memo must be primed for a trigger that IS registered, or the assertion "
			.. "below would pass against a classify_trigger that never answers true at all")

		Registry.disable_group("memo_grp")

		local exact_after = Registry.classify_trigger("gamma")
		helpers.assert_true(not exact_after,
			"the mapping was removed from the corpus, so classify_trigger must stop "
			.. "claiming it exists. sort_mappings is the only place the memo is dropped and "
			.. "disable_group does not go through it")
	end)

	helpers.it("re-enabling a group makes the memo answer again", function()
		-- Without this case the assertion above would pass against a fix that simply
		-- disabled memoisation, or that cleared the memo and never refilled it.
		local state = fresh_registry()

		Registry.register_lua_group("memo_grp2", "Memo Group 2", {})
		state.groups.memo_grp2.path = "fake_path"
		Registry.set_group_context("memo_grp2")
		Registry.add("delta", "DELTA", { is_case_sensitive = true })
		Registry.set_group_context(nil)
		Registry.sort_mappings()
		Registry.disable_group("memo_grp2")

		-- Put the mapping back the way enable_group's post-load hook would, then let
		-- the normal sort funnel run.
		Registry.set_group_context("memo_grp2")
		Registry.add("delta", "DELTA", { is_case_sensitive = true })
		Registry.set_group_context(nil)
		Registry.sort_mappings()

		helpers.assert_true(Registry.classify_trigger("delta"),
			"a re-registered trigger must be classified again")
	end)
end)
