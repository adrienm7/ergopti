--- tests/unit/platform/remap/generator/test_generator_layers.lua

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
