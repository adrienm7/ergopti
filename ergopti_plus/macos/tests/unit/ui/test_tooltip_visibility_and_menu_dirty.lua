--- tests/unit/ui/test_tooltip_visibility_and_menu_dirty.lua

--- ==============================================================================
--- MODULE: Regression — two states that claimed something the UI had not done
--- DESCRIPTION:
--- 1. TooltipHotstring set _state.is_visible = true BEFORE rendering. A render
---    that threw left no canvas on screen while tooltip.is_visible() went on
---    reporting true — and the persistent Escape trap consults exactly that to
---    decide whether to swallow Escape, so the user's next Escape vanished into
---    a tooltip that did not exist.
--- 2. Changing the log level from the Debug submenu never marked the menubar
---    cache dirty, so the static NSMenu kept showing the previous level and its
---    checkmark indefinitely — the menu asserting a setting the engine no longer
---    had.
---
--- ROOT CAUSE ENCODED:
--- Both are a claim recorded before, or without, the action that justifies it.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("tooltip: a failed render does not leave the tooltip 'visible'", function()

	helpers.it("rolls the visibility claim back when render_stacked throws", function()
		helpers.load_with_stubs("ui.tooltip.config")
		package.loaded["adapters.event_provenance"] = nil
		package.loaded["adapters.synthetic_input"] = nil
		local renderer
		renderer = {
			standard_hidden = false,
			stacked_hidden = false,
			render_stacked = function() error("simulated stacked canvas failure") end,
			hide = function() renderer.standard_hidden = true; return true end,
			hide_stacked = function() renderer.stacked_hidden = true; return true end,
		}
		package.loaded["ui.tooltip.renderer"] = renderer
		package.loaded["ui.tooltip.tooltip_hotstring"] = nil
		local Tooltip = require("ui.tooltip.tooltip_hotstring")

		local shown = Tooltip.show_stacked({ { text = "preview" } }, true)

		helpers.assert_eq(shown, false,
			"a swallowed stacked-render exception must fail the transaction")
		helpers.assert_true(not Tooltip.is_visible(),
			"a failed render must withdraw the logical visibility claim")
		helpers.assert_true(renderer.standard_hidden and renderer.stacked_hidden,
			"a failed render must close both physical canvas layers")
	end)

end)

helpers.describe("menu: changing the log level refreshes the cached menubar", function()

	helpers.it("marks the menu dirty", function()
		local src = helpers.read_driver_source("Log level set to")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"the menu source must be readable or this asserts nothing")
		-- Anchored on the handler's own log line: "set_log_level" alone matches the
		-- menu manifest and the logger's own set_level far earlier in the blob.
		local at = src:find("Log level set to", 1, true)
		helpers.assert_not_nil(at, "the log-level handler must exist")
		local body = src:sub(at, at + 600)
		helpers.assert_true(body:find("_menu_dirty", 1, true) ~= nil,
			"the menubar tree is cached and rebuilt only when _menu_dirty is set; without it "
			.. "the Debug submenu keeps showing the previous level and its checkmark")
	end)

end)
