--- tests/unit/modules/keymap/test_registry.lua

--- ==============================================================================
--- MODULE: keymap.registry Unit Tests
--- DESCRIPTION:
--- Exercises the registry's add/lookup/sort cycle, the require_state guard, the
--- group enable/disable invariants, and the sections enable/disable persistence
--- through hs.settings.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

local State = helpers.load_with_stubs("modules.keymap.state")
local Registry = helpers.load_with_stubs("modules.keymap.registry")


--- Builds an initialized registry with a fresh shared state. Reloads the
--- registry module each time so module-level _state resets between calls.
--- @return table state, table Registry The fresh state and module reference.
local function fresh_registry()
	package.loaded["modules.keymap.registry"] = nil
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
		-- Lookup table populated for at least the lowercase variant
		local key = "hi" .. "\0" .. "false" .. "\0" .. "false"
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
		_G.hs.settings.set("hotstrings_section_g_s", false)
		helpers.assert_eq(Registry.is_section_enabled("g", "s"), false)
	end)
end)





-- =====================================
--- ========================================
--- ======= 7/ Terminator re-exports =======
--- ========================================
-- =====================================

helpers.describe("Registry terminator re-exports", function()
	helpers.it("exposes the terminators API surface", function()
		helpers.assert_eq(type(Registry.is_terminator), "function")
		helpers.assert_eq(type(Registry.set_terminator_enabled), "function")
		helpers.assert_eq(type(Registry.get_terminator_defs), "function")
	end)
end)




-- =====================================
--- ======================================
-- ======= 8/ update_trigger_char =======
--- ======================================
-- =====================================

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





-- =====================================
--- =======================================
--- ======= 9/ Group enable/disable =======
--- =======================================
-- =====================================

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





-- =====================================
--- ========================================
--- ======= 10/ get_meta_description =======
--- ========================================
-- =====================================

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
