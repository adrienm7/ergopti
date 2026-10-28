--- tests/unit/modules/shortcuts/keyboard/test_migrated_config_keeps_bindings.lua

--- ==============================================================================
--- MODULE: A Migrated Configuration Keeps Every Binding
--- DESCRIPTION:
--- The v14 -> v15 step renames the retired slot ids. This replays an old Linux
--- configuration through the real migration engine and reads the result with the
--- real keyboard-slot owner: every binding is a candidate under its role-named
--- id and no key is left unowned (nothing is reported as outdated).
--- ==============================================================================

local helpers = require("tests.helpers")
local Engine = require("config_migrate")
local Codec = require("toml_codec")
local ConfigOutdated = require("config_outdated")

local OLD = table.concat({
	"[_meta]", "schema_version = 14", "[shortcuts.keyboard]",
	'ctrl_g = "open_chatgpt"', 'ctrl_shift_v = "paste_plain"', 'super_space = "llm_generate_prediction"',
	'super_shift_a = "select_all"', 'alt_x = "undo"', 'alt_shift_y = "redo"', "",
}, "\n")

helpers.describe("Linux keyboard slots: a migrated configuration (migrated-bindings)", function()
	helpers.it("(migrated-bindings) keeps every binding under a slot the owner knows", function()
		local root = helpers.driver_root() .. "/../_shared/"
		local registry = assert(Engine.load_registry(root .. Engine.REGISTRY_PATH))
		local catalogue = dofile(helpers.driver_root() .. "/../macos/_generated/action_catalogue.lua")
		local context = assert(Engine.load_context(root .. "modules/actions/modifier_chords.json", catalogue))
		local plan = Engine.plan(OLD, registry, "linux", context)
		helpers.assert_eq(plan.outcome, "migrated", tostring(plan.detail))
		local document = Codec.decode(plan.candidate)
		local migrated = document.shortcuts.keyboard
		helpers.assert_eq(migrated, {
			primary_g = "open_chatgpt", primary_shift_v = "paste_plain", meta_space = "llm_generate_prediction",
			meta_shift_a = "select_all", alt_x = "undo", alt_shift_y = "redo" })
		ConfigOutdated.reset_for_tests()
		package.loaded["modules.shortcuts.keyboard_shortcuts"] = nil
		local shortcuts = require("modules.shortcuts.keyboard_shortcuts")
		local paths
		local reported = ConfigOutdated.collect_reports(function()
			paths = shortcuts.configuration_paths(document)
		end)
		helpers.assert_eq(next(reported), nil, "no migrated key may be left unowned")
		local owned = {}
		for _, path in ipairs(paths) do owned[path] = true end
		for slot in pairs(migrated) do
			helpers.assert_true(owned["shortcuts.keyboard." .. slot], slot .. " must be a slot the owner knows")
		end
		package.loaded["modules.shortcuts.keyboard_shortcuts"] = nil
	end)
end)
