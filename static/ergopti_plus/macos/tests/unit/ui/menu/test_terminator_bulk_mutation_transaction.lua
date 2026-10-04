--- tests/unit/ui/menu/test_terminator_bulk_mutation_transaction.lua

--- ==============================================================================
--- MODULE: Terminator Bulk Mutation Transaction
--- DESCRIPTION:
--- Clicks the real word-expander provider actions. Runtime refusal must leave
--- every menu-state bit and preference write untouched; exact success publishes
--- one complete built-in batch while excluding custom terminators.
--- ==============================================================================

local helpers = require("tests.helpers")

local FAILURE_OUTCOMES = { "false", "nil", "throw" }


--- Copies a flat table for mutation-sensitive assertions.
--- @param value table
--- @return table copy
local function clone_flat(value)
	local copy = {}
	for key, item in pairs(value or {}) do copy[key] = item end
	return copy
end


--- Finds a raw provider row by its rendered label.
--- @param rows table|nil
--- @param label string
--- @return table|nil row
local function find_row(rows, label)
	for _, row in ipairs(rows or {}) do
		if (row.label or row.title) == label then return row end
		local nested = find_row(row.items or row.submenu or row.menu, label)
		if nested then return nested end
	end
	return nil
end


--- Runs one real management-provider action against strict mutation boundaries.
--- @param label string Action label.
--- @param outcome string true|false|nil|throw.
--- @return table fixture
local function run_action(label, outcome, options)
	options = options or {}
	local saved = {}
	local module_names = {
		"infra.manifest_menu", "infra.manifest_reader", "infra.notifications",
		"modules.hotstrings.hotstrings_config", "ui.menu.keymap_lifecycle",
		"ui.menu.menu_hotstrings_management",
	}

	for _, name in ipairs({
		"infra.manifest_menu",
		"infra.manifest_reader",
		"infra.notifications",
		"modules.hotstrings.hotstrings_config",
		"ui.menu.keymap_lifecycle",
		"ui.menu.menu_hotstrings_management",
	}) do
		saved[name] = package.loaded[name]
	end

	local calls = {
		batches = 0,
		singles = 0,
		saves = 0,
		updates = 0,
		notices = 0,
	}
	local state = {
		terminator_states = { space = false, slash = true, custom_x = false },
		delays = {},
		trigger_char = "★",
		expansion_delay = 0.1,
	}
	local defs = {
		{ key = "space", chars = { " " }, label = "Space", default_enabled = true },
		{ key = "slash", chars = { "/" }, label = "Slash", default_enabled = false },
		{ key = "custom_x", chars = { "x" }, label = "Custom", custom = true },
	}
	local last_changes = nil

	local native_renderer = assert(require("menu.renderer").new({
		platform = "hs",
		manifest_path = function() return helpers.shared("modules/menu/menu_manifest.json") end,
		json_decode = function(raw)
			local value = require("adapters.json_codec").decode(raw)
			if options.reorder then
				local rows = value.word_expanders_menu
				rows[1], rows[3] = rows[3], rows[1]
			end
			return value
		end,
		i18n = require("infra.i18n"),
		logger = require("infra.logger"),
	}))
	local command_row = require("infra.manifest_menu").command_row
	package.loaded["infra.manifest_menu"] = {
		command_row = command_row,
		check_row = native_renderer.check_row,
		get_array = native_renderer.get_array,
		build = function(section, category, handlers, groups, ctx, providers)
			return native_renderer.build(section, category, handlers, groups, ctx, providers)
		end,
	}
	package.loaded["infra.manifest_reader"] = {
		default_for = function() return "★" end,
	}
	package.loaded["infra.notifications"] = {
		notify = function(_title, _body, kind)
			helpers.assert_eq(kind, "error")
			calls.notices = calls.notices + 1
		end,
	}
	package.loaded["modules.hotstrings.hotstrings_config"] = {
		resolve = function() return { delay = 0.1, has_override = false } end,
	}
	package.loaded["ui.menu.keymap_lifecycle"] = nil
	package.loaded["ui.menu.menu_hotstrings_management"] = nil

	local ok, fixture_or_err = xpcall(function()
		local keymap = {
			DELAYS_DEFAULT = {
				STAR_TRIGGER = 0.1,
				autocorrection = 0.1,
				llm_prediction = 0.1,
				dynamichotstrings = 0.1,
			},
			DEFAULT_STATE = { expansion_delay = 0.1 },
			get_terminator_defs = function() return defs end,
			is_terminator_enabled = function(key) return state.terminator_states[key] end,
			set_terminators_enabled = function(changes)
				calls.batches = calls.batches + 1
				last_changes = clone_flat(changes)
				if outcome == "throw" then error("injected batch refusal", 0) end
				if outcome == "false" then return false end
				if outcome == "nil" then return nil end
				return true
			end,
			set_terminator_enabled = function()
				calls.singles = calls.singles + 1
				if outcome == "throw" then error("injected single refusal", 0) end
				if outcome == "false" then return false end
				if outcome == "nil" then return nil end
				return true
			end,
			is_repeat_feature_enabled = function() return false end,
		}
		local Management = require("ui.menu.menu_hotstrings_management")
		local ctx = {
			state = state,
			paused = false,
			keymap = keymap,
			hotstring_editor = {},
			applyTriggerChar = function(value) return value end,
			notify_feature = function() end,
			save_prefs = function()
				calls.saves = calls.saves + 1
				return true
			end,
			updateMenu = function() calls.updates = calls.updates + 1 end,
			do_reload = function() end,
		}
		local built = Management.build_management(ctx)
		local parent = find_row(built.menu, require("infra.i18n").get("menu.hotstrings.word_expanders"))
		local controls = parent.items or parent.submenu or parent.menu
		if options.pause_after_build then ctx.paused = true end
		local row = find_row(built.menu, label)
		helpers.assert_type(row, "table", "the word-expander action must be reachable")
		helpers.assert_type(row.action or row.fn, "function", "the provider row must be clickable")
		local result
		if not options.inspect_only then result = (row.action or row.fn)() end
		return {
			result = result,
			controls = controls,
			state = state,
			calls = calls,
			changes = last_changes,
		}
	end, debug.traceback)

	for _, name in ipairs(module_names) do package.loaded[name] = saved[name] end
	if not ok then error(fixture_or_err, 0) end
	return fixture_or_err
