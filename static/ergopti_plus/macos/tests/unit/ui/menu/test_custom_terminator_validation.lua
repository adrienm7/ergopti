--- tests/unit/ui/menu/test_custom_terminator_validation.lua

--- ==============================================================================
--- MODULE: Custom Terminator Validation
--- DESCRIPTION:
--- Drives the real management-provider actions. Duplicate delimiter characters
--- and malformed magic-key bytes must be rejected before runtime, editor, or
--- persistence publication, while one valid Unicode scalar still commits.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Finds one raw provider row recursively.
--- @param rows table|nil
--- @param predicate function
--- @return table|nil row
local function find_row(rows, predicate)
	for _, row in ipairs(rows or {}) do
		if predicate(row) then return row end
		local nested = find_row(row.items, predicate)
		if nested then return nested end
	end
	return nil
end


--- Runs one provider action with strict observable boundaries.
--- @param mode string Action scenario.
--- @param outcome string|nil Runtime mutation outcome.
--- @return table fixture
local function run_action(mode, outcome)
	local module_names = {
		"infra.dialog_util",
		"infra.i18n",
		"infra.manifest_menu",
		"infra.manifest_reader",
		"infra.notifications",
		"modules.hotstrings.hotstrings_config",
		"ui.menu.keymap_lifecycle",
		"ui.menu.menu_hotstrings_management",
	}
	local saved = {}
	for _, name in ipairs(module_names) do saved[name] = package.loaded[name] end

	local effects = {
		adds = 0,
		alerts = {},
		editor_sets = 0,
		keymap_sets = 0,
		notifications = 0,
		reloads = 0,
		saves = 0,
		updates = 0,
	}
	local state = {
		custom_terminators = {},
		delays = {},
		expansion_delay = 0.1,
		terminator_states = {},
		trigger_char = "★",
	}
	local prompt_calls = 0
	local invalid_byte = string.char(0xC2)

	package.loaded["infra.i18n"] = {
		get = function(key)
			if key == "editor.hotstrings.err_id_exists" then return "DUPLICATE:%s" end
			return key
		end,
	}
	package.loaded["infra.dialog_util"] = {
		text_prompt = function()
			prompt_calls = prompt_calls + 1
			if mode == "duplicate" then
				if prompt_calls == 1 then return "OK", "," end
				return "button.cancel", ""
			end
			if mode == "invalid_magic" then return "OK", invalid_byte end
			if mode == "add_refusal" then return "OK", "@" end
			return "OK", "§"
		end,
		block_alert = function(_title, body)
			effects.alerts[#effects.alerts + 1] = body
			if body == "DUPLICATE:," then return "button.retry" end
			if body == "dialog.hotstrings.consume_body" then
				return "dialog.hotstrings.consume_no"
			end
			return "button.retry"
		end,
	}
	package.loaded["infra.manifest_menu"] = {
		build = function(_, _, _, _, _, providers)
			local rows = {}
			for _, id in ipairs({ "word_expanders", "magic_key_config" }) do
				for _, row in ipairs(providers[id]()) do rows[#rows + 1] = row end
			end
			return rows
		end,
	}
	package.loaded["infra.manifest_reader"] = {
		default_for = function() return "★" end,
	}
	package.loaded["infra.notifications"] = {
		notify = function() effects.notifications = effects.notifications + 1 end,
	}
	package.loaded["modules.hotstrings.hotstrings_config"] = {
		resolve = function() return { delay = 0.1, has_override = false } end,
	}
	package.loaded["ui.menu.keymap_lifecycle"] = nil
	package.loaded["ui.menu.menu_hotstrings_management"] = nil

	local ok, fixture_or_err = xpcall(function()
		local Terminators = require("keymap.terminators")
		local keymap = {
			DELAYS_DEFAULT = {
				STAR_TRIGGER = 0.1,
				autocorrection = 0.1,
				dynamichotstrings = 0.1,
				llm_prediction = 0.1,
			},
			DEFAULT_STATE = { expansion_delay = 0.1 },
			add_custom_terminator = function(...)
				effects.adds = effects.adds + 1
				if mode == "add_refusal" then
					if outcome == "throw" then error("injected custom-add refusal", 0) end
					if outcome == "false" then return false end
					if outcome == "nil" then return nil end
				end
				return Terminators.add_custom_terminator(...)
			end,
			get_terminator_defs = Terminators.get_terminator_defs,
			is_repeat_feature_enabled = function() return false end,
			is_terminator_enabled = Terminators.is_terminator_enabled,
			set_terminator_enabled = Terminators.set_terminator_enabled,
			set_trigger_char = function(char)
				effects.keymap_sets = effects.keymap_sets + 1
				if mode == "magic_refusal" then
					if outcome == "throw" then error("injected magic-key refusal", 0) end
					if outcome == "false" then return false end
					if outcome == "nil" then return nil end
				end
				state.keymap_char = char
				return true
			end,
		}
		local Management = require("ui.menu.menu_hotstrings_management")
		local built = Management.build_management({
			state = state,
			paused = false,
			keymap = keymap,
			hotstring_editor = {
				set_trigger_char = function(char)
					effects.editor_sets = effects.editor_sets + 1
					state.editor_char = char
				end,
			},
			applyTriggerChar = function(value) return value end,
			do_reload = function() effects.reloads = effects.reloads + 1 end,
			notify_feature = function() end,
			save_prefs = function()
				effects.saves = effects.saves + 1
				return true
			end,
			updateMenu = function() effects.updates = effects.updates + 1 end,
		})

		local row
		if mode == "duplicate" or mode == "add_refusal" then
			row = find_row(built.menu, function(candidate)
				return candidate.label == "menu.hotstrings.add_custom"
			end)
		else
			row = find_row(built.menu, function(candidate)
				return type(candidate.label) == "string"
					and candidate.label:find("menu.hotstrings.magic_key_prefix", 1, true) == 1
			end)
		end
		helpers.assert_type(row, "table", "the target provider row must be reachable")
		helpers.assert_type(row.action, "function", "the target provider row must be clickable")
		local result = row.action()
		for _, def in ipairs(Terminators.get_terminator_defs()) do
			if def.key == "custom_1" then
				Terminators.remove_custom_terminator("custom_1")
				break
			end
		end
		return {
			effects = effects,
			invalid_byte = invalid_byte,
			result = result,
			state = state,
		}
	end, debug.traceback)

	for _, name in ipairs(module_names) do package.loaded[name] = saved[name] end
	if not ok then error(fixture_or_err, 0) end
	return fixture_or_err
end


helpers.describe("custom terminator and magic-key input validation", function()
	helpers.it("refuses a duplicate delimiter with a visible retry and no publication", function()
		local fixture = run_action("duplicate")
		helpers.assert_eq(fixture.effects.alerts[1], "DUPLICATE:,")
		helpers.assert_eq(fixture.effects.adds, 0)
		helpers.assert_eq(fixture.effects.saves, 0)
		helpers.assert_eq(fixture.effects.updates, 0)
		helpers.assert_eq(#fixture.state.custom_terminators, 0)
	end)

	helpers.it("refuses an isolated UTF-8 lead byte before every magic-key consumer", function()
		local fixture = run_action("invalid_magic")
		helpers.assert_eq(fixture.state.trigger_char, "★")
		helpers.assert_eq(fixture.effects.keymap_sets, 0)
		helpers.assert_eq(fixture.effects.editor_sets, 0)
		helpers.assert_eq(fixture.effects.saves, 0)
		helpers.assert_eq(fixture.effects.reloads, 0)
		helpers.assert_eq(fixture.effects.alerts[1], "dialog.hotstrings.invalid_body")
	end)

	helpers.it("publishes no custom delimiter after an exact runtime refusal", function()
		for _, outcome in ipairs({ "false", "nil", "throw" }) do
			local fixture = run_action("add_refusal", outcome)
			helpers.assert_eq(fixture.effects.adds, 1, outcome)
			helpers.assert_eq(fixture.effects.notifications, 1, outcome)
			helpers.assert_eq(fixture.effects.saves, 0, outcome)
			helpers.assert_eq(fixture.effects.updates, 0, outcome)
			helpers.assert_eq(#fixture.state.custom_terminators, 0, outcome)
		end
	end)

	helpers.it("publishes no magic key after an exact runtime refusal", function()
		for _, outcome in ipairs({ "false", "nil", "throw" }) do
			local fixture = run_action("magic_refusal", outcome)
			helpers.assert_eq(fixture.effects.keymap_sets, 1, outcome)
			helpers.assert_eq(fixture.effects.notifications, 1, outcome)
			helpers.assert_eq(fixture.state.trigger_char, "★", outcome)
			helpers.assert_eq(fixture.effects.editor_sets, 0, outcome)
			helpers.assert_eq(fixture.effects.saves, 0, outcome)
			helpers.assert_eq(fixture.effects.reloads, 0, outcome)
		end
	end)

	helpers.it("commits one valid multibyte magic-key scalar", function()
		local fixture = run_action("valid_magic")
		helpers.assert_eq(fixture.state.trigger_char, "§")
		helpers.assert_eq(fixture.effects.keymap_sets, 1)
		helpers.assert_eq(fixture.effects.editor_sets, 1)
		helpers.assert_eq(fixture.effects.saves, 1)
		helpers.assert_eq(fixture.effects.reloads, 1)
	end)
end)

return true
