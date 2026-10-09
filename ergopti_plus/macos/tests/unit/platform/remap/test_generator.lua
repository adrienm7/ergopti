--- tests/unit/platform/remap/test_generator.lua

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

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

-- Stub adapters.file_system so load_json_file never hits the real disk.
-- Tests that need a classified read to return data override _fs_data below.
local _fs_data = {}
package.loaded["adapters.file_system"] = {
	read = function(path) return _fs_data[path] end,
	read_with_status = function(path)
		local content = _fs_data[path]
		if content == nil then return nil, "absent" end
		return content, "ok"
	end,
	write = function(_path, _content) return true end,
}

-- Stub ui.menu.menu_paths (required at module load time to compute the
-- KE_PHYSICAL_KC_LOG constant — it must not hit the filesystem).
package.loaded["infra.config_paths"] = {
	get_config_dir = function() return "/tmp/ergopti_test" end,
}

-- Stub lib.keycodes with the minimal surface used by generator.lua.
package.loaded["infra.keycodes"] = {
	to_name              = function(code) return "key_" .. tostring(code) end,
	F13_KARABINER_RETURN   = 105,
	F14_KARABINER_BACKSPACE = 107,
	F15_KARABINER_ESCAPE   = 113,
	F20_LAYER_NAV_ENTERED  = 90,
	F19_LAYER_NAV_EXITED   = 80,
}

local Generator = helpers.load_with_stubs("platform.remap.generator")
local TEST_LEASE_TOKEN = "0123456789abcdef0123456789abcdef"
local raw_build_karabiner_json = Generator.build_karabiner_json
local raw_build_paused_script_control_rules = Generator.build_paused_script_control_rules

-- Existing snapshot cases focus on their own rule shapes. The dedicated
-- managed-lease suite tests the strict token boundary itself
Generator.build_karabiner_json = function(state, actions, keys, combos, non_canonical, shared_dir)
	return raw_build_karabiner_json(
		state,
		actions,
		keys,
		combos,
		non_canonical,
		shared_dir,
		TEST_LEASE_TOKEN
	)
end
Generator.build_paused_script_control_rules = function()
	return raw_build_paused_script_control_rules(TEST_LEASE_TOKEN)
