--- tests/unit/modules/keymap/test_section_toggle_batches.lua

--- ==============================================================================
--- MODULE: Regression — toggling N sections rebuilds the group once, not N times
--- DESCRIPTION:
--- enable_section/disable_section conflated "persist the user's choice" with
--- "rebuild the group", and each did the full rebuild unconditionally: tear the
--- group down, re-register every entry, re-sort the entire corpus, rebuild both
--- tail indexes. The menu's "toggle every section of this group" helper called
--- that once PER SECTION, so one click on a twenty-four-section group paid for
--- twenty-four rebuilds and kept the last one.
---
--- ROOT CAUSE ENCODED:
--- The API had no batch form, so the caller had no way to express "these N
--- choices, then one rebuild". Asserting on elapsed time would be a benchmark,
--- not a regression test — and this machine has no macOS runtime to measure on.
--- The invariant is COUNTABLE instead: how many times the group was torn down
--- and reloaded, which is what the work is proportional to.
---
--- The batched writer then used `enabled and nil or false` as a ternary. Lua's
--- `and/or` idiom cannot select nil: the nil falls through to `or false`, so an
--- enable click persisted the disabled state again. The persistence cases seed
--- explicit false values and assert both the raw store and the public reader.
--- ==============================================================================

local helpers = require("tests.helpers")

local GROUP = "rolls"
local SECTION_COUNT = 24


--- Loads registry_index with counting wrappers around the two rebuild halves.
--- @return table RI, table counts
local function load_with_counters()
	local Registry = helpers.load_with_stubs("modules.keymap.registry")
	package.loaded["modules.keymap.state"] = nil
	local State = require("modules.keymap.state")
	local state = State.new({ trigger_char = "★", expansion_delay = 0.4 }, {})
	Registry.init(state)
	Registry.register_lua_group(GROUP, "Rolls", {})
	Registry.set_post_load_hook(GROUP, function() end)
	local RI = package.loaded["modules.keymap.registry_index"]

	local counts = { disable = 0, enable = 0, settings = 0 }

	-- Count the rebuild, not the settings writes: the writes are cheap and must
	-- happen once per section, while the rebuild is the expensive half.
	local real_disable, real_enable = RI.disable_group, RI.enable_group
	RI.disable_group = function(...) counts.disable = counts.disable + 1; return real_disable(...) end
	RI.enable_group  = function(...) counts.enable  = counts.enable  + 1; return real_enable(...) end
	RI.is_group_enabled = function() return true end

	local real_set, real_clear = hs.settings.set, hs.settings.clear
	hs.settings.set = function(...) counts.settings = counts.settings + 1; return real_set(...) end
	hs.settings.clear = function(...) counts.settings = counts.settings + 1; return real_clear(...) end
	counts.restore = function()
		hs.settings.set = real_set
		hs.settings.clear = real_clear
	end

	return RI, counts
end


--- @return table Array of SECTION_COUNT section names.
local function section_names()
	local names = {}
	for i = 1, SECTION_COUNT do names[i] = "section_" .. i end
	return names
end




-- ==================================================================
-- ==================================================================
-- ======= 1/ One rebuild per batch, not one per section ============
-- ==================================================================
-- ==================================================================

helpers.describe("registry_index: a batched section toggle rebuilds the group once", function()

	helpers.it("enabling 24 sections tears the group down exactly once", function()
		local RI, counts = load_with_counters()

		RI.set_sections_enabled(GROUP, section_names(), true)
		counts.restore()

		helpers.assert_eq(counts.disable, 1,
			"toggling N sections of one group must rebuild that group exactly once; one rebuild "
			.. "per section discards all but the last and re-sorts the whole corpus each time")
		helpers.assert_eq(counts.enable, 1,
			"a fix that batches only the teardown half still pays for N reloads")
	end)

	helpers.it("still records every section's choice", function()
		local RI, counts = load_with_counters()

		RI.set_sections_enabled(GROUP, section_names(), false)
		counts.restore()

		helpers.assert_eq(counts.settings, SECTION_COUNT,
			"batching the rebuild must not batch away the persistence: every section's state "
			.. "still has to be written, or the choices are lost on reload")
	end)

	helpers.it("the single-section API still rebuilds once, so nothing regressed for it", function()
		local RI, counts = load_with_counters()

		RI.enable_section(GROUP, "section_1")
		counts.restore()

		helpers.assert_eq(counts.disable, 1)
		helpers.assert_eq(counts.settings, 1)
	end)

	helpers.it("an empty section list does no work at all", function()
		local RI, counts = load_with_counters()

		RI.set_sections_enabled(GROUP, {}, true)
		counts.restore()

		helpers.assert_eq(counts.disable, 0,
			"an empty batch must not rebuild the corpus for nothing")
	end)

	helpers.it("single-section enable clears the explicit disabled setting", function()
		local RI, counts = load_with_counters()
		RI.is_group_enabled = function() return false end
		local key = "hotstrings_section_" .. GROUP .. "_section_1"
		hs.settings.set(key, false)
		counts.settings = 0

		RI.enable_section(GROUP, "section_1")
		counts.restore()

		helpers.assert_nil(hs.settings.get(key),
			"enabling must remove the explicit false instead of persisting false again")
		helpers.assert_true(RI.is_section_enabled(GROUP, "section_1"),
			"the public reader must observe the section as enabled immediately")
		helpers.assert_eq(counts.settings, 1)
	end)

	helpers.it("batch enable clears every explicit disabled setting", function()
		local RI, counts = load_with_counters()
		RI.is_group_enabled = function() return false end
		local names = section_names()
		for _, section_name in ipairs(names) do
			hs.settings.set("hotstrings_section_" .. GROUP .. "_" .. section_name, false)
		end
		counts.settings = 0

		RI.set_sections_enabled(GROUP, names, true)
		counts.restore()

		for _, section_name in ipairs(names) do
			local key = "hotstrings_section_" .. GROUP .. "_" .. section_name
			helpers.assert_nil(hs.settings.get(key),
				"batch enable must clear every explicit false setting")
			helpers.assert_true(RI.is_section_enabled(GROUP, section_name))
		end
		helpers.assert_eq(counts.settings, SECTION_COUNT)
	end)

end)