end


helpers.describe("word-expander terminator mutations are transactional", function()
	local i18n = require("infra.i18n")
	local bulk_labels = {
		i18n.get("menu.hotstrings.check_all"),
		i18n.get("menu.hotstrings.uncheck_all"),
		i18n.get("common.restore_recommended"),
	}

	helpers.it("retains every acknowledged bit when a bulk mutation is refused", function()
		for _, label in ipairs(bulk_labels) do
			for _, outcome in ipairs(FAILURE_OUTCOMES) do
				local fixture = run_action(label, outcome)
				helpers.assert_eq(fixture.result, false, label .. "/" .. outcome)
				helpers.assert_eq(fixture.calls.batches, 1, label .. "/" .. outcome)
				helpers.assert_eq(fixture.calls.singles, 0, label .. "/" .. outcome)
				helpers.assert_eq(fixture.calls.saves, 0, label .. "/" .. outcome)
				helpers.assert_eq(fixture.calls.updates, 0, label .. "/" .. outcome)
				helpers.assert_eq(fixture.calls.notices, 1, label .. "/" .. outcome)
				helpers.assert_eq(fixture.state.terminator_states,
					{ space = false, slash = true, custom_x = false }, label .. "/" .. outcome)
			end
		end
	end)

	helpers.it("publishes each exact built-in batch and leaves custom state alone", function()
		local cases = {
			{
				label = i18n.get("menu.hotstrings.check_all"),
				expected = { space = true, slash = true },
			},
			{
				label = i18n.get("menu.hotstrings.uncheck_all"),
				expected = { space = false, slash = false },
			},
			{
				label = i18n.get("common.restore_recommended"),
				expected = { space = true, slash = false },
			},
		}
		for _, case in ipairs(cases) do
			local fixture = run_action(case.label, "true")
			helpers.assert_eq(fixture.result, true, case.label)
			helpers.assert_eq(fixture.calls.batches, 1, case.label)
			helpers.assert_eq(fixture.calls.singles, 0, case.label)
			helpers.assert_eq(fixture.changes, case.expected, case.label)
			helpers.assert_eq(fixture.state.terminator_states, {
				space = case.expected.space,
				slash = case.expected.slash,
				custom_x = false,
			}, case.label)
			helpers.assert_eq(fixture.calls.saves, 1, case.label)
			helpers.assert_eq(fixture.calls.updates, 1, case.label)
			helpers.assert_eq(fixture.calls.notices, 0, case.label)
		end
	end)

	helpers.it("retains one built-in bit when its individual mutation is refused", function()
		for _, outcome in ipairs(FAILURE_OUTCOMES) do
			local fixture = run_action("Space", outcome)
			helpers.assert_eq(fixture.result, false, outcome)
			helpers.assert_eq(fixture.calls.batches, 0, outcome)
			helpers.assert_eq(fixture.calls.singles, 1, outcome)
			helpers.assert_eq(fixture.calls.saves, 0, outcome)
			helpers.assert_eq(fixture.calls.updates, 0, outcome)
			helpers.assert_eq(fixture.calls.notices, 1, outcome)
			helpers.assert_eq(fixture.state.terminator_states.space, false, outcome)
		end
	end)
end)


