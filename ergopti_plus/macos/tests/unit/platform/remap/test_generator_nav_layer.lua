--- tests/unit/platform/remap/test_generator_nav_layer.lua

--- ==============================================================================
--- MODULE: Navigation Layer In The Generated Karabiner Config
--- DESCRIPTION:
--- The generator used to append data/layer_keys.json verbatim. It now deploys
--- the rule platform/remap/nav_layer.lua builds from state.nav_layer (the user's
--- layers.toml), and reads the frozen hand-written file only as the anchor that
--- proves older, unleased ErgoptiPlus blocks.
---
--- COVERAGE:
--- 1. A bound layer is deployed, gated on the lease like every managed rule and
---    reading this generation's layer variable.
--- 2. No binding, or no nav_layer at all, deploys no navigation rule.
--- 3. The frozen legacy file is the legacy anchor, and is never deployed.
--- 4. A layer the rule builder rejects fails the build instead of dropping it.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

local DATA_DIR = "/fake/data_dir/"
local LEGACY_LAYER = {
	description = "Legacy layer anchor",
	manipulators = {
		{
			type = "basic",
			from = { key_code = "q" },
			conditions = { { type = "variable_if", name = "layer_active", value = 1 } },
			to = { { key_code = "home" } },
		},
	},
}
local files = {}

package.loaded["adapters.file_system"] = {
	read = function(path) return files[path] end,
	read_with_status = function(path)
		if files[path] then return files[path], "ok" end
		return nil, "absent"
	end,
	write = function() return true end,
}
package.loaded["infra.config_paths"] = {
	get_config_dir = function() return "/tmp/ergopti_test" end,
}
package.loaded["infra.keycodes"] = {
	to_name                 = function(code) return "key_" .. tostring(code) end,
	F13_KARABINER_RETURN    = 105,
	F14_KARABINER_BACKSPACE = 107,
	F15_KARABINER_ESCAPE    = 113,
	F20_LAYER_NAV_ENTERED   = 90,
	F19_LAYER_NAV_EXITED    = 80,
}

local Generator = helpers.load_with_stubs("platform.remap.generator")
local TOKEN = "0123456789abcdef0123456789abcdef"
files[DATA_DIR .. "legacy_layer_keys.json"] = _G.hs.json.encode(LEGACY_LAYER)

local ACTIONS = { { id = "none", label = "None", karabiner_to = {} } }
local REGISTRY = { keys = {
	KeyH = { kind = "key", group = "alphanumeric", karabiner = { key_code = "h" } },
	ArrowLeft = { kind = "key", group = "navigation", karabiner = { key_code = "left_arrow" } },
} }
local ARROW_LEFT_ON_H = {
	KeyH = { kind = "keystroke", chords = { { mods = {}, key = "ArrowLeft" } }, repeatable = true, action = "arrow_left" },
}

--- A generator state, optionally carrying a navigation layer.
local function make_state(nav_layer)
	return {
		tap_hold_config = {},
		mod_combos_config = {},
		tap_hold_timeout_ms = 200,
		simultaneous_threshold_ms = 100,
		combo_symmetric = false,
		nav_layer = nav_layer,
	}
end

--- The deployed manipulators firing on a key code.
local function manipulators_on(config, key_code)
	local found = {}
	for _, rule in ipairs(config.profiles[1].complex_modifications.rules) do
		for _, manipulator in ipairs(rule.manipulators or {}) do
			if manipulator.from and manipulator.from.key_code == key_code then found[#found + 1] = manipulator end
		end
	end
	return found
end

--- Whether a manipulator carries a condition on a variable.
local function has_condition(manipulator, name, value)
	for _, condition in ipairs(manipulator.conditions or {}) do
		if condition.name == name and condition.value == value then return true end
	end
	return false
end

helpers.describe("Navigation layer in the generated Karabiner config", function()
	helpers.it("deploys the layer built from state.nav_layer, gated on the lease (nav-layer-generated)", function()
		local config, err = Generator.build_karabiner_json(make_state({ bindings = ARROW_LEFT_ON_H, registry = REGISTRY }),
			ACTIONS, {}, {}, {}, DATA_DIR, TOKEN)
		helpers.assert_nil(err)
		local on_h = manipulators_on(config, "h")
		helpers.assert_eq(#on_h, 1, "KeyH is bound once")
		helpers.assert_eq(on_h[1].to[1].key_code, "left_arrow")
		helpers.assert_true(has_condition(on_h[1], "ergopti_layer_active_" .. TOKEN, 1),
			"the layer reads this generation's layer variable")
		helpers.assert_true(has_condition(on_h[1], "ergopti_mode_" .. TOKEN, 1),
			"the layer is gated on the lease mode like every managed rule")
	end)

	helpers.it("deploys no navigation rule without a binding", function()
		for _, nav_layer in ipairs({ { bindings = {}, registry = REGISTRY }, false }) do
			local config, err = Generator.build_karabiner_json(make_state(nav_layer or nil),
				ACTIONS, {}, {}, {}, DATA_DIR, TOKEN)
			helpers.assert_nil(err)
			helpers.assert_eq(#manipulators_on(config, "h"), 0)
		end
	end)

	helpers.it("reads the frozen layer as the legacy anchor and never deploys it", function()
		local config, err, legacy_rules, legacy_context = Generator.build_karabiner_json(
			make_state({ bindings = ARROW_LEFT_ON_H, registry = REGISTRY }), ACTIONS, {}, {}, {}, DATA_DIR, TOKEN)
		helpers.assert_nil(err)
		helpers.assert_true(helpers.deep_equal(legacy_context.static_anchors.layer_keys, LEGACY_LAYER),
			"older unleased blocks are proven against the frozen hand-written layer")
		helpers.assert_eq(#manipulators_on(config, "q"), 0, "the frozen layer is not deployed")
		-- The historical graph is what an older release generated from the same
		-- state: its static layer where this one deploys the generated layer.
		local frozen, generated = 0, 0
		for _, rule in ipairs(legacy_rules) do
			if helpers.deep_equal(rule, LEGACY_LAYER) then frozen = frozen + 1 end
			for _, manipulator in ipairs(rule.manipulators or {}) do
				if manipulator.from and manipulator.from.key_code == "h" then generated = generated + 1 end
			end
		end
		helpers.assert_eq(frozen, 1, "the historical graph holds the frozen layer once")
		helpers.assert_eq(generated, 0, "the historical graph never holds the generated layer")
	end)

	helpers.it("fails the build on a layer the rule builder rejects", function()
		local config, err = Generator.build_karabiner_json(make_state({
			bindings = { KeyH = { kind = "repeat_count", count = 2 } }, registry = REGISTRY,
		}), ACTIONS, {}, {}, {}, DATA_DIR, TOKEN)
		helpers.assert_nil(config, "a navigation layer that cannot be built must not be dropped silently")
		helpers.assert_true(type(err) == "string" and err:find("navigation layer", 1, true) ~= nil, tostring(err))
	end)
end)
