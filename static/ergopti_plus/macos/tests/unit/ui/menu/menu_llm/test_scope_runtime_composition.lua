--- tests/unit/ui/menu/menu_llm/test_scope_runtime_composition.lua

--- Calls the actual keymap bridge, prediction engine and core together.
local helpers = require("tests.helpers")

helpers.describe("LLM scope runtime composition", function()
	helpers.it("applies all real runtime fields and restores their prior values with AI OFF", function()
		local keymap = helpers.load_with_stubs("modules.keymap")
		local core = require("modules.llm")
		local Preferences = require("infra.preferences")
		local Manifest = require("infra.manifest_reader")
		local state = { llm_profile_shortcuts = {} }
		for _, row in ipairs(Manifest.scope_operations("llm", "clear")) do
			local path = row.section .. "." .. row.key
			state[assert(Preferences.flat_key_for(path))] = Preferences.state_value_for(path, Manifest.default_for(path))
		end
		local starts = 0
		package.loaded["modules.llm.api_ollama"].ensure_running = function() starts = starts + 1; return true end
		helpers.assert_eq(keymap.set_llm_enabled(false), true)
		helpers.assert_eq(keymap.set_llm_debounce(0.725), true)
		local runtime = require("ui.menu.menu_llm.scope_runtime").new({
			state = state, core = core, keymap = keymap, idle = function() return true end,
			shortcuts = { configuration_snapshot = function() return { llm_profile_shortcuts = {} } end,
				apply_configuration = function() return true end },
			reset_health = function() return true end, model_power = function() return 1 end,
			display_model = function(model) return model end, backend_label = function(backend) return backend end,
		})
		local before = runtime.capture()
		helpers.assert_not_nil(before)
		helpers.assert_eq(runtime.apply({}, Manifest.scope_operations("llm", "clear")), true)
		local found, value = keymap.get_llm_runtime_setting("llm_debounce")
		helpers.assert_eq(found, true)
		helpers.assert_eq(value, 0.2)
		helpers.assert_eq(keymap.get_llm_enabled(), false)
		helpers.assert_eq(starts, 0)
		helpers.assert_eq(runtime.restore(before), true)
		local _, restored = keymap.get_llm_runtime_setting("llm_debounce")
		helpers.assert_eq(restored, 0.725)
		helpers.assert_eq(starts, 0)
	end)
end)
