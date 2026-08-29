--- tests/unit/modules/keymap/test_registry.lua

--- ==============================================================================
--- MODULE: keymap.registry Unit Tests
--- DESCRIPTION:
--- Exercises the registry's add/lookup/sort cycle, the require_state guard, the
--- group enable/disable invariants, and the sections enable/disable persistence
--- through hs.settings.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

local State = helpers.load_with_stubs("modules.keymap.state")
local Registry = helpers.load_with_stubs("modules.keymap.registry")


--- Builds an initialized registry with a fresh shared state. Reloads the
--- registry module each time so module-level _state resets between calls.
--- @return table state, table Registry The fresh state and module reference.
local function fresh_registry()
	package.loaded["adapters.storage"] = nil
	package.loaded["modules.keymap.registry"] = nil
	package.loaded["modules.keymap.registry_groups"] = nil
	package.loaded["modules.keymap.registry_index"] = nil
	package.loaded["modules.keymap.terminators"] = nil
	local R = require("modules.keymap.registry")
	local state = State.new({ trigger_char = "★", expansion_delay = 0.4 }, { autocorrection = 0.3 })
	R.init(state)
	Registry = R
	return state, R
end




-- =====================================
-- =====================================
-- ======= 1/ Init guard ================
-- =====================================
-- =====================================

helpers.describe("Registry.init / guard", function()
	helpers.it("init silently rejects non-table arg", function()
		local fresh = helpers.load_with_stubs("modules.keymap.registry")
		fresh.init("oops")
		-- add() must short-circuit because state is still nil
		fresh.add("a", "A")  -- Should log an error, not crash
	end)

	helpers.it("warns on duplicate init", function()
		local state = State.new({ trigger_char = "★", expansion_delay = 0.4 }, { a = 0.3 })
		local fresh = helpers.load_with_stubs("modules.keymap.registry")
		fresh.init(state)
		fresh.init(state)  -- Second call must not crash
	end)
end)




-- =====================================
-- =====================================
-- ======= 2/ add() basic flow ==========
-- =====================================
-- =====================================

