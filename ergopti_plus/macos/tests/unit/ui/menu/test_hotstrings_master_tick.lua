--- tests/unit/ui/menu/test_hotstrings_master_tick.lua

--- ==============================================================================
--- MODULE: Regression — the Hotstrings tick is the typing engine's switch
--- DESCRIPTION:
--- Runs a first-run wizard answer through the real answers contract into a
--- fresh config.toml, loads it with the real preferences owner, lets the real
--- boot synchronization start or stop the typing engine, and builds the real
--- tray over the loaded state. The tick, the engine and the file must agree
--- after the wizard, after the switch is clicked, and after a reload.
---
--- WHY IT EXISTS (hotstrings-master-tick): the tray ticked Hotstrings only when
--- every category was on, while the engine expanded as soon as
--- hotstrings.enabled was on. The wizard's Yes turns that master on with the
--- recommendation, which imports one section of one category, so a fresh
--- configuration showed Hotstrings unticked while ★ expanded. Clicking the
--- unticked switch then turned every category on, and switching it off left
--- the engine running for the personal groups.
--- ==============================================================================

local helpers = require("tests.helpers")
local output_fixture = require("tests.support.toml_output_fixture")

local Answers = require("onboarding_answers")

-- The menu modules ui/menu/init.lua loads, under the keys Builder.generate reads.
local MENU_MODULES = {
	hotstrings = "ui.menu.menu_hotstrings",
}





-- ===============================
-- ===============================
-- ======= 1/ Fixtures ===========
-- ===============================
-- ===============================

--- The generated wizard catalogue, read through the driver's path owner.
--- @return string
local function catalogue_text()
	local path = require("infra.paths").shared(Answers.CATALOGUE_PATH)
	local fh = assert(io.open(path, "r"), "the onboarding catalogue is missing: " .. tostring(path))
	local text = fh:read("*a")
	fh:close()
	return text
end

--- The wizard page with the given id.
--- @param index table From Answers.load.
--- @param id string
--- @return table
local function page_of(index, id)
	for _, page in ipairs(index.pages) do
		if page.id == id then return page end
	end
	error("no onboarding page " .. id)
end

--- The operations the page sends for the Hotstrings question on a fresh
--- configuration, as the page's _operations() builds them: the master is
--- always explicit; a Yes checks the recommendation and writes every item and
--- file switch that differs from its neutral value.
--- @param page table The catalogue's hotstrings page.
--- @param answer boolean
--- @return table operations
local function page_operations(page, answer)
	local operations = { { path = page.master.path, value = answer } }
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

