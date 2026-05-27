--- tests/unit/lib/test_color_utils.lua

--- ==============================================================================
--- MODULE: color_utils Unit Tests
--- DESCRIPTION:
--- Validates hex parsing edge cases and the white-mix blending formula.
--- ==============================================================================

local helpers = require("tests.helpers")
local color   = helpers.load_with_stubs("lib.color_utils")

helpers.describe("lib.color_utils.hex_to_rgb", function()
	helpers.it("parses a 6-digit hex string", function()
		local r, g, b = color.hex_to_rgb("#ff8000")
		helpers.assert_eq(r, 1.0)
		helpers.assert_true(math.abs(g - 128/255) < 1e-9)
		helpers.assert_eq(b, 0)
	end)

	helpers.it("accepts hex without leading hash", function()
		local r, g, b = color.hex_to_rgb("000000")
		helpers.assert_eq(r, 0) ; helpers.assert_eq(g, 0) ; helpers.assert_eq(b, 0)
	end)

	helpers.it("returns nil for non-string input", function()
		local r = color.hex_to_rgb(nil) ; helpers.assert_nil(r)
		local r2 = color.hex_to_rgb(123) ; helpers.assert_nil(r2)
	end)

	helpers.it("returns nil for malformed length", function()
		helpers.assert_nil(color.hex_to_rgb("#abc"))
		helpers.assert_nil(color.hex_to_rgb("#1234567"))
	end)

	helpers.it("returns nil for non-hex chars", function()
		helpers.assert_nil(color.hex_to_rgb("#zzzzzz"))
	end)
end)

helpers.describe("lib.color_utils.mix_hex_with_white", function()
	helpers.it("returns white for ratio 0", function()
		local c = color.mix_hex_with_white("#000000", 0)
		helpers.assert_eq(c.red, 1) ; helpers.assert_eq(c.green, 1) ; helpers.assert_eq(c.blue, 1)
	end)

	helpers.it("returns the original color for ratio 1", function()
		local c = color.mix_hex_with_white("#ff0000", 1)
		helpers.assert_eq(c.red, 1) ; helpers.assert_eq(c.green, 0) ; helpers.assert_eq(c.blue, 0)
	end)

	helpers.it("clamps ratio above 1", function()
		local c = color.mix_hex_with_white("#000000", 5)
		helpers.assert_eq(c.red, 0)
	end)

	helpers.it("clamps ratio below 0", function()
		local c = color.mix_hex_with_white("#000000", -5)
		helpers.assert_eq(c.red, 1)
	end)

	helpers.it("falls back to white when hex is invalid", function()
		local c = color.mix_hex_with_white("nope", 0.5, 0.7)
		helpers.assert_eq(c.white, 1) ; helpers.assert_eq(c.alpha, 0.7)
	end)

	helpers.it("uses default alpha = 1 when none provided", function()
		local c = color.mix_hex_with_white("#ff0000", 0.5)
		helpers.assert_eq(c.alpha, 1)
	end)

	helpers.it("respects custom alpha", function()
		local c = color.mix_hex_with_white("#ff0000", 0.5, 0.3)
		helpers.assert_eq(c.alpha, 0.3)
	end)
end)
