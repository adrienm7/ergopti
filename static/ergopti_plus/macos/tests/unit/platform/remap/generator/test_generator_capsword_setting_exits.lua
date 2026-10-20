--- tests/unit/platform/remap/generator/test_generator_capsword_setting_exits.lua

--- ==============================================================================
--- MODULE: Generator CapsWord Setting Exits Tests
--- DESCRIPTION:
--- The deployed CapsWord rule leaves the exits [shortcuts.caps_word] decides
--- (Space, Enter, Tab, Ergopti's "." and "," keys, the left and right clicks) to
--- the Hammerspoon watcher, which matches the typed character and the checked
--- pointer kind. Karabiner used to end CapsWord on those keys whatever the user
--- chose, and on the letters g and v of any non-Ergopti layout. The fixed exits
--- stay, and capsword.json stays whole as the historical anchor.
--- ==============================================================================

local helpers = require("tests.helpers")
local TOKEN = "0123456789abcdef0123456789abcdef"

--- Builds the shipped graph and returns its CapsWord rule and legacy context.
local function build()
	local config, err, _legacy, context
	helpers.with_stub_scope({ "platform.remap.generator", "infra.logger", "adapters.file_system" }, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		local Generator = helpers.load_with_stubs("platform.remap.generator")
		config, err, _legacy, context = Generator.build_karabiner_json({
			tap_hold_config = {}, mod_combos_config = {}, tap_hold_timeout_ms = 200,
			simultaneous_threshold_ms = 100, combo_symmetric = false,
		}, { { id = "none", label = "None", karabiner_to = {} } }, {}, {}, {},
			helpers.driver_root() .. "platform/remap/data/", TOKEN)
	end)
	helpers.assert_nil(err)
	return config, context
end

--- Collects the CapsWord exits of a rule: key codes and pointing buttons.
local function exits(rule)
	local found = {}
	for _, manipulator in ipairs(rule.manipulators or {}) do
		local from = manipulator.from or {}
		local active_only = false
		for _, condition in ipairs(manipulator.conditions or {}) do
			if condition.name:find("capsword", 1, true) and condition.type == "variable_if"
				and condition.value == 1 then active_only = true end
		end
		if active_only then found[from.key_code or from.pointing_button] = true end
	end
	return found
end

helpers.describe("Generator: CapsWord exits the settings own are not deployed", function()
	helpers.it("drops the delimiter keys and the clicks, keeps the fixed exits", function()
		local config = build()
		local rule = config.profiles[1].complex_modifications.rules[1]
		helpers.assert_contains(rule.description, "CapsWord")
		local deployed = exits(rule)
		for _, owned in ipairs({ "spacebar", "return_or_enter", "tab", "g", "v", "button1", "button2" }) do
			helpers.assert_nil(deployed[owned], owned .. " must be left to the CapsWord settings")
		end
		for _, fixed in ipairs({ "caps_lock", "escape", "delete_forward", "up_arrow", "page_down", "home", "f1" }) do
			helpers.assert_true(deployed[fixed], fixed .. " stays a Karabiner CapsWord exit")
		end
	end)

	helpers.it("keeps capsword.json whole as the historical anchor", function()
		local _config, context = build()
		local anchor = exits(context.static_anchors.capsword)
		for _, historical in ipairs({ "spacebar", "return_or_enter", "tab", "g", "v", "button1", "button2" }) do
			helpers.assert_true(anchor[historical], historical .. " must stay in the frozen anchor")
		end
	end)
end)
