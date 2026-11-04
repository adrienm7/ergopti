--- tests/unit/platform/remap/generator/test_generator_lease_interruption.lua

--- ==============================================================================
--- MODULE: Lease Interruption Leaves No Key Down
--- DESCRIPTION:
--- Replays the generated tap-hold graph through the pinned Karabiner model and
--- fences the lease (revoked = 1) at every moment of a press: before the hold
--- threshold, after the hold went down, and before the key was pressed at all.
--- Whatever the moment, once every physical key is up no output key and no
--- modifier stays down and no layer stays on: a held output key is what macOS
--- auto-repeats or turns into the press-and-hold accent popup (issue #100, which
--- lost the lease eight times in an hour) (lease-interruption-key-up).
--- ==============================================================================

local helpers = require("tests.helpers")
local Model = require("tests.support.karabiner_model")
local Lease = require("platform.remap.lease_contract")
local TOKEN = "0123456789abcdef0123456789abcdef"
local KEYS = { "escape", "tab", "return_or_enter", "spacebar", "delete_or_backspace", "caps_lock" }
local HOLDS = { "shift", "ctrl", "layer" }

helpers.with_fresh_modules({ "platform.remap.generator", "adapters.file_system", "infra.logger" }, function()
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	local Generator = helpers.load_with_stubs("platform.remap.generator")
	local actions = {
		{ id = "none", label = "None", karabiner_to = {} },
		{ id = "shift", label = "Shift", karabiner_to = { { key_code = "left_shift" } } },
		{ id = "ctrl", label = "Control", karabiner_to = { { key_code = "left_control" } } },
		{ id = "layer", label = "Navigation", karabiner_to = {
			{ set_variable = { name = "layer_active", value = 1 } },
		}, karabiner_to_after_key_up = { { set_variable = { name = "layer_active", value = 0 } } } },
	}

	--- Builds the live lease graph for one tap-hold key.
	--- @param key string Karabiner key code.
	--- @param hold string Hold action id.
	--- @return table engine
	local function engine(key, hold)
		local config, err = Generator.build_karabiner_json({
			tap_hold_config = { [key] = { tap = "none", hold = hold } },
			mod_combos_config = {}, tap_hold_timeout_ms = 200,
			simultaneous_threshold_ms = 100, combo_symmetric = false,
		}, actions, { { id = key, label = key, from = { key_code = key, modifiers = { optional = { "any" } } } } },
			{}, {}, helpers.driver_root() .. "platform/remap/data/", TOKEN)
		helpers.assert_nil(err)
		return Model.new(config.profiles[1].complex_modifications.rules, {
			variables = { [Generator.mode_variable_name(TOKEN)] = 1 },
		})
	end

	--- Fences the generation the way the lease worker and its revoker do.
	--- @param model table Karabiner model.
	local function fence(model)
		model.variables[Lease.variables(TOKEN).revoked] = 1
	end

	--- Asserts that nothing stays down once every physical key is up.
	--- @param model table Karabiner model.
	--- @param label string Case label.
	local function assert_released(model, label)
		helpers.assert_eq(model:held(), {}, label .. ": no output key may stay down (macOS would repeat it)")
		helpers.assert_eq(model:pressed(), {}, label .. ": no modifier may stay down")
		helpers.assert_eq(model:variable(Lease.runtime_variable_name("layer_active", TOKEN)), 0,
			label .. ": no layer may stay on")
	end

	helpers.describe("a lease fence never leaves a key down (lease-interruption-key-up)", function()
		for _, key in ipairs(KEYS) do
			for _, hold in ipairs(HOLDS) do
				local label = key .. " held as " .. hold
				helpers.it(label .. ": fenced after the hold went down", function()
					local model = engine(key, hold)
					model:down(key)
					model:advance(250)
					fence(model)
					model:down("a")
					model:up("a", true)
					model:up(key, false)
					assert_released(model, label)
				end)
				helpers.it(label .. ": fenced before the hold threshold", function()
					local model = engine(key, hold)
					model:down(key)
					model:advance(50)
					fence(model)
					model:advance(300)
					model:up(key, false)
					assert_released(model, label)
				end)
				helpers.it(label .. ": pressed while fenced, released after", function()
					local model = engine(key, hold)
					fence(model)
					model:down(key)
					model:down("a")
					model:up("a", true)
					model:up(key, true)
					assert_released(model, label)
				end)
			end
		end
		helpers.it("a letter held across a fence is released like any key", function()
			local model = engine("spacebar", "shift")
			model:down("a")
			fence(model)
			model:up("a", true)
			assert_released(model, "letter")
		end)
	end)
end)
