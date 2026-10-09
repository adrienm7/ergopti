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

local Manifest = require("infra.manifest_reader")
local previous_preferences = package.loaded["infra.hotstring_preferences"]

--- Installs an in-memory canonical preference owner and returns it.
---
--- The manager is loaded fresh after the swap, so it binds this owner. It keeps
--- the real owner's contract: canonical paths and sparse writes against the
--- manifest's neutral defaults. The real owner's file behaviour has its own test.
--- @param initial table|nil Pre-existing explicit values by canonical path.
--- @param writes_fail boolean|nil Whether writes are refused.
--- @return table
local function with_storage(initial, writes_fail)
	local storage = { values = {} }
	for path, value in pairs(initial or {}) do storage.values[path] = value end
	function storage.get(path)
		local value = storage.values[path]
		if value == nil then return Manifest.default_for(path) end
		return value
	end
	function storage.is_explicit(path) return storage.values[path] ~= nil end
	function storage.has(path) return storage.values[path] ~= nil end
	--- The family leaves only: the fixture switches the master on first.
	function storage.family_keys()
		local keys = {}
		for path in pairs(storage.values) do
			if path ~= "hotstrings.dynamic.enabled" then keys[#keys + 1] = path end
		end
		return keys
	end
	function storage.set(path, value)
		if writes_fail then return false end
		if value == Manifest.default_for(path) then storage.values[path] = nil else storage.values[path] = value end
		return true
	end
	package.loaded["infra.hotstring_preferences"] = storage
	return storage
end

--- Restores the owner, so nothing leaks into the tests that follow.
local function drop_storage()
	package.loaded["infra.hotstring_preferences"] = previous_preferences
end

--- A manager initialised with the date rules registered.
--- @return table
local function manager(import_families)
	local dh = helpers.load_module("modules.dynamic_hotstrings.manager")
	dh.init({ trigger_char = "\\" })
	dh.set_enabled(true)
	if import_families then
		for _, family in ipairs(dh.RULE_FAMILIES) do
			if family.section then assert(dh.set_rule_enabled(family.section, true)) end
		end
	end
	return dh
end

helpers.describe("dynamic rule families: bulk owner dispatch", function()
	helpers.it("dynamic bulk: passes an explicit posture, actual manager and ordinary matcher to one owner", function()
		with_storage()
		local dh = manager()
		local previous = package.loaded["infra.dynamic_hotstrings_scope"]
		local requests, config = {}, {}
		package.loaded["infra.dynamic_hotstrings_scope"] = {
			apply = function(enabled, dynamic, ordinary)
				requests[#requests + 1] = { enabled = enabled, dynamic = dynamic, config = ordinary }
				return false, "refused"
			end,
		}
		local called, committed, detail = pcall(function() return dh.set_scope_enabled(true, config) end)
		package.loaded["infra.dynamic_hotstrings_scope"] = previous
		drop_storage()
		helpers.assert_true(called, tostring(committed))
		helpers.assert_eq(committed, false, "the manager does not replace refusal with success")
		helpers.assert_eq(detail, "refused")
		helpers.assert_eq(requests, { { enabled = true, dynamic = dh, config = config } })
	end)
end)

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
		local dh = manager(true)
		for section, trigger in pairs(TRIGGER_FOR) do
			helpers.assert_not_nil(dh.preview(trigger .. "\\", true),
				section .. " expands before anything is switched off")
		end
		drop_storage()
	end)

	helpers.it("stops previewing the family that was switched off", function()
		with_storage()
		local dh = manager(true)
		dh.set_rule_enabled("datefr", false)

		helpers.assert_nil(dh.preview("dt\\", true),
			"the bubble must not offer a family the engine will refuse: a user who "
				.. "sees the expansion they just disabled concludes the switch is broken")
		helpers.assert_not_nil(dh.preview("td\\", true),
			"and only that family — switching one off must not take its siblings with it")
		drop_storage()
	end)

	helpers.it("stops INJECTING the family that was switched off", function()
		with_storage()
		local dh = manager(true)
		dh.set_rule_enabled("date", false)

		local previous = package.loaded["modules.hotstrings.injector"]
		local injected = nil
		package.loaded["modules.hotstrings.injector"] = {
			inject = function(_count, text)
				injected = text
				return { ok = true }
			end,
		}

		local fired_off = dh.on_trigger("td\\", "\\", true)
		local fired_on  = dh.on_trigger("dt\\", "\\", true)

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
		with_storage({ ["hotstrings.dynamic.date_long_fr.enabled"] = false })
		local dh = manager()
		helpers.assert_nil(dh.preview("date\\", true), "off is read back from storage on boot")

		dh.set_rule_enabled("datelongfr", true)
		helpers.assert_not_nil(dh.preview("date\\", true), "and on brings it back")
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
		helpers.assert_eq(#storage.family_keys(), 0,
			"writing the default would freeze today's default for anyone who had "
				.. "already run the driver once, so neutral absence stays absent")
		drop_storage()
	end)

	helpers.it("uses the family's canonical manifest leaf", function()
		local storage = with_storage()
		local dh = manager()
		dh.set_rule_enabled("datefr", true)
		helpers.assert_eq(storage.values["hotstrings.dynamic.date_fr.enabled"], true,
			"the manifest row hotstrings.dynamic.date_fr declares the leaf, so the "
				.. "cleanup and the scopes own the same key the switch writes")
		drop_storage()
	end)

	helpers.it("clears the key rather than storing the neutral false", function()
		local storage = with_storage({ ["hotstrings.dynamic.date.enabled"] = true })
		local dh = manager()
		dh.set_rule_enabled("date", false)
		helpers.assert_true(not storage.has("hotstrings.dynamic.date.enabled"),
			"back to the default means back to no entry")
		drop_storage()
	end)

	helpers.it("refuses a section that is not a family", function()
		local storage = with_storage()
		local dh = manager()
		helpers.assert_true(dh.set_rule_enabled("datefrr", false) == false,
			"a typo must be reported, not silently written")
		helpers.assert_eq(#storage.family_keys(), 0, "and must write nothing")
		drop_storage()
	end)

	helpers.it("reports failed writes and keeps the durable family state", function()
		local storage = with_storage({ ["hotstrings.dynamic.date.enabled"] = false,
			["hotstrings.dynamic.date_fr.enabled"] = true }, true)
		local dh = manager()
		helpers.assert_eq(dh.set_rule_enabled("date", true), false)
		helpers.assert_eq(dh.is_rule_enabled(nil, "date"), false,
			"a failed write must not make the family appear enabled")
		helpers.assert_eq(dh.set_rule_enabled("datefr", false), false)
		helpers.assert_eq(dh.is_rule_enabled(nil, "datefr"), true,
			"a failed delete must not make the family appear disabled")
		helpers.assert_eq(storage.values["hotstrings.dynamic.date.enabled"], false)
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
		with_storage({ ["hotstrings.dynamic.date_fr.enabled"] = false, ["hotstrings.dynamic.date.enabled"] = true,
			["hotstrings.dynamic.date_long_fr.enabled"] = true,
			["hotstrings.dynamic.text_expansion_personal_information.enabled"] = true })
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
		helpers.assert_eq(ticks.date, true, "explicitly enabled families remain ticked")
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

		helpers.assert_eq(storage.values["hotstrings.dynamic.date_long_fr.enabled"], true,
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

		-- Explicit scoped commands remain available so a closed category can
		-- recover in one transaction; individual family choices still stay grey.
		for index, key in ipairs({ "menu.hotstrings.scope_enable_all", "menu.hotstrings.scope_disable_all" }) do
			local command = (sub or {})[index]
			helpers.assert_not_nil(command)
			helpers.assert_eq(command.title, require("infra.i18n").get(key))
			helpers.assert_nil(command.checked)
			helpers.assert_eq(command.disabled == true, false)
			helpers.assert_type(command.fn, "function")
		end

		local seen = 0
		for i, row in ipairs(sub or {}) do
			if i > 1 and row.checked ~= nil then
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

helpers.describe("dynamic menu shared family order", function()
	local file = assert(io.open(require("infra.paths").shared("tests/corpus/dynamic_hotstrings/menu_vectors.json"), "rb"))
	local corpus = assert(require("json").decode(file:read("*a")))
	file:close()
	helpers.it("keeps the independent published family metadata and returns detached records", function()
		local menu = require("infra.manifest_menu")
		local root = assert(menu.get_root())
		helpers.assert_eq(root.dynamic_hotstring_families.rows, corpus.rows,
			"the pre-centralization metadata snapshot must remain exact")
		local first = menu.get_dynamic_hotstring_families()
		local second = menu.get_dynamic_hotstring_families()
		for index, expected in ipairs(corpus.rows) do
			helpers.assert_eq(second[index].date_field, expected.date_field)
			helpers.assert_eq(second[index].is_prefix, expected.is_prefix)
			helpers.assert_eq(second[index].i18n, expected.i18n)
			helpers.assert_eq(second[index].is_module_placeholder, expected.is_module_placeholder)
			helpers.assert_eq(second[index].linux_section, expected.linux_section)
			helpers.assert_eq(second[index].legacy_key, expected.legacy_key)
		end
		first[1].section = "changed-in-first-caller"
		first[#first + 1] = { separator = true }
		helpers.assert_eq(second[1].section, "datelongfr")
		helpers.assert_eq(#second, 8)
		helpers.assert_eq(root.dynamic_hotstring_families.rows, corpus.rows,
			"native callers cannot mutate the manifest cache")
	end)
	for _, vector in ipairs(corpus.vectors) do
		helpers.it("consumes the actual published family order: " .. vector.id, function()
			local menu = require("infra.manifest_menu")
			local root = assert(menu.get_root())
			local previous = root.dynamic_hotstring_families
			local rows = {}
			for _, index in ipairs(vector.indices) do rows[#rows + 1] = corpus.rows[index] end
			root.dynamic_hotstring_families = { rows = rows }
			local called, observed = xpcall(function()
				with_storage()
				local dh = manager()
				local result = {}
				for _, family in ipairs(dh.rule_families()) do
					result[#result + 1] = family.separator and "-" or family.section
				end
				return result
			end, debug.traceback)
			root.dynamic_hotstring_families = previous
			drop_storage()
			helpers.assert_true(called, tostring(observed))
			helpers.assert_eq(observed, vector.linux,
				"the real native family publisher must use the shared child records, including separators")
		end)
	end
end)

return true
