--- tests/unit/platform/remap/generator/test_generator_paused_script.lua

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
local Generator = Fixture.Generator
local NONE_ACTION = Fixture.NONE_ACTION
local TEST_LEASE_TOKEN = Fixture.TEST_LEASE_TOKEN
local _fs_data = Fixture._fs_data
local make_state = Fixture.make_state





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

helpers.describe("virtual keyboard follows the active layout (iso-typing-convention)", function()
	helpers.it("the extra ISO physical key reaches code 50 rather than the layout's code 10", function()
		local state = make_state()
		state.virtual_keyboard_type = "iso"
		local result = Generator.build_karabiner_json(state, { NONE_ACTION }, {}, {}, nil, "/fake/data_dir/")
		helpers.assert_not_nil(result)
		local source = assert(io.open(helpers.shared("../../layouts/registry/ergopti/ergopti.keylayout"), "rb"))
		local xml = source:read("*a"); source:close()
		local base = assert(xml:match('<keyMap index="0">(.-)</keyMap>'))
		helpers.assert_true(base:find('<key code="10" output="$"/>', 1, true) ~= nil,
			"the shipped ISO source declares the top-left dollar key")
		helpers.assert_true(base:find('<key code="50" action="ê"/>', 1, true) ~= nil,
			"the shipped ISO source declares the extra-key action")
		helpers.assert_true(xml:match('<action id="ê">%s*<when state="none" output="ê"/>') ~= nil,
			"the extra-key action really types ê at the base level")
		-- Independently declared HID-to-Carbon semantics and ISO layout outputs.
		-- This is a portable receiving model, not a native Quartz/USB observation.
		local carbon = {
			ansi = { non_us_backslash = 10, grave_accent_and_tilde = 50 },
			iso = { non_us_backslash = 50, grave_accent_and_tilde = 10 },
		}
		local layout = { [10] = "$", [50] = "ê" }
		local virtual = result.profiles[1].virtual_hid_keyboard.keyboard_type_v2
		helpers.assert_eq(layout[carbon[virtual].non_us_backslash], "ê", "ISO key left of Z")
		helpers.assert_eq(layout[carbon[virtual].grave_accent_and_tilde], "$", "ISO key left of 1")
		state.virtual_keyboard_type = "ansi"
		result = Generator.build_karabiner_json(state, { NONE_ACTION }, {}, {}, nil, "/fake/data_dir/")
		local ansi_layout = { [10] = "<", [50] = "`" }
		virtual = result.profiles[1].virtual_hid_keyboard.keyboard_type_v2
		helpers.assert_eq(ansi_layout[carbon[virtual].non_us_backslash], "<", "non-Ergopti ANSI source")
		helpers.assert_eq(ansi_layout[carbon[virtual].grave_accent_and_tilde], "`")
	end)

	helpers.it("rejects a malformed captured form instead of silently selecting ANSI", function()
		for _, form in ipairs({ false, "jis", "", 10 }) do
			local state = make_state()
			state.virtual_keyboard_type = form
			local result, reason = Generator.build_karabiner_json(state, { NONE_ACTION }, {}, {}, nil, "/fake/data_dir/")
			helpers.assert_nil(result)
			helpers.assert_true(type(reason) == "string" and reason ~= "")
		end
	end)

	helpers.it("updates only the selected profile's virtual type and retains source bytes and personal fields", function()
		local state = make_state()
		state.virtual_keyboard_type = "iso"
		local generated = Generator.build_karabiner_json(state, { NONE_ACTION }, {}, {}, nil, "/fake/data_dir/")
		local path = "/fake/iso-form.json"
		local original = {
			global = { show_in_menu_bar = false }, profiles = {
				{ selected = true, name = "Personal", devices = { { ignore = true } },
					virtual_hid_keyboard = { keyboard_type_v2 = "ansi", country_code = 33, personal = "kept" },
					complex_modifications = { parameters = { personal = 19 }, rules = { { description = "Personal", manipulators = {} } } },
				},
				{ selected = false, name = "Other", virtual_hid_keyboard = { keyboard_type_v2 = "jis", country_code = 81 } },
			},
		}
		_fs_data[path] = _G.hs.json.encode(original)
		local bytes = _fs_data[path]
		local merged, reason, source, changed = Generator.merge_into_existing_config(generated, path)
		helpers.assert_nil(reason)
		helpers.assert_true(changed)
		helpers.assert_eq(merged.profiles[1].virtual_hid_keyboard,
			{ keyboard_type_v2 = "iso", country_code = 33, personal = "kept" })
		helpers.assert_eq(merged.profiles[2], original.profiles[2])
		helpers.assert_eq(merged.global, original.global)
		helpers.assert_eq(merged.profiles[1].devices, original.profiles[1].devices)
		helpers.assert_eq(merged.profiles[1].complex_modifications.parameters, { personal = 19 })
		helpers.assert_eq(merged.profiles[1].complex_modifications.rules[1].description, "Personal")
		helpers.assert_eq(_fs_data[path], bytes, "planning does not publish")
		helpers.assert_eq(source.content, bytes, "CAS still owns the exact pre-read source")
		_fs_data[path] = _G.hs.json.encode(merged)
		local again, _, _, changed_again = Generator.merge_into_existing_config(generated, path)
		helpers.assert_eq(changed_again, false, "identical form and rules require no publication")
		helpers.assert_eq(again, merged)
	end)
end)
