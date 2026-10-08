--- tests/unit/ui/menu/test_custom_terminator_add_transaction.lua

--- ==============================================================================
--- MODULE: Custom Terminator Addition Transaction
--- DESCRIPTION:
--- Exercises the real provider, shared registry and preference transaction.
--- Retained dialogs must keep current admission; refused disk publication
--- rolls the real registry back through the existing preference owner.
--- ==============================================================================

local helpers = require("tests.helpers")
local OutputFixture = require("tests.support.toml_output_fixture")

--- Reads the independent custom-command identity used by each native provider.
--- @return table expected Canonical command expectation.
local function custom_command_expected()
	local path = require("infra.paths").shared("tests/corpus/menus/word_expander_add_controls.json")
	local file = assert(io.open(path, "rb"))
	local text = file:read("*a")
	file:close()
	local corpus = assert(require("adapters.json_codec").decode(text))
	return corpus
end

local KEY = "custom_delete_probe"
local SOURCE = '[hotstrings]\nterminators = [{ key = "custom_delete_probe", char = "☃", label = "Snowman", consume = false, future = { keep = 17 } }]\n'
	.. '[hotstrings.terminator_states]\ncustom_delete_probe = false\n[foreign]\nkeep = "untouched"\n'

--- Reads exact owned bytes independently of the codec.
--- @param path string Fixture path.
--- @return string bytes
local function read_bytes(path)
	local handle = assert(io.open(path, "rb"))
	local bytes = handle:read("*a")
	handle:close()
	return bytes
end

--- Finds the real delete command recursively.
--- @param rows table|nil Provider rows.
--- @return table|nil row
local function find_add(rows, label, legacy_label)
	for _, row in ipairs(rows or {}) do
		if row.label == label or row.label == legacy_label then return row end
		local nested = find_add(row.items or row.submenu, label, legacy_label)
		if nested then return nested end
	end
end

