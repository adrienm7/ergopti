--- tests/unit/platform/remap/layout/test_virtual_keyboard_choice_source.lua

--- ==============================================================================
--- MODULE: Virtual Keyboard Choice Reaches Each Regeneration
--- DESCRIPTION:
--- The remap owner reads the user's virtual keyboard choice (Automatic, ISO or
--- ANSI) from the source the boot registered, every time a generation resolves
--- its actions, and the generator receives the resolved product. The layout's
--- keycode convention never replaces an explicit choice.
---
--- COVERAGE:
--- 1. Without a registered source, the shipped default (Automatic, so ANSI) applies.
--- 2. Each registered choice reaches both the action resolution and the generator.
--- 3. The choice is read again by the next generation (the menu persists, then
---    asks for a regeneration).
--- 4. A second source is refused, a non-function source is an error, and an
---    unreadable choice raises instead of guessing a product.
--- 5. The arrival convention follows the product.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.platform.remap.layout.wake_reresolves_layout_actions_fixture"] = nil
local Fixture = require("tests.support.platform.remap.layout.wake_reresolves_layout_actions_fixture")
local SYSTEM_DID_WAKE = Fixture.SYSTEM_DID_WAKE
local load_remap = Fixture.load_remap

-- The product each choice must deploy, declared independently of the production
-- resolver: Automatic is ANSI, an explicit choice is itself.
local CHOICE_PRODUCT = { auto = "ansi", iso = "iso", ansi = "ansi" }
local CHOICES = { "auto", "iso", "ansi" }

--- Runs one settled wake regeneration and returns what it resolved and built.
--- @param calls table Fixture observations.
local function regenerate(calls)
	calls.resolve_products = {}
	calls.built_products = {}
	local called, err = calls.wake(SYSTEM_DID_WAKE)
	helpers.assert_true(called, tostring(err))
	helpers.assert_true(calls.fire_latest_timer())
end

helpers.describe("the virtual keyboard choice reaches each regeneration", function()
	helpers.it("applies Automatic's product while no choice source is registered", function()
		local _, calls = load_remap()
		calls.activate_initial()
		regenerate(calls)
		helpers.assert_eq(calls.resolve_products[#calls.resolve_products], "ansi")
		helpers.assert_eq(calls.built_products[#calls.built_products], "ansi")
	end)

	helpers.it("hands each choice's product to the resolution and the generator", function()
		for _, choice in ipairs(CHOICES) do
			local remap, calls = load_remap()
			calls.activate_initial()
			helpers.assert_true(remap.set_virtual_keyboard_source(function() return choice end))
			regenerate(calls)
			helpers.assert_eq(calls.resolve_products[#calls.resolve_products], CHOICE_PRODUCT[choice],
				"the " .. choice .. " choice resolves its actions")
			helpers.assert_eq(calls.built_products[#calls.built_products], CHOICE_PRODUCT[choice],
				"the " .. choice .. " choice reaches the generator")
		end
	end)

	helpers.it("reads the choice again on the next generation", function()
		local remap, calls = load_remap()
		calls.activate_initial()
		local current = "iso"
		helpers.assert_true(remap.set_virtual_keyboard_source(function() return current end))
		regenerate(calls)
		helpers.assert_eq(calls.built_products[#calls.built_products], "iso")
		current = "auto"
		regenerate(calls)
		helpers.assert_eq(calls.built_products[#calls.built_products], "ansi")
	end)

	helpers.it("derives the arrival convention from the product", function()
		-- The fixture's layout has the ANSI convention; the ISO product swaps the pair.
		for choice, arrival in pairs({ auto = "ansi", ansi = "ansi", iso = "iso" }) do
			local remap, calls = load_remap()
			calls.activate_initial()
			helpers.assert_true(remap.set_virtual_keyboard_source(function() return choice end))
			regenerate(calls)
			helpers.assert_eq(remap.virtual_keyboard_form(), arrival, "the " .. choice .. " choice")
		end
	end)

	helpers.it("refuses a second source and a source that is not a function", function()
		local remap = load_remap()
		helpers.assert_true(remap.set_virtual_keyboard_source(function() return "auto" end))
		helpers.assert_eq(remap.set_virtual_keyboard_source(function() return "iso" end), false,
			"the first registration is kept")
		helpers.assert_true(not pcall(remap.set_virtual_keyboard_source, "iso"), "a value is not a source")
	end)

	helpers.it("raises on an unreadable choice instead of guessing a product", function()
		local remap, calls = load_remap()
		calls.activate_initial()
		helpers.assert_true(remap.set_virtual_keyboard_source(function() return "jis" end))
		calls.resolve_products = {}
		calls.built_products = {}
		calls.wake(SYSTEM_DID_WAKE)
		calls.fire_latest_timer()
		helpers.assert_eq(#calls.built_products, 0, "no generation is built for an unknown choice")
	end)
end)
