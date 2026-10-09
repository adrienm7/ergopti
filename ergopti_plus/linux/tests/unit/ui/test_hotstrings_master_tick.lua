--- tests/unit/ui/test_hotstrings_master_tick.lua

--- ==============================================================================
--- MODULE: Regression — the Hotstrings tick is what the engine expands
--- DESCRIPTION:
--- Runs a first-run wizard answer through the real answers contract into a
--- private config.toml, loads it with the real hotstring configuration owner,
--- and builds the real tray over it. The tick, the mappings the engine
--- receives and the file must agree after the wizard, after the switch is
--- clicked, and after a reload.
---
--- WHY IT EXISTS (hotstrings-master-tick): this driver's Hotstrings switch has
--- no flag of its own; its tick read « every category on », while the engine
--- expands any open category. The wizard's recommendation opens one section of
--- one category, so a fresh configuration showed Hotstrings unticked while ★
--- expanded, and clicking the unticked switch turned every category on.
--- ==============================================================================

local helpers = require("tests.helpers")
local Choices = require("tests.support.hotstring_choices")

local Answers = require("onboarding_answers")





-- ===============================
-- ===============================
-- ======= 1/ Fixtures ===========
-- ===============================
-- ===============================

--- The wizard catalogue's Linux Hotstrings page.
--- @return table index, table page
local function wizard_page()
	local handle = assert(io.open(helpers.driver_root() .. "/../_shared/" .. Answers.CATALOGUE_PATH, "r"))
	local index = Answers.load(handle:read("*a"), "linux")
	handle:close()
	for _, page in ipairs(index.pages) do
		if page.id == "hotstrings" then return index, page end
	end
	error("the Linux wizard has no Hotstrings page")
end

