--- tests/unit/modules/hotstrings/test_preview_policy_failure.lua

--- ==============================================================================
--- MODULE: Hotstring Preview Policy Failure
--- DESCRIPTION:
--- Ensures missing, throwing, or malformed category policy hides a bubble. The
--- display gate must never turn an unresolved explicit false into permission.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")

local previous_renderer = package.loaded["adapters.graphics_renderer"]
local previous_scheduler = package.loaded["adapters.timer_scheduler"]

local shown = 0
package.loaded["adapters.graphics_renderer"] = {
	is_available = function() return true end,
	show = function() shown = shown + 1; return true end,
	hide = function() end,
	is_visible = function() return shown > 0 end,
	destroy = function() end,
}
package.loaded["adapters.timer_scheduler"] = Fakes.timer_scheduler()

local Preview = helpers.load_module("ui.tooltip.preview")
local CANDIDATES = {
	{ trigger = "btw", replacement = "by the way", group = "rolls", fires = true },
}
local STYLE = { positioning = { window_bottom_inset = 0 } }

helpers.describe("preview policy: unresolved state fails closed", function()
	helpers.it("does not render without a policy resolver", function()
		shown = 0
		Preview.init({ style = STYLE })
		helpers.assert_eq(Preview.show(CANDIDATES, "autocorrect"), false)
		helpers.assert_eq(shown, 0)
	end)

	helpers.it("does not render after a resolver exception or malformed result", function()
		shown = 0
		Preview.init({ style = STYLE, config = { resolve = function() error("broken policy") end } })
		helpers.assert_eq(Preview.show(CANDIDATES, "autocorrect"), false)
		Preview.init({ style = STYLE, config = { resolve = function() return {} end } })
		helpers.assert_eq(Preview.show(CANDIDATES, "autocorrect"), false)
		helpers.assert_eq(shown, 0)
	end)

	helpers.it("honours explicit false and recovers only from explicit true", function()
		shown = 0
		local visible = false
		Preview.init({
			style = STYLE,
			config = {
				resolve = function()
					return { show_tooltip = visible, delay = 0.5, color = "#1e88e5" }
				end,
			},
		})
		helpers.assert_eq(Preview.show(CANDIDATES, "autocorrect"), false)
		visible = true
		helpers.assert_true(Preview.show(CANDIDATES, "autocorrect"))
		helpers.assert_eq(shown, 1)
	end)
end)

package.loaded["ui.tooltip.preview"] = nil
package.loaded["adapters.graphics_renderer"] = previous_renderer
package.loaded["adapters.timer_scheduler"] = previous_scheduler
