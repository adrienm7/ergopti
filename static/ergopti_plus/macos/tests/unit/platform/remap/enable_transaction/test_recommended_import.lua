--- tests/unit/platform/remap/enable_transaction/test_recommended_import.lua

--- ==============================================================================
--- MODULE: The Wizard's Tap-Holds Import In The Remap Owner
--- DESCRIPTION:
--- The first-run wizard's checked tap-hold keys reach the remap owner, the only
--- writer of config_karabiner.toml. A running bridge takes them in its exact
--- settings transaction and reports success only on the Karabiner terminal;
--- a folder it does not run gets the same candidate saved through Config. Each
--- checked key becomes exactly its shipped recommendation, the Tap-Holds switch
--- turns on, and every other key keeps its binding.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.remap_transaction_fixture")

-- The shipped [hs_tap_hold] slots the owner reads, as defaults.lua exposes them.
local PRESET = {
	left_shift = { "copy", "shift" },
	caps_lock = { "return", "cmd" },
	escape = { "none", "none" },
}
local KEYS = { { id = "left_shift" }, { id = "caps_lock" }, { id = "escape" } }

--- Loads an enabled remap that knows three keys and the preset above, with an
--- observable regeneration.
--- @param fixture table remap_transaction_fixture constructors.
--- @return table remap, table calls, table deploy
local function importing_remap(fixture)
	local remap, calls = fixture.load_enabled_remap()
	package.loaded["platform.remap.defaults"].tap_hold = PRESET
	package.loaded["platform.remap.config"].load_tap_hold_keys = function() return KEYS end
	for index = #remap.TAP_HOLD_KEYS + 1, #KEYS do remap.TAP_HOLD_KEYS[index] = KEYS[index] end
	local deploy = { regenerations = 0 }
	remap.regenerate = function(on_done)
		deploy.regenerations = deploy.regenerations + 1
		deploy.terminal = on_done
		return true
	end
	return remap, calls, deploy
end

helpers.describe("the remap owner imports the wizard's checked keys", function()
	helpers.it("takes them in the running bridge's transaction, success on the terminal", function()
		with_fixture(function(fixture)
			local remap, calls, deploy = importing_remap(fixture)
			helpers.assert_true(remap.set_tap_holds_enabled(false))
			helpers.assert_true(remap.set_tap_action("left_shift", "paste"))
			helpers.assert_true(remap.set_tap_action("caps_lock", "escape"))
			calls.saved_payloads = {}
			local settled = {}
			helpers.assert_true(remap.import_recommended_keys({ "caps_lock" }, function(ok, reason)
				settled[#settled + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_eq(#settled, 0, "no success before the Karabiner terminal")
			helpers.assert_eq(deploy.regenerations, 1)
			local saved = calls.saved_payloads[1]
			helpers.assert_eq(saved.tap_holds_enabled, true, "an imported key is live")
			helpers.assert_eq(saved.tap_hold_config.caps_lock, { tap = "return", hold = "cmd" },
				"the checked key is exactly its recommendation")
			helpers.assert_eq(saved.tap_hold_config.left_shift.tap, "paste", "an unchecked key keeps its binding")
			deploy.terminal(true, "ready")
			helpers.assert_eq(settled, { { ok = true, reason = "ready" } })
			helpers.assert_eq(remap.get_tap_action("caps_lock"), "return")
			helpers.assert_eq(remap.get_tap_holds_enabled(), true)
		end)
	end)

	helpers.it("refuses a key it cannot import exactly before any write", function()
		with_fixture(function(fixture)
			local remap, calls, deploy = importing_remap(fixture)
			local saves = calls.save
			for label, keys in pairs({
				["no recommendation"] = { "escape" },
				["unknown key"] = { "hyper" },
				["twice"] = { "caps_lock", "caps_lock" },
				["none"] = {},
			}) do
				local settled = {}
				helpers.assert_eq(remap.import_recommended_keys(keys, function(ok, reason)
					settled[#settled + 1] = { ok = ok, reason = reason }
				end), false, label)
				helpers.assert_eq(settled, { { ok = false, reason = "invalid-keys" } }, label)
			end
			helpers.assert_eq(calls.save, saves, "nothing is persisted")
			helpers.assert_eq(deploy.regenerations, 0, "nothing is deployed")
		end)
	end)

	helpers.it("saves the same candidate to a folder the bridge does not run", function()
		with_fixture(function(fixture)
			local remap, calls, deploy = importing_remap(fixture)
			local Config = package.loaded["platform.remap.config"]
			local paths = {}
			Config.load_user_config = function(_, _, path)
				paths[#paths + 1] = path
				return { enabled = true, tap_holds_enabled = false, mod_combos_enabled = nil,
					tap_hold_config = { left_shift = { tap = "paste", hold = "none" } }, mod_combos_config = {},
					tap_hold_timeout_ms = 200, sticky_timeout_ms = 1000, simultaneous_threshold_ms = 50,
					combo_symmetric = false }, "ok"
			end
			calls.saved_payloads = {}
			local saved_ok, detail = remap.save_recommended_keys({ "caps_lock" }, "/wizard/config_karabiner.toml")
			helpers.assert_true(saved_ok, tostring(detail))
			helpers.assert_eq(paths, { "/wizard/config_karabiner.toml" }, "the folder's own file is read")
			local saved = calls.saved_payloads[1]
			helpers.assert_eq(saved.tap_holds_enabled, true)
			helpers.assert_eq(saved.tap_hold_config.caps_lock, { tap = "return", hold = "cmd" })
			helpers.assert_eq(saved.tap_hold_config.left_shift.tap, "paste", "an unchecked key keeps its binding")
			helpers.assert_nil(saved.enabled, "the save carries no « Ergopti uses Karabiner » decision")
			helpers.assert_eq(deploy.regenerations, 0, "nothing is live there to deploy")
			helpers.assert_eq(remap.get_tap_action("caps_lock"), "none", "the running bridge is left alone")

			Config.load_user_config = function() return nil, "error" end
			local refused = remap.save_recommended_keys({ "caps_lock" }, "/wizard/config_karabiner.toml")
			helpers.assert_eq(refused, false, "an unsafe file is refused, never replaced")
			helpers.assert_eq(#calls.saved_payloads, 1)
			helpers.assert_eq(remap.save_recommended_keys({ "escape" }, "/wizard/config_karabiner.toml"), false,
				"a key without a recommendation is refused")
		end)
	end)
end)

return true
