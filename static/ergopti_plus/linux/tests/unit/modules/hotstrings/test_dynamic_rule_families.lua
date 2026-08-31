--- tests/unit/modules/hotstrings/test_dynamic_rule_families.lua

--- ==============================================================================
--- MODULE: One Switch per Dynamic Rule Family
--- DESCRIPTION:
--- The per-family toggles Windows and macOS have always had, and the thing that
--- makes them toggles rather than decoration: switching one off has to stop that
--- family from firing.
---
--- THE DEFECT CLASS THIS PINS:
--- A switch that flips a stored boolean nothing consults. Linux passed `nil` as
--- the section predicate at both call sites of the shared engine — `match_buffer`
--- and `preview` — so every rule fired unconditionally. A toggle added on top of
--- that would have persisted, ticked, survived a restart, and changed nothing
--- about what the driver typed. That failure is silent from every angle except
--- this one, which is why the runtime half comes first here and the menu half
--- second.
---
--- WHY THE PLAN CALLED THIS BLOCKED, AND WHY IT WAS NOT:
--- The Linux plan recorded the blocker as "the shared engine registers the three
--- date rules as a batch, with no identifier". Reading it settles the question:
--- `add_rule(suffix, section, resolver)` has carried a section since it was
--- written, `register_date_rules` passes "date"/"datefr"/"datelongfr", and
--- `match_buffer(buffer, group, predicate)` has always filtered on it. Nothing
--- was blocked; one argument was missing at two call sites.
---
--- WHAT IS NOT ASSERTED HERE:
--- That the tray draws the rows. `build` returns a description of a menu, and
--- turning that into GTK widgets needs a display — HARDWARE.md covers it.
--- ==============================================================================

local helpers = require("tests.helpers")

local Fakes = helpers.load_module("tests.fakes")

--- Installs a fake storage adapter and returns it.
---
--- The manager re-requires the adapter on every call rather than caching it, so
--- swapping `package.loaded` is enough and no re-init is needed.
--- @param initial table|nil Pre-existing stored values.
--- @return table
local function with_storage(initial)
	local storage = Fakes.storage({ initial = initial })
	package.loaded["adapters.storage"] = storage
	return storage
end

--- Drops the fake, so nothing leaks into the tests that follow.
local function drop_storage()
	package.loaded["adapters.storage"] = nil
end

--- A manager initialised with the date rules registered.
--- @return table
local function manager()
	local dh = helpers.load_module("modules.dynamic_hotstrings.manager")
	dh.init({ trigger_char = "\\" })
	dh.set_enabled(true)
	return dh
end

-- What each date family expands, so a preview can be attributed to a family.
local TRIGGER_FOR = { date = "td", datefr = "dt", datelongfr = "date" }




-- =================================================================
-- =================================================================
-- ======= 1/ A switched-off family stops firing ===================
-- =================================================================
-- =================================================================

