--- tests/unit/meta/test_empty_config_neutral.lua

local helpers = require("tests.helpers")
local Loader = require("platform.remap.tap_hold_loader")
local defaults = require("infra.paths").shared("tap_hold/defaults.toml")

helpers.describe("empty tap-hold configuration is neutral", function()
	helpers.it("neutral-config: dynamic rule availability never grants activation", function()
		local module = helpers.load_module("modules.dynamic_hotstrings.manager")
		helpers.assert_eq(module.is_enabled(), false)
		helpers.assert_eq(module.init({ personal_info_path = "/nonexistent/neutral-personal-info.toml" }), true)
		helpers.assert_true(module.get_rules_count() > 0, "exercise registered date rules")
		helpers.assert_eq(module.is_enabled(), false)
	end)

	helpers.it("neutral-config: enabling the dynamic master does not import date families", function()
		local restore = require("tests.support.dynamic_hotstrings_fixture").route()
		local ok, detail = pcall(function()
			local module = helpers.load_module("modules.dynamic_hotstrings.manager")
			module.init({ personal_info_path = "/nonexistent/neutral-personal-info.toml" })
			helpers.assert_eq(module.set_enabled(true), true)
			for _, family in ipairs(module.RULE_FAMILIES) do
				if family.section then helpers.assert_eq(module.is_rule_enabled(nil, family.section), false) end
			end
		end)
		restore()
		assert(ok, detail)
	end)

	helpers.it("neutral-config: personal and extension sections remain off without explicit intent", function()
		local config = helpers.load_module("modules.hotstrings.hotstrings_config")
		helpers.assert_eq(config.is_section_checked("personal_user_file", "custom"), false)
		helpers.assert_eq(config.is_section_checked("extension_user_pack", "custom"), false)
	end)

	helpers.it("neutral-config: does not acquire recommended keys when the user file is absent", function()
		local loaded = Loader.load(defaults, "/nonexistent/neutral-tap-hold.toml")
		helpers.assert_eq(loaded.enabled, false)
		helpers.assert_eq(next(loaded.keys), nil)
		helpers.assert_type(loaded.hold_picker, "table", "the picker catalogue remains available")
	end)

	helpers.it("neutral-config: preserves desired keys behind an absent master without filling other bindings", function()
		local path = os.tmpname()
		local file = assert(io.open(path, "w"))
		file:write('[tap_hold.keys.caps_lock]\ntap_action = "copy"\n')
		file:close()
		local ok, loaded = pcall(Loader.load, defaults, path)
		os.remove(path)
		assert(ok, loaded)
		helpers.assert_eq(loaded.enabled, false)
		helpers.assert_eq(loaded.keys.caps_lock.tap_action, "copy")
		helpers.assert_eq(loaded.keys.caps_lock.hold_modifier, nil)
		helpers.assert_eq(loaded.keys.left_shift, nil)
	end)
end)

require("test.scope_sparse_contract")(helpers)
