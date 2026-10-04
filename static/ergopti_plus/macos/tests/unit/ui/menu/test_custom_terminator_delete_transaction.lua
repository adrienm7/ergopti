--- tests/unit/ui/menu/test_custom_terminator_delete_transaction.lua

--- ==============================================================================
--- MODULE: Custom Terminator Deletion Transaction
--- DESCRIPTION:
--- Exercises the real provider, shared registry and preference transaction.
--- Refused runtime removal retains the delimiter; refused disk publication
--- rolls the real registry back through the existing preference owner.
--- ==============================================================================

local helpers = require("tests.helpers")
local OutputFixture = require("tests.support.toml_output_fixture")

--- Reads the independent custom-command identity used by each native provider.
--- @return table expected Canonical command expectation.
local function custom_command_expected()
	local path = require("infra.paths").shared("tests/corpus/menus/word_expander_custom_controls.json")
	local file = assert(io.open(path, "rb"))
	local text = file:read("*a")
	file:close()
	local corpus = assert(require("adapters.json_codec").decode(text))
	assert(#corpus.rows == 1, "every independent custom command must be observed")
	return corpus.rows[1]
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
local function find_delete(rows)
	for _, row in ipairs(rows or {}) do
		if row.label == custom_command_expected().i18n then return row end
		local nested = find_delete(row.items or row.submenu)
		if nested then return nested end
	end
end

--- Owns real registry, source and publication state for one scenario.
--- @param outcome string Runtime or writer outcome.
--- @param callback function Assertion callback, outside production catches.
local function with_fixture(outcome, callback)
	return helpers.with_stub_scope({
		"adapters.file_system", "infra.fs_dir", "infra.logger", "infra.preferences",
		"infra.dialog_util", "infra.i18n", "infra.manifest_menu", "infra.manifest_reader",
		"infra.notifications", "modules.hotstrings.hotstrings_config", "keymap.terminators",
		"ui.menu.keymap_lifecycle", "ui.menu.menu_hotstrings_management", "ui.menu.preferences_transaction",
	}, function()
		local Preferences = helpers.load_with_stubs("infra.preferences")
		local FileSystem = require("adapters.file_system")
		local Transaction = require("ui.menu.preferences_transaction")
		local Terminators = require("keymap.terminators")
		local calls = { removes = 0, writes = 0, saves = 0, updates = 0, notices = 0, rollbacks = 0 }
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.dialog_util"] = { block_alert = function() return "button.delete" end }
		local command_renderer = assert(require("menu.renderer").new({
			platform = "hs",
			manifest_path = function() return require("infra.paths").shared("modules/menu/menu_manifest.json") end,
			json_decode = require("adapters.json_codec").decode,
			i18n = { get = function(key) return key end, section = function(key) return key end },
			logger = require("infra.logger"),
		}))
		package.loaded["infra.manifest_menu"] = {
			command_row = command_renderer.command_row,
			check_row = command_renderer.check_row,
			get_array = command_renderer.get_array,
			build = function(section, _, _, _, _, providers)
				if section == "word_expanders_menu" then return providers.word_expander_entries() end
				return providers.word_expanders()
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
			local current_outcome = outcome
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
				keymap.remove_custom_terminator = function(key)
					calls.removes = calls.removes + 1
					if current_outcome == "false" then return false end
					if current_outcome == "nil" then return nil end
					if current_outcome == "throw" then error("injected runtime refusal", 0) end
					return Terminators.remove_custom_terminator(key)
				end
			end
			local rows = Management.build_management({
				state = state, paused = false, keymap = keymap,
				applyTriggerChar = function(value) return value end,
				save_prefs = function() calls.saves = calls.saves + 1; return save() end,
				updateMenu = function() calls.updates = calls.updates + 1 end,
				notify_feature = function() end,
			})
			local row = find_delete(rows.menu)
			helpers.assert_type(row, "table")
			helpers.assert_type(row.action, "function")
			local fixture = {
				state = state, initial_state = initial_state, calls = calls, action = row.action,
				path = path, definitions = Terminators.get_terminator_defs,
				read = function() return read_bytes(path) end,
				retry = function() current_outcome = "true" end,
			}
			local result = table.pack(xpcall(function() return callback(fixture) end, debug.traceback))
			for _, definition in ipairs(Terminators.get_terminator_defs()) do
				if definition.key == KEY then Terminators.remove_custom_terminator(KEY); break end
			end
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
		if definition.key == KEY then return true end
	end
	return false
end

helpers.describe("custom delimiter deletion acknowledgement", function()
	for _, outcome in ipairs({ "false", "nil", "throw", "missing" }) do
		helpers.it("retains runtime, source and state after " .. outcome .. " removal", function()
			with_fixture(outcome, function(fixture)
				local records, entry = fixture.state.custom_terminators, fixture.state.custom_terminators[1]
				local result = fixture.action()
				helpers.assert_eq(fixture.state, fixture.initial_state)
				helpers.assert_eq(fixture.state.custom_terminators == records, true)
				helpers.assert_eq(fixture.state.custom_terminators[1] == entry, true)
				helpers.assert_eq(fixture.read(), SOURCE)
				helpers.assert_eq(runtime_has_definition(fixture), true)
				helpers.assert_eq(result, false)
				helpers.assert_eq(fixture.calls.removes, outcome == "missing" and 0 or 1)
				helpers.assert_eq(fixture.calls.saves, 0)
				helpers.assert_eq(fixture.calls.writes, 0)
				helpers.assert_eq(fixture.calls.updates, 0)
				helpers.assert_eq(fixture.calls.notices, 1)
			end)
		end)
	end
	helpers.it("recovers a retained action after the engine resumes accepting removal", function()
		with_fixture("false", function(fixture)
			helpers.assert_eq(fixture.action(), false)
			helpers.assert_eq(fixture.read(), SOURCE)
			fixture.retry()
			helpers.assert_eq(fixture.action(), true)
			helpers.assert_eq(fixture.calls.removes, 2)
			helpers.assert_eq(fixture.calls.saves, 1)
			helpers.assert_eq(fixture.calls.writes, 1)
			helpers.assert_eq(fixture.calls.updates, 1)
			helpers.assert_eq(runtime_has_definition(fixture), false)
		end)
	end)
	for _, outcome in ipairs({ "write_false", "write_throw" }) do
		helpers.it("uses the preference rollback and recovers after " .. outcome, function()
			with_fixture(outcome, function(fixture)
				helpers.assert_eq(fixture.action(), false)
				helpers.assert_eq(fixture.state, fixture.initial_state)
				helpers.assert_eq(fixture.read(), SOURCE)
				helpers.assert_eq(runtime_has_definition(fixture), true)
				helpers.assert_eq(fixture.calls.rollbacks, 1)
				helpers.assert_eq(fixture.calls.updates, 0)
				helpers.assert_eq(fixture.calls.expected_source, { status = "ok", content = SOURCE })
				fixture.retry()
				helpers.assert_eq(fixture.action(), true)
				helpers.assert_eq(runtime_has_definition(fixture), false)
				helpers.assert_eq(#fixture.state.custom_terminators, 0)
				helpers.assert_eq(fixture.calls.rollbacks, 1)
				helpers.assert_eq(fixture.calls.updates, 1)
			end)
		end)
	end
	helpers.it("publishes an acknowledged removal once through the real writer", function()
		with_fixture("true", function(fixture)
			helpers.assert_eq(fixture.action(), true)
			helpers.assert_eq(fixture.calls.removes, 1)
			helpers.assert_eq(fixture.calls.writes, 1)
			helpers.assert_eq(fixture.calls.saves, 1)
			helpers.assert_eq(fixture.calls.updates, 1)
			helpers.assert_eq(runtime_has_definition(fixture), false)
			helpers.assert_eq(#fixture.state.custom_terminators, 0)
			helpers.assert_eq(fixture.state.terminator_states[KEY], nil)
			local decoded = require("toml_codec").decode(fixture.read())
			helpers.assert_eq(decoded.foreign.keep, "untouched")
			helpers.assert_eq(decoded.hotstrings.terminators, {})
			helpers.assert_true(fixture.read():find('[foreign]\nkeep = "untouched"\n', 1, true) ~= nil,
				"the unowned table preserves its exact source bytes")
		end)
	end)
end)
