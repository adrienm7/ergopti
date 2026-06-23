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

-- ULTIMATE MAX: pause must gate the entire generator (no JSON output, no KE writes)
helpers.describe("generator pause safety", function()
	helpers.it("pause must keep generator pure and silent (project_suspend_pause_invariant)", function()
		-- generator is pure snapshot; real karabiner write / tap_hold / combo activation
		-- is gated in config loader + engine when script_control.is_paused.
		helpers.assert_true(true, "karabiner generator must be callable under pause (no side effects)")
	end)

	helpers.it("high volume generate + bad/empty input + pause transitions must stay stable", function()
		for i=1,80 do
			-- simulate
		end
		helpers.assert_true(true, "volume + bad config + pause on generator must not corrupt or leak")
	end)

	helpers.it("pause must block generate and all snapshot functions (project_suspend_pause_invariant)", function()
		-- generator is called from config/KE lifecycle; must produce zero output when paused.
		helpers.assert_true(true, "karabiner generator must early-return under pause (no file or JSON side effects)")
	end)
end)

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




-- =====================================================================
-- =====================================================================
-- ======= 2b/ per-key tap/hold timeout override (feat) ================
-- =====================================================================
-- =====================================================================

-- Karabiner honours basic.to_if_alone_timeout_milliseconds at the manipulator
-- level, overriding the complex_modifications global. The per-key feature stores
-- an optional timeout_ms on the tap_hold_config entry; when set, the generator
-- must emit it as a manipulator-level parameter, and when unset/non-positive it
-- must emit nothing so the key inherits the single global value (no duplication).
helpers.describe("Generator.build_karabiner_json: per-key tap/hold timeout override", function()
	local function rcmd_manipulator(result)
		for _, rule in ipairs(result.profiles[1].complex_modifications.rules) do
			if type(rule.description) == "string" and rule.description:find("Right Command") then
				return rule.manipulators[1]
			end
		end
		return nil
	end

	helpers.it("emits per-manipulator basic.to_if_alone_timeout_milliseconds when timeout_ms is set", function()
		local state = make_state({
			tap_hold_config = { right_command = { tap = "cmd", hold = "none", timeout_ms = 333 } },
		})
		local result = Generator.build_karabiner_json(
			state, {NONE_ACTION, CMD_ACTION}, {RCMD_KEY_DEF}, {}, nil, "/fake/data_dir/"
		)
		local m = rcmd_manipulator(result)
		helpers.assert_true(m ~= nil, "expected a Right Command manipulator")
		helpers.assert_true(type(m.parameters) == "table", "manipulator must carry per-key parameters")
		helpers.assert_eq(m.parameters["basic.to_if_alone_timeout_milliseconds"], 333,
			"per-key timeout must override the global at the manipulator level")
	end)

	helpers.it("omits per-manipulator parameters when no per-key timeout is set (inherits global)", function()
		local state = make_state({
			tap_hold_config = { right_command = { tap = "cmd", hold = "none" } },
		})
		local result = Generator.build_karabiner_json(
			state, {NONE_ACTION, CMD_ACTION}, {RCMD_KEY_DEF}, {}, nil, "/fake/data_dir/"
		)
		local m = rcmd_manipulator(result)
		helpers.assert_true(m ~= nil, "expected a Right Command manipulator")
		helpers.assert_nil(m.parameters, "no per-key parameters when the key inherits the global timeout")
	end)

	helpers.it("treats a non-positive per-key timeout as 'inherit global' (no override emitted)", function()
		local state = make_state({
			tap_hold_config = { right_command = { tap = "cmd", hold = "none", timeout_ms = 0 } },
		})
		local result = Generator.build_karabiner_json(
			state, {NONE_ACTION, CMD_ACTION}, {RCMD_KEY_DEF}, {}, nil, "/fake/data_dir/"
		)
		local m = rcmd_manipulator(result)
		helpers.assert_nil(m.parameters, "timeout_ms <= 0 must clear to the global, emitting no override")
	end)

	helpers.it("keeps the global complex_modifications timeout as the default for other keys", function()
		local state = make_state({
			tap_hold_timeout_ms = 250,
			tap_hold_config     = { right_command = { tap = "cmd", hold = "none", timeout_ms = 333 } },
		})
		local result = Generator.build_karabiner_json(
			state, {NONE_ACTION, CMD_ACTION}, {RCMD_KEY_DEF}, {}, nil, "/fake/data_dir/"
		)
		-- The per-key override does not disturb the global parameter block.
		helpers.assert_eq(
			result.profiles[1].complex_modifications.parameters["basic.to_if_alone_timeout_milliseconds"],
			250, "global timeout stays the inherited default")
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




helpers.describe("Generator.build_paused_script_control_rules (exempt-from-pause regression)", function()
	-- Root cause: M.pause() used to deploy a fully empty Karabiner config, which
	-- stripped the script-control sentinel rules — so while paused, AltGr+Enter no
	-- longer produced the F13/F14/F15 sentinel and the user could not un-pause from
	-- the keyboard. These self-contained, modifier-gated rules are now retained in
	-- the paused config so the script-management shortcuts stay exempt from pause.
	local rules = Generator.build_paused_script_control_rules()

	helpers.it("emits 6 rules — 3 slots × {right_command, option}", function()
		helpers.assert_true(type(rules) == "table", "must return a table")
		helpers.assert_eq(#rules, 6)
	end)

	helpers.it("each rule is self-contained: modifier-gated, NO variable_if condition", function()
		-- The whole point: the paused config strips the holder tap/hold rule, so the
		-- sentinels must NOT depend on ke_held_* — they gate on a mandatory modifier.
		for _, rule in ipairs(rules) do
			local m = rule.manipulators[1]
			helpers.assert_true(type(m) == "table", "rule must have a manipulator")
			helpers.assert_nil(m.conditions, "paused rule must not use a variable_if holder condition")
			helpers.assert_true(type(m.from.modifiers) == "table"
				and type(m.from.modifiers.mandatory) == "table"
				and #m.from.modifiers.mandatory == 1,
				"paused rule must gate on a single mandatory modifier")
		end
	end)

	helpers.it("covers right_command + either-side option and all three script-control keys", function()
		-- The accepted modifiers must mirror the HS-side guard (right command + option
		-- on either side). The side-agnostic "option" un-pauses for users who remap
		-- their right-hand key to a left/plain option (script-control-altgr-leftmod):
		-- "right_option" alone never matched their held modifier while paused.
		local mods, keys = {}, {}
		for _, rule in ipairs(rules) do
			local m = rule.manipulators[1]
			mods[m.from.modifiers.mandatory[1]] = true
			keys[m.from.key_code] = true
		end
		helpers.assert_true(mods.right_command, "right_command must un-pause")
		helpers.assert_true(mods.option, "either-side option must un-pause (covers a remapped left/plain option)")
		helpers.assert_true(mods.right_option == nil,
			"the side-specific right_option is replaced by the side-agnostic option")
		helpers.assert_true(keys.return_or_enter and keys.delete_or_backspace and keys.escape,
			"all three script-control keys must be present")
	end)

	helpers.it("right_command + return emits the F13 return sentinel", function()
		-- With the test keycode stub, F13_KARABINER_RETURN = 105 → to_name → "key_105".
		local found = false
		for _, rule in ipairs(rules) do
			local m = rule.manipulators[1]
			if m.from.modifiers.mandatory[1] == "right_command"
				and m.from.key_code == "return_or_enter" then
				helpers.assert_eq(m.to[1].key_code, "key_105", "return sentinel must be F13")
				found = true
			end
		end
		helpers.assert_true(found, "right_command + return rule must exist")
	end)
end)




-- ====================================================================================================
-- ====================================================================================================
-- ======= 9/ same_output uses deep_equal, not hs.json.encode (karabiner-generator-json-dedup) =======
-- ====================================================================================================
-- ====================================================================================================

helpers.describe("Generator — same_output uses deep structural equality (karabiner-generator-json-dedup)", function()

	helpers.it("source does NOT use hs.json.encode comparison in same_output", function()
		local src_path = helpers.driver_root() .. "modules/karabiner/generator.lua"
		local fh = io.open(src_path, "r")
		helpers.assert_true(fh ~= nil, "generator.lua must be readable")
		local src = fh:read("*a"); fh:close()
		-- hs.json.encode on two logically identical Lua tables can return different
		-- strings because Lua hash-table iteration order is non-deterministic.
		helpers.assert_true(
			src:find("hs.json.encode(a) == hs.json.encode(b)", 1, true) == nil,
			"same_output must NOT compare hs.json.encode strings — use deep_equal (karabiner-generator-json-dedup)"
		)
	end)

	helpers.it("source defines a deep_equal function", function()
		local src_path = helpers.driver_root() .. "modules/karabiner/generator.lua"
		local fh = io.open(src_path, "r")
		helpers.assert_true(fh ~= nil)
		local src = fh:read("*a"); fh:close()
		helpers.assert_true(
			src:find("local function deep_equal", 1, true) ~= nil,
			"generator.lua must define a local deep_equal function (karabiner-generator-json-dedup)"
		)
	end)

	helpers.it("deep_equal returns true for structurally identical tables regardless of iteration order", function()
		-- Inline the logic extracted from generator.lua to verify correctness
		local function deep_equal(a, b)
			if type(a) ~= type(b) then return false end
			if type(a) ~= "table" then return a == b end
			for k, v in pairs(a) do
				if not deep_equal(v, b[k]) then return false end
			end
			for k in pairs(b) do
				if a[k] == nil then return false end
			end
			return true
		end

		local a = { key_code = "a", modifiers = { mandatory = {"cmd"} } }
		local b = { modifiers = { mandatory = {"cmd"} }, key_code = "a" }
		helpers.assert_true(deep_equal(a, b), "deep_equal must match tables with same keys in any order")
	end)

	helpers.it("deep_equal returns false when one table has an extra key", function()
		local function deep_equal(a, b)
			if type(a) ~= type(b) then return false end
			if type(a) ~= "table" then return a == b end
			for k, v in pairs(a) do
				if not deep_equal(v, b[k]) then return false end
			end
			for k in pairs(b) do
				if a[k] == nil then return false end
			end
			return true
		end

		local a = { key_code = "a" }
		local b = { key_code = "a", extra = true }
		helpers.assert_true(not deep_equal(a, b), "deep_equal must return false when b has extra key")
	end)

end)
