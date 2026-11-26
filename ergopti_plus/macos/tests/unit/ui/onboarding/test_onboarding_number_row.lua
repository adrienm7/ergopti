--- tests/unit/ui/onboarding/test_onboarding_number_row.lua

--- ==============================================================================
--- MODULE: Onboarding Number-Row Order (macOS)
--- DESCRIPTION:
--- The wizard's number-row order follows the menu row of the same driver, as
--- on Linux (maintainer decision of 2026-11-06): the host tells the page
--- whether a layout of ours types now, and a stored order is rebuilt live into
--- the typing layout before the reload, which would otherwise leave it inert.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.onboarding_delivery_fixture")

local Onboarding = helpers.load_with_stubs("ui.onboarding")

--- Replaces the live number-row owner for one call.
local function with_live(live, callback)
	local previous = Onboarding._number_row_live
	Onboarding._number_row_live = function() return live end
	local ok, err = pcall(callback)
	Onboarding._number_row_live = previous
	if not ok then error(err, 0) end
end

helpers.describe("onboarding number-row order (number-row-order-macos)", function()
	helpers.it("(number-row-order-macos) the capability is the menu row's availability", function()
		with_live({ available = function() return true end }, function()
			helpers.assert_eq(Onboarding._number_row_capability(), true)
		end)
		with_live({ available = function() return false, "no_source_layout" end }, function()
			helpers.assert_eq(Onboarding._number_row_capability(), "platform_reason.number_row_live_no_layout")
		end)
		with_live({ available = function() error("registry exploded") end }, function()
			helpers.assert_eq(Onboarding._number_row_capability(), "platform_reason.number_row_live_no_layout",
				"a failed probe greys the control rather than offering it")
		end)
	end)

	helpers.it("(number-row-order-macos) initData carries the number-row capability", function()
		fixture.with_delivery(function(_, state, pending)
			local loaded = package.loaded["ui.onboarding"]
			local previous = loaded._number_row_live
			loaded._number_row_live = function() return { available = function() return true end } end
			local ok, err = pcall(function()
				state.receiver({ body = { action = "ready" } })
				pending[#pending]()
				helpers.assert_eq(state.payload.capabilities.number_row_live, true)
				helpers.assert_eq(state.payload.capabilities.gesture_registration, false)
			end)
			loaded._number_row_live = previous
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("(number-row-order-macos) finds the order a batch writes", function()
		helpers.assert_eq(Onboarding._number_row_order_written({
			{ section = "hotstrings", key = "enabled", value = true },
			{ section = "layout", key = "direct_access_digits", value = "symbols" },
		}), "symbols")
		helpers.assert_nil(Onboarding._number_row_order_written({ { section = "layout", key = "other", value = "x" } }))
		helpers.assert_nil(Onboarding._number_row_order_written({ { section = "layout", key = "direct_access_digits", delete = true } }))
	end)

	helpers.it("(number-row-order-macos) applies the stored order live, then lets the reload go", function()
		local applied, done = nil, 0
		with_live({ apply = function(rows, on_done)
			applied = rows
			helpers.assert_eq(done, 0, "the reload waits for the rebuild")
			on_done(true)
			return true
		end }, function()
			Onboarding._apply_number_row_then("digits", "/virtual/absent/config.toml", function() done = done + 1 end)
		end)
		helpers.assert_eq(applied, { order = "digits", edges = false })
		helpers.assert_eq(done, 1, "the reload runs once the rebuild settled")
	end)

	helpers.it("(number-row-order-macos) a refused or raising rebuild still lets the reload go once", function()
		for _, live in ipairs({
			{ apply = function(_, on_done) on_done(false, "no_source_layout"); return false end },
			{ apply = function() error("build exploded") end },
		}) do
			local done = 0
			with_live(live, function()
				Onboarding._apply_number_row_then("symbols", "/virtual/absent/config.toml", function() done = done + 1 end)
			end)
			helpers.assert_eq(done, 1)
		end
	end)
end)