--- The operations the page sends for the Hotstrings question on a fresh
--- configuration, as its _operations() builds them: a Yes checks the
--- recommendation and writes every item and file switch that differs from its
--- neutral value; a No writes nothing on a page without a master.
--- @param page table
--- @param answer boolean
--- @return table operations
local function page_operations(page, answer)
	local operations = {}
	if page.master then operations[1] = { path = page.master.path, value = answer } end
	if not answer then return operations end
	local function walk(groups)
		for _, group in ipairs(groups or {}) do
			local checked = 0
			for _, item in ipairs(group.items or {}) do
				if item.recommended == true then
					checked = checked + 1
					operations[#operations + 1] = { path = item.path, value = item.value }
				end
			end
			walk(group.groups)
			if type(group.path) == "string" and checked > 0 then
				operations[#operations + 1] = { path = group.path, value = group.value }
			end
		end
	end
	walk(page.groups)
	return operations
end

--- The catalogue the page offers, one mapping per section, for the loader.
--- @param page table
--- @return table categories, table mappings
local function catalogue(page)
	local categories, mappings = {}, {}
	local function walk(groups)
		for _, group in ipairs(groups or {}) do
			local stem = type(group.path) == "string" and group.path:match("^hotstrings%.groups%.(.+)$")
			if stem then
				local category = { id = stem, count = 0, sections_order = {}, sections = {} }
				for _, item in ipairs(group.items or {}) do
					local section = item.path:match("%.([^%.]+)$")
					category.sections_order[#category.sections_order + 1] = section
					category.sections[section] = { count = 1 }
					category.count = category.count + 1
					mappings[#mappings + 1] = { trigger = stem .. "_" .. section, replacement = "x",
						group = stem, section = section }
				end
				categories[stem] = category
			end
			walk(group.groups)
		end
	end
	walk(page.groups)
	return categories, mappings
end

--- The one section the recommendation imports.
--- @param page table
--- @return string trigger The trigger of its mapping.
local function recommended_trigger(page)
	for _, operation in ipairs(page_operations(page, true)) do
		local group, section = operation.path:match("^hotstrings%.modules%.([^%.]+)%.([^%.]+)$")
		if group then return group .. "_" .. section end
	end
	error("the recommendation imports no hotstring section")
end

--- A dynamic-hotstrings manager double.
--- @param on boolean
--- @return table
local function dyn_double(on)
	local dyn = { on = on }
	function dyn.is_enabled() return dyn.on end
	function dyn.set_enabled(value) dyn.on = value; return true end
	function dyn.active_count() return 0 end
	function dyn.rule_families() return {} end
	return dyn
end

--- Runs a scenario over a fresh configuration the wizard answered.
--- @param answer boolean The Hotstrings question's answer.
--- @param scenario function scenario(world)
local function with_wizard(answer, scenario)
	local index, page = wizard_page()
	local categories, mappings = catalogue(page)
	local rows = assert(Answers.rows(index, page_operations(page, answer), require("infra.manifest_reader")))
	local saved_loader = package.loaded["modules.hotstrings.loader"]
	package.loaded["modules.hotstrings.loader"] = {
		find_toml_files = function() return {} end,
		list_subdirs = function() return {} end,
		read_file = function() return nil end,
		load_catalogue = function()
			return { committed = true, errors = 0, categories = categories, mappings = mappings }
		end,
	}
	local ok, err = pcall(function()
		local Config = helpers.load_module("modules.hotstrings.hotstrings_config")
		Choices.with_file(Config, nil, function(path)
			if #rows > 0 then
				helpers.assert_true(require("toml_codec.writer").batch_write(path, rows) == true,
					"the wizard batch must commit")
			end
			local world = { Config = Config, path = path, page = page, dyn = dyn_double(false) }
			--- Starts one session from the file, as a reload does.
			function world.boot()
				world.published = {}
				Config.init({ load_mappings = function(_, published)
					world.published[#world.published + 1] = published
					return true
				end }, "virtual.toml", nil)
				local _, committed = Config.load_all()
				helpers.assert_true(committed, "the fixture catalogue must publish")
			end
			--- Whether typing this trigger expands: the engine holds its mapping.
			function world.expands(trigger)
				for _, mapping in ipairs(world.published[#world.published] or {}) do
					if mapping.trigger == trigger then return true end
				end
				return false
			end
			--- The real tray's Hotstrings row.
			function world.row()
				local mb = helpers.load_module("ui.menu.menu_builder")
				local title = require("infra.i18n").get("menu.hotstrings.title")
				local ctx = { config = Config, _version = "9.9.9", dyn_hotstrings = world.dyn }
				for _, item in ipairs(mb.build(ctx) or {}) do
					if type(item.title) == "string" and item.title:sub(1, #title) == title then return item end
				end
				error("the tray has no Hotstrings row")
			end
			--- The switch, first row of the Hotstrings submenu.
			function world.switch()
				local first = world.row().menu[1]
				helpers.assert_eq(first.title, require("infra.i18n").get("menu.hotstrings.enable"),
					"the Hotstrings submenu opens with its switch")
				return first
			end
			scenario(world)
		end)
	end)
	package.loaded["modules.hotstrings.loader"] = saved_loader
	package.loaded["modules.hotstrings.hotstrings_config"] = nil
	if not ok then error(err, 0) end
end





-- ===============================
-- ===============================
-- ======= 2/ Scenarios ==========
-- ===============================
-- ===============================

helpers.describe("the Hotstrings tick follows the engine (hotstrings-master-tick)", function()

	helpers.it("(hotstrings-master-tick) a fresh wizard Yes ticks the switch and expands", function()
		with_wizard(true, function(world)
			local trigger = recommended_trigger(world.page)
			world.boot()
			helpers.assert_true(world.expands(trigger), "the recommended section expands after the wizard's Yes")
			helpers.assert_eq(world.row().checked, true, "the Hotstrings row is ticked while it expands")
			helpers.assert_eq(world.switch().checked, true, "and so is its switch")
		end)
	end)

	helpers.it("(hotstrings-master-tick) switching off stops every expansion and unticks, then and after reload", function()
		with_wizard(true, function(world)
			local trigger = recommended_trigger(world.page)
			world.boot()
			world.dyn.on = true
			world.switch().fn()
			helpers.assert_eq(world.expands(trigger), false, "switching off stops the expansion")
			helpers.assert_eq(world.dyn.on, false, "and the dynamic hotstrings")
			helpers.assert_true(world.row().checked ~= true, "the Hotstrings row is unticked")
			helpers.assert_true(world.switch().checked ~= true, "and so is its switch")

			world.boot()
			helpers.assert_eq(world.expands(trigger), false, "a reload keeps every category off")
			helpers.assert_true(world.row().checked ~= true, "and the row unticked")

			world.switch().fn()
			helpers.assert_true(world.expands(trigger), "switching on expands again")
			helpers.assert_eq(world.row().checked, true, "and ticks the row")
			world.boot()
			helpers.assert_true(world.expands(trigger), "after a reload too")
			helpers.assert_eq(world.row().checked, true, "with the row still ticked")
		end)
	end)

	helpers.it("(hotstrings-master-tick) a fresh wizard No leaves everything off and the tick off", function()
		with_wizard(false, function(world)
			world.boot()
			helpers.assert_eq(#(world.published[#world.published] or {}), 0, "nothing reaches the engine")
			helpers.assert_true(world.row().checked ~= true, "the Hotstrings row is unticked")
		end)
	end)

end)