helpers.describe("Registry.add", function()
	helpers.it("rejects empty trigger", function()
		local state = fresh_registry()
		Registry.add("", "X")
		helpers.assert_eq(#state.mappings, 0)
	end)

	helpers.it("rejects non-string replacement", function()
		local state = fresh_registry()
		Registry.add("hi", nil)
		helpers.assert_eq(#state.mappings, 0)
	end)

	helpers.it("inserts the lowercase trigger plus case variants", function()
		local state = fresh_registry()
		Registry.add("hi", "Hello")
		helpers.assert_true(#state.mappings >= 1)
		-- Lookup table populated for at least the lowercase variant. The dedup key
		-- ends with the owning group ("" here, since this ad-hoc add has no group).
		local key = "hi" .. "\0" .. "false" .. "\0" .. "false" .. "\0" .. ""
		helpers.assert_true(state.mappings_lookup[key] ~= nil)
	end)

	helpers.it("respects is_case_sensitive (no case-variant generation)", function()
		local state = fresh_registry()
		Registry.add("xyz", "X", { is_case_sensitive = true })
		helpers.assert_eq(#state.mappings, 1)
	end)

	helpers.it("auto-detects final_result when replacement contains tokens", function()
		local state = fresh_registry()
		Registry.add("foo", "A{Enter}B")
		-- At least one mapping should be marked final
		local any_final = false
		for _, m in ipairs(state.mappings) do
			if m.final_result then any_final = true ; break end
		end
		helpers.assert_true(any_final)
	end)

	helpers.it("refreshes every mutable option on same-group re-registration", function()
		local state = fresh_registry()
		state.magic_key = "§"
		state.current_group = "same_group"
		Registry.add("secret§", "FIRST", {
			is_case_sensitive = true,
			is_private = true,
			field = "old_field",
			section = "old_section",
			priority = 11,
		})
		Registry.add("secret§", "SECOND", {
			is_case_sensitive = true,
			is_case_sensitive_strict = true,
			is_magic_trigger = true,
			is_private = false,
			field = "new_field",
			section = "new_section",
			priority = 77,
			final_result = true,
		})
		state.current_group = nil

		helpers.assert_eq(#state.mappings, 1)
		local surviving = state.mappings[1]
		helpers.assert_eq(surviving.repl, "SECOND")
		helpers.assert_eq(surviving.is_private, false)
		helpers.assert_eq(surviving.field, "new_field")
		helpers.assert_eq(surviving.section, "new_section")
		helpers.assert_eq(surviving.priority, 77)
		helpers.assert_eq(surviving.final_result, true)
		helpers.assert_eq(surviving.match_mode, "exact")
		helpers.assert_nil(surviving.trigger_folded)
		helpers.assert_eq(surviving.has_magic, true)
		helpers.assert_eq(surviving.star_base, "secret")
		helpers.assert_eq(surviving.star_base_bytes, #"secret")
		helpers.assert_eq(surviving.star_base_tail_char, "t")
	end)
end)




-- =====================================
-- =====================================
-- ======= 3/ sort_mappings =============
-- =====================================
-- =====================================

helpers.describe("Registry.sort_mappings", function()
	helpers.it("orders longest trigger first", function()
		local state = fresh_registry()
		Registry.add("a", "A", { is_case_sensitive = true })
		Registry.add("abc", "ABC", { is_case_sensitive = true })
		Registry.add("ab", "AB", { is_case_sensitive = true })
		Registry.sort_mappings()
		helpers.assert_eq(state.mappings[1].trigger, "abc")
		helpers.assert_eq(state.mappings[2].trigger, "ab")
		helpers.assert_eq(state.mappings[3].trigger, "a")
	end)

	helpers.it("rebuilds tail-char buckets in sorted order", function()
		local state = fresh_registry()
		Registry.add("foo", "F", { is_case_sensitive = true })
		Registry.sort_mappings()
		local bucket = Registry.mappings_for_tail("o")
		helpers.assert_true(bucket ~= nil and #bucket >= 1)
	end)
end)




-- =====================================
-- =====================================
-- ======= 4/ defer_sort / flush_sort ===
-- =====================================
-- =====================================

helpers.describe("Registry.defer_sort / flush_sort", function()
	helpers.it("flush_sort applies pending sort", function()
		local state = fresh_registry()
		Registry.defer_sort()
		Registry.add("aa", "A", { is_case_sensitive = true })
		Registry.add("aaa", "AAA", { is_case_sensitive = true })
		-- During defer, calls to sort_mappings only flag a pending sort
		Registry.sort_mappings()
		Registry.flush_sort()
		helpers.assert_eq(state.mappings[1].trigger, "aaa")
	end)
end)




-- =====================================
-- =====================================
-- ======= 5/ Group lifecycle ===========
-- =====================================
-- =====================================

helpers.describe("Registry group lifecycle", function()
	helpers.it("register_lua_group creates an enabled group", function()
		local state = fresh_registry()
		Registry.register_lua_group("g1", "Group one", {})
		helpers.assert_eq(Registry.is_group_enabled("g1"), true)
		helpers.assert_eq(state.groups.g1.enabled, true)
	end)

	helpers.it("list_groups returns name → enabled map", function()
		fresh_registry()
		Registry.register_lua_group("ga", "A", {})
		Registry.register_lua_group("gb", "B", {})
		local list = Registry.list_groups()
		helpers.assert_eq(list.ga, true)
		helpers.assert_eq(list.gb, true)
	end)

	helpers.it("is_group_enabled returns false for unknown group", function()
		fresh_registry()
		helpers.assert_eq(Registry.is_group_enabled("nope"), false)
	end)
end)




-- =====================================
-- =====================================
-- ======= 6/ Section enablement ========
-- =====================================
-- =====================================

helpers.describe("Registry section enable/disable", function()
	helpers.it("default-enabled (settings entry absent)", function()
		fresh_registry()
		helpers.assert_eq(Registry.is_section_enabled("g", "s"), true)
	end)

	helpers.it("returns false when settings store has explicit false", function()
		fresh_registry()
		_G.hs.settings.set("ergopti.hotstrings_section_g_s", false)
		helpers.assert_eq(Registry.is_section_enabled("g", "s"), false)
	end)
end)





--- ========================================
--- ========================================
--- ======= 7/ Terminator re-exports =======
--- ========================================
--- ========================================

helpers.describe("Registry terminator re-exports", function()
	helpers.it("exposes the terminators API surface", function()
		helpers.assert_eq(type(Registry.is_terminator), "function")
		helpers.assert_eq(type(Registry.set_terminator_enabled), "function")
		helpers.assert_eq(type(Registry.set_terminators_enabled), "function")
		helpers.assert_eq(type(Registry.get_terminator_defs), "function")
	end)
end)





-- ======================================
-- ======================================
-- ======= 8/ update_trigger_char =======
-- ======================================
-- ======================================

helpers.describe("Registry.update_trigger_char", function()
	helpers.it("rejects non-string char", function()
		fresh_registry()
		Registry.update_trigger_char(nil)  -- Logs error, does not throw
	end)

	helpers.it("is a no-op when char is unchanged", function()
		local state = fresh_registry()
		Registry.update_trigger_char("★")
		helpers.assert_eq(state.magic_key, "★")
	end)

	helpers.it("renames magic-key triggers when the char changes", function()
		local state = fresh_registry()
		Registry.add("foo★", "Foo!", { is_case_sensitive = true })
		Registry.update_trigger_char("§")
		helpers.assert_eq(state.magic_key, "§")
		-- The mapping's trigger should now end with §
		local found = false
		for _, m in ipairs(state.mappings) do
			if m.trigger:sub(- #"§") == "§" then found = true ; break end
		end
		helpers.assert_true(found, "expected a trigger renamed to end in §")
		-- Restore the canonical magic key so later tests that check the
		-- default terminator state ("★" is enabled) are not affected.
		Registry.update_trigger_char("★")
	end)
end)





--- =======================================
--- =======================================
--- ======= 9/ Group enable/disable =======
--- =======================================
--- =======================================

helpers.describe("Registry group enable/disable", function()
	helpers.it("disable_group removes mappings from the live list", function()
		local state = fresh_registry()
		Registry.register_lua_group("g1", "G1", {})
		state.groups.g1.path = "fake_path"  -- Trigger the purge branch
		Registry.set_group_context("g1")
		Registry.add("alpha", "A", { is_case_sensitive = true })
		Registry.set_group_context(nil)
		local before = #state.mappings
		helpers.assert_true(before >= 1)
		Registry.disable_group("g1")
		helpers.assert_eq(Registry.is_group_enabled("g1"), false)
	end)

	helpers.it("disable_group is a no-op when group is unknown", function()
		fresh_registry()
		Registry.disable_group("nonexistent")
	end)

	helpers.it("enable_group warns on unknown group", function()
		fresh_registry()
		Registry.enable_group("nonexistent")  -- No crash
	end)

	helpers.it("set_post_load_hook accepts a function", function()
		fresh_registry()
		Registry.register_lua_group("g_hook", "G", {})
		Registry.set_post_load_hook("g_hook", function() end)
	end)

	helpers.it("set_post_load_hook rejects non-function value", function()
		fresh_registry()
		Registry.set_post_load_hook("g", "not a function")
	end)
end)





--- ========================================
--- ========================================
--- ======= 10/ get_meta_description =======
--- ========================================
--- ========================================

helpers.describe("Registry.get_meta_description", function()
	helpers.it("returns nil for unknown group", function()
		fresh_registry()
		helpers.assert_eq(Registry.get_meta_description("none"), nil)
	end)

	helpers.it("returns the recorded description after register_lua_group", function()
		fresh_registry()
		Registry.register_lua_group("gx", "Description X", {})
		helpers.assert_eq(Registry.get_meta_description("gx"), "Description X")
	end)
end)




-- Section 11: Collision priority tie-break (mirrors the AHK engine).

helpers.describe("Registry collision priority", function()
	helpers.it("source_priority ranks personal > package > common", function()
		fresh_registry()
		helpers.assert_eq(Registry.source_priority("personal"), 50)
		helpers.assert_eq(Registry.source_priority("PERSONAL"), 50)
		helpers.assert_eq(Registry.source_priority("ext.demo"), 30)
		helpers.assert_eq(Registry.source_priority("autocorrection"), 10)
		helpers.assert_eq(Registry.source_priority(nil), 10)
	end)

	-- Regression: the macOS loader registers the user's extra extension TOMLs
	-- under the group name "personal_ext_<stem>" (init.lua), the platform analog
	-- of Windows "ext.<id>" packages. They must score the PACKAGE tier (30), not
	-- silently fall to common (10) as they did before the personal_ext_ branch —
	-- otherwise the same extension file outranks common on Windows but ties it on
	-- macOS, breaking cross-driver parity and the documented loading order
	-- personal (50) > extension (30) > common (10).
	helpers.it("source_priority scores personal_ext_* as the package tier (parity with Windows ext.*)", function()
		fresh_registry()
		helpers.assert_eq(Registry.source_priority("personal_ext_demo"), 30)
		helpers.assert_eq(Registry.source_priority("PERSONAL_EXT_Demo"), 30)
		-- Nested stems use "__" as the separator; still package tier.
		helpers.assert_eq(Registry.source_priority("personal_ext_sub__group"), 30)
		-- The bare personal file stays at the personal tier, above its extensions.
		helpers.assert_eq(Registry.source_priority("personal"), 50)
	end)

	-- Regression: the hotstring editor reloads personal_hotstrings.toml into the
	-- "custom" group on a live save, while init.lua loads the same file as
	-- "personal" at boot. Scoring "custom" at the common tier (10) would make an
	-- edited personal hotstring lose to bundled common ones until the next restart
	-- (where it returns to tier 50) — an invisible cross-restart inconsistency.
	helpers.it("source_priority scores the editor's custom group at the personal tier", function()
		fresh_registry()
		helpers.assert_eq(Registry.source_priority("custom"), 50)
		helpers.assert_eq(Registry.source_priority("CUSTOM"), 50)
	end)

	helpers.it("add stores an explicit opts.priority on the mapping", function()
		local state = fresh_registry()
		Registry.add("qp", "QP", { is_case_sensitive = true, priority = 77 })
		helpers.assert_eq(#state.mappings, 1)
		helpers.assert_eq(state.mappings[1].priority, 77)
	end)

	helpers.it("defaults a missing priority to the common source value", function()
		local state = fresh_registry()
		Registry.add("qp", "QP", { is_case_sensitive = true })
		helpers.assert_eq(state.mappings[1].priority, 10)
	end)

	helpers.it("higher priority wins an equal-length collision", function()
		local state = fresh_registry()
		Registry.add("yy", "Y", { is_case_sensitive = true, priority = 10 })
		Registry.add("zz", "Z", { is_case_sensitive = true, priority = 90 })
		Registry.sort_mappings()
		-- Both length 2; the higher-priority trigger must sort first (without
		-- priority, seq order would put the first-added "yy" ahead).
		helpers.assert_eq(state.mappings[1].trigger, "zz")
		helpers.assert_eq(state.mappings[2].trigger, "yy")
	end)

	helpers.it("priority order is independent of insertion order", function()
		local state = fresh_registry()
		Registry.add("zz", "Z", { is_case_sensitive = true, priority = 90 })
		Registry.add("yy", "Y", { is_case_sensitive = true, priority = 10 })
		Registry.sort_mappings()
		helpers.assert_eq(state.mappings[1].trigger, "zz")
	end)

	helpers.it("longest trigger still wins over a shorter higher-priority one", function()
		local state = fresh_registry()
		Registry.add("ab",  "AB",  { is_case_sensitive = true, priority = 99 })
		Registry.add("abc", "ABC", { is_case_sensitive = true, priority = 1 })
		Registry.sort_mappings()
		helpers.assert_eq(state.mappings[1].trigger, "abc")
	end)

	-- Regression: before the group-aware dedup key, a same-trigger hotstring from a
	-- different source overwrote the earlier one in place (same trigger\0is_word\0
	-- auto key), keeping the FIRST entry's priority but the LAST entry's
	-- replacement. At startup personal loads first and common second, so the user's
	-- personal hotstring was silently clobbered by the bundled common one — the
	-- collision-priority feature became a no-op for its headline case. The two
	-- sources must now coexist as competing entries and the higher priority wins.
	helpers.it("a higher-priority source wins a same-trigger collision instead of being overwritten", function()
		local state = fresh_registry()
		-- Mirror the production load order: personal FIRST, then a bundled common
		-- hotstring sharing the trigger. Case-sensitive so no case variants are
		-- generated and exactly one entry exists per source.
		state.current_group = "personal"
		Registry.add("abc", "PERSONAL", { is_case_sensitive = true, priority = 50 })
		state.current_group = "common"
		Registry.add("abc", "COMMON", { is_case_sensitive = true, priority = 10 })
		state.current_group = nil
		Registry.sort_mappings()

		-- Both sources survive as distinct competing entries (not collapsed to one).
		local abc_entries = {}
		for _, m in ipairs(state.mappings) do
			if m.trigger == "abc" then abc_entries[#abc_entries + 1] = m end
		end
		helpers.assert_eq(#abc_entries, 2)

		-- The higher-priority personal entry is elected the winner: it sorts first
		-- in the "c" tail bucket, so typing "abc" expands to the personal text.
		local bucket = Registry.mappings_for_tail("c")
		helpers.assert_true(bucket ~= nil and #bucket >= 1, "tail bucket for 'c' must exist")
		helpers.assert_eq(bucket[1].repl, "PERSONAL")
		helpers.assert_eq(bucket[1].priority, 50)
	end)

	helpers.it("resolve_priority follows individual > section > file > source", function()
		fresh_registry()
		-- Individual wins over every lower level.
		helpers.assert_eq(Registry.resolve_priority(80, 60, 40, "personal"), 80)
		-- Section wins when there is no individual.
		helpers.assert_eq(Registry.resolve_priority(nil, 60, 40, "personal"), 60)
		-- File wins when there is no individual or section.
		helpers.assert_eq(Registry.resolve_priority(nil, nil, 40, "personal"), 40)
		-- Source default when nothing is set: personal 50, common 10.
		helpers.assert_eq(Registry.resolve_priority(nil, nil, nil, "personal"), 50)
		helpers.assert_eq(Registry.resolve_priority(nil, nil, nil, "autocorrection"), 10)
	end)
end)
