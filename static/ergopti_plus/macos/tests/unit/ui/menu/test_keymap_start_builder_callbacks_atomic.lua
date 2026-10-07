--- tests/unit/ui/menu/test_keymap_start_builder_callbacks_atomic.lua

--- ==============================================================================
--- MODULE: Menu Builder Keymap-Start Transactions
--- DESCRIPTION:
--- Drives the real callbacks returned by the custom-hotstring and extension-hotstring
--- builders. A refused keymap start must end the user action before any feature
--- state, engine setting, persistence, notification, menu refresh, or reload is
--- published. Testing the callbacks matters: a source scan can see a lifecycle
--- gate even when it sits after the mutation it was meant to protect.
--- ==============================================================================

local helpers = require("tests.helpers")
local CaptionFixture = require("tests.support.personal_menu_caption_fixture")

local START_OUTCOMES = { "false", "nil", "throw" }


--- Recursively finds a row callback by its exact label, in either dialect:
--- provider rows (`label`/`action`/`items`) or rows the renderer has already
--- materialised (`title`/`fn`/`menu`), which is what the layout menu returns.
--- @param rows table|nil Menu rows.
--- @param label string Exact row label.
--- @return function|nil action
local function find_action(rows, label)
	for _, row in ipairs(type(rows) == "table" and rows or {}) do
		local callback = row.action or row.fn
		if (row.label == label or row.title == label) and type(callback) == "function" then
			return callback
		end
		local nested = find_action(row.items or row.menu, label)
		if nested then return nested end
	end
	return nil
end


--- Builds one strict-start double for a requested failure mode.
--- @param outcome string false|nil|throw.
--- @param calls table Mutable call counters.
--- @return function start
local function failing_start(outcome, calls)
	return function()
		calls.starts = calls.starts + 1
		if outcome == "throw" then error("injected keymap start failure") end
		if outcome == "false" then return false end
		return nil
	end
end


--- Asserts that a refused callback had no externally observable side effect.
--- @param fixture table Fixture returned by a builder helper below.
--- @param label string Assertion prefix.
local function assert_refused_without_effects(fixture, label)
	local ok, err = pcall(fixture.action)
	helpers.assert_true(ok, label .. " must contain a throwing keymap.start: " .. tostring(err))
	helpers.assert_eq(fixture.calls.starts, 1, label .. " must attempt one strict start")
	helpers.assert_eq(fixture.calls.keymap_mutations, 0,
		label .. " must not mutate keymap groups or sections")
	helpers.assert_eq(fixture.calls.saves, 0, label .. " must not persist a false enable")
	helpers.assert_eq(fixture.calls.notifications, 0, label .. " must not announce success")
	helpers.assert_eq(fixture.calls.updates, 0, label .. " must not publish enabled menu state")
	helpers.assert_eq(fixture.calls.reloads, 0, label .. " must not reload after a refused action")
	helpers.assert_eq(fixture.state.keymap, false, label .. " must leave the keymap state disabled")
	fixture.assert_state(label)
end


--- Builds the real custom-hotstring provider and selects one start-bearing action.
--- @param outcome string false|nil|throw.
--- @param action_kind string top|bulk|section.
--- @return table fixture
local function custom_fixture(outcome, action_kind)
	local Custom = helpers.load_with_stubs("ui.menu.menu_hotstrings_custom")
	local group_enabled = action_kind ~= "top"
	local calls = {
		starts = 0,
		keymap_mutations = 0,
		saves = 0,
		notifications = 0,
		updates = 0,
		reloads = 0,
	}
	local state = {
		keymap = false,
		hotstrings = { personal = group_enabled, custom = group_enabled },
		trigger_char = "★",
		custom_editor_shortcut = false,
		custom_default_section = false,
		custom_close_on_add = false,
	}
	local function keymap_mutation()
		calls.keymap_mutations = calls.keymap_mutations + 1
	end
	local ctx = {
		paused = false,
		state = state,
		hotfiles = { "personal.toml" },
		get_group_name = function(path) return path:gsub("%.toml$", "") end,
		applyTriggerChar = function(value) return value end,
		keymap = {
			start = failing_start(outcome, calls),
			is_group_enabled = function() return group_enabled end,
			is_section_enabled = function() return false end,
			get_sections = function(group)
				if group == "custom" then
					return { { name = "target", description = "TARGET_CUSTOM_SECTION" } }
				end
				return nil
			end,
			enable_group = keymap_mutation,
			disable_group = keymap_mutation,
			enable_section = keymap_mutation,
			disable_section = keymap_mutation,
			set_sections_enabled = keymap_mutation,
		},
		hotstring_editor = { open = function() end },
		save_prefs = function() calls.saves = calls.saves + 1; return true end,
		notify_feature = function() calls.notifications = calls.notifications + 1 end,
		updateMenu = function() calls.updates = calls.updates + 1 end,
		do_reload = function() calls.reloads = calls.reloads + 1 end,
	}

	ctx.keymap.set_category_scope_enabled = function(_names, _enabled, publish)
		calls.keymap_mutations = calls.keymap_mutations + 1
		return publish()
	end

	local built = CaptionFixture.build_custom(Custom, ctx, { group_counts = {} })
	helpers.assert_type(built, "table", "the real custom builder must return a provider row")
	helpers.assert_nil(built.action, "the personal parent row must carry no action")
	local action
	if action_kind == "section" then
		action = find_action(built.submenu, "TARGET_CUSTOM_SECTION")
	else
		action = built.submenu[action_kind == "top" and 1 or 2].fn
	end
	helpers.assert_type(action, "function",
		"the real custom builder must expose its " .. action_kind .. " callback")

	return {
		action = action,
		calls = calls,
		state = state,
		assert_state = function(label, expected)
			if expected == nil then expected = group_enabled end
			helpers.assert_eq(state.hotstrings.personal, expected,
				label .. " must leave the personal-group state unchanged")
			helpers.assert_eq(state.hotstrings.custom, expected,
				label .. " must leave the custom-group state unchanged")
		end,
	}
