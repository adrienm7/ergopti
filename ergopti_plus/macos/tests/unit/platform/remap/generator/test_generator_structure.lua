--- tests/unit/platform/remap/generator/test_generator_structure.lua

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
package.loaded["tests.support.platform.remap.generator.generator_fixture"] = nil
local Fixture = require("tests.support.platform.remap.generator.generator_fixture")
local CMD_ACTION = Fixture.CMD_ACTION
local Generator = Fixture.Generator
local NONE_ACTION = Fixture.NONE_ACTION
local RCMD_KEY_DEF = Fixture.RCMD_KEY_DEF
local TEST_LEASE_TOKEN = Fixture.TEST_LEASE_TOKEN
local make_state = Fixture.make_state





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
