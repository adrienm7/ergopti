--- tests/unit/platform/remap/test_capsword_control_signal.lua

--- ==============================================================================
--- MODULE: CapsWord Karabiner Activation Signals
--- DESCRIPTION:
--- Replays the shipped activation through the real generator and Karabiner
--- model, then verifies its control tag is consumed by the sole keymap owner.
--- ==============================================================================

local helpers = require("tests.helpers")
local Model = require("tests.support.karabiner_model")
local TOKEN = "0123456789abcdef0123456789abcdef"

local function quartz_flags(physical)
	return {
		ctrl = physical.left_control == true or physical.right_control == true,
		alt = physical.left_option == true or physical.right_option == true,
		shift = physical.left_shift == true or physical.right_shift == true,
		cmd = physical.left_command == true or physical.right_command == true,
		fn = physical.fn == true,
	}
end

helpers.describe("CapsWord native graph and shared control tags", function()
	helpers.it("emits an activation edge for the actual AltGr plus CapsLock path", function()
		helpers.with_stub_scope({ "platform.remap.generator", "infra.logger", "adapters.file_system" }, function()
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			local Generator = helpers.load_with_stubs("platform.remap.generator")
			local config, err = Generator.build_karabiner_json({
				tap_hold_config = {}, mod_combos_config = {}, tap_hold_timeout_ms = 200,
				simultaneous_threshold_ms = 100, combo_symmetric = false,
			}, { { id = "none", label = "None", karabiner_to = {} } }, {}, {}, {},
				helpers.driver_root() .. "platform/remap/data/", TOKEN)
			helpers.assert_nil(err)
			local engine = Model.new(config.profiles[1].complex_modifications.rules, {
				variables = { [Generator.mode_variable_name(TOKEN)] = 1 },
			})
			engine:down("right_option")
			engine:down("caps_lock")
			helpers.assert_eq(engine:variable("ergopti_capsword_" .. TOKEN), 1)
			local seen = {}
			for _, emitted in ipairs(engine:emissions()) do
				if emitted.key_code == "f20" then seen[#seen + 1] = emitted end
			end
			helpers.assert_eq(#seen, 1, "Karabiner activation must notify Hammerspoon without a CLI read")
			local signal = require("keymap.control_signals").decode(quartz_flags(seen[1].flags))
			helpers.assert_eq(signal, "capsword_activated")
			engine:up("caps_lock")
			engine:up("right_option")
			engine:clear()
			engine:down("spacebar")
			local exits = {}
			for _, emitted in ipairs(engine:emissions()) do
				if emitted.key_code == "f20" then exits[#exits + 1] = emitted end
			end
			helpers.assert_eq(#exits, 1, "native deactivation must invalidate earlier LED ownership")
			helpers.assert_eq(require("keymap.control_signals").decode(quartz_flags(exits[1].flags)), "capsword_deactivated")
		end)
	end)

	helpers.it("keeps CapsWord tags separate from navigation, one-shot Shift and unrelated chords", function()
		helpers.with_stub_scope({ "modules.keymap.control_sentinels", "infra.logger" }, function()
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			local owner = require("modules.keymap.control_sentinels")
			local signals = {}
			owner.set_listener("capsword.test", function(signal) signals[#signals + 1] = signal end)
			helpers.assert_true(owner.claim_key(90, true, { ctrl = true, alt = true, shift = true }))
			helpers.assert_true(owner.claim_key(90, false, { ctrl = true, alt = true, shift = true }))
			helpers.assert_true(owner.claim_key(90, true, { ctrl = true, alt = true, cmd = true }))
			helpers.assert_true(owner.claim_key(90, true, { ctrl = true, alt = true }))
			helpers.assert_true(owner.claim_key(90, true, {}))
			helpers.assert_true(owner.claim_key(90, true, { shift = true }))
			helpers.assert_eq(signals, { "capsword_activated", "capsword_deactivated", "one_shot_shift",
				"nav_layer_entered", "nav_layer_entered" })
		end)
	end)
end)
