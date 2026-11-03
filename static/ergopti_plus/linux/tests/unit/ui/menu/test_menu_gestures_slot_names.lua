--- tests/unit/ui/menu/test_menu_gestures_slot_names.lua

--- ==============================================================================
--- MODULE: Gesture Slot Names Are Translated
--- DESCRIPTION:
--- The Linux gesture rows named each slot with a French sentence built in the
--- menu module (« Balayage 3 doigts vers haut »), whatever the user's language.
--- Every slot of the shared catalogue now reads as its gesture.slots.* text,
--- the one Windows and macOS show, in French and in English.
--- ==============================================================================

local helpers = require("tests.helpers")
local check = require("test.menu_row_text")

local SHARED_ROOT = "../_shared"

helpers.describe("gesture slot names", function()
	helpers.it("names every slot by its translated gesture.slots text", function()
		local Menu = require("ui.menu.menu_gestures")
		local Manager = require("modules.gestures.manager")
		local saved = rawget(_G, "i18n_safe")
		local ok, err = pcall(function()
			local slots = {}
			for _, slot in ipairs(Manager.SINGLE_SLOTS) do slots[#slots + 1] = slot end
			for _, slot in ipairs(Manager.AXIS_SLOTS) do slots[#slots + 1] = slot end
			helpers.assert_true(#slots > 0, "the shared catalogue offers gesture slots")
			for _, locale in ipairs({ "fr", "en" }) do
				local catalogue = check.catalogue(SHARED_ROOT, locale, require("json").decode)
				_G.i18n_safe = function(key) return catalogue[key] or key end
				for _, slot in ipairs(slots) do
					local label = Menu.slot_label(slot)
					helpers.assert_eq(label, catalogue["gesture.slots." .. slot], slot .. " in " .. locale)
					helpers.assert_true(not label:find("Balayage", 1, true) or locale == "fr",
						slot .. " reads in " .. locale)
				end
			end
		end)
		_G.i18n_safe = saved
		if not ok then error(err, 0) end
	end)
end)
