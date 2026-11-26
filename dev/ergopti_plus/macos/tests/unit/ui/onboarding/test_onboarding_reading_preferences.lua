--- tests/unit/ui/onboarding/test_onboarding_reading_preferences.lua

--- ==============================================================================
--- MODULE: Onboarding Reading Preferences
--- DESCRIPTION:
--- The setup wizard offers the reader's font and spacing beside the languages
--- (maintainer request, 2026-11-24): a choice posted by the page is saved
--- through the Configuration menu's own writer, which pushes it to the open
--- windows and ticks the menu again, and an unknown choice reaches no writer.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.onboarding_delivery_fixture")
local with_delivery = fixture.with_delivery

helpers.describe("onboarding reading preferences (reading-preferences-wizard)", function()
	helpers.it("saves a reading choice through the Configuration menu's writer", function()
		local saved_menu = package.loaded["menu.ui"]
		local saved = {}
		package.loaded["menu.ui"] = {
			set_reading_preference = function(owner, value)
				saved[#saved + 1] = { owner = owner, value = value }
				return true
			end,
		}
		local ok, err = pcall(with_delivery, function(_, state)
			state.receiver({ body = { action = "setReadingPreference", name = "font", value = "dyslexic" } })
			state.receiver({ body = { action = "setReadingPreference", name = "spacing", value = "wide" } })
			state.receiver({ body = { action = "setReadingPreference", name = "colors", value = "cvd" } })
		end)
		package.loaded["menu.ui"] = saved_menu
		assert(ok, err)
		helpers.assert_eq(#saved, 2, "an unknown choice reaches no writer")
		helpers.assert_eq(saved[1].owner, "core.ui.engine.webview.reading_font")
		helpers.assert_eq(saved[1].value, "dyslexic")
		helpers.assert_eq(saved[2].owner, "core.ui.engine.webview.reading_spacing")
		helpers.assert_eq(saved[2].value, "wide")
	end)
end)
