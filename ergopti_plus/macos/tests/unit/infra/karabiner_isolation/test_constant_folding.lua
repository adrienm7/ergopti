--- tests/unit/infra/karabiner_isolation/test_constant_folding.lua

--- ==============================================================================
--- MODULE: Karabiner Isolation folding cases
--- DESCRIPTION:
--- Behavioral scenarios for the shared Karabiner source detector.
--- ==============================================================================

local helpers = require("tests.helpers")
local syntax = require("tests.support.karabiner_isolation.syntax")
local has_folded_stock_target = syntax.has_folded_stock_target

helpers.describe("Karabiner isolation: folding cases", function()
	helpers.it("(fold-operator-prefilter) avoids constant lookups without concatenation", function()
		local lookups = 0
		local constants = setmetatable({}, {
			__index = function()
				lookups = lookups + 1
				return "karabiner_grabber"
			end,
		})
		for _, source in ipairs({ "", "local target = family", "family", "'karabiner_grabber'" }) do
			helpers.assert_eq(has_folded_stock_target(source, constants), false,
				"standalone values are not concatenations")
		end
		helpers.assert_eq(lookups, 0, "operator-free statements must not resolve constants")
		for _, operator in ipairs({ "..", "+" }) do
			helpers.assert_eq(has_folded_stock_target("prefix " .. operator .. " 'grabber'",
				{ prefix = "karabiner_" }), true, "both supported concatenation operators remain covered")
			helpers.assert_eq(has_folded_stock_target("'safe " .. operator .. " literal'", {}), false,
				"an operator inside a literal must not manufacture a concatenation")
		end
	end)end)
