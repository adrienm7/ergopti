--- tests/unit/ui/test_wpm_darken_hex_malformed_input.lua

--- ==============================================================================
--- MODULE: Regression — the pill's strip survives a malformed colour (F-MED-25)
--- DESCRIPTION:
--- A hotstring group's colour comes from a TOML file the user edits freely, so
--- "#fff", a colour name or garbage used to reach hex arithmetic and raise
--- inside the widget's timer. The darkening now lives once, in the shared model
--- (_shared/lua/wpm_widget/model.lua), which both Lua drivers draw with; the
--- colour it darkens is always one the model validated, and its own guard
--- refuses anything that is not six hex digits.
--- ==============================================================================

local helpers = require("tests.helpers")
local WPMModel = require("wpm_widget.model")

helpers.describe("wpm readouts: darkening a malformed colour (F-MED-25)", function()

	helpers.it("refuses a shorthand, a colour name and nil instead of raising", function()
		for _, bad in ipairs({ "#fff", "red", "#12345g" }) do
			local ok, result = pcall(WPMModel.darken_hex, bad, 0.5)
			helpers.assert_true(ok, "darken_hex must not raise on " .. bad)
			helpers.assert_nil(result, bad .. " must be refused")
		end
		local ok_nil, result_nil = pcall(WPMModel.darken_hex, nil, 0.5)
		helpers.assert_true(ok_nil)
		helpers.assert_nil(result_nil)
	end)

	helpers.it("darkens a well-formed colour, rounding half up as the AHK driver does", function()
		helpers.assert_eq(WPMModel.darken_hex("#8040c0", 0.5), "#402060")
		helpers.assert_eq(WPMModel.darken_hex("#0055cc", 0.40), "#002252")
	end)

	helpers.it("never hands a group's malformed colour to the drawing", function()
		local canon = {
			colors = { bg_ai = "#7a30b0", bg_manual = "#0055cc", fallback_accent = "#007aff" },
			neutral_sources = { none = true, manual = true },
		}
		helpers.assert_eq(WPMModel.source_hex(canon, "magickey", function() return "#fff" end), "#007aff")
	end)

	helpers.it("the widget keeps no darkening of its own", function()
		local src = helpers.read_driver_source("local function resolve_shared_constants_path")
		helpers.assert_true(src ~= nil, "ui/wpm/wpm_widget.lua source must be locatable")
		helpers.assert_nil(src:find("local function _wpm_darken_hex", 1, true),
			"a second darkening is a second place for the strips to drift apart")
		helpers.assert_true(src:find('require("wpm_widget.model")', 1, true) ~= nil,
			"the widget draws the shared model's frames")
	end)

end)