end


--- Builds the real extension provider and selects its bound replacement action.
--- @param outcome string false|nil|throw.
--- @return table fixture
local function extension_fixture(outcome)
	local Hotstrings = helpers.load_with_stubs("ui.menu.menu_hotstrings")
	local calls = {
		starts = 0, keymap_mutations = 0, saves = 0,
		notifications = 0, updates = 0, reloads = 0,
	}
	local state = {
		keymap = false, hotstrings = { magickey = true },
		layout_pause_switch_enabled = false, layout_on_pause = false, layout_on_resume = false,
	}
	local function keymap_mutation()
		calls.keymap_mutations = calls.keymap_mutations + 1
		return true
	end
	local ctx = {
		paused = false, state = state, hotfiles = { "magickey" },
		get_group_name = function(name) return name end,
		applyTriggerChar = function(text) return text end,
		extension_packs = { { id = "ergopti", bound_files = {
			{ binding = { category = "magickey", sections = { "replace" } } },
		} } },
		keymap = {
			start = failing_start(outcome, calls),
			is_group_enabled = function(group) return group == "magickey" end,
			is_section_enabled = function() return false end,
			get_sections = function(group)
				if group == "magickey" then
					return { { name = "replace", description = "TARGET_REPLACE_SECTION" } }
				end
				return nil
			end,
			enable_section = keymap_mutation, disable_section = keymap_mutation,
			set_groups_sections_enabled = keymap_mutation,
		},
		save_prefs = function() calls.saves = calls.saves + 1; return true end,
		notify_feature = function() calls.notifications = calls.notifications + 1 end,
		updateMenu = function() calls.updates = calls.updates + 1 end,
		do_reload = function() calls.reloads = calls.reloads + 1 end,
	}
	local bound = Hotstrings.bound_sections(ctx)
	local rows = Hotstrings.build_bound_section_rows(ctx, bound.ergopti)
	helpers.assert_type(rows, "table", "the real extension provider returns bound section rows")
	local action = find_action(rows, "TARGET_REPLACE_SECTION")
	helpers.assert_type(action, "function",
		"the real extension provider exposes its replacement-section callback")

	return {
		action = action,
		calls = calls,
		state = state,
		assert_state = function(label)
			helpers.assert_eq(state.layout_pause_switch_enabled, false,
				label .. " must leave pause-layout state unchanged")
			helpers.assert_eq(state.layout_on_pause, false,
				label .. " must leave the pause layout unchanged")
			helpers.assert_eq(state.layout_on_resume, false,
				label .. " must leave the resume layout unchanged")
		end,
	}
end


helpers.describe("menu builder callbacks: capture and desired selection stay independent", function()
	for _, action_kind in ipairs({ "top", "bulk", "section" }) do
		local title = action_kind == "section" and "keeps custom section enable callbacks inert"
			or ("prepares custom " .. action_kind .. " scope without attempting capture")
		helpers.it(title, function()
			for _, outcome in ipairs(START_OUTCOMES) do
				local fixture = custom_fixture(outcome, action_kind)
				local label = "custom " .. action_kind .. " / " .. outcome
				if action_kind == "section" then
					assert_refused_without_effects(fixture, label)
				else
					local ok, committed = pcall(fixture.action)
					helpers.assert_true(ok, label .. " must select without invoking a refused capture start")
					helpers.assert_eq(committed, true)
					helpers.assert_eq(fixture.calls.starts, 0)
					helpers.assert_eq(fixture.calls.keymap_mutations, 1)
					helpers.assert_eq(fixture.calls.saves, 1)
					helpers.assert_eq(fixture.calls.updates, 1)
					helpers.assert_eq(fixture.calls.notifications, 0)
					helpers.assert_eq(fixture.calls.reloads, 0)
					helpers.assert_eq(fixture.state.keymap, false)
					fixture.assert_state(label, action_kind == "top")
				end
			end
		end)
	end

	helpers.it("keeps the extension replacement callback inert", function()
		for _, outcome in ipairs(START_OUTCOMES) do
			assert_refused_without_effects(
				extension_fixture(outcome),
				"extension replacement / " .. outcome)
		end
	end)
end)