helpers.describe("shared word-expander fixed commands", function()
	local i18n = require("infra.i18n")
	local function corpus()
		local raw = assert(io.open(helpers.shared("tests/corpus/menus/word_expander_controls.json"), "rb"))
		local content = raw:read("*a")
		raw:close()
		return assert(require("adapters.json_codec").decode(content))
	end

	helpers.it("replays the independent three-command golden through the real child renderer", function()
		local expected = corpus()
		local fixture = run_action(i18n.get(expected.rows[1].i18n), "true", { inspect_only = true })
		for position, row in ipairs(expected.rows) do
			helpers.assert_eq(fixture.controls[position].title, i18n.get(row.i18n))
			helpers.assert_type(fixture.controls[position].fn, "function")
			helpers.assert_eq(fixture.controls[position].disabled, nil)
		end
		helpers.assert_eq(fixture.controls[4].title, "-")
		helpers.assert_eq(fixture.calls.batches, 0)
		helpers.assert_eq(fixture.calls.saves, 0)
	end)

	helpers.it("follows shared command reordering without rebinding the native owner", function()
		local expected = corpus()
		local by_id = {}
		for _, row in ipairs(expected.rows) do by_id[row.id] = row end
		local fixture = run_action(i18n.get(by_id[expected.reordered_ids[1]].i18n), "true", { reorder = true })
		for position, id in ipairs(expected.reordered_ids) do
			helpers.assert_eq(fixture.controls[position].title, i18n.get(by_id[id].i18n))
		end
		helpers.assert_eq(fixture.result, true)
		helpers.assert_eq(fixture.state.terminator_states, expected.delimiter_states.restore)
		helpers.assert_eq(fixture.calls.saves, 1)
	end)

	helpers.it("refuses an existing native command when the captured context becomes paused", function()
		for _, row in ipairs(corpus().rows) do
			local fixture = run_action(i18n.get(row.i18n), "true", { pause_after_build = true })
			helpers.assert_eq(fixture.result, false)
			helpers.assert_eq(fixture.calls.batches, 0)
			helpers.assert_eq(fixture.calls.saves, 0)
			helpers.assert_eq(fixture.calls.updates, 0)
			helpers.assert_eq(fixture.state.terminator_states, corpus().delimiter_states.initial)
		end
	end)
end)

return true
