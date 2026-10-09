--- tests/unit/modules/keylogger/test_physical_clock.lua

--- Checks native clock conversion independently from delivery and scheduler time.
local helpers = require("tests.helpers")
local Clock = require("modules.keylogger.physical_clock")

local function information(numer, denom)
	return { version = 1, domain = "mach_absolute_time", numer = numer, denom = denom }
end

local function rejects(callback)
	local ok = pcall(callback)
	helpers.assert_eq(ok, false)
end

helpers.describe("physical clock (hs274)", function()
	helpers.it("scales original ticks without floating point rounding or intermediate overflow", function()
		local convert = Clock.new(information(125, 3))
		helpers.assert_eq(convert("45824088534"), 1909337022250)
		helpers.assert_eq(convert("1"), 41)
		helpers.assert_eq(convert("0"), 0)
		helpers.assert_eq(Clock.new(information(3, 2))("6000000000000000001"), 9000000000000000001)
		helpers.assert_eq(Clock.new(information(1, 3))("18446744073709551615"), 6148914691236517205)
		helpers.assert_eq(Clock.new(information(4294967295, 4294967295))("9223372036854775807"), math.maxinteger)
		helpers.assert_eq(math.type(convert("1")), "integer")
	end)

	helpers.it("owns the timebase independently of mutations to its receipt", function()
		local receipt = information(125, 3)
		local convert = Clock.new(receipt)
		receipt.numer, receipt.denom = 1, 1
		helpers.assert_eq(convert("3"), 125)
	end)

	helpers.it("rejects absent or incompatible native timebase information", function()
		for _, receipt in ipairs({ {}, information(0, 1), information(1, 0), information(1.5, 1),
			information(1, 4294967296), information(false, 1), information(1, false),
			information("125", 3), information(1, nil), information(nil, 1),
			{ version = 1, domain = "wall_clock", numer = 1, denom = 1 } }) do
			rejects(function() Clock.new(receipt) end)
		end
	end)

	helpers.it("rejects malformed ticks and unrepresentable converted timestamps", function()
		local convert = Clock.new(information(1, 1))
		for _, ticks in ipairs({ "", "01", "-1", "1.0", "1e3", "18446744073709551616",
			"9223372036854775808", 1, false }) do
			rejects(function() convert(ticks) end)
		end
		rejects(function() Clock.new(information(4294967295, 1))("18446744073709551615") end)
	end)
end)
