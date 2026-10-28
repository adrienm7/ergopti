--- _shared/lua/test/physical_position_observation_contract.lua

--- ==============================================================================
--- MODULE: Physical Position Observation Contract
--- DESCRIPTION:
--- Pins keystats/physical_position_observation directly. The module reduces one
--- admitted native press and its held roster to a closed {native_code, mods}
--- payload and must refuse everything it cannot represent, because a guessed
--- fact would be recorded as the user's shortcut. The macOS physical channel
--- is the consumer; the module is pure, so the cases run on both Lua drivers.
--- ==============================================================================

local M = {}

--- Registers the contract cases.
--- @param helpers table The driver's test helpers.
function M.register(helpers)
	local Observation = require("keystats.physical_position_observation")

	--- A closed press: the pressed key is part of its own roster.
	local function press(held)
		local own = { device = "kbd", cookie = 7, page = 7, usage = 4, keyboard_type = 40 }
		local roster = { own }
		for _, key in ipairs(held or {}) do roster[#roster + 1] = key end
		return { page = 7, usage = 4, keycode = 0, device = "kbd", cookie = 7, keyboard_type = 40, held = roster }
	end

	--- A held modifier on the same keyboard.
	local function modifier(usage, overrides)
		local key = { device = "kbd", cookie = 9, page = 7, usage = usage, keyboard_type = 40 }
		for field, value in pairs(overrides or {}) do key[field] = value end
		return key
	end

	helpers.describe("physical position observation (physical-position-observation)", function()
		helpers.it("(physical-position-observation) admits only a letter-block primary key with a whole native keycode", function()
			helpers.assert_true(Observation.primary(7, 4, 0))
			helpers.assert_true(Observation.primary(7, 255, 120))
			helpers.assert_eq(Observation.primary(7, 3, 0), false, "usages below the letters are not keys")
			helpers.assert_eq(Observation.primary(7, 256, 0), false)
			helpers.assert_eq(Observation.primary(6, 4, 0), false, "only the keyboard page")
			helpers.assert_eq(Observation.primary(7, 0xE1, 0), false, "a modifier is never primary")
			helpers.assert_eq(Observation.primary(7, 0x39, 0), false, "caps lock is not representable")
			helpers.assert_eq(Observation.primary(7, 4, nil), false, "no guessed keycode")
			helpers.assert_eq(Observation.primary(7, 4, 10), false, "the section key is excluded")
			helpers.assert_eq(Observation.primary(7, 4, 50), false, "the grave key is excluded")
			helpers.assert_eq(Observation.primary(7, 4, -1), false)
			helpers.assert_eq(Observation.primary(7, 4.5, 0), false)
			helpers.assert_eq(Observation.primary(7, 4, 1.5), false)
		end)

		helpers.it("(physical-position-observation) reduces a press and its same-keyboard modifiers to a closed payload", function()
			local facts = Observation.facts(press({ modifier(0xE0), modifier(0xE5) }))
			helpers.assert_eq(facts, { native_code = 0, mods = { ctrl = true, shift = true } })
			helpers.assert_eq(Observation.facts(press()), { native_code = 0, mods = {} })
			local both_sides = Observation.facts(press({ modifier(0xE3), modifier(0xE7) }))
			helpers.assert_eq(both_sides.mods, { super = true }, "left and right collapse to one modifier")
		end)

		helpers.it("(physical-position-observation) refuses a press it cannot prove", function()
			helpers.assert_nil(Observation.facts(nil))
			helpers.assert_nil(Observation.facts(setmetatable(press(), {})), "a press with a metatable is not closed")
			local no_roster = press(); no_roster.held = nil
			helpers.assert_nil(Observation.facts(no_roster))
			local no_device = press(); no_device.device = nil
			helpers.assert_nil(Observation.facts(no_device))
			local modifier_press = press(); modifier_press.usage = 0xE0
			helpers.assert_nil(Observation.facts(modifier_press))
			local missing_own = press(); table.remove(missing_own.held, 1)
			helpers.assert_nil(Observation.facts(missing_own), "the pressed key must be in its own roster")
			local drifted = press(); drifted.held[1].usage = 5
			helpers.assert_nil(Observation.facts(drifted), "the roster row of the press must agree with it")
			local open_row = press({ setmetatable(modifier(0xE0), {}) })
			helpers.assert_nil(Observation.facts(open_row))
		end)

		helpers.it("(physical-position-observation) refuses a chord assembled across devices or with an unrepresentable key", function()
			helpers.assert_nil(Observation.facts(press({ modifier(0xE0, { device = "other" }) })))
			helpers.assert_nil(Observation.facts(press({ modifier(0xE0, { keyboard_type = 41 }) })))
			helpers.assert_nil(Observation.facts(press({ { device = "kbd", cookie = 9, page = 7, usage = 0x39, keyboard_type = 40 } })),
				"caps lock held")
			helpers.assert_nil(Observation.facts(press({ { device = "kbd", cookie = 9, page = 0xFF, usage = 3, keyboard_type = 40 } })),
				"fn held")
			helpers.assert_nil(Observation.facts(press({ { device = "kbd", cookie = 9, page = 0xFF01, usage = 3, keyboard_type = 40 } })),
				"fn held on the vendor page")
		end)
	end)
end

return M