--- The category and section inventory the page offers: the groups the engine
--- registers for these files.
--- @param page table
--- @return table groups `{ [stem] = { section, ... } }`
--- @return table hotfiles Group names in a stable order.
local function inventory(page)
	local groups, hotfiles = {}, {}
	local function walk(list)
		for _, group in ipairs(list or {}) do
			local stem = type(group.path) == "string" and group.path:match("^hotstrings%.groups%.(.+)$")
			if stem then
				groups[stem] = {}
				hotfiles[#hotfiles + 1] = stem
				for _, item in ipairs(group.items or {}) do
					groups[stem][#groups[stem] + 1] = item.path:match("%.([^%.]+)$")
				end
			end
			walk(group.groups)
		end
	end
	walk(page.groups)
	table.sort(hotfiles)
	return groups, hotfiles
end

--- A typing engine that keeps the registry's gates: a trigger expands only
--- while the taps run, its category is on and its section is on.
--- @param groups table Inventory from inventory().
--- @param Preferences table The real preferences owner.
--- @return table engine
local function engine_double(groups, Preferences)
	local engine = { started = false, starts = 0, stops = 0, groups = {}, sections = {} }
	function engine.start()
		engine.starts = engine.starts + 1
		engine.started = true
		return true
	end
	function engine.stop()
		engine.stops = engine.stops + 1
		engine.started = false
		return true
	end
	function engine.apply_hotstring_preferences(saved)
		local desired = Preferences.project_hotstring_preferences(saved, groups, engine.get_sections)
		engine.groups, engine.sections = desired.hotstrings, desired.section_states
		return true
	end
	function engine.get_sections(name)
		local sections = {}
		for _, section in ipairs(groups[name] or {}) do sections[#sections + 1] = { name = section } end
		return sections
	end
	function engine.is_group_enabled(name) return engine.groups[name] == true end
	function engine.is_section_enabled(name, section)
		return (engine.sections[name] or {})[section] == true
	end
	function engine.enable_group(name) engine.groups[name] = true; return true end
	function engine.disable_group(name) engine.groups[name] = false; return true end
	function engine.enable_section(name, section)
		engine.sections[name] = engine.sections[name] or {}
		engine.sections[name][section] = true
		return true
	end
	--- Whether typing a trigger of this section expands.
	function engine.expands(name, section)
		return engine.started and engine.is_group_enabled(name) and engine.is_section_enabled(name, section)
	end
	return engine
end

--- Starts one session from the file: the real load, the real state build and
--- the real boot synchronization, which starts or stops the engine from the
--- saved master exactly as a reload does.
--- @param world table Fixture world.
--- @param refused string|nil The one hotstrings step the scenario refuses.
--- @return table state
--- @return table report The synchronization's report.
local function boot(world, refused)
	local saved, status = world.Preferences.load(world.path)
	helpers.assert_eq(status, "ok", "the configuration the wizard wrote must load")
	local state = world.Preferences.build_initial_state(world.hotfiles, {}, { keymap = world.Keymap })
	world.Preferences.merge_saved_data(state, saved)
	-- Boot starts the taps before the menu applies the saved switch.
	world.engine.started = true
	-- Only the typing engine is wired: the other features' refusals are theirs.
	local _, report = world.MenuState.sync_state_to_modules(state, saved, false,
		{ keymap = world.engine, hotstring_editor = {}, core_mods = {} })
	for _, failure in ipairs(report.failures) do
		helpers.assert_true(failure.feature ~= "hotstrings" or failure.step == refused,
			"the boot synchronization refused the hotstrings: " .. failure.step .. " " .. failure.detail)
	end
	world.state = state
	return state, report
end

--- Builds the real Hotstrings tray row over the session's state.
--- @param world table Fixture world.
--- @return table parent The Hotstrings top-level row.
local function hotstrings_row(world)
	local Builder = world.Builder
	local mods = {}
	for key, name in pairs(MENU_MODULES) do mods[key] = require(name) end
	local ctx = {
		config         = { log_level = 2 },
		base_dir       = helpers.driver_root(),
		state          = world.state,
		hotfiles       = world.hotfiles,
		get_group_name = function(name) return name end,
		keymap         = world.engine,
		save_prefs     = function()
			return world.Preferences.save(world.path, world.state, world.hotfiles, { keymap = world.engine })
		end,
		updateMenu     = function() end,
		notify_feature = function() end,
		applyTriggerChar = function(text) return text end,
	}
	local actions = setmetatable({}, { __index = function() return function() end end })
	local ok, tray = pcall(Builder.generate, ctx, mods, actions)
	helpers.assert_true(ok, "Builder.generate raised: " .. tostring(tray))
	local title = require("infra.i18n").get("menu.hotstrings.title")
	for _, row in ipairs(tray) do
		if type(row.title) == "string" and row.title:sub(1, #title) == title then return row end
	end
	error("the tray has no Hotstrings row")
end

--- Runs a scenario over a fresh configuration the wizard answered.
--- @param answer boolean The Hotstrings question's answer.
--- @param scenario function Receives the fixture world.
local function with_wizard(answer, scenario)
	helpers.with_stub_scope({
		"infra.preferences", "adapters.file_system", "infra.fs_dir",
		"ui.menu.menu_state", "ui.menu.builder", "ui.menu.menu_hotstrings", "ui.menu.keymap_lifecycle",
		"infra.notifications",
	}, function()
		package.loaded["infra.notifications"] = { notify = function() return true end }
		local Preferences = helpers.load_with_stubs("infra.preferences")
		local Manifest = require("infra.manifest_reader")
		local TomlWriter = require("toml_codec.writer")
		local index = Answers.load(catalogue_text(), "macos")
		local page = page_of(index, "hotstrings")
		local groups, hotfiles = inventory(page)
		output_fixture.with_output(function(path)
			-- A fresh folder: the wizard writes the first config.toml.
			os.remove(path)
			local rows = assert(Answers.rows(index, page_operations(page, answer), Manifest))
			if #rows > 0 then
				helpers.assert_true(TomlWriter.batch_write(path, rows) == true, "the wizard batch must commit")
			else
				local fh = assert(io.open(path, "w"))
				fh:close()
			end
			local world = {
				path = path, hotfiles = hotfiles, groups = groups,
				Preferences = Preferences,
				Keymap = { DEFAULT_STATE = { keymap = Manifest.default_for("hotstrings.enabled") } },
				MenuState = require("ui.menu.menu_state"),
				Builder = require("ui.menu.builder"),
			}
			world.engine = engine_double(groups, Preferences)
			scenario(world)
		end)
	end)
end

--- The one section the recommendation imports, and the tick of the row.
--- @param world table
--- @return string group, string section
local function recommended_section(world)
	local index = Answers.load(catalogue_text(), "macos")
	for _, operation in ipairs(page_operations(page_of(index, "hotstrings"), true)) do
		local group, section = operation.path:match("^hotstrings%.modules%.([^%.]+)%.([^%.]+)$")
		if group and world.groups[group] then return group, section end
	end
	error("the recommendation imports no hotstring section")
end

--- The switch row, first row of the Hotstrings submenu.
--- @param parent table
--- @return table
local function switch_of(parent)
	local first = parent.menu and parent.menu[1]
	helpers.assert_eq(first and first.title, require("infra.i18n").get("menu.hotstrings.enable"),
		"the Hotstrings submenu opens with its switch")
	return first
end





-- ===============================
-- ===============================
-- ======= 2/ Scenarios ==========
-- ===============================
-- ===============================

helpers.describe("the Hotstrings tick follows the typing engine (hotstrings-master-tick)", function()

	helpers.it("(hotstrings-master-tick) a fresh wizard Yes ticks the switch and expands", function()
		with_wizard(true, function(world)
			local group, section = recommended_section(world)
			boot(world)
			helpers.assert_true(world.engine.expands(group, section),
				"the recommended section expands after the wizard's Yes")
			local parent = hotstrings_row(world)
			helpers.assert_eq(parent.checked, true, "the Hotstrings row is ticked while its engine expands")
			helpers.assert_eq(switch_of(parent).checked, true, "and so is its switch")
		end)
	end)

	helpers.it("(hotstrings-master-tick) switching off stops every expansion and unticks, then and after reload", function()
		with_wizard(true, function(world)
			local group, section = recommended_section(world)
			boot(world)
			switch_of(hotstrings_row(world)).fn()
			helpers.assert_eq(world.engine.expands(group, section), false, "switching off stops the expansion")
			helpers.assert_eq(world.engine.started, false, "the typing engine is stopped, personal groups included")
			local parent = hotstrings_row(world)
			helpers.assert_true(parent.checked ~= true, "the Hotstrings row is unticked")
			helpers.assert_true(switch_of(parent).checked ~= true, "and so is its switch")
			helpers.assert_true(world.engine.is_group_enabled(group),
				"the categories keep their choice under the master")

			boot(world)
			helpers.assert_eq(world.engine.expands(group, section), false, "a reload keeps the engine stopped")
			helpers.assert_true(hotstrings_row(world).checked ~= true, "and the row unticked")

			switch_of(hotstrings_row(world)).fn()
			helpers.assert_true(world.engine.expands(group, section), "switching on expands again")
			helpers.assert_eq(hotstrings_row(world).checked, true, "and ticks the row")
			boot(world)
			helpers.assert_true(world.engine.expands(group, section), "after a reload too")
			helpers.assert_eq(hotstrings_row(world).checked, true, "with the row still ticked")
		end)
	end)

	helpers.it("(hotstrings-master-tick) a stop refused at boot leaves the tick on the running engine", function()
		with_wizard(false, function(world)
			world.engine.stop = function() return false end
			local state, report = boot(world, "keymap.stop")
			helpers.assert_eq(world.engine.started, true, "the taps boot started are still running")
			helpers.assert_eq(state.keymap, true, "the switch shows the engine that may still type")
			helpers.assert_eq(#report.demotions, 1, "as a session demotion that config.toml never keeps")
			helpers.assert_eq(hotstrings_row(world).checked, true, "so the row is ticked and a click retries the stop")
		end)
	end)

	helpers.it("(hotstrings-master-tick) a fresh wizard No leaves the engine stopped and the tick off", function()
		with_wizard(false, function(world)
			local group, section = recommended_section(world)
			boot(world)
			helpers.assert_eq(world.engine.started, false, "the neutral configuration keeps the engine stopped")
			helpers.assert_eq(world.engine.expands(group, section), false, "nothing expands")
			for _, name in ipairs(world.hotfiles) do
				helpers.assert_eq(world.engine.is_group_enabled(name), false, name .. " stays off")
			end
			helpers.assert_true(hotstrings_row(world).checked ~= true, "the Hotstrings row is unticked")
		end)
	end)

end)
