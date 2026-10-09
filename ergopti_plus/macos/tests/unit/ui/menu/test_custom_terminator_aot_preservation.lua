--- tests/unit/ui/menu/test_custom_terminator_aot_preservation.lua

--- ==============================================================================
--- MODULE: Hand-written Terminator Record Preservation
--- DESCRIPTION:
--- Uses independent array-of-table bytes through the actual boot replay,
--- management provider and preference transaction. Mutating one delimiter must
--- retain unknown fields of untouched records and foreign source bytes.
--- ==============================================================================

local helpers = require("tests.helpers")
local OutputFixture = require("tests.support.toml_output_fixture")
local TARGET, NEIGHBOR = "custom_aot_target", "custom_aot_neighbor"
local FOREIGN = '# independent foreign sibling\n[[future.rules]]\nname = "one" # future rule comment\nvalue = { nested = [4, 9] }\n'
	.. '[[future.rules]]\nname = "two"\nvalue = "retain"\n'
local SOURCE = '# document comment\n[hotstrings]\nexpansion_delay = 0.1\n'
	.. '[hotstrings.terminator_states]\ncustom_aot_target = false\ncustom_aot_neighbor = true\n'
	.. '# target comment\n[[hotstrings.terminators]]\nkey = "custom_aot_target"\nchar = "☃"\n'
	.. 'label = "Snowman"\nconsume = false\nfuture = { nested = [17, 23], mode = "target" }\n'
	.. '# neighbor comment\n[[hotstrings.terminators]]\nkey = "custom_aot_neighbor"\nchar = "¤"\n'
	.. 'label = "Currency"\nconsume = true\nfuture = { nested = [31, 47], mode = "neighbor" }\n'
	.. FOREIGN

--- Reads the fixture without normalizing its independent source.
--- @param path string File path.
--- @return string bytes
local function read_bytes(path)
	local file = assert(io.open(path, "rb"))
	local bytes = file:read("*a")
	file:close()
	return bytes
end

--- Finds actual provider commands through either native child representation.
--- @param rows table|nil Rows.
--- @param label string Expected independent localization identifier.
--- @return table|nil row
local function find_row(rows, label)
	for _, row in ipairs(rows or {}) do
		if row.label == label then return row end
		local nested = find_row(row.items or row.submenu, label)
		if nested then return nested end
	end
end

--- Owns boot replay and real conditional disk publication for one action.
--- @param callback function Observations asserted outside production catches.
local function with_fixture(callback)
	return helpers.with_stub_scope({
		"adapters.file_system", "infra.fs_dir", "infra.logger", "infra.preferences",
		"infra.dialog_util", "infra.i18n", "infra.manifest_menu", "infra.manifest_reader",
		"infra.notifications", "modules.hotstrings.hotstrings_config", "keymap.terminators",
		"ui.menu.keymap_lifecycle", "ui.menu.menu_state", "ui.menu.menu_hotstrings_management",
		"ui.menu.preferences_transaction",
	}, function()
		local Preferences = helpers.load_with_stubs("infra.preferences")
		local Transaction = require("ui.menu.preferences_transaction")
		local Terminators = require("keymap.terminators")
		local calls = { writes = 0, updates = 0 }
		package.loaded["infra.i18n"] = { get = function(key) return key end, section = function(key) return key end }
		package.loaded["infra.dialog_util"] = {
			text_prompt = function(_, _, _, accept_label) return accept_label, "☂" end,
			block_alert = function(_, body)
				return body == "dialog.hotstrings.consume_body" and "dialog.hotstrings.consume_no" or "button.delete"
			end,
		}
		local renderer = require("infra.manifest_menu")
		local command_row = require("infra.manifest_menu").command_row
		local check_row = require("infra.manifest_menu").check_row
		local get_array = require("infra.manifest_menu").get_array
		package.loaded["infra.manifest_menu"] = {
			command_row = command_row,
			check_row = check_row,
			get_array = get_array,
			template_rows = renderer.template_rows,
			get_root = renderer.get_root,
			native_child_rows = renderer.native_child_rows,
			build = function(section, category, dynamic, groups, context, providers)
				if section == "word_expanders_menu" then
					return renderer.build(section, category, dynamic, groups, context, providers)
				end
				return providers.word_expanders()
			end,
		}
		package.loaded["infra.manifest_reader"] = { default_for = function() return "★" end }
		package.loaded["infra.notifications"] = { notify = function() end }
		package.loaded["modules.hotstrings.hotstrings_config"] = {
			resolve = function() return { delay = 0.1, has_override = false } end,
		}
		local MenuState = require("ui.menu.menu_state")
		local Management = require("ui.menu.menu_hotstrings_management")
		return OutputFixture.with_output(function(path)
			local file = assert(io.open(path, "wb"))
			assert(file:write(SOURCE))
			file:close()
			local loaded, status = Preferences.load(path)
			helpers.assert_eq(status, "ok")
			local state = {
				custom_terminators = Transaction.clone(loaded.custom_terminators),
				terminator_states = Transaction.clone(loaded.terminator_states),
				delays = {}, expansion_delay = 0.1, trigger_char = "★", hotstrings = {},
			}
			local keymap = {
				get_terminator_defs = Terminators.get_terminator_defs,
				validate_custom_terminator = Terminators.validate_custom_terminator,
				add_custom_terminator = Terminators.add_custom_terminator,
				remove_custom_terminator = Terminators.remove_custom_terminator,
				set_terminator_enabled = Terminators.set_terminator_enabled,
				is_terminator_enabled = Terminators.is_terminator_enabled,
				set_llm_model = function() return true end,
				is_repeat_feature_enabled = function() return false end,
				DELAYS_DEFAULT = { STAR_TRIGGER = 0.1, autocorrection = 0.1, llm_prediction = 0.1, dynamichotstrings = 0.1 },
				DEFAULT_STATE = { expansion_delay = 0.1 },
			}
			local applied, report = MenuState.sync_state_to_modules(state, loaded, false,
				{ keymap = keymap, core_mods = {}, hotstring_editor = {} })
			helpers.assert_eq(applied, true, "the real boot replay accepts both valid delimiters")
			helpers.assert_eq(report.repairs, {}, "valid records need no repair")
			local initial_state = Transaction.clone(state)
			local FileSystem = require("adapters.file_system")
			local writer = FileSystem.write_if_unchanged
			FileSystem.write_if_unchanged = function(...)
				calls.writes = calls.writes + 1
				if calls.refuse_write then return false, "injected publication refusal" end
				return writer(...)
			end
			local save = Transaction.bind(Preferences, {
				path = path, state = state, initial_state = initial_state, initial_preferences = initial_state,
				hotfiles = {}, core_modules = {}, restore_runtime = function(snapshot)
					return MenuState.sync_state_to_modules(state, snapshot, false,
						{ keymap = keymap, core_mods = {}, hotstring_editor = {} })
				end,
			})
			local result = table.pack(xpcall(function()
				local rows = Management.build_management({
					state = state, paused = false, keymap = keymap,
					applyTriggerChar = function(value) return value end,
					save_prefs = save, updateMenu = function() calls.updates = calls.updates + 1 end,
					notify_feature = function() end,
				})
				return callback({ state = state, loaded = loaded, rows = rows.menu, save = save,
					calls = calls, read = function() return read_bytes(path) end })
			end, debug.traceback))
			for _, definition in ipairs(Terminators.get_terminator_defs()) do
				if definition.custom then Terminators.remove_custom_terminator(definition.key) end
			end
			if not result[1] then error(result[2], 0) end
			return table.unpack(result, 2, result.n)
		end)
	end)