--- Owns real registry, source and publication state for one scenario.
--- @param outcome string Runtime or writer outcome.
--- @param callback function Assertion callback, outside production catches.
local function with_fixture(outcome, callback, locale)
	return helpers.with_stub_scope({
		"adapters.file_system", "infra.fs_dir", "infra.logger", "infra.preferences",
		"infra.dialog_util", "infra.i18n", "infra.manifest_menu", "infra.manifest_reader",
		"infra.notifications", "modules.hotstrings.hotstrings_config", "keymap.terminators",
		"ui.menu.keymap_lifecycle", "ui.menu.menu_hotstrings_management", "ui.menu.preferences_transaction",
		"ui.hotstrings_config_window",
	}, function()
		local Preferences = helpers.load_with_stubs("infra.preferences")
		local FileSystem = require("adapters.file_system")
		local Transaction = require("ui.menu.preferences_transaction")
		local Terminators = require("keymap.terminators")
		local calls = { adds = 0, prompts = 0, consumes = 0, writes = 0, saves = 0, updates = 0, notices = 0, rollbacks = 0 }
		local translations = {}
		if not locale then
			local file = assert(io.open(require("infra.paths").shared("data/locales/en.json"), "rb"))
			local raw = file:read("*a")
			file:close()
			local english = assert(require("adapters.json_codec").decode(raw))
			translations["button.ok"], translations["button.cancel"] = english["button.ok"], english["button.cancel"]
		end
		if locale then
			local file = assert(io.open(require("infra.paths").shared("data/locales/" .. locale .. ".json"), "rb"))
			local raw = file:read("*a")
			file:close()
			translations = assert(require("adapters.json_codec").decode(raw))
		end
		local translate = function(key) return translations[key] or key end
		package.loaded["infra.i18n"] = { get = translate }
		local active_context, current_outcome = nil, outcome
		package.loaded["infra.dialog_util"] = {
			text_prompt = function(_, _, _, affirmative, cancel)
				calls.prompts = calls.prompts + 1
				if current_outcome == "pause_after_prompt" then active_context.paused = true end
				if current_outcome == "input_error" then error("injected prompt refusal", 0) end
				if current_outcome == "input_cancel" or (current_outcome == "input_empty" and calls.prompts > 1) then return cancel, "" end
				if current_outcome == "input_empty" or (current_outcome == "pause_after_invalid_alert" and calls.prompts == 1) then return affirmative, "" end
				return affirmative, custom_command_expected().target.char
			end,
			block_alert = function(title)
				if title ~= translate("dialog.hotstrings.consume_title") then
					if current_outcome == "pause_after_invalid_alert" then active_context.paused = true end
					return translate("button.retry")
				end
				calls.consumes = calls.consumes + 1
				if current_outcome == "pause_after_consume" then active_context.paused = true end
				if current_outcome == "consume_cancel" then return translate("button.cancel") end
				if current_outcome == "consume_nil" then return nil end
				if current_outcome == "consume_unknown" then return "foreign_native_response" end
				return current_outcome == "consume_no" and translate("dialog.hotstrings.consume_no") or translate("dialog.hotstrings.consume_yes")
			end,
		}
		local command_renderer = assert(require("menu.renderer").new({
			platform = "hs",
			manifest_path = function() return require("infra.paths").shared("modules/menu/menu_manifest.json") end,
			json_decode = function(raw)
				local value = require("adapters.json_codec").decode(raw)
				if outcome == "config_shared_label" and type(value.hotstrings_delays_menu) == "table" then
					value.hotstrings_delays_menu[1].i18n = "button.ok"
				end
				return value
			end,
			i18n = { get = translate, section = translate },
			logger = require("infra.logger"),
		}))
		package.loaded["infra.manifest_menu"] = {
			command_row = command_renderer.command_row,
			check_row = command_renderer.check_row,
			get_array = command_renderer.get_array,
			template_rows = command_renderer.template_rows,
			get_root = command_renderer.get_root,
			native_child_rows = command_renderer.native_child_rows,
			build = function(section, category, dynamic, groups, context, providers)
				if section == "word_expanders_menu" then
					return command_renderer.build(section, category, dynamic, groups, context, providers)
				end
				local rows = providers.word_expanders()
				for _, row in ipairs(providers.delays_colors()) do rows[#rows + 1] = row end
				return rows
			end,
		}
		package.loaded["infra.manifest_reader"] = { default_for = function() return "★" end }
		package.loaded["infra.notifications"] = { notify = function() calls.notices = calls.notices + 1 end }
		package.loaded["modules.hotstrings.hotstrings_config"] = {
			resolve = function() return { delay = 0.1, has_override = false } end,
		}
		local Management = require("ui.menu.menu_hotstrings_management")
		return OutputFixture.with_output(function(path)
			local handle = assert(io.open(path, "wb"))
			assert(handle:write(SOURCE))
			handle:close()
			local loaded, status = Preferences.load(path)
			helpers.assert_eq(status, "ok")
			helpers.assert_type(loaded.custom_terminators, "table")
			local state = {
				custom_terminators = Transaction.clone(loaded.custom_terminators),
				terminator_states = Transaction.clone(loaded.terminator_states),
				delays = {}, expansion_delay = 0.1, trigger_char = "★",
			}
			local initial_state = Transaction.clone(state)
			helpers.assert_eq(Terminators.add_custom_terminator(KEY, "☃", "Snowman", false), true)
			helpers.assert_eq(Terminators.set_terminator_enabled(KEY, false), true)
			local native_writer = FileSystem.write_if_unchanged
			FileSystem.write_if_unchanged = function(write_path, bytes, expected_source)
				calls.writes = calls.writes + 1
				calls.expected_source = Transaction.clone(expected_source)
				if current_outcome == "write_false" then return false, "injected writer refusal" end
				if current_outcome == "write_throw" then error("injected writer exception", 0) end
				return native_writer(write_path, bytes, expected_source)
			end
			local save = Transaction.bind(Preferences, {
				path = path, state = state, initial_state = initial_state,
				initial_preferences = initial_state, hotfiles = {}, core_modules = {},
				restore_runtime = function(snapshot)
					calls.rollbacks = calls.rollbacks + 1
					for _, def in ipairs(Terminators.get_terminator_defs()) do
						if def.key == custom_command_expected().target.macos_key then
							if Terminators.remove_custom_terminator(def.key) ~= true then return false end
							break
						end
					end
					local definition = snapshot.custom_terminators[1]
					if not definition then return false end
					local exists = false
					for _, def in ipairs(Terminators.get_terminator_defs()) do
						if def.key == KEY then exists = true end
					end
					if not exists and Terminators.add_custom_terminator(KEY, definition.char,
						definition.label, definition.consume) ~= true then return false end
					return Terminators.set_terminator_enabled(KEY, snapshot.terminator_states[KEY]) == true
				end,
			})
			local keymap = {
				get_terminator_defs = Terminators.get_terminator_defs,
				is_terminator_enabled = Terminators.is_terminator_enabled,
				is_repeat_feature_enabled = function() return false end,
				DELAYS_DEFAULT = { STAR_TRIGGER = 0.1, autocorrection = 0.1, llm_prediction = 0.1, dynamichotstrings = 0.1 }, DEFAULT_STATE = { expansion_delay = 0.1 },
			}
			if outcome ~= "missing" then
				keymap.add_custom_terminator = function(key, char, label, consume)
					calls.adds = calls.adds + 1
					if current_outcome == "false" then return false end
					if current_outcome == "nil" then return nil end
					if current_outcome == "throw" then error("injected runtime refusal", 0) end
					return Terminators.add_custom_terminator(key, char, label, consume)
				end
			end
			active_context = {
				state = state, paused = false, keymap = keymap,
				applyTriggerChar = function(value) return value end,
				save_prefs = function() calls.saves = calls.saves + 1; return save() end,
				updateMenu = function() calls.updates = calls.updates + 1 end,
				notify_feature = function() end,
			}
			if outcome == "config_paused" then active_context.paused = true end
			local rows = Management.build_management(active_context)
			local row = find_add(rows.menu, translate(custom_command_expected().i18n), translate("menu.hotstrings.add_custom"))
			helpers.assert_type(row, "table")
			helpers.assert_type(row.action, "function")
			local fixture = {
				state = state, initial_state = initial_state, calls = calls, action = row.action, label = row.label, context = active_context,
				path = path, definitions = Terminators.get_terminator_defs,
				delay_rows = assert(find_add(rows.menu, translate("menu.hotstrings.delays_colors"), translate("menu.hotstrings.delays_colors"))).items,
				translate = translate,
				read = function() return read_bytes(path) end,
				retry = function() current_outcome = "true" end,
			}
			local result = table.pack(xpcall(function() return callback(fixture) end, debug.traceback))
			local retired_keys = {}
			for _, definition in ipairs(Terminators.get_terminator_defs()) do
				if definition.key == KEY or definition.key == custom_command_expected().target.macos_key then
					retired_keys[#retired_keys + 1] = definition.key
				end
			end
			for _, key in ipairs(retired_keys) do Terminators.remove_custom_terminator(key) end
			if not result[1] then error(result[2], 0) end
			return table.unpack(result, 2, result.n)
		end)
	end)
end

--- Observes the registry separately from the menu state.
--- @param fixture table Provider fixture.
--- @return boolean present
local function runtime_has_definition(fixture)
	for _, definition in ipairs(fixture.definitions()) do
		if definition.key == custom_command_expected().target.macos_key then return true end
	end
	return false
end



helpers.describe("custom delimiter Add declaration and acknowledged native owner", function()
	for _, outcome in ipairs({ "true", "consume_no" }) do
		helpers.it("publishes a native Add with unknown neighbours retained after " .. outcome, function()
			with_fixture(outcome, function(fixture)
				helpers.assert_eq(fixture.action(), true)
				helpers.assert_eq(runtime_has_definition(fixture), true)
				helpers.assert_eq(fixture.calls.adds, 1)
				helpers.assert_eq(fixture.calls.saves, 1)
				helpers.assert_eq(fixture.calls.writes, 1)
				helpers.assert_eq(fixture.calls.updates, 1)
				local decoded = require("toml_codec").decode(fixture.read())
				helpers.assert_eq(decoded.foreign.keep, "untouched")
				helpers.assert_eq(decoded.hotstrings.terminators[1].future.keep, 17)
				helpers.assert_eq(decoded.hotstrings.terminators[2].char, custom_command_expected().target.char)
				helpers.assert_eq(decoded.hotstrings.terminators[2].consume, outcome ~= "consume_no")
			end)
		end)
	end
	for _, outcome in ipairs({ "false", "nil", "throw", "missing", "write_false", "write_throw" }) do
		helpers.it("refuses native Add and compensates the real preference owner after " .. outcome, function()
			with_fixture(outcome, function(fixture)
				helpers.assert_eq(fixture.action(), false)
				helpers.assert_eq(runtime_has_definition(fixture), false)
				helpers.assert_eq(fixture.read(), SOURCE)
				helpers.assert_eq(fixture.state, fixture.initial_state)
				helpers.assert_eq(fixture.calls.updates, 0)
				helpers.assert_eq(fixture.calls.rollbacks, outcome:find("write_", 1, true) == 1 and 1 or 0)
			end)
		end)
	end
	for _, outcome in ipairs({ "late_pause", "pause_after_prompt", "pause_after_consume", "pause_after_invalid_alert", "input_cancel", "input_empty", "input_error", "consume_cancel", "consume_nil", "consume_unknown" }) do
		helpers.it("keeps native Add unpublished after " .. outcome, function()
			with_fixture(outcome, function(fixture)
				if outcome == "late_pause" then fixture.context.paused = true end
				local result = fixture.action()
				helpers.assert_eq(runtime_has_definition(fixture), false)
				helpers.assert_eq(fixture.read(), SOURCE)
				helpers.assert_eq(fixture.calls.adds, 0)
				helpers.assert_eq(fixture.calls.writes, 0)
				helpers.assert_eq(fixture.calls.updates, 0)
				helpers.assert_eq(result, false)
				if outcome == "late_pause" then helpers.assert_eq(fixture.calls.prompts, 0) end
				if outcome == "pause_after_prompt" then helpers.assert_eq(fixture.calls.consumes, 0) end
				if outcome == "pause_after_invalid_alert" then helpers.assert_eq(fixture.calls.prompts, 1) end
			end)
		end)
	end
	helpers.it("the actual Add row uses its canonical delimiter translation", function()
		with_fixture("true", function(fixture)
			helpers.assert_eq(fixture.label, custom_command_expected().i18n)
		end)
	end)
	helpers.it("a refused Add recovers through the same preference transaction", function()
		with_fixture("write_false", function(fixture)
			helpers.assert_eq(fixture.action(), false)
			helpers.assert_eq(fixture.read(), SOURCE)
			fixture.retry()
			helpers.assert_eq(fixture.action(), true)
			helpers.assert_eq(runtime_has_definition(fixture), true)
			helpers.assert_eq(fixture.calls.rollbacks, 1)
			helpers.assert_eq(fixture.calls.updates, 1)
		end)
	end)
end)


helpers.describe("custom delimiter Add uses actual supplied native button labels", function()
	helpers.it("accepts and cancels native dialogs through all 21 real locale receipts", function()
		local locales = { "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja", "ko", "nl", "no", "pl", "pt", "ru", "sv", "tr", "uk", "zh" }
		local admitted, refused = 0, 0
		for _, locale in ipairs(locales) do
			with_fixture("true", function(fixture)
				helpers.assert_eq(fixture.action(), true, locale)
				helpers.assert_eq(runtime_has_definition(fixture), true, locale)
				helpers.assert_eq(fixture.calls.writes, 1, locale)
				helpers.assert_eq(fixture.calls.updates, 1, locale)
				local decoded = require("toml_codec").decode(fixture.read())
				helpers.assert_eq(decoded.hotstrings.terminators[1].future.keep, 17, locale)
				helpers.assert_eq(decoded.foreign.keep, "untouched", locale)
				admitted = admitted + 1
			end, locale)
			with_fixture("input_cancel", function(fixture)
				helpers.assert_eq(fixture.action(), false, locale)
				helpers.assert_eq(runtime_has_definition(fixture), false, locale)
				helpers.assert_eq(fixture.read(), SOURCE, locale)
				helpers.assert_eq(fixture.calls.writes, 0, locale)
				refused = refused + 1
			end, locale)
		end
		helpers.assert_eq(admitted, 21)
		helpers.assert_eq(refused, 21)
	end)
end)


--- Reads the independent command and existing native window identity.
--- @return table corpus Historical command expectation.
local function delay_settings_command_expected()
	local file = assert(io.open(require("infra.paths").shared("tests/corpus/menus/delays_settings_command.json"), "rb"))
	local bytes = file:read("*a")
	file:close()
	return assert(require("adapters.json_codec").decode(bytes))
end

helpers.describe("declared delay configuration command: actual macOS provider", function()
	helpers.it("uses the declared label in all 21 locale providers and keeps variable rows", function()
		for _, locale in ipairs({ "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja", "ko", "nl", "no", "pl", "pt", "ru", "sv", "tr", "uk", "zh" }) do
			with_fixture("config_shared_label", function(fixture)
				local expected = delay_settings_command_expected()
				local row = fixture.delay_rows[expected.position]
				helpers.assert_eq(row.label, fixture.translate("button.ok"), locale)
				helpers.assert_eq(fixture.delay_rows[2].separator, true)
				helpers.assert_eq(#fixture.delay_rows, 8, "the five variable quick-delay rows keep their position")
			end, locale)
		end
	end)

	for _, outcome in ipairs({ "true", "write_false", "write_throw" }) do
		helpers.it("retains the real save/refresh owner after opening: " .. outcome, function()
			with_fixture(outcome, function(fixture)
				local observations = { opens = 0 }
				local window = { open = function() observations.opens = observations.opens + 1 end }
				package.loaded["ui.hotstrings_config_window"] = window
				fixture.delay_rows[1].action()
				helpers.assert_eq(observations.opens, 1)
				helpers.assert_eq(fixture.calls.saves, 0, "opening the existing window writes no preferences")
				fixture.state.trigger_char = "◇"
				observations.callback_result = window._on_config_changed()
				helpers.assert_eq(fixture.calls.saves, 1)
				helpers.assert_eq(fixture.calls.updates, outcome == "true" and 1 or 0)
				if outcome ~= "true" then
					helpers.assert_eq(observations.callback_result, false)
					helpers.assert_eq(fixture.read(), SOURCE, "refused refresh writes preserve the real physical source")
				else
					helpers.assert_eq(require("toml_codec").decode(fixture.read()).foreign.keep, "untouched")
				end
			end)
		end)
	end

	helpers.it("preserves the existing paused disabled row without acquiring its window", function()
		with_fixture("config_paused", function(fixture)
			local observations = { opens = 0 }
			package.loaded["ui.hotstrings_config_window"] = { open = function() observations.opens = observations.opens + 1 end }
			helpers.assert_eq(fixture.delay_rows[1].disabled, true)
			if fixture.delay_rows[1].action then fixture.delay_rows[1].action() end
			helpers.assert_eq(observations.opens, 0)
			helpers.assert_eq(fixture.calls.saves, 0)
		end)
	end)

	helpers.it("contains an unavailable window owner and performs no save or redraw", function()
		with_fixture("true", function(fixture)
			package.loaded["ui.hotstrings_config_window"] = { open = false }
			fixture.delay_rows[1].action()
			helpers.assert_eq(fixture.calls.saves, 0)
			helpers.assert_eq(fixture.calls.updates, 0)
		end)
	end)
end)
