--- tests/unit/modules/shortcuts/keyboard/test_migrated_config_keeps_bindings.lua

--- ==============================================================================
--- MODULE: A Migrated Configuration Keeps Every Binding
--- DESCRIPTION:
--- The v14 -> v15 step renames the retired slot ids. This replays an old macOS
--- configuration through the real migration engine and loads the result into the
--- real keyboard-slot owner: every binding is live under its role-named id and
--- no key is left unowned (nothing is reported as outdated).
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = {
	"adapters.storage",
	"infra.preferences",
	"infra.config_paths",
	"adapters.hotkey_registrar",
	"adapters.file_system",
	"infra.paths",
	"infra.logger",
	"modules.gestures.actions",
	"modules.shortcuts.keyboard_shortcuts",
}

-- The only ids the stubbed catalogue offers; the manifest is the real one.
local OFFERED = { lookup = true, none = true, llm_generate_prediction = true }

--- Runs `scenario` against the real keyboard-shortcut owner over stubbed
--- settings, registrar and catalogue, then restores every displaced module.
--- @param store table Initial canonical assignment map, mutated by conditional writes.
--- @param scenario function(subject, observed)
--- @return table observed { bound = {chord...} }
local function with_subject(store, scenario)
	local prior = {}
	for _, name in ipairs(MODULES) do prior[name] = package.loaded[name] end

	local observed = { bound = {} }
	package.loaded["adapters.hotkey_registrar"] = {
		bind = function(chord)
			observed.bound[#observed.bound + 1] = chord
			return { id = #observed.bound }
		end,
		unbind = function() return true end,
		setEnabled = function() return true end,
	}
	package.loaded["adapters.file_system"] = {
		read = function() return '{"keys":[{"id":"a","label":"A"},{"id":"space","label":"Space"}]}' end,
	}
	package.loaded["infra.paths"] = { shared = function() return "catalogue.json" end }
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["modules.gestures.actions"] = {
		is_assignable = function(action_id) return OFFERED[action_id] == true end,
		execute_single = function() return true end,
	}
	package.loaded["adapters.storage"] = nil
	package.loaded["modules.shortcuts.keyboard_shortcuts"] = nil

	require("tests.support.keyboard_config_fixture").install(store)

	local subject
	local ok, err = xpcall(function()
		subject = require("modules.shortcuts.keyboard_shortcuts")
		scenario(subject, observed)
	end, debug.traceback)

	if subject and type(subject.stop) == "function" then pcall(subject.stop) end
	for _, name in ipairs(MODULES) do package.loaded[name] = prior[name] end
	if not ok then error(err, 0) end
	return observed
end

local ConfigOutdated = require("config_outdated")
local Engine = require("config_migrate")
local Codec = require("toml_codec")

-- Slots the stub catalogue of with_subject can own: keys "a" and "space".
local OLD = table.concat({
	"[_meta]", "schema_version = 14", "[shortcuts.keyboard]",
	'cmd_a = "lookup"', 'hs_ctrl_a = "lookup"', 'hs_ctrl_space = "llm_generate_prediction"',
	'hs_option_a = "lookup"', 'cmd_shift_a = "lookup"', 'hs_ctrl_shift_a = "lookup"', "",
}, "\n")

helpers.describe("keyboard shortcuts: a migrated configuration (migrated-bindings)", function()
	helpers.it("(migrated-bindings) loads every renamed slot and reports nothing as outdated", function()
		local registry = assert(Engine.load_registry(helpers.shared(Engine.REGISTRY_PATH)))
		local catalogue = dofile(helpers.shared("../macos/_generated/action_catalogue.lua"))
		local context = assert(Engine.load_context(helpers.shared("modules/actions/modifier_chords.json"), catalogue))
		local plan = Engine.plan(OLD, registry, "hs", context)
		helpers.assert_eq(plan.outcome, "migrated", tostring(plan.detail))
		local migrated = Codec.decode(plan.candidate).shortcuts.keyboard
		helpers.assert_eq(migrated, {
			primary_a = "lookup", secondary_a = "lookup", secondary_space = "llm_generate_prediction",
			alt_a = "lookup", primary_shift_a = "lookup", secondary_shift_a = "lookup" })
		ConfigOutdated.reset_for_tests()
		local reported = ConfigOutdated.collect_reports(function()
			with_subject(migrated, function(subject)
				helpers.assert_eq(subject.start(), true)
				for slot, action in pairs(migrated) do
					helpers.assert_eq(subject.get_action(slot), action, slot .. " must stay bound")
				end
			end)
		end)
		helpers.assert_eq(next(reported), nil, "no migrated key may be left unowned")
	end)
end)

return true