end

--- Checks unknown metadata against independent expectations.
--- @param records table Records.
--- @param key string Expected untouched record.
local function assert_neighbor(records, key)
	local record
	for _, candidate in ipairs(records) do if candidate.key == key then record = candidate end end
	helpers.assert_type(record, "table")
	helpers.assert_eq(record.future, { nested = { 31, 47 }, mode = "neighbor" },
		"untouched delimiter metadata belongs to the user")
end

helpers.describe("hand-written delimiter records through the management owner", function()
	helpers.it("retains unowned fields during actual boot replay", function()
		with_fixture(function(fixture)
			helpers.assert_eq(fixture.read(), SOURCE, "boot replay does not write")
			assert_neighbor(fixture.loaded.custom_terminators, NEIGHBOR)
			assert_neighbor(fixture.state.custom_terminators, NEIGHBOR)
			fixture.state.custom_terminators[2].future.nested[1] = 99
			assert_neighbor(fixture.loaded.custom_terminators, NEIGHBOR)
		end)
	end)
	for _, action in ipairs({ "add_custom", "delete_expander" }) do
		local label = action == "delete_expander" and "menu.hotstrings.delete_delimiter" or "menu.hotstrings.add_delimiter"
		helpers.it("preserves the untouched AoT sibling through " .. action, function()
			with_fixture(function(fixture)
				local row = find_row(fixture.rows, label)
				helpers.assert_type(row, "table")
				helpers.assert_eq(row.action(), true)
				helpers.assert_eq(fixture.calls.writes, 1)
				helpers.assert_eq(fixture.calls.updates, 1)
				local disk = fixture.read()
				local decoded = require("toml_codec").decode(disk)
				local records = decoded.hotstrings.terminators
				helpers.assert_eq(#records, action == "add_custom" and 3 or 1)
				if action == "add_custom" then
					helpers.assert_eq(records[1].future, { nested = { 17, 23 }, mode = "target" })
					helpers.assert_eq(records[3].char, "☂")
					helpers.assert_eq(records[3].consume, false)
				else
					helpers.assert_eq(records[1].key, NEIGHBOR, "only the selected record is removed")
				end
				assert_neighbor(records, NEIGHBOR)
				helpers.assert_true(disk:find(FOREIGN, 1, true) ~= nil, "foreign sibling records keep exact bytes")
				helpers.assert_true(disk:find("# neighbor comment\n", 1, true) ~= nil, "neighbor comments survive")
			end)
		end)
		helpers.it("rolls an AoT " .. action .. " back after real publication refuses", function()
			with_fixture(function(fixture)
				local row = find_row(fixture.rows, label)
				helpers.assert_type(row, "table")
				local before = require("ui.menu.preferences_transaction").clone(fixture.state)
				fixture.calls.refuse_write = true
				helpers.assert_eq(row.action(), false)
				helpers.assert_eq(fixture.state, before, "the existing transaction restores complete records")
				helpers.assert_eq(fixture.read(), SOURCE, "refused publication preserves exact hand-written bytes")
				assert_neighbor(fixture.state.custom_terminators, NEIGHBOR)
				helpers.assert_eq(fixture.calls.updates, 0)
				fixture.calls.refuse_write = false
				helpers.assert_eq(row.action(), true, "the same retained action can recover")
				assert_neighbor(require("toml_codec").decode(fixture.read()).hotstrings.terminators, NEIGHBOR)
				helpers.assert_eq(fixture.calls.updates, 1)
			end)
		end)
	end
end)
