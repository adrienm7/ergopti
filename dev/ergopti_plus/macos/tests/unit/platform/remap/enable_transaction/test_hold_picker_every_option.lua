--- tests/unit/platform/remap/enable_transaction/test_hold_picker_every_option.lua

--- ==============================================================================
--- MODULE: Every Option Of The Hold Picker Is The Hold The Key Gets
--- DESCRIPTION:
--- The maintainer's rule of 2026-10-01: whatever the hold picker offers (a
--- modifier, a combination of them, the layer, none) is the hold the key has
--- after the pick, on a key that held another one before. Each holdable action
--- of the catalogue is set through the production setter over a key and over a
--- combination that held Shift: the live value and the saved one are the pick.
--- The holdable actions are read from the shipped catalogue, which the picker
--- filters on the same field.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.remap_transaction_fixture")

local KEY, COMBO = "left_shift", "left_shift+right_shift"

--- The ids the hold picker offers: the catalogue's holdable actions.
local function holdable_ids()
	local fh = assert(io.open(helpers.driver_root() .. "/platform/remap/data/actions.json", "rb"))
	local actions = require("json").decode(fh:read("*a"))
	fh:close()
	local ids = {}
	for _, action in ipairs(actions) do
		if action.holdable == true then ids[#ids + 1] = action.id end
	end
	return ids
end

helpers.describe("remap setters: every option of the hold picker", function()
	helpers.it("(hold-picker-every-option-2026-10-01) the hold a key gets is the option picked, after Shift", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			local offered, kinds = 0, {}
			for _, id in ipairs(holdable_ids()) do
				local action = { id = id }
				do
					offered = offered + 1
					kinds[action.id] = true
					helpers.assert_true(remap.set_hold_action(KEY, "shift"), "the key holds Shift before the pick")
					helpers.assert_true(remap.set_combo_hold_action(COMBO, "shift"))
					helpers.assert_true(remap.set_hold_action(KEY, action.id), action.id .. " must be saved on a key")
					helpers.assert_eq(remap.get_hold_action(KEY), action.id, action.id .. " is the key's hold")
					helpers.assert_eq(calls.saved_payloads[#calls.saved_payloads].tap_hold_config[KEY].hold, action.id,
						action.id .. " is what the key's file holds")
					helpers.assert_true(remap.set_combo_hold_action(COMBO, action.id),
						action.id .. " must be saved on a combination")
					helpers.assert_eq(remap.get_combo_hold_action(COMBO), action.id, action.id .. " is the combination's hold")
					helpers.assert_eq(calls.saved_payloads[#calls.saved_payloads].mod_combos_config[COMBO].hold, action.id,
						action.id .. " is what the combination's file holds")
				end
			end
			helpers.assert_true(offered >= 5, "the picker offers the modifiers and the layer, got " .. offered)
			for _, id in ipairs({ "shift", "layer" }) do
				helpers.assert_true(kinds[id] == true, "the picker offers '" .. id .. "'")
			end
			helpers.assert_true(remap.set_hold_action(KEY, "none"))
			helpers.assert_eq(remap.get_hold_action(KEY), "none", "the native option holds nothing")
		end)
	end)
end)

return true
