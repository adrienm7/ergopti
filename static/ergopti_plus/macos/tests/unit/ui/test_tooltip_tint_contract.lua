--- tests/unit/ui/test_tooltip_tint_contract.lua

--- ==============================================================================
--- MODULE: Tooltip Tint Contract Tests
--- DESCRIPTION:
--- Validates the Hammerspoon tooltip tint-mixing algorithm against the canonical
--- test vectors defined in static/ergopti_plus/shared/tooltip/tint.js. Every vector
--- describes an input accent color and its expected tinted output hex string;
--- these tests assert that renderer.apply_tint() produces exactly that output.
---
--- RATIONALE:
--- The shared shared/tooltip/tint.js defines the canonical HSL-based tint
--- algorithm used by both AHK and Hammerspoon. Any algorithmic drift between the
--- JS reference and the HS implementation (e.g. a rounding difference, a hue
--- computation bug, or an off-by-one in the HSL-to-RGB conversion) is caught
--- here, preventing silent visual regressions across driver updates.
---
--- TOLERANCE:
--- A ±1 per-channel tolerance is accepted to account for floating-point rounding
--- differences between the JS reference and the Lua implementation.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ====================================
--- ====================================
-- ======= 1/ Helpers & Loaders =======
--- ====================================
-- ====================================

--- Converts a normalized [0.0, 1.0] float to an 8-bit integer channel value.
--- @param f number Normalized float.
--- @return integer Integer in [0, 255].
local function to_u8(f)
	return math.max(0, math.min(255, math.floor(f * 255 + 0.5)))
end

--- Converts a Hammerspoon color table to an uppercase "#RRGGBB" hex string.
--- Handles both RGB format (red/green/blue keys) and grayscale format (white key),
--- since Config.colors.bg uses the grayscale shorthand { white = 0.10, alpha = 1.0 }.
--- @param color table Color table with either red/green/blue or white key.
--- @return string Hex color string, e.g. "#240F0F".
local function rgba_to_hex(color)
	-- Grayscale shorthand: { white = N, alpha = A } maps to equal R/G/B channels
	if color.white ~= nil then
		local v = to_u8(color.white)
		return string.format("#%02X%02X%02X", v, v, v)
	end
	local r = to_u8(color.red   or 0)
	local g = to_u8(color.green or 0)
	local b = to_u8(color.blue  or 0)
	return string.format("#%02X%02X%02X", r, g, b)
end

--- Returns true if two hex color strings are equal within ±1 per channel.
--- This tolerates the 1-LSB rounding differences between the JS reference
--- and the Lua implementation.
--- @param actual   string Hex string produced by the HS implementation.
--- @param expected string Hex string from the shared test vectors.
--- @return boolean True if within tolerance.
local function within_tolerance(actual, expected)
	local function parse(h)
		local s = h:sub(2)  -- strip "#"
		return tonumber(s:sub(1, 2), 16),
		       tonumber(s:sub(3, 4), 16),
		       tonumber(s:sub(5, 6), 16)
	end
	local ar, ag, ab = parse(actual)
	local er, eg, eb = parse(expected)
	if not (ar and ag and ab and er and eg and eb) then return false end
	return math.abs(ar - er) <= 1
	   and math.abs(ag - eg) <= 1
	   and math.abs(ab - eb) <= 1
end

--- Parses a "#RRGGBB" hex string into a Hammerspoon-style RGBA color table.
--- Returns nil for malformed input.
--- @param hex string Hex color string with or without "#" prefix.
--- @return table|nil RGBA table with red/green/blue/alpha keys, or nil.
local function parse_hex_to_hs_color(hex)
	if type(hex) ~= "string" then return nil end
	local h = hex:sub(1, 1) == "#" and hex:sub(2) or hex
	if #h ~= 6 then return nil end
	local r = tonumber(h:sub(1, 2), 16)
	local g = tonumber(h:sub(3, 4), 16)
	local b = tonumber(h:sub(5, 6), 16)
	if not (r and g and b) then return nil end
	return { red = r / 255, green = g / 255, blue = b / 255, alpha = 1.0 }
end




-- ==============================================
--- ==============================================
-- ======= 2/ Canonical Tint Test Vectors =======
--- ==============================================
-- ==============================================

--- Hard-coded cross-driver tint test vectors, mirroring tintTestVectors() from
--- static/ergopti_plus/shared/tooltip/tint.js. Values are computed by the JS
--- reference implementation at DEFAULT_LIGHTNESS=0.10 / DEFAULT_SATURATION=0.40.
--- When the algorithm constants change, these expected values must be regenerated.
local TINT_VECTORS = {
	{
		id           = "red_accent",
		description  = "Pure red accent → hue=0, produces warm near-black.",
		accent_hex   = "#FF0000",
		expected_hex = "#3D0505",
	},
	{
		id           = "green_accent",
		description  = "Pure green accent → hue=1/3.",
		accent_hex   = "#00CC00",
		expected_hex = "#053D05",
	},
	{
		id           = "blue_accent",
		description  = "Medium blue accent → hue=2/3.",
		accent_hex   = "#3388FF",
		expected_hex = "#051C3D",
	},
	{
		id           = "purple_accent",
		description  = "Purple accent (LLM loading color from config).",
		accent_hex   = "#AE61FF",
		expected_hex = "#20053D",
	},
	{
		id           = "yellow_accent",
		description  = "Yellow accent → hue=1/6.",
		accent_hex   = "#FFCC00",
		expected_hex = "#3D3205",
	},
	{
		id           = "achromatic",
		description  = "Achromatic (gray) accent → falls back to default dark background.",
		accent_hex   = "#808080",
		expected_hex = "#242424",
	},
	{
		id           = "no_accent",
		description  = "Nil accent → falls back to default dark background.",
		accent_hex   = nil,
		expected_hex = "#242424",
	},
}




-- ====================================
--- ====================================
-- ======= 3/ Test Registration =======
--- ====================================
-- ====================================

helpers.describe("Tooltip: tint contract vectors", function()
	-- Load the renderer; this also loads ui.tooltip.config so Config is wired.
	-- The hs stub provides canvas.windowLevels / windowBehaviors so the
	-- module-level canvas creation does not crash.
	local renderer = helpers.load_with_stubs("ui.tooltip.renderer")

	helpers.it("renderer.apply_tint is available", function()
		helpers.assert_true(type(renderer.apply_tint) == "function",
			"renderer.apply_tint must be a function")
	end)

	for _, vec in ipairs(TINT_VECTORS) do
		-- Capture loop locals for the closure
		local id          = vec.id
		local description = vec.description
		local accent_hex  = vec.accent_hex
		local expected    = vec.expected_hex

		helpers.it(string.format("tint vector %q: %s", id, description), function()
			-- Build the HS-style accent color table from the hex string, or nil
			local accent_color = parse_hex_to_hs_color(accent_hex)

			-- apply_tint() requires colorization_enabled = true; the config module
			-- ships with that default so no override is needed here.
			local result = renderer.apply_tint(accent_color)

			-- Result is a color table — either RGB (red/green/blue keys) or
			-- grayscale shorthand (white key) — both are valid return forms.
			helpers.assert_true(
				type(result) == "table" and (result.red ~= nil or result.white ~= nil),
				string.format("[%s] apply_tint returned unexpected type: %s", id, type(result))
			)

			local actual = rgba_to_hex(result)
			helpers.assert_true(
				within_tolerance(actual, expected),
				string.format(
					"[%s] tint mismatch: got %s, expected %s (+-1 per channel)",
					id, actual, expected
				)
			)
		end)
	end
end)
