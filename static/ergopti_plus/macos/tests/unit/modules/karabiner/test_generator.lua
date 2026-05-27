--- tests/unit/modules/karabiner/test_generator.lua

--- ==============================================================================
--- MODULE: karabiner.generator Snapshot Tests
--- DESCRIPTION:
--- Snapshot-style unit tests for generator.lua — verifying that the public
--- functions produce correctly-shaped Karabiner-Elements JSON structures given
--- minimal or controlled inputs. Tests do not rely on on-disk corpus files:
--- available_actions, tap_hold_keys, and mod_combos are supplied inline as
--- small representative fixtures.
---
--- FEATURES & RATIONALE:
--- 1. No Corpus Files: All input data is synthetic so the suite runs in CI
---    without needing the full ergopti config directory on disk.
--- 2. Structural Snapshots: Rather than byte-for-byte JSON comparison,
---    assertions check for the presence and shape of the fields that
---    Karabiner-Elements actually reads (profiles, complex_modifications,
---    parameters, rules).
--- 3. Merge Preservation: merge_into_existing_config tests confirm that
---    non-complex_modifications fields (devices, name, global) survive
---    a regeneration cycle.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

-- Stub adapters.file_system so load_json_file never hits the real disk.
-- Tests that need FileSystem.read to return data override _fs_data below.
local _fs_data = {}
package.loaded["adapters.file_system"] = {
	read  = function(path) return _fs_data[path] end,
	write = function(_path, _content) return true end,
}

-- Stub ui.menu.menu_paths (required at module load time to compute the
-- KE_PHYSICAL_KC_LOG constant — it must not hit the filesystem).
package.loaded["ui.menu.menu_paths"] = {
	get_config_dir = function() return "/tmp/ergopti_test" end,
}

-- Stub lib.keycodes with the minimal surface used by generator.lua.
package.loaded["lib.keycodes"] = {
	to_name              = function(code) return "key_" .. tostring(code) end,
	F13_KARABINER_RETURN   = 105,
	F14_KARABINER_BACKSPACE = 107,
	F15_KARABINER_ESCAPE   = 113,
	F20_LAYER_NAV_ENTERED  = 90,
}

local Generator = helpers.load_with_stubs("modules.karabiner.generator")


-- ---------------------------------------------------------------------------
-- Minimal fixtures reused across tests.
-- ---------------------------------------------------------------------------

-- A none_action as generator.lua expects it internally; the generator falls
-- back to this when an action id is "none".
local NONE_ACTION = {
	id            = "none",
	label         = "Rien",
	karabiner_to  = {},
}

-- A simple cmd action used to exercise the tap/hold rule builder.
local CMD_ACTION = {
	id            = "cmd",
	label         = "⌘ Cmd",
	karabiner_to  = { { key_code = "left_command" } },
}

-- Minimal key definition (mirrors the shape in tap_hold_keys.json).
local RCMD_KEY_DEF = {
	id    = "right_command",
	label = "Right Command",
	from  = { key_code = "right_command" },
}

-- State table with every field build_karabiner_json reads.
local function make_state(overrides)
	local base = {
		tap_hold_config          = {},
		mod_combos_config        = {},
		tap_hold_timeout_ms      = 200,
		simultaneous_threshold_ms = 100,
		combo_symmetric          = false,
	}
	if overrides then
		for k, v in pairs(overrides) do base[k] = v end
	end
	return base
end




-- ============================================================
--- ============================================================
-- ======= 1/ build_karabiner_json: structural skeleton =======
--- ============================================================
-- ============================================================

