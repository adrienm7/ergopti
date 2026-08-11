--- tests/unit/ui/test_tooltip_on_show_callback_visibility.lua

--- ==============================================================================
--- MODULE: Tooltip facade on-show callback failure regression
--- DESCRIPTION:
--- Drives every real facade show route with a successful concrete renderer and a
--- throwing ownership callback. The callback arms the persistent Escape trap in
--- production; swallowing its error publishes visible pixels that cannot honour
--- the interaction contract. Every route must log the traceback, revoke both
--- owners, and return false.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Loads the real facade over controllable concrete-owner stubs.
--- @return table fixture Observable facade fixture.
local function load_fixture()
	helpers.load_with_stubs("ui.tooltip.config")
	local fixture = {
		llm_hides = 0,
		hotstring_hides = 0,
		errors = {},
	}

	package.loaded["ui.tooltip.tooltip_llm"] = {
		hide = function() fixture.llm_hides = fixture.llm_hides + 1; return true end,
		hide_silent = function() fixture.llm_hides = fixture.llm_hides + 1; return true end,
		is_visible = function() return false end,
		set_runtime_guard = function() end,
		show_predictions = function() return true end,
	}
	package.loaded["ui.tooltip.tooltip_hotstring"] = {
		hide = function() return true end,
		hide_forced = function() fixture.hotstring_hides = fixture.hotstring_hides + 1; return true end,
		is_visible = function() return false end,
		show = function() return true end,
		show_stacked = function() return true end,
		show_loading = function() return true end,
		dismiss_silent = function() return true end,
	}
	package.loaded["infra.logger"] = setmetatable({
		error = function(_log, format, ...)
			fixture.errors[#fixture.errors + 1] = string.format(tostring(format), ...)
		end,
	}, { __index = helpers.make_logger_stub() })

	package.loaded["ui.tooltip"] = nil
	fixture.tooltip = require("ui.tooltip")
	return fixture
end





-- ==========================================================
-- ==========================================================
-- ======= 1/ Every Show Route Owns Its Callback ============
-- ==========================================================
-- ==========================================================

helpers.describe("tooltip facade: on-show callback failures are visible", function()
	local cases = {
		{
			name = "standard hotstring",
			expected_llm_hides = 2,
			show = function(tooltip) return tooltip.show("preview", false, true, nil) end,
		},
		{
			name = "stacked hotstring",
			expected_llm_hides = 2,
			show = function(tooltip) return tooltip.show_stacked({ { text = "preview" } }, true) end,
		},
		{
			name = "loading indicator",
			expected_llm_hides = 2,
			show = function(tooltip) return tooltip.show_loading("loading", true, nil) end,
		},
		{
			name = "LLM predictions",
			expected_llm_hides = 1,
			show = function(tooltip)
				return tooltip.show_predictions(
					{ { to_type = " completion" } }, 1, true, nil,
					"none", 0, {}, nil, nil, 1
				)
			end,
		},
	}

	for _, case in ipairs(cases) do
		helpers.it("fails closed for a throwing " .. case.name .. " callback", function()
			local fixture = load_fixture()
			fixture.tooltip.set_on_show_callback(function()
				error("escape trap arm failed")
			end)

			local shown = case.show(fixture.tooltip)

			helpers.assert_eq(shown, false,
				"facade success requires its external interaction owner")
			helpers.assert_eq(fixture.llm_hides, case.expected_llm_hides,
				"the LLM owner must include exactly one authoritative cleanup")
			helpers.assert_eq(fixture.hotstring_hides, 1,
				"the hotstring owner must be revoked exactly once")
			helpers.assert_eq(#fixture.errors, 1,
				"the swallowed callback must become one file ERROR")
			helpers.assert_contains(fixture.errors[1], "escape trap arm failed")
			helpers.assert_contains(fixture.errors[1], "stack traceback")
		end)
	end

	helpers.it("keeps a successful callback on the normal committed path", function()
		local fixture = load_fixture()
		local callbacks = 0
		fixture.tooltip.set_on_show_callback(function() callbacks = callbacks + 1 end)

		helpers.assert_eq(fixture.tooltip.show("preview", false, true, nil), true)
		helpers.assert_eq(callbacks, 1)
		helpers.assert_eq(fixture.llm_hides, 1,
			"the normal hotstring handoff still hides the prior LLM owner once")
		helpers.assert_eq(fixture.hotstring_hides, 0)
		helpers.assert_eq(#fixture.errors, 0)
	end)
end)
