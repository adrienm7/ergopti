--- tests/unit/modules/keystats/physical/test_physical_wire_boundaries.lua

--- Checks lossless native sequence validation across the unsigned 64-bit range.
local helpers = require("tests.helpers")
local Wire = require("modules.keystats.physical_wire")

helpers.describe("physical wire boundaries (physical-wire-uint64)", function()
	helpers.it("increments decimal sequence values without rounding", function()
		for _, pair in ipairs({ { "0", "1" }, { "999", "1000" },
			{ "9007199254740992", "9007199254740993" },
			{ "18446744073709551614", "18446744073709551615" } }) do
			helpers.assert_eq(Wire.successor(Wire.decimal(pair[1], false)), pair[2])
			helpers.assert_true(Wire.less(pair[1], pair[2]))
		end
		helpers.assert_throws(function() Wire.successor("18446744073709551615") end)
	end)

	helpers.it("rejects noncanonical and out-of-range wire identifiers", function()
		for _, value in ipairs({ "", "00", "01", "-1", "1.0", "18446744073709551616" }) do
			helpers.assert_throws(function() Wire.decimal(value, false) end)
		end
		helpers.assert_throws(function() Wire.decimal("0", true) end)
		helpers.assert_eq(Wire.decimal("18446744073709551615", true), "18446744073709551615")
	end)
end)