helpers.describe("dynamic rule families: the switch reaches the engine", function()

	helpers.it("previews every family while they are all on", function()
		with_storage()
		local dh = manager()
		for section, trigger in pairs(TRIGGER_FOR) do
			helpers.assert_not_nil(dh.preview(trigger .. "\\"),
				section .. " expands before anything is switched off")
		end
		drop_storage()
	end)

	helpers.it("stops previewing the family that was switched off", function()
		with_storage()
		local dh = manager()
		dh.set_rule_enabled("datefr", false)

		helpers.assert_nil(dh.preview("dt\\"),
			"the bubble must not offer a family the engine will refuse: a user who "
				.. "sees the expansion they just disabled concludes the switch is broken")
		helpers.assert_not_nil(dh.preview("td\\"),
			"and only that family — switching one off must not take its siblings with it")
		drop_storage()
	end)

	helpers.it("stops INJECTING the family that was switched off", function()
		with_storage()
		local dh = manager()
		dh.set_rule_enabled("date", false)

		local previous = package.loaded["modules.hotstrings.injector"]
		local injected = nil
		package.loaded["modules.hotstrings.injector"] = {
			inject = function(_count, text)
				injected = text
				return { ok = true }
			end,
		}

		local fired_off = dh.on_trigger("td\\", "\\")
		local fired_on  = dh.on_trigger("dt\\", "\\")

		package.loaded["modules.hotstrings.injector"] = previous
		drop_storage()

		helpers.assert_true(fired_off == false,
			"the preview and the injection are two separate call sites and the "
				.. "predicate has to reach both — guarding only the preview leaves a "
				.. "driver that shows nothing and types anyway")
		helpers.assert_true(fired_on == true, "the family still on keeps expanding")
		helpers.assert_not_nil(injected, "and it is the one that reached the injector")
	end)

	helpers.it("brings a family back when it is switched on again", function()
		with_storage({ ["hotstrings.dynamic.datelongfr"] = false })
		local dh = manager()
		helpers.assert_nil(dh.preview("date\\"), "off is read back from storage on boot")

		dh.set_rule_enabled("datelongfr", true)
		helpers.assert_not_nil(dh.preview("date\\"), "and on brings it back")
		drop_storage()
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ What is stored ========================================
-- =================================================================
-- =================================================================

helpers.describe("dynamic rule families: persistence", function()

	helpers.it("stores nothing for a family left at its shipped default", function()
		local storage = with_storage()
		local dh = manager()
		dh.rule_families()
		helpers.assert_eq(#storage.keys(), 0,
			"writing the default would freeze today's default for anyone who had "
				.. "already run the driver once, so only the OFF state is persisted")
		drop_storage()
	end)

	helpers.it("uses the same preference path macOS uses", function()
		local storage = with_storage()
		local dh = manager()
		dh.set_rule_enabled("datefr", false)
		helpers.assert_eq(storage.get("hotstrings.dynamic.datefr"), false,
			"macos/infra/preferences.lua maps dynamichotstrings_datefr to "
				.. "hotstrings.dynamic.datefr; a driver-local spelling would make the "
				.. "same user's choice mean nothing on the other platform")
		drop_storage()
	end)

	helpers.it("clears the key rather than storing true", function()
		local storage = with_storage({ ["hotstrings.dynamic.date"] = false })
		local dh = manager()
		dh.set_rule_enabled("date", true)
		helpers.assert_true(not storage.has("hotstrings.dynamic.date"),
			"back to the default means back to no entry")
		drop_storage()
	end)

	helpers.it("refuses a section that is not a family", function()
		local storage = with_storage()
		local dh = manager()
		helpers.assert_true(dh.set_rule_enabled("datefrr", false) == false,
			"a typo must be reported, not silently written")
		helpers.assert_eq(#storage.keys(), 0, "and must write nothing")
		drop_storage()
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 3/ The rows ==============================================
-- =================================================================
-- =================================================================

--- The smallest hotstrings config the menu builder accepts. Without one the
--- whole Hotstrings submenu collapses to "(config non disponible)" and the
--- dynamic handler never runs — so the rows would be missing for a reason that
--- has nothing to do with what this file is testing.
--- @return table
local function empty_config()
	return {
		get_groups         = function() return {} end,
		is_group_enabled   = function() return false end,
		toggle_group       = function() end,
		is_section_enabled = function() return false end,
		toggle_section     = function() end,
		set_all_sections   = function() end,
		get_category       = function() return nil end,
		reload             = function() end,
	}
end

--- The dynamic category's submenu, as the tray builder returns it.
--- @param dh table The manager to hand the builder.
--- @return table|nil
local function dynamic_submenu(dh)
	local mb = helpers.load_module("ui.menu.menu_builder")
	local first = dh.rule_families()[1].label
	local found = nil

	local function search(list)
		for _, item in ipairs(list or {}) do
			if type(item.menu) == "table" then
				for _, row in ipairs(item.menu) do
					if row.title == first then found = item.menu ; return end
				end
				search(item.menu)
				if found then return end
			end
		end
	end
	search(mb.build({ _version = "9.9.9", dyn_hotstrings = dh, config = empty_config() }))
	return found
end

helpers.describe("dynamic rule families: the rows", function()

	helpers.it("offers one row per family, ticked from storage", function()
		with_storage({ ["hotstrings.dynamic.datefr"] = false })
		local dh = manager()
		local sub = dynamic_submenu(dh)
		helpers.assert_not_nil(sub, "the dynamic category has a submenu")

		local ticks = {}
		for _, family in ipairs(dh.rule_families()) do
			if family.label then
				for _, row in ipairs(sub) do
					if row.title == family.label then ticks[family.section] = row.checked end
				end
			end
		end

		helpers.assert_eq(ticks.datefr, false, "the family switched off is unticked")
		helpers.assert_eq(ticks.date, true, "the ones left alone are ticked")
		helpers.assert_eq(ticks.datelongfr, true)
		helpers.assert_eq(ticks.personal_info, true,
			"the @-tag family is a family too, and Windows renders it last with a "
				.. "separator before it")
		drop_storage()
	end)

	helpers.it("flips the family the row names when it is clicked", function()
		local storage = with_storage()
		local dh = manager()
		local sub = dynamic_submenu(dh)

		local label = nil
		for _, family in ipairs(dh.rule_families()) do
			if family.section == "datelongfr" then label = family.label end
		end
		for _, row in ipairs(sub) do
			if row.title == label then row.fn() end
		end

		helpers.assert_eq(storage.get("hotstrings.dynamic.datelongfr"), false,
			"a row bound to the wrong section is invisible in the tray and only "
				.. "shows up as the wrong expansion disappearing")
		drop_storage()
	end)

	helpers.it("shows today's date in the label, not the placeholder", function()
		with_storage()
		local dh = manager()
		local Engine = require("dynamic_hotstrings")
		local today = Engine.today_date_strings()

		for _, family in ipairs(dh.rule_families()) do
			if family.section == "datefr" then
				helpers.assert_true(not family.label:find("{date}", 1, true),
					"an unsubstituted placeholder reaches the tray verbatim")
				helpers.assert_contains(family.label, today.fr,
					"the label promises what the rule inserts, so it must come from the "
						.. "engine that inserts it")
			end
		end
		drop_storage()
	end)

	helpers.it("greys every family row while the category itself is off", function()
		with_storage()
		local dh = manager()
		dh.set_enabled(false)
		local sub = dynamic_submenu(dh)
		dh.set_enabled(true)

		local seen = 0
		for _, row in ipairs(sub or {}) do
			if row.checked ~= nil then
				seen = seen + 1
				helpers.assert_true(row.disabled,
					"a row that can be clicked under a switched-off category writes a "
						.. "preference the engine is not reading")
			end
		end
		helpers.assert_true(seen > 0, "the rows are greyed, not absent")
		drop_storage()
	end)

end)