end


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

	helpers.it("complex_modifications contains managed rules without profile-global parameters", function()
		local result = Generator.build_karabiner_json(
			make_state(), {NONE_ACTION}, {}, {}, nil, "/fake/data_dir/"
		)
		local cm = result.profiles[1].complex_modifications
		helpers.assert_true(type(cm) == "table", "complex_modifications must be a table")
		helpers.assert_true(type(cm.rules) == "table", "rules must be a table")
		helpers.assert_nil(cm.parameters,
			"managed timings must not alter current or future personal rules at profile scope")
	end)

	helpers.it("managed tap rules carry the configured timeout locally", function()
		local state = make_state({
			tap_hold_timeout_ms       = 175,
			simultaneous_threshold_ms = 80,
			tap_hold_config = { right_command = { tap = "none", hold = "cmd" } },
		})
		local result = Generator.build_karabiner_json(
			state, {NONE_ACTION, CMD_ACTION}, {RCMD_KEY_DEF}, {}, nil, "/fake/data_dir/"
		)
		local timed_manipulator = nil
		for _, rule in ipairs(result.profiles[1].complex_modifications.rules) do
			if rule.description:find("Right Command", 1, true) then
				timed_manipulator = rule.manipulators[1]
				break
			end
		end
		helpers.assert_not_nil(timed_manipulator, "managed tap/hold rule must exist")
		helpers.assert_eq(
			timed_manipulator.parameters["basic.to_if_alone_timeout_milliseconds"],
			175,
			"tap/hold timeout must be local to the managed manipulator"
		)
	end)

	helpers.it("produces no rules when all inputs are empty and no data files exist", function()
		local result = Generator.build_karabiner_json(
			make_state(), {NONE_ACTION}, {}, {}, nil, "/fake/data_dir/"
		)
		local rules = result.profiles[1].complex_modifications.rules
		-- The script chords' sentinel rules of an empty configuration (the
		-- four presets), but tap/hold and combo lists are empty.
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

	--- Builds one tap-hold rule per catalogue key with the same two slots.
	--- @param hold_action table|nil Hold action; nil leaves the hold empty.
	--- @return table manipulators Key id → its unblocked manipulator.
	local function tap_hold_matrix(hold_action)
		local ids = {
			"escape", "tab", "caps_lock", "left_shift", "fn", "left_control",
			"left_option", "left_command", "spacebar", "right_command",
			"right_option", "right_shift", "return_or_enter", "delete_or_backspace",
		}
		local actions = {
			NONE_ACTION,
			{ id = "matrix_tap", label = "Matrix tap", karabiner_to = { { key_code = "f18" } } },
		}
		if hold_action then actions[#actions + 1] = hold_action end
		local config, key_defs = {}, {}
		for _, id in ipairs(ids) do
			config[id] = { tap = "matrix_tap", hold = hold_action and hold_action.id or "none" }
			key_defs[#key_defs + 1] = {
				id = id,
				label = "matrix:" .. id,
				from = { key_code = id, modifiers = { optional = { "any" } } },
			}
		end

		local result = Generator.build_karabiner_json(
			make_state({ tap_hold_config = config }),
			actions, key_defs, {}, nil, "/fake/data_dir/"
		)
		local found = {}
		for _, rule in ipairs(result.profiles[1].complex_modifications.rules) do
			local id = type(rule.description) == "string"
				and rule.description:match("matrix:([^:]+):") or nil
			if id then
				local manip
				for _, candidate in ipairs(rule.manipulators or {}) do
					local blocked = false
					for _, condition in ipairs(candidate.conditions or {}) do
						if condition.type == "variable_if" and condition.name:find("ke_held_", 1, true) then
							blocked = true
						end
					end
					if not blocked and not manip then manip = candidate end
				end
				helpers.assert_true(type(manip) == "table", "missing manipulator for " .. id)
				found[id] = manip
			end
		end
		for _, id in ipairs(ids) do
			helpers.assert_true(found[id] ~= nil, "missing tap-hold matrix rule for " .. id)
		end
		return found
	end

	helpers.it("keeps no-hold modifier chords native and suppresses taps interrupted by typing", function()
		local Model = require("tests.support.karabiner_model")
		for _, id in ipairs({ "left_shift", "left_control", "right_shift", "right_command", "fn" }) do
			local manip = tap_hold_matrix(nil)[id]
			local model = Model.new({ { manipulators = { manip } } }, {
				variables = { ["ergopti_mode_" .. TEST_LEASE_TOKEN] = 1 },
			})
			model:down(id)
			helpers.assert_true(model:pressed()[id], "the physical modifier stays held: " .. id)
			model:down("a")
			model:up("a", true)
			model:up(id, true)
			for _, event in ipairs(model:emissions()) do
				helpers.assert_true(event.key_code ~= "f18", "a shortcut must not also fire the tap: " .. id)
			end
			helpers.assert_nil(next(model:pressed()), "release every owned modifier")
			model:clear()
			model:tap(id)
			local taps = 0
			for _, event in ipairs(model:emissions()) do
				if event.key_code == "f18" then taps = taps + 1 end
			end
			helpers.assert_eq(taps, 1, "a quick lone release fires exactly one tap: " .. id)
		end
	end)

	helpers.it("blocks the Fn tap at the Windows Control position when a thumb or CapsLock was held at press (ctrl-tap-blockers)", function()
		local Model = require("tests.support.karabiner_model")
		local keys = {}
		for _, id in ipairs({ "fn", "left_command", "caps_lock" }) do
			keys[#keys + 1] = { id = id, label = id,
				from = { key_code = id, modifiers = { optional = { "any" } } } }
		end
		for _, hold in ipairs({ "none", "cmd" }) do
			local config = Generator.build_karabiner_json(make_state({ tap_hold_config = {
				fn = { tap = "probe", hold = hold },
			} }), { NONE_ACTION, CMD_ACTION,
				{ id = "probe", label = "Probe", karabiner_to = { { key_code = "f18" } } },
			}, keys, {}, nil, "/fake/data_dir/")
			for _, blocker in ipairs({ "left_command", "caps_lock" }) do
				local model = Model.new(config.profiles[1].complex_modifications.rules, {
					variables = { ["ergopti_mode_" .. TEST_LEASE_TOKEN] = 1 },
				})
				model:down(blocker)
				model:down("fn")
				model:up(blocker, true)
				model:up("fn", true)
				for _, event in ipairs(model:emissions()) do
					helpers.assert_true(event.key_code ~= "f18", "the blocker at press cancels the tap: " .. blocker)
				end
				helpers.assert_nil(next(model:pressed()), "the blocked tap must still release its hold")
			end
		end
	end)

	helpers.it("uses to_if_alone for every delayed tap-hold key, including Space and Enter", function()
		-- Karabiner's to_if_alone contract cancels the tap when another key,
		-- pointing button, or scroll-wheel event occurs before key-up. Cover the
		-- complete macOS key catalogue here so this safety never becomes specific
		-- to modifiers or to one configured action.
		for id, manip in pairs(tap_hold_matrix(CMD_ACTION)) do
			helpers.assert_true(type(manip.to_if_alone) == "table" and #manip.to_if_alone == 1
				and manip.to_if_alone[1].key_code == "f18",
				"tap output must stay in to_if_alone for pointer cancellation: " .. id)
		end
	end)

	helpers.it("keeps native modifier holds and immediate ordinary taps without a configured hold (tap-only-key-types-its-tap)", function()
		-- A key with nothing to hold has no tap to wait for: its tap goes out at
		-- key down and repeats, like the native key. Sending the physical key
		-- there and the tap at release typed two keys for one tap, and a tap
		-- left in to_if_alone is lost whenever the next key goes down first.
		for id, manip in pairs(tap_hold_matrix(nil)) do
			local native = id == "left_shift" or id == "left_control"
				or id == "right_shift" or id == "right_command" or id == "fn"
			if native then
				helpers.assert_not_nil(manip.to_if_alone, "native modifier taps wait for release: " .. id)
				helpers.assert_eq(manip.to_if_alone[1].key_code, "f18")
			else
				helpers.assert_nil(manip.to_if_alone, "ordinary tap-only keys type at press: " .. id)
			end
			local sent = {}
			for _, event in ipairs(manip.to or {}) do
				if event.key_code ~= nil then sent[#sent + 1] = event.key_code end
			end
			helpers.assert_eq(table.concat(sent, ","), native and id or "f18",
				"modifier hold versus ordinary immediate tap: " .. id)
		end
	end)

	helpers.it("gives a sticky key one rule that arms the tap and logs one press and release (sticky-tap-under-held-modifier)", function()
		-- A manipulator gated on another key being held used to precede this rule
		-- and send the plain modifier with no tap: under any held modifier key the
		-- one-shot never armed, while the main rule's hold already sent the same
		-- modifier. The key's own rule must be the only one that can take it.
		local sticky_shift = {
			id = "sticky_shift",
			label = "Sticky Shift",
			karabiner_to = { { sticky_modifier = { left_shift = "toggle" } } },
		}
		local shift = {
			id = "shift",
			label = "Shift",
			karabiner_to = { { key_code = "left_shift" } },
		}
		local result = Generator.build_karabiner_json(
			make_state({
				tap_hold_config = {
					right_option = { tap = "sticky_shift", hold = "shift" },
				},
			}),
			{NONE_ACTION, sticky_shift, shift},
			{
				{
					id = "right_option",
					label = "Right Option sticky ledger probe",
					from = { key_code = "right_option" },
				},
			},
			{},
			nil,
			"/fake/data_dir/"
		)
		local sticky_rule = nil
		for _, rule in ipairs(result.profiles[1].complex_modifications.rules) do
			if rule.description:find("Right Option sticky ledger probe", 1, true) then
				sticky_rule = rule
				break
			end
		end
		helpers.assert_not_nil(sticky_rule, "the sticky-equivalent rule must be generated")
		helpers.assert_eq(#sticky_rule.manipulators, 1,
			"a manipulator placed before the key's own rule would take its tap under a held key")

		local manipulator = sticky_rule.manipulators[1]
		for _, condition in ipairs(manipulator.conditions or {}) do
			helpers.assert_true(not tostring(condition.name):find("ke_held_", 1, true),
				"the sticky key's rule must not depend on another key being held: " .. tostring(condition.name))
		end
		local Keycodes = require("infra.keycodes")
		helpers.assert_true(type(manipulator.to_if_alone) == "table"
			and type(manipulator.to_if_alone[1]) == "table"
			and manipulator.to_if_alone[1].key_code == Keycodes.to_name(Keycodes.F20_LAYER_NAV_ENTERED),
			"the tap must arm the one-shot")
		helpers.assert_eq(manipulator.to_if_alone[1].modifiers, { "left_control", "left_option" },
			"the internal signal must carry the one-shot tag")
		helpers.assert_eq(manipulator.to_if_alone[1]["repeat"], false,
			"holding the signal must not repeatedly rearm the one-shot")
		helpers.assert_eq(manipulator.to[#manipulator.to].key_code, "left_shift",
			"the hold must send the plain modifier")

		local press_command = "echo 'right_option' >> '/tmp/ergopti_test/metrics/karabiner_kc.log'"
		local release_command = "echo 'U:right_option' >> '/tmp/ergopti_test/metrics/karabiner_kc.log'"
		local press_count = 0
		for _, event in ipairs(manipulator.to or {}) do
			if event.shell_command == press_command then press_count = press_count + 1 end
		end
		local release_count = 0
		for _, event in ipairs(manipulator.to_after_key_up or {}) do
			if event.shell_command == release_command then release_count = release_count + 1 end
		end
		helpers.assert_eq(press_count, 1, "the rule must log one physical press")
		helpers.assert_eq(release_count, 1, "the rule must log one physical release")
	end)

	helpers.it("emits a native Shift hold in Karabiner's immediate transaction", function()
		local shift_action = {
			id = "shift",
			label = "Shift",
			karabiner_to = { { key_code = "left_shift" } },
		}
		local shift_key = {
			id = "left_shift",
			label = "Left Shift",
			from = { key_code = "left_shift", modifiers = { optional = { "any" } } },
		}
		local result = Generator.build_karabiner_json(
			make_state({ tap_hold_config = { left_shift = { tap = "none", hold = "shift" } } }),
			{NONE_ACTION, shift_action}, {shift_key}, {}, nil, "/fake/data_dir/"
		)
		local manipulator = nil
		for _, rule in ipairs(result.profiles[1].complex_modifications.rules) do
			if type(rule.description) == "string" and rule.description:find("Left Shift", 1, true) then
				manipulator = rule.manipulators[1]
				break
			end
		end
		helpers.assert_not_nil(manipulator, "native Shift tap/hold rule must exist")
		local shift_event_index = nil
		for index, event in ipairs(manipulator.to or {}) do
			if event.key_code == "left_shift" then shift_event_index = index end
		end
		helpers.assert_not_nil(shift_event_index,
			"the Shift edge must be part of Karabiner's immediate `to` transaction, not a deferred Hammerspoon injection")
		helpers.assert_nil(manipulator.to_if_alone,
			"native Shift must not be delayed behind to_if_alone when its hold output is the same physical modifier")
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
-- must emit it as a manipulator-level parameter. The generation lease merge
-- preserves the user's profile-level parameters, so an unset/non-positive
-- override copies the ErgoptiPlus global value onto the managed manipulator
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
			tap_hold_config = { right_command = { tap = "none", hold = "cmd", timeout_ms = 333 } },
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

	helpers.it("copies the managed default when no per-key timeout is set", function()
		local state = make_state({
			tap_hold_config = { right_command = { tap = "none", hold = "cmd" } },
		})
		local result = Generator.build_karabiner_json(
			state, {NONE_ACTION, CMD_ACTION}, {RCMD_KEY_DEF}, {}, nil, "/fake/data_dir/"
		)
		local m = rcmd_manipulator(result)
		helpers.assert_true(m ~= nil, "expected a Right Command manipulator")
		helpers.assert_eq(m.parameters["basic.to_if_alone_timeout_milliseconds"], 200,
			"managed rule must not depend on a preserved personal profile-level timeout")
	end)

	helpers.it("treats a non-positive per-key timeout as the managed default", function()
		local state = make_state({
			tap_hold_config = { right_command = { tap = "none", hold = "cmd", timeout_ms = 0 } },
		})
		local result = Generator.build_karabiner_json(
			state, {NONE_ACTION, CMD_ACTION}, {RCMD_KEY_DEF}, {}, nil, "/fake/data_dir/"
		)
		local m = rcmd_manipulator(result)
		helpers.assert_eq(m.parameters["basic.to_if_alone_timeout_milliseconds"], 200,
			"timeout_ms <= 0 must resolve to the managed default at manipulator scope")
	end)

	helpers.it("does not emit a profile-global timeout beside a per-key override", function()
		local state = make_state({
			tap_hold_timeout_ms = 250,
			tap_hold_config     = { right_command = { tap = "none", hold = "cmd", timeout_ms = 333 } },
		})
		local result = Generator.build_karabiner_json(
			state, {NONE_ACTION, CMD_ACTION}, {RCMD_KEY_DEF}, {}, nil, "/fake/data_dir/"
		)
		helpers.assert_nil(result.profiles[1].complex_modifications.parameters,
			"profile-global timings would also affect personal rules added later")
	end)
end)




-- =============================================================================
-- =============================================================================
-- ======= 2c/ navigation-layer sentinel (sentinel-never-reaches-app) ==========
-- =============================================================================
-- =============================================================================

-- Karabiner announces navigation-layer entry with the F20 sentinel, which
-- Hammerspoon consumes before any application sees it. The generator must keep
-- emitting it first on every layer activation, and only inside the ACTIVE lease
-- graph: the PAUSED graph and a revoked lease (driver not running) emit none.
-- Its pair F19 closes every deactivation (layer-wheel-slots): Hammerspoon runs
-- the layer's wheel bindings only between the two.
helpers.describe("Generator.build_karabiner_json: navigation-layer sentinel", function()
	local F20_NAME = "key_90"
	local F19_NAME = "key_80"
	local LAYER_ACTION = {
		id = "layer",
		label = "Layer",
		karabiner_to = { { set_variable = { name = "layer_active", value = 1 } } },
		karabiner_to_after_key_up = { { set_variable = { name = "layer_active", value = 0 } } },
	}
	local LAYER_OFF_ACTION = {
		id = "layer_off",
		label = "Layer off",
		karabiner_to = { { set_variable = { name = "layer_active", value = 0 } } },
	}
	local BACKSPACE_ACTION = {
		id = "backspace",
		label = "Backspace",
		karabiner_to = { { key_code = "delete_or_backspace" } },
	}
	local LCMD_KEY_DEF = {
		id = "left_command",
		label = "Left Command",
		from = { key_code = "left_command" },
	}
	local RCMD_LAYER_OFF_KEY_DEF = {
		id = "right_command",
		label = "Right Command",
		from = { key_code = "right_command" },
	}

	--- Returns whether any nested event emits the given key code.
	local function emits_key(node, key_code)
		if type(node) ~= "table" then return false end
		if node.key_code == key_code then return true end
		for _, child in pairs(node) do
			if emits_key(child, key_code) then return true end
		end
		return false
	end

	--- Collects every output list that switches the navigation layer on.
	local function layer_activations(node, found)
		if type(node) ~= "table" then return found end
		for _, event in ipairs(node) do
			local variable = type(event) == "table" and event.set_variable or nil
			if type(variable) == "table" and variable.value == 1
				and tostring(variable.name):find("layer_active", 1, true) then
				found[#found + 1] = node
				break
			end
		end
		for _, child in pairs(node) do layer_activations(child, found) end
		return found
	end

	-- Mirrors the reported configuration: left Command taps Backspace and holds
	-- the navigation layer (_shared/tap_hold/defaults.toml).
	local function build()
		local state = make_state({
			tap_hold_config = { left_command = { tap = "backspace", hold = "layer" } },
		})
		return Generator.build_karabiner_json(state,
			{ NONE_ACTION, BACKSPACE_ACTION, LAYER_ACTION }, { LCMD_KEY_DEF }, {}, nil, "/fake/data_dir/")
	end

	--- Collects every output list that switches the navigation layer off, with
	--- the manipulator field holding it.
	local function layer_deactivations(node, field, found)
		if type(node) ~= "table" then return found end
		for _, event in ipairs(node) do
			local variable = type(event) == "table" and event.set_variable or nil
			if type(variable) == "table" and variable.value == 0
				and tostring(variable.name):find("layer_active", 1, true) then
				found[#found + 1] = { events = node, field = field }
				break
			end
		end
		for key, child in pairs(node) do
			layer_deactivations(child, type(key) == "string" and key or field, found)
		end
		return found
	end

	helpers.it("emits F20 as the first key of every navigation-layer activation", function()
		local activations = layer_activations(build().profiles[1].complex_modifications.rules, {})
		helpers.assert_true(#activations > 0, "the hold output must activate the navigation layer")
		for _, events in ipairs(activations) do
			-- Holder-state and physical-key logging entries are prepended by other
			-- builders; they emit no key. The sentinel is the first key event and
			-- precedes the variable that switches the layer on.
			local first_key, activation = nil, nil
			for index, event in ipairs(events) do
				if first_key == nil and event.key_code ~= nil then first_key = index end
				local variable = event.set_variable
				if activation == nil and type(variable) == "table" and variable.value == 1
					and tostring(variable.name):find("layer_active", 1, true) then
					activation = index
				end
			end
			helpers.assert_not_nil(first_key, "a layer activation must emit the sentinel key")
			helpers.assert_eq(events[first_key].key_code, F20_NAME,
				"the sentinel must be the first key the activation emits")
			helpers.assert_true(first_key < activation,
				"Hammerspoon must receive the sentinel before any layer key is remapped")
		end
	end)

	helpers.it("confines F20 and F19 to the ACTIVE lease graph", function()
		local mode_name = "ergopti_mode_" .. TEST_LEASE_TOKEN
		local revoked_name = "ergopti_revoked_" .. TEST_LEASE_TOKEN
		local gated = 0
		for _, rule in ipairs(build().profiles[1].complex_modifications.rules) do
			for _, manipulator in ipairs(rule.manipulators) do
				if emits_key(manipulator, F20_NAME) or emits_key(manipulator, F19_NAME) then
					local values = {}
					for _, condition in ipairs(manipulator.conditions or {}) do
						if condition.type == "variable_if" then values[condition.name] = condition.value end
					end
					helpers.assert_eq(values[mode_name], 1,
						"a sentinel manipulator must require the ACTIVE mode of this lease")
					helpers.assert_eq(values[revoked_name], 0,
						"the lease guardian's revocation must silence the sentinel with the driver")
					gated = gated + 1
				end
			end
		end
		helpers.assert_true(gated > 0, "the configured layer hold must emit the sentinel")
		helpers.assert_true(not emits_key(Generator.build_paused_script_control_rules(), F20_NAME),
			"the PAUSED graph must never emit the navigation-layer sentinel")
		helpers.assert_true(not emits_key(Generator.build_paused_script_control_rules(), F19_NAME),
			"the PAUSED graph must never emit the navigation-layer exit sentinel")
	end)

	helpers.it("taps F19 right before every navigation-layer deactivation (layer-wheel-slots)", function()
		local state = make_state({
			tap_hold_config = {
				left_command = { tap = "backspace", hold = "layer" },
				right_command = { tap = "layer_off", hold = "none" },
			},
		})
		local config = Generator.build_karabiner_json(state,
			{ NONE_ACTION, BACKSPACE_ACTION, LAYER_ACTION, LAYER_OFF_ACTION },
			{ LCMD_KEY_DEF, RCMD_LAYER_OFF_KEY_DEF }, {}, nil, "/fake/data_dir/")
		local found = layer_deactivations(config.profiles[1].complex_modifications.rules, nil, {})
		local fields = {}
		for _, list in ipairs(found) do
			fields[list.field] = true
			local sentinels, deactivation, sentinel = 0, nil, nil
			for index, event in ipairs(list.events) do
				if event.key_code == F19_NAME then sentinels, sentinel = sentinels + 1, index end
				local variable = event.set_variable
				if deactivation == nil and type(variable) == "table" and variable.value == 0
					and tostring(variable.name):find("layer_active", 1, true) then
					deactivation = index
				end
			end
			helpers.assert_eq(sentinels, 1, "one exit per deactivation in " .. tostring(list.field))
			helpers.assert_eq(sentinel, deactivation - 1,
				"the exit sentinel comes right before the variable in " .. tostring(list.field))
			-- Karabiner holds the last entry of a `to` list until the key is
			-- released: a held sentinel would take the place of the first key's
			-- held modifiers after a chord (chord-first-key-modifiers).
			helpers.assert_true(list.events[#list.events].key_code ~= F19_NAME,
				"the exit sentinel is never the held last entry of " .. tostring(list.field))
		end
		helpers.assert_true(fields.to_after_key_up == true,
			"the layer hold's release must announce the exit")
		helpers.assert_true(#found >= 2, "both the hold's release and the explicit layer off are covered")
	end)

	helpers.it("keeps F19 out of the historical graph older releases deployed", function()
		local config, err, legacy_rules = build()
		helpers.assert_nil(err)
		helpers.assert_true(emits_key(config.profiles[1].complex_modifications.rules, F19_NAME),
			"the deployed graph announces the exit")
		helpers.assert_true(type(legacy_rules) == "table" and #legacy_rules > 0)
		helpers.assert_true(not emits_key(legacy_rules, F19_NAME),
			"the legacy compatibility graph must be what older releases generated, without the exit sentinel")
		helpers.assert_true(emits_key(legacy_rules, F20_NAME),
			"the legacy graph keeps the entry sentinel older releases did emit")
	end)
end)

-- The cross-driver rule for a key whose own hold is the navigation layer while
-- another key already holds it (layer-key-under-another-holder-2026-09-27):
-- the layer's mapping when the layer maps the key, otherwise the plain key,
-- whose tap types it and whose hold auto-repeats, as on Windows and Linux,
-- except left Command tapping Backspace, which the layer swallows as Windows
-- swallows LAlt. The key's tap/hold rule matched under the layer: it held the
-- layer a second time, typed its tap only on a quick release, and its release
-- switched the layer off under the key still holding it. The cases replay
-- Karabiner's first-match over the generated rules, with no modifier held.
helpers.describe("Generator.build_karabiner_json: a layer key on a layer another key holds", function()
	local LAYER_ACTION = {
		id = "layer",
		label = "Layer",
		karabiner_to = { { set_variable = { name = "layer_active", value = 1 } } },
		karabiner_to_after_key_up = { { set_variable = { name = "layer_active", value = 0 } } },
	}
	local BACKSPACE_ACTION = { id = "backspace", label = "Backspace",
		karabiner_to = { { key_code = "delete_or_backspace" } } }
	local RETURN_ACTION = { id = "return", label = "Return",
		karabiner_to = { { key_code = "return_or_enter" } } }
	local KEYS = {
		{ id = "left_command", label = "Left Command", from = { key_code = "left_command" } },
		{ id = "caps_lock", label = "Caps Lock", from = { key_code = "caps_lock" } },
		{ id = "spacebar", label = "Space", from = { key_code = "spacebar" } },
	}
	-- The explicit layer maps Space (Spotlight) and not CapsLock.
	local NAV_LAYER = {
		bindings = { Space = { kind = "keystroke", action = "spotlight",
			chords = { { mods = { "meta" }, key = "Space" } } } },
		registry = { keys = { Space = { karabiner = { key_code = "spacebar" } } } },
	}

	--- @param left_command_tap string|nil Left Command's tap; Backspace by default.
	local function build(left_command_tap)
		local ok, result = pcall(Generator.build_karabiner_json, make_state({
			nav_layer = NAV_LAYER,
			tap_hold_config = {
				left_command = { tap = left_command_tap or "backspace", hold = "layer" },
				caps_lock = { tap = "return", hold = "layer" },
				spacebar = { tap = "none", hold = "layer" },
			},
		}), { NONE_ACTION, BACKSPACE_ACTION, RETURN_ACTION, LAYER_ACTION }, KEYS, {}, nil, "/fake/data_dir/")
		assert(ok, result)
		return result.profiles[1].complex_modifications.rules
	end

	--- The generated name of the layer variable (the lease scopes it).
	local function layer_variable(rules)
		local found
		local function walk(node)
			if type(node) ~= "table" or found then return end
			local variable = node.set_variable
			if type(variable) == "table" and tostring(variable.name):find("layer_active", 1, true) then
				found = variable.name
				return
			end
			for _, child in pairs(node) do walk(child) end
		end
		walk(rules)
		return found
	end

	local function conditions_hold(conditions, variables)
		for _, condition in ipairs(conditions or {}) do
			local value = variables[condition.name] or 0
			if condition.type == "variable_if" and value ~= condition.value then return false end
			if condition.type == "variable_unless" and value == condition.value then return false end
		end
		return true
	end

	--- The manipulator Karabiner runs for a lone press of `key_code`, or nil
	--- when none matches and the key reaches macOS as itself.
	local function first_match(rules, key_code, variables)
		for _, rule in ipairs(rules) do
			for _, manipulator in ipairs(rule.manipulators) do
				local modifiers = manipulator.from.modifiers
				local needs_modifier = type(modifiers) == "table" and type(modifiers.mandatory) == "table"
					and #modifiers.mandatory > 0
				if manipulator.from.key_code == key_code and not needs_modifier
					and conditions_hold(manipulator.conditions, variables) then
					return manipulator, rule
				end
			end
		end
		return nil
	end

	local function variables(rules, layer_on)
		return {
			["ergopti_mode_" .. TEST_LEASE_TOKEN] = 1,
			[layer_variable(rules)] = layer_on and 1 or 0,
		}
	end

	helpers.it("types a key held as the layer plainly when the layer does not map it", function()
		local rules = build()
		helpers.assert_not_nil(layer_variable(rules), "the layer holds must set the layer variable")
		helpers.assert_nil(first_match(rules, "caps_lock", variables(rules, true)),
			"on a layer another key holds, CapsLock matches no rule: macOS types it and repeats it")
		local own = first_match(rules, "caps_lock", variables(rules, false))
		helpers.assert_not_nil(own, "alone, CapsLock is its own tap/hold rule")
		helpers.assert_true(layer_variable(own.to) ~= nil, "which holds the layer as configured")
		local plain = build("return")
		helpers.assert_nil(first_match(plain, "left_command", variables(plain, true)),
			"left Command tapping anything but Backspace is the plain Command key there")
	end)

	-- Windows' nav_layer.ahk swallows LAlt tapping Backspace with the layer on
	-- hold, and Linux's engine its LAlt: passed through, it is a modifier under
	-- every chord of the layer (J gives Cmd+Left here).
	helpers.it("swallows left Command tapping Backspace on a layer another key holds", function()
		local rules = build()
		local on_layer = first_match(rules, "left_command", variables(rules, true))
		helpers.assert_not_nil(on_layer, "on the layer, left Command must not reach macOS as Command")
		for _, event in ipairs(on_layer.to or {}) do
			helpers.assert_nil(event.key_code, "it posts no key")
			helpers.assert_nil(event.set_variable, "nor holds the layer or anything else")
		end
		helpers.assert_nil(on_layer.to_if_alone, "its release types no Backspace")
		for _, event in ipairs(on_layer.to_after_key_up or {}) do
			helpers.assert_nil(event.set_variable, "its release leaves the other key's layer on")
		end
		local alone = first_match(rules, "left_command", variables(rules, false))
		helpers.assert_true(layer_variable(alone.to) ~= nil, "alone, left Command holds the layer as configured")
		helpers.assert_eq(alone.to_if_alone[1].key_code, "delete_or_backspace", "and taps Backspace")
	end)

	helpers.it("applies the layer's mapping to a key held as the layer when the layer maps it", function()
		local rules = build()
		local on_layer, rule = first_match(rules, "spacebar", variables(rules, true))
		helpers.assert_not_nil(on_layer, "on the layer, Space matches the layer's mapping")
		helpers.assert_eq(on_layer.to[1].key_code, "spacebar")
		helpers.assert_eq(on_layer.to[1].modifiers, { "command" }, "the layer sends Spotlight, not a plain Space")
		helpers.assert_true(tostring(rule.description):find("Navigation layer", 1, true) ~= nil,
			"the layer's rule, not Space's own tap/hold")
		local alone = first_match(rules, "spacebar", variables(rules, false))
		helpers.assert_nil(layer_variable(alone.to), "Space must not enable navigation before the typing threshold")
		helpers.assert_true(layer_variable(alone.to_if_held_down) ~= nil,
			"Space holds the configured layer after the typing threshold")
		helpers.assert_eq(alone.to_delayed_action.to_if_canceled, { { key_code = "spacebar" } },
			"another press before the threshold must type Space instead of starting navigation")
	end)
end)




-- ==============================================================
-- ==============================================================
-- ======= 3/ merge_into_existing_config: snapshot tests ========
-- ==============================================================
-- ==============================================================

helpers.describe("Generator.merge_into_existing_config: no existing file", function()
	helpers.it("returns the hs_config directly when the file cannot be read", function()
		-- The classified read is already stubbed to return absent for unknown paths.
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
		helpers.assert_nil(result.global,
			"a fresh managed config must not invent stock Karabiner UI preferences")
	end)
end)

helpers.describe("Generator.merge_into_existing_config: existing file preservation", function()
	helpers.it("replaces only managed rules while preserving every personal field", function()
		-- Provide a fake existing karabiner.json via the FileSystem stub.
		local existing_path = "/fake/karabiner.json"
		local existing_config = {
			global   = { show_in_menu_bar = true, ask_for_confirmation_before_quitting = true },
			profiles = {
				{
					complex_modifications = {
						parameters = { personal_parameter = 777 },
						rules = {
							{
								description = "Personal rule",
								manipulators = { { type = "basic" } },
							},
						},
					},
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
			{
				description = "[ErgoptiPlus managed:" .. TEST_LEASE_TOKEN .. ":normal] New rule",
				manipulators = {
					{
						type = "basic",
						conditions = {
							{ type = "variable_if", name = "ergopti_mode_" .. TEST_LEASE_TOKEN, value = 1 },
							{ type = "variable_if", name = "ergopti_revoked_" .. TEST_LEASE_TOKEN, value = 0 },
						},
					},
				},
			},
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

		-- Personal rules stay first and the managed block is appended
		local cm = result.profiles[1].complex_modifications
		helpers.assert_true(type(cm) == "table", "complex_modifications must be a table")
		helpers.assert_eq(#cm.rules, 2, "personal and managed rules must coexist")
		helpers.assert_eq(cm.rules[1].description, "Personal rule")
		helpers.assert_true(cm.rules[2].description:find("New rule", 1, true) ~= nil)
		helpers.assert_eq(cm.parameters.personal_parameter, 777,
			"complex-modification parameters must remain personal")
		helpers.assert_nil(cm.parameters["basic.to_if_alone_timeout_milliseconds"],
			"generated profile parameters must not replace personal parameters")

		-- Stock Karabiner UI preferences belong to the user
		helpers.assert_eq(result.global.show_in_menu_bar, true)
		helpers.assert_eq(result.global.ask_for_confirmation_before_quitting, true)
		helpers.assert_nil(result.global.check_for_updates_on_startup)
	end)

	helpers.it("fails closed when existing JSON is invalid", function()
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
		local result, err = Generator.merge_into_existing_config(hs_config, bad_path)
		helpers.assert_nil(result, "corrupt personal JSON must never be overwritten")
		helpers.assert_true(type(err) == "string" and err:find("JSON", 1, true) ~= nil)
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
		local rules = Generator.build_paused_script_control_rules(TEST_LEASE_TOKEN)

	helpers.it("emits 4 rules — one per shared script chord of an empty configuration", function()
		-- While paused the remap is off, so the user reaches these with the REAL option
		-- key (option+Enter/Backspace/Delete/Escape). One rule per slot, option-only —
		-- NOT one per modifier, and NOT a right_command variant (the user does not press
		-- rcmd while paused, and rcmd+Backspace/Escape would shadow native macOS chords).
		-- F-H6. Every preset is a script-management action, so all four stay live.
		helpers.assert_true(type(rules) == "table", "must return a table")
		helpers.assert_eq(#rules, 4)
	end)

	helpers.it("each rule is option-gated with the exact generation fence variables", function()
		-- Pause disables the normal holder rule, so pause-only sentinels must not
		-- depend on ke_held_* — they gate directly on the real option key
		for _, rule in ipairs(rules) do
			local m = rule.manipulators[1]
			helpers.assert_true(type(m) == "table", "rule must have a manipulator")
			local condition_values = {}
			for _, condition in ipairs(m.conditions or {}) do
				condition_values[condition.name] = condition.value
				helpers.assert_true(condition.name ~= "ke_held_right_command",
					"paused rule must not depend on the stripped holder rule")
			end
			helpers.assert_eq(condition_values["ergopti_mode_" .. TEST_LEASE_TOKEN], 2)
			helpers.assert_eq(condition_values["ergopti_revoked_" .. TEST_LEASE_TOKEN], 0)
			helpers.assert_true(type(m.from.modifiers) == "table"
				and type(m.from.modifiers.mandatory) == "table"
				and #m.from.modifiers.mandatory == 1
				and m.from.modifiers.mandatory[1] == "option",
				"paused rule must gate on the real option key only")
		end
	end)

	helpers.it("gates on the real option key (NOT right_command) for all four keys", function()
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
		helpers.assert_true(keys.return_or_enter and keys.delete_or_backspace and keys.delete_forward
			and keys.escape, "all four script-control keys must be present")
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





-- ===================================================================================================
-- ===================================================================================================
-- ======= 9/ same_output uses deep_equal, not hs.json.encode (karabiner-generator-json-dedup) =======
-- ===================================================================================================
-- ===================================================================================================

helpers.describe("Generator — same_output uses deep structural equality (karabiner-generator-json-dedup)", function()

	helpers.it("source does NOT use hs.json.encode comparison in same_output", function()
		-- Selected by a declaration unique to platform/remap/generator.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function build_chord_combo_rule")
		helpers.assert_true(src ~= nil, "platform/remap/generator.lua source must be locatable")
		-- hs.json.encode on two logically identical Lua tables can return different
		-- strings because Lua hash-table iteration order is non-deterministic.
		helpers.assert_true(
			src:find("hs.json.encode(a) == hs.json.encode(b)", 1, true) == nil,
			"same_output must NOT compare hs.json.encode strings — use deep_equal (karabiner-generator-json-dedup)"
		)
	end)

	helpers.it("source defines a deep_equal function", function()
		-- Selected by a declaration unique to platform/remap/generator.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function build_chord_combo_rule")
		helpers.assert_true(src ~= nil, "platform/remap/generator.lua source must be locatable")
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
	-- Karabiner v16 tests a chord's modifiers on its first key's key_down, before
	-- either chord key reaches the output (manipulator_manager.hpp posts a key only
	-- once every manipulator has passed it). Without a modifiers block the chord
	-- matches only with nothing else held; every sibling rule builder declares
	-- `modifiers.optional = {"any"}` (the tap/hold combo path, and every layer_keys
	-- rule), so the chord accepts an unrelated held modifier too. The chord's own
	-- keys are never among the tested flags: requiring them made it unreachable.
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
		helpers.assert_true(m ~= nil and type(m.to) == "table", "chord must carry a `to` output")
		-- The first key event: the chord also records its first key's held state.
		local output = nil
		for _, event in ipairs(m.to) do
			if output == nil and event.key_code ~= nil then output = event end
		end
		helpers.assert_true(output ~= nil, "chord must send a key")
		helpers.assert_eq(output.key_code, "delete_or_backspace", "chord output key must be delete_or_backspace")
		helpers.assert_true(type(output.modifiers) == "table" and output.modifiers[1] == "left_option",
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

	-- Regression (chord-matches-its-own-modifier-keys): listing the chord's own
	-- modifier keys as mandatory, meant to keep their ⌘ out of the ⌥⌫ output, made
	-- the chord unreachable, since neither key is in the output flags Karabiner
	-- tests at the first key's key_down, and there is no such ⌘ to remove.
	local function mandatory_set(mods)
		local set = {}
		if type(mods) == "table" and type(mods.mandatory) == "table" then
			for _, v in ipairs(mods.mandatory) do set[v] = true end
		end
		return set
	end

	helpers.it("never requires the chord's own command keys as mandatory (chord-matches-its-own-modifier-keys)", function()
		local result = Generator.build_karabiner_json(
			combo_state(), { NONE_ACTION, OPT_BACKSPACE }, {}, { RCMD_LCMD }, {}, "/fake/data_dir/"
		)
		local m = chord_manipulator(result)
		helpers.assert_true(m ~= nil, "a [chord] rule must be generated for the rcmd_lcmd combo slot")
		local mand = mandatory_set(m.from.modifiers)
		helpers.assert_nil(mand.right_command,
			"right_command cannot be held in the output when its own chord is tested")
		helpers.assert_nil(mand.left_command,
			"left_command cannot be held in the output when its own chord is tested")
		helpers.assert_true(optional_has_any(m.from.modifiers),
			"optional:any must remain so unrelated incidental modifiers still match")
	end)

	helpers.it("never requires the chord's own keys in symmetric mode either", function()
		local result = Generator.build_karabiner_json(
			combo_state({ combo_symmetric = true }), { NONE_ACTION, OPT_BACKSPACE }, {}, { RCMD_LCMD }, {}, "/fake/data_dir/"
		)
		local m = chord_manipulator(result)
		local mand = mandatory_set(m.from.modifiers)
		helpers.assert_true(mand.right_command == nil and mand.left_command == nil,
			"neither command key may be mandatory in symmetric mode")
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





-- ===========================================
-- ===========================================
-- ======= 9/ Purity of the generator ========
-- ===========================================
-- ===========================================

-- These three used to sit at the top of the file as assert_true(true, "…"), and
-- above the fixtures, so they could not have generated anything even if they had
-- wanted to. The claim was "the generator is a pure snapshot" — which is worth
-- asserting, because the whole safety argument for the Karabiner pipeline rests
-- on it: the write and the reload are gated in the config loader, and that gate
-- is meaningless if building the JSON already touched the disk.
helpers.describe("generator purity", function()
	helpers.it("build_karabiner_json performs no file I/O of its own", function()
		-- Move-resilient: the symbol selects the file, so a split or a rename of
		-- generator.lua does not turn this invariant into a path error.
		local src = helpers.read_driver_source("function M.build_karabiner_json")
		helpers.assert_not_nil(src, "the generator source must be findable by symbol")
		local body = src:match("function M%.build_karabiner_json.-" .. string.char(10) .. "end" .. string.char(10))
		helpers.assert_true(body ~= nil, "build_karabiner_json must be present in the source")
		for _, forbidden in ipairs({ "io%.open", "os%.execute", "hs%.task", "os%.remove" }) do
			helpers.assert_true(body:find(forbidden) == nil,
				"build_karabiner_json must not call " .. forbidden ..
				" — the write is gated in the config loader, and that gate means nothing if " ..
				"building the JSON already wrote")
		end
	end)

	helpers.it("is deterministic: the same input yields the same rule set", function()
		local a = Generator.build_karabiner_json(make_state(), { NONE_ACTION }, {}, {}, nil, "/fake/data_dir/")
		local b = Generator.build_karabiner_json(make_state(), { NONE_ACTION }, {}, {}, nil, "/fake/data_dir/")
		helpers.assert_eq(#a.profiles, #b.profiles, "profile count must be stable across calls")
		helpers.assert_eq(#a.profiles[1].complex_modifications.rules,
			#b.profiles[1].complex_modifications.rules,
			"rule count must be stable across calls — a generator that drifted would rewrite " ..
			"the user's Karabiner config on every regen for no reason")
	end)

	helpers.it("survives 80 regenerations without accumulating rules", function()
		local first = #Generator.build_karabiner_json(
			make_state(), { NONE_ACTION }, {}, {}, nil, "/fake/data_dir/"
		).profiles[1].complex_modifications.rules
		local last = first
		for _ = 1, 80 do
			last = #Generator.build_karabiner_json(
				make_state(), { NONE_ACTION }, {}, {}, nil, "/fake/data_dir/"
			).profiles[1].complex_modifications.rules
		end
		helpers.assert_eq(last, first,
			"rule count must not grow across regenerations — module-level state leaking between " ..
			"calls is how a config file doubles in size every reload")
	end)

	helpers.it("empty inputs still produce a valid, selected profile", function()
		local result = Generator.build_karabiner_json(make_state(), {}, {}, {}, nil, "/fake/data_dir/")
		helpers.assert_true(type(result.profiles) == "table", "empty input must still yield profiles")
		helpers.assert_true(#result.profiles >= 1, "and at least one of them")
		helpers.assert_true(result.profiles[1].selected == true,
			"the first profile must stay selected — an unselected profile leaves Karabiner with " ..
			"no active configuration at all")
	end)
end)

-- This fixture is intentionally local to generator snapshots. Release it once
-- those tests have run so test discovery order cannot make later modules read
-- from the synthetic in-memory filesystem.
package.loaded["adapters.file_system"] = nil