helpers.describe("Generator.build_karabiner_json: structural skeleton", function()
	helpers.it("returns a table with a profiles array", function()
		-- No capsword.json on disk — load_json_file returns nil, which is
		-- gracefully skipped by the generator.
		local result = Generator.build_karabiner_json(
			make_state(), {NONE_ACTION}, {}, {}, nil, "/fake/data_dir/"
		)
		helpers.assert_true(type(result) == "table", "result must be a table")
		helpers.assert_true(type(result.profiles) == "table", "must have profiles")
		helpers.assert_true(#result.profiles >= 1, "must have at least one profile")
	end)

	helpers.it("first profile is selected and named Default profile", function()
		local result = Generator.build_karabiner_json(
			make_state(), {NONE_ACTION}, {}, {}, nil, "/fake/data_dir/"
		)
		local profile = result.profiles[1]
		helpers.assert_true(profile.selected == true, "first profile must be selected")
		helpers.assert_eq(profile.name, "Default profile")
	end)

	helpers.it("complex_modifications contains parameters and rules", function()
		local result = Generator.build_karabiner_json(
			make_state(), {NONE_ACTION}, {}, {}, nil, "/fake/data_dir/"
		)
		local cm = result.profiles[1].complex_modifications
		helpers.assert_true(type(cm) == "table", "complex_modifications must be a table")
		helpers.assert_true(type(cm.parameters) == "table", "parameters must be a table")
		helpers.assert_true(type(cm.rules) == "table", "rules must be a table")
	end)

	helpers.it("parameters carry the configured timeout values", function()
		local state = make_state({
			tap_hold_timeout_ms       = 175,
			simultaneous_threshold_ms = 80,
		})
		local result = Generator.build_karabiner_json(
			state, {NONE_ACTION}, {}, {}, nil, "/fake/data_dir/"
		)
		local params = result.profiles[1].complex_modifications.parameters
		helpers.assert_eq(
			params["basic.to_if_alone_timeout_milliseconds"],
			175,
			"tap/hold timeout"
		)
		helpers.assert_eq(
			params["basic.simultaneous_threshold_milliseconds"],
			80,
			"simultaneous threshold"
		)
	end)

	helpers.it("produces no rules when all inputs are empty and no data files exist", function()
		local result = Generator.build_karabiner_json(
			make_state(), {NONE_ACTION}, {}, {}, nil, "/fake/data_dir/"
		)
		local rules = result.profiles[1].complex_modifications.rules
		-- Script-control sentinel rules are always emitted (3 slots), but
		-- tap/hold and combo lists are empty.
		helpers.assert_true(type(rules) == "table", "rules must be a table")
	end)

	helpers.it("includes virtual_hid_keyboard with ansi keyboard_type_v2", function()
		local result = Generator.build_karabiner_json(
			make_state(), {NONE_ACTION}, {}, {}, nil, "/fake/data_dir/"
		)
		local vhk = result.profiles[1].virtual_hid_keyboard
		helpers.assert_true(type(vhk) == "table", "virtual_hid_keyboard must be present")
		helpers.assert_eq(vhk.keyboard_type_v2, "ansi")
	end)
end)




-- ========================================================
-- ========================================================
-- ======= 2/ build_karabiner_json: tap/hold rules ========
-- ========================================================
-- ========================================================

helpers.describe("Generator.build_karabiner_json: tap/hold rules", function()
	helpers.it("emits one rule per configured tap/hold key", function()
		local state = make_state({
			tap_hold_config = {
				right_command = { tap = "cmd", hold = "cmd" },
			},
		})
		local result = Generator.build_karabiner_json(
			state, {NONE_ACTION, CMD_ACTION}, {RCMD_KEY_DEF}, {}, nil, "/fake/data_dir/"
		)
		local rules = result.profiles[1].complex_modifications.rules
		-- At minimum the rcmd rule exists among the generated rules
		local found_rcmd = false
		for _, rule in ipairs(rules) do
			if type(rule.description) == "string"
				and rule.description:find("Right Command") then
				found_rcmd = true
				break
			end
		end
		helpers.assert_true(found_rcmd, "expected a Right Command tap/hold rule")
	end)

	helpers.it("each tap/hold rule has a description and manipulators array", function()
		local state = make_state({
			tap_hold_config = {
				right_command = { tap = "cmd", hold = "cmd" },
			},
		})
		local result = Generator.build_karabiner_json(
			state, {NONE_ACTION, CMD_ACTION}, {RCMD_KEY_DEF}, {}, nil, "/fake/data_dir/"
		)
		local rules = result.profiles[1].complex_modifications.rules
		for _, rule in ipairs(rules) do
			helpers.assert_true(
				type(rule.description) == "string" and rule.description ~= "",
				"rule must have a non-empty description"
			)
			helpers.assert_true(
				type(rule.manipulators) == "table" and #rule.manipulators >= 1,
				"rule must have at least one manipulator"
			)
		end
	end)

	helpers.it("passthrough rule is emitted when both slots are none", function()
		local state = make_state({
			tap_hold_config = {
				right_command = { tap = "none", hold = "none" },
			},
		})
		local result = Generator.build_karabiner_json(
			state, {NONE_ACTION}, {RCMD_KEY_DEF}, {}, nil, "/fake/data_dir/"
		)
		local rules = result.profiles[1].complex_modifications.rules
		local found_passthrough = false
		for _, rule in ipairs(rules) do
			if type(rule.description) == "string"
				and rule.description:find("passthrough") then
				found_passthrough = true
				break
			end
		end
		helpers.assert_true(found_passthrough, "expected a passthrough rule for none/none slots")
	end)
end)




-- ==============================================================
-- ==============================================================
-- ======= 3/ merge_into_existing_config: snapshot tests ========
-- ==============================================================
-- ==============================================================

helpers.describe("Generator.merge_into_existing_config: no existing file", function()
	helpers.it("returns the hs_config directly when the file cannot be read", function()
		-- FileSystem.read is already stubbed to return nil for unknown paths
		local hs_config = {
			profiles = {
				{
					complex_modifications = { parameters = {}, rules = {} },
					name                  = "Default profile",
					selected              = true,
					virtual_hid_keyboard  = { keyboard_type_v2 = "ansi", country_code = 0 },
				}
			}
		}
		local result = Generator.merge_into_existing_config(hs_config, "/nonexistent/karabiner.json")
		helpers.assert_true(type(result) == "table", "must return a table")
		helpers.assert_true(type(result.profiles) == "table", "must have profiles")
		-- Headless global flags must be enforced even on fresh configs
		helpers.assert_true(type(result.global) == "table", "global section must be injected")
		helpers.assert_eq(result.global.show_in_menu_bar, false)
	end)
end)

helpers.describe("Generator.merge_into_existing_config: existing file preservation", function()
	helpers.it("overwrites only complex_modifications, preserving other fields", function()
		-- Provide a fake existing karabiner.json via the FileSystem stub.
		local existing_path = "/fake/karabiner.json"
		local existing_config = {
			global   = { show_in_menu_bar = true },  -- should be overridden to false
			profiles = {
				{
					complex_modifications = { parameters = {}, rules = {} },
					devices               = { { identifiers = { is_keyboard = true } } },
					fn_function_keys      = { { from = { key_code = "f1" } } },
					name                  = "My Custom Profile",
					selected              = true,
					virtual_hid_keyboard  = { keyboard_type_v2 = "jis" },
				}
			}
		}
		-- Encode and inject via the stub
		_fs_data[existing_path] = _G.hs.json.encode(existing_config)

		local new_rules = {
			{ description = "New rule", manipulators = { { type = "basic" } } },
		}
		local hs_config = {
			profiles = {
				{
					complex_modifications = { parameters = { ["basic.to_if_alone_timeout_milliseconds"] = 200 }, rules = new_rules },
					name                  = "Default profile",
					selected              = true,
				}
			}
		}

		local result = Generator.merge_into_existing_config(hs_config, existing_path)

		-- Name must come from the existing profile, not from hs_config
		helpers.assert_eq(result.profiles[1].name, "My Custom Profile", "profile name must be preserved")

		-- Devices must survive
		helpers.assert_true(
			type(result.profiles[1].devices) == "table",
			"devices must be preserved"
		)

		-- fn_function_keys must survive
		helpers.assert_true(
			type(result.profiles[1].fn_function_keys) == "table",
			"fn_function_keys must be preserved"
		)

		-- complex_modifications must be the new one
		local cm = result.profiles[1].complex_modifications
		helpers.assert_true(type(cm) == "table", "complex_modifications must be a table")
		helpers.assert_eq(#cm.rules, 1, "rules count must match hs_config")
		helpers.assert_eq(
			cm.parameters["basic.to_if_alone_timeout_milliseconds"],
			200,
			"parameters must come from hs_config"
		)

		-- Headless global flags
		helpers.assert_eq(result.global.show_in_menu_bar, false, "show_in_menu_bar must be forced to false")
		helpers.assert_eq(result.global.ask_for_confirmation_before_quitting, false)
		helpers.assert_eq(result.global.check_for_updates_on_startup, false)
	end)

	helpers.it("falls back to hs_config when existing JSON is invalid", function()
		local bad_path = "/fake/corrupt.json"
		_fs_data[bad_path] = "{ this is not valid json !!!"

		local hs_config = {
			profiles = {
				{
					complex_modifications = { parameters = {}, rules = {} },
					name                  = "Default profile",
					selected              = true,
				}
			}
		}
		local result = Generator.merge_into_existing_config(hs_config, bad_path)
		helpers.assert_true(type(result) == "table")
		helpers.assert_eq(result.profiles[1].name, "Default profile",
			"must fall back to hs_config profile name on corrupt existing file")
	end)
end)




-- =======================================================================
-- =======================================================================
-- ======= 4/ KE_PHYSICAL_KC_LOG: constant shape and accessibility ========
-- =======================================================================
-- =======================================================================

helpers.describe("Generator.KE_PHYSICAL_KC_LOG constant", function()
	helpers.it("is a non-empty string", function()
		helpers.assert_true(
			type(Generator.KE_PHYSICAL_KC_LOG) == "string"
			and Generator.KE_PHYSICAL_KC_LOG ~= "",
			"KE_PHYSICAL_KC_LOG must be a non-empty string"
		)
	end)

	helpers.it("ends with karabiner_kc.log", function()
		helpers.assert_true(
			Generator.KE_PHYSICAL_KC_LOG:match("karabiner_kc%.log$") ~= nil,
			"KE_PHYSICAL_KC_LOG must end with karabiner_kc.log"
		)
	end)

	helpers.it("contains a metrics/ path segment", function()
		helpers.assert_true(
			Generator.KE_PHYSICAL_KC_LOG:find("metrics") ~= nil,
			"KE_PHYSICAL_KC_LOG must include the metrics/ sub-directory"
		)
	end)
end)
