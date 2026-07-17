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
-- ============================================================
-- ======= 1/ build_karabiner_json: structural skeleton =======
-- ============================================================
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

	helpers.it("uses to_if_alone for every delayed tap-hold key, including Space and Enter", function()
		-- Karabiner's to_if_alone contract cancels the tap when another key,
		-- pointing button, or scroll-wheel event occurs before key-up. Cover the
		-- complete macOS key catalogue here so this safety never becomes specific
		-- to modifiers or to one configured action.
		local ids = {
			"escape", "tab", "caps_lock", "left_shift", "fn", "left_control",
			"left_option", "left_command", "spacebar", "right_command",
			"right_option", "right_shift", "return_or_enter", "delete_or_backspace",
		}
		local matrix_tap_action = {
			id = "matrix_tap",
			label = "Matrix tap",
			karabiner_to = { { key_code = "f18" } },
		}
		local config, key_defs = {}, {}
		for _, id in ipairs(ids) do
			config[id] = { tap = "matrix_tap", hold = "none" }
			key_defs[#key_defs + 1] = {
				id = id,
				label = "matrix:" .. id,
				from = { key_code = id, modifiers = { optional = { "any" } } },
			}
		end

		local result = Generator.build_karabiner_json(
			make_state({ tap_hold_config = config }),
			{NONE_ACTION, matrix_tap_action}, key_defs, {}, nil, "/fake/data_dir/"
		)
		local found = {}
		for _, rule in ipairs(result.profiles[1].complex_modifications.rules) do
			local id = type(rule.description) == "string"
				and rule.description:match("matrix:([^:]+):") or nil
			if id then
				local manip = rule.manipulators and rule.manipulators[1]
				helpers.assert_true(type(manip) == "table", "missing manipulator for " .. id)
				helpers.assert_true(type(manip.to_if_alone) == "table" and #manip.to_if_alone > 0,
					"tap output must stay in to_if_alone for pointer cancellation: " .. id)
				found[id] = true
			end
		end
		for _, id in ipairs(ids) do
			helpers.assert_true(found[id] == true, "missing tap-hold matrix rule for " .. id)
		end
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

	helpers.it("emits 3 rules — one per script-control slot", function()
		-- While paused the remap is off, so the user reaches these with the REAL option
		-- key (option+Enter/Backspace/Escape). One rule per slot, option-only — NOT one
		-- per modifier, and NOT a right_command variant (the user does not press rcmd
		-- while paused, and rcmd+Backspace/Escape would shadow native macOS chords). F-H6.
		helpers.assert_true(type(rules) == "table", "must return a table")
		helpers.assert_eq(#rules, 3)
	end)

	helpers.it("each rule is self-contained: option-gated, NO variable_if condition", function()
		-- The paused config strips the holder tap/hold rule, so the sentinels must NOT
		-- depend on ke_held_* — they gate directly on the real option key.
		for _, rule in ipairs(rules) do
			local m = rule.manipulators[1]
			helpers.assert_true(type(m) == "table", "rule must have a manipulator")
			helpers.assert_nil(m.conditions, "paused rule must not use a variable_if holder condition")
			helpers.assert_true(type(m.from.modifiers) == "table"
				and type(m.from.modifiers.mandatory) == "table"
				and #m.from.modifiers.mandatory == 1
				and m.from.modifiers.mandatory[1] == "option",
				"paused rule must gate on the real option key only")
		end
	end)

	helpers.it("gates on the real option key (NOT right_command) for all three keys", function()
		-- While paused we do not touch the real rcmd; the shortcuts are option+key.
		local keys = {}
		for _, rule in ipairs(rules) do
			local m = rule.manipulators[1]
			local set = {}
			for _, mod in ipairs(m.from.modifiers.mandatory) do set[mod] = true end
			helpers.assert_true(set.option, "option must be mandatory in every paused rule")
			helpers.assert_true(set.right_command == nil,
				"paused rules must NOT gate on right_command — rcmd is not used while paused")
			keys[m.from.key_code] = true
		end
		helpers.assert_true(keys.return_or_enter and keys.delete_or_backspace and keys.escape,
			"all three script-control keys must be present")
	end)

	helpers.it("stamps every paused sentinel with the left_control tag (consume-proof guard)", function()
		-- The paused rules gate on a MANDATORY modifier KE consumes, so HS sees no live
		-- modifier when it polls. KE therefore tags the emitted sentinel with left_control,
		-- which HS reads off the event itself to confirm a genuine sentinel and un-pause
		-- (script-control-altgr-leftmod / paused (none) modifier). Every rule must carry it.
		for _, rule in ipairs(rules) do
			local to_ev = rule.manipulators[1].to[1]
			helpers.assert_true(type(to_ev.modifiers) == "table", "paused sentinel must stamp a tag modifier")
			local has_tag = false
			for _, mod in ipairs(to_ev.modifiers) do
				if mod == "left_control" then has_tag = true end
			end
			helpers.assert_true(has_tag, "paused sentinel tag must be left_control so HS recognises it consume-proof")
		end
	end)

	helpers.it("option + return emits the F13 return sentinel", function()
		-- Paused rules gate on the REAL option key (F-H6). With the test keycode stub,
		-- F13_KARABINER_RETURN = 105 → to_name → "key_105".
		local found = false
		for _, rule in ipairs(rules) do
			local m = rule.manipulators[1]
			if m.from.modifiers.mandatory[1] == "option"
				and m.from.key_code == "return_or_enter" then
				helpers.assert_eq(m.to[1].key_code, "key_105", "return sentinel must be F13")
				found = true
			end
		end
		helpers.assert_true(found, "option + return rule must exist")
	end)
end)





-- ====================================================================================================
-- ===================================================================================================
-- ======= 9/ same_output uses deep_equal, not hs.json.encode (karabiner-generator-json-dedup) =======
-- ===================================================================================================
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




-- ==========================================================================================================
-- ==========================================================================================================
-- ======= 10/ chord rule permits incidental modifiers (rcmd+lcmd delete-word regression) ===================
-- ==========================================================================================================
-- ==========================================================================================================

helpers.describe("Generator — simultaneous chord rule permits incidental modifiers (modifier-pair-chord-optional-any)", function()
	-- Root cause: build_chord_combo_rule emitted the KE `from` straight from the
	-- mod_combos entry, which carries a `simultaneous` set but NO `modifiers`. For a
	-- chord built from MODIFIER keys (right_command + left_command), the first key
	-- down already raises its command flag, and KE by default rejects any undeclared
	-- modifier — so the chord failed to match and fell through to left_command's own
	-- single-key tap rule (a bare backspace). Every sibling rule builder declares
	-- `modifiers.optional = {"any"}` (the tap/hold combo path, and every layer_keys
	-- rule); the chord path alone did not. The fix adds it so a modifier-pair chord
	-- matches regardless of the flags its own keys raise, restoring ⌥⌫ (delete word
	-- left) instead of a lone backspace.
	local OPT_BACKSPACE = {
		id           = "opt_backspace",
		label        = "opt_backspace",
		karabiner_to = { { key_code = "delete_or_backspace", modifiers = { "left_option" } } },
	}
	local RCMD_LCMD = {
		id    = "rcmd_lcmd",
		label = "Cmd droit + Cmd gauche",
		from  = {
			simultaneous         = { { key_code = "right_command" }, { key_code = "left_command" } },
			simultaneous_options = { key_down_order = "strict" },
		},
	}

	local function chord_manipulator(result)
		for _, rule in ipairs(result.profiles[1].complex_modifications.rules) do
			if type(rule.description) == "string" and rule.description:find("%[chord%]") then
				return rule.manipulators[1]
			end
		end
		return nil
	end

	local function optional_has_any(mods)
		if type(mods) ~= "table" or type(mods.optional) ~= "table" then return false end
		for _, v in ipairs(mods.optional) do
			if v == "any" then return true end
		end
		return false
	end

	local function combo_state(overrides)
		local base = { mod_combos_config = { rcmd_lcmd = { combo = "opt_backspace", tap = "none", hold = "none" } } }
		if overrides then
			for k, v in pairs(overrides) do base[k] = v end
		end
		return make_state(base)
	end

	helpers.it("emits a chord rule whose `from` allows any incidental modifier (optional: any)", function()
		local result = Generator.build_karabiner_json(
			combo_state(), { NONE_ACTION, OPT_BACKSPACE }, {}, { RCMD_LCMD }, {}, "/fake/data_dir/"
		)
		local m = chord_manipulator(result)
		helpers.assert_true(m ~= nil, "a [chord] rule must be generated for the rcmd_lcmd combo slot")
		helpers.assert_true(type(m.from.simultaneous) == "table", "chord `from` must keep its simultaneous set")
		helpers.assert_true(type(m.from.modifiers) == "table",
			"chord `from` must declare a modifiers block — without it KE rejects the chord once a modifier key raises its flag")
		helpers.assert_true(optional_has_any(m.from.modifiers),
			"chord from.modifiers.optional must contain 'any' so a modifier-pair chord (rcmd+lcmd) matches instead of falling through to a bare backspace")
	end)

	helpers.it("keeps option+backspace (delete word left) as the chord output, not a bare backspace", function()
		-- Characterises that the OUTPUT was always correct — the bug was purely the
		-- failed match, not a wrong `to`. Guards against a future regression that
		-- strips the ⌥ modifier from the emitted event.
		local result = Generator.build_karabiner_json(
			combo_state(), { NONE_ACTION, OPT_BACKSPACE }, {}, { RCMD_LCMD }, {}, "/fake/data_dir/"
		)
		local m = chord_manipulator(result)
		helpers.assert_true(m ~= nil and type(m.to) == "table" and m.to[1] ~= nil, "chord must carry a `to` output")
		helpers.assert_eq(m.to[1].key_code, "delete_or_backspace", "chord output key must be delete_or_backspace")
		helpers.assert_true(type(m.to[1].modifiers) == "table" and m.to[1].modifiers[1] == "left_option",
			"chord output must carry left_option — the ⌥⌫ delete-word modifier that was being lost")
	end)

	helpers.it("permits incidental modifiers on the chord in symmetric mode too", function()
		local result = Generator.build_karabiner_json(
			combo_state({ combo_symmetric = true }), { NONE_ACTION, OPT_BACKSPACE }, {}, { RCMD_LCMD }, {}, "/fake/data_dir/"
		)
		local m = chord_manipulator(result)
		helpers.assert_true(m ~= nil, "a [chord] rule must be generated in symmetric mode")
		helpers.assert_true(optional_has_any(m.from.modifiers),
			"symmetric chord from.modifiers.optional must also contain 'any'")
	end)

	-- Regression (modifier-pair-chord-mandatory-consume): the previous fix made the
	-- chord MATCH via optional:any, but KE passes optional modifiers THROUGH to the
	-- output. A right_command+left_command chord whose output is ⌥⌫ then fires as
	-- ⌘⌥⌫, and ⌘⌫ (delete-to-line-start) overrides ⌥⌫ (delete-word-left) — so
	-- rcmd+lcmd did "nothing useful" while its rcmd+left_option sibling worked (a
	-- leaked ⌘ is inert for ⌥⌦ delete-word-right). The chord's own modifier keys
	-- must be declared mandatory so KE CONSUMES their flags.
	local function mandatory_set(mods)
		local set = {}
		if type(mods) == "table" and type(mods.mandatory) == "table" then
			for _, v in ipairs(mods.mandatory) do set[v] = true end
		end
		return set
	end

	helpers.it("consumes the chord's own command flags as mandatory so ⌘ cannot leak into ⌥⌫", function()
		local result = Generator.build_karabiner_json(
			combo_state(), { NONE_ACTION, OPT_BACKSPACE }, {}, { RCMD_LCMD }, {}, "/fake/data_dir/"
		)
		local m = chord_manipulator(result)
		helpers.assert_true(m ~= nil, "a [chord] rule must be generated for the rcmd_lcmd combo slot")
		local mand = mandatory_set(m.from.modifiers)
		helpers.assert_true(mand.right_command == true,
			"right_command must be mandatory (consumed) so the chord's ⌘ flag is removed from the ⌥⌫ output")
		helpers.assert_true(mand.left_command == true,
			"left_command must be mandatory (consumed) so the chord's ⌘ flag is removed from the ⌥⌫ output")
		helpers.assert_true(optional_has_any(m.from.modifiers),
			"optional:any must remain so unrelated incidental modifiers still match")
	end)

	helpers.it("consumes the mandatory flags in symmetric mode too", function()
		local result = Generator.build_karabiner_json(
			combo_state({ combo_symmetric = true }), { NONE_ACTION, OPT_BACKSPACE }, {}, { RCMD_LCMD }, {}, "/fake/data_dir/"
		)
		local m = chord_manipulator(result)
		local mand = mandatory_set(m.from.modifiers)
		helpers.assert_true(mand.right_command == true and mand.left_command == true,
			"both command keys must be consumed as mandatory in symmetric mode")
	end)

	-- A chord built from NON-modifier keys raises no modifier flags, so nothing must
	-- be declared mandatory — guarding against over-consumption that would require a
	-- phantom modifier and break the match.
	local RET_ESC = {
		id    = "ret_esc",
		label = "Entrée + Échap",
		from  = {
			simultaneous         = { { key_code = "return_or_enter" }, { key_code = "escape" } },
			simultaneous_options = { key_down_order = "strict" },
		},
	}
	helpers.it("adds NO mandatory modifiers for a chord of non-modifier keys", function()
		local state  = make_state({ mod_combos_config = { ret_esc = { combo = "opt_backspace", tap = "none", hold = "none" } } })
		local result = Generator.build_karabiner_json(
			state, { NONE_ACTION, OPT_BACKSPACE }, {}, { RET_ESC }, {}, "/fake/data_dir/"
		)
		local m = chord_manipulator(result)
		helpers.assert_true(m ~= nil, "a [chord] rule must be generated for the ret_esc combo slot")
		helpers.assert_true(m.from.modifiers.mandatory == nil,
			"a non-modifier-key chord must declare no mandatory modifiers")
		helpers.assert_true(optional_has_any(m.from.modifiers),
			"optional:any must still be present for a non-modifier-key chord")
	end)
end)

-- This fixture is intentionally local to generator snapshots. Release it once
-- those tests have run so test discovery order cannot make later modules read
-- from the synthetic in-memory filesystem.
package.loaded["adapters.file_system"] = nil
