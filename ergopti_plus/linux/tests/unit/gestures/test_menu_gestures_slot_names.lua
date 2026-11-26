--- tests/unit/gestures/test_menu_gestures_slot_names.lua

--- ==============================================================================
--- MODULE: Gesture Slot Names Are Translated
--- DESCRIPTION:
--- The Linux gesture rows named each slot with a French sentence built in the
--- menu module (« Balayage 3 doigts vers haut »), whatever the user's language.
--- Every slot of the shared catalogue, the axis slots included, now reads as
--- its gesture.slots.* text, the one Windows and macOS show, in French and in
--- English, from the gesture manager the menu rows ask.
--- ==============================================================================

local helpers = require("tests.helpers")
local check = require("tests.lua.menu.row_text")

local SHARED_ROOT = "../_shared"

helpers.describe("gesture slot names", function()
	helpers.it("names every slot by its translated gesture.slots text", function()
		local Manager = require("gestures.engine.manager")
		local i18n = require("core.i18n.engine.i18n")
		local saved = i18n.get
		local ok, err = pcall(function()
			local slots = {}
			for _, slot in ipairs(Manager.SINGLE_SLOTS) do slots[#slots + 1] = slot end
			for _, slot in ipairs(Manager.AXIS_SLOTS) do slots[#slots + 1] = slot end
			helpers.assert_true(#slots > 0, "the shared catalogue offers gesture slots")
			for _, locale in ipairs({ "fr", "en" }) do
				local catalogue = check.catalogue(SHARED_ROOT, locale, require("core.text.engine.json").decode)
				i18n.get = function(key) return catalogue[key] or key end
				for _, slot in ipairs(slots) do
					local text = catalogue["gesture.slots." .. slot]
					helpers.assert_type(text, "string", slot .. " has a name in " .. locale)
					helpers.assert_eq(Manager.slot_label(slot), text, slot .. " in " .. locale)
				end
			end
		end)
		i18n.get = saved
		if not ok then error(err, 0) end
	end)
end)
