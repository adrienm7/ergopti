--- tests/unit/modules/gestures/test_default_gestures_are_manifest.lua

--- ==============================================================================
--- MODULE: Recommended Gesture Actions Come From The Manifest
--- DESCRIPTION:
--- Startup stays neutral while explicit restoration uses recommendations. Both
--- tables derive every slot from the manifest, without mixing those policies.
---
--- The expected values are read from the generated manifest file directly, not
--- through the reader the module uses, so the check does not grade itself.
--- ==============================================================================

local helpers = require("tests.helpers")

--- The macOS gesture action defaults of the generated manifest, by slot.
--- @param field string Manifest field to project.
--- @return table slot -> action
local function manifest_actions(field)
	local chunk = assert(loadfile(helpers.driver_root() .. "/_generated/features_manifest.lua"))
	local manifest = chunk()
	local actions = {}
	for _, entry in ipairs(manifest.features) do
		if entry.section == "gestures" and entry.type == "action" then
			actions[entry.id] = entry[field]
		end
	end
	return actions
end

helpers.describe("gestures: DEFAULT_GESTURES is the manifest's macOS values", function()
	helpers.it("covers every single and axis slot with the manifest's action", function()
		package.loaded["modules.gestures.engine"] = nil
		package.loaded["modules.gestures.actions"] = nil
		package.loaded["modules.gestures.conflicts"] = nil
		local Gestures = helpers.load_with_stubs("modules.gestures")
		local expected = manifest_actions("default")
		local recommended = manifest_actions("recommended")

		local slots = {}
		for _, slot in ipairs(Gestures.SINGLE_SLOTS) do slots[#slots + 1] = slot end
		for _, slot in ipairs(Gestures.AXIS_SLOTS) do slots[#slots + 1] = slot end
		helpers.assert_true(#slots >= 39, "the module must list every slot, got " .. #slots)

		local count = 0
		for _ in pairs(Gestures.DEFAULT_GESTURES) do count = count + 1 end
		helpers.assert_eq(count, #slots, "DEFAULT_GESTURES must hold exactly the single and axis slots")

		for _, slot in ipairs(slots) do
			helpers.assert_eq(Gestures.DEFAULT_GESTURES[slot], expected[slot],
				"gestures." .. slot .. " must be the manifest's macOS default action")
			helpers.assert_eq(Gestures.RECOMMENDED_GESTURES[slot], recommended[slot],
				"gestures." .. slot .. " must preserve the explicit restoration action")
		end
		helpers.assert_eq(Gestures.DEFAULT_GESTURES.tap_3, "none")
		helpers.assert_eq(Gestures.RECOMMENDED_GESTURES.tap_3, "left_click_toggle")
	end)
end)
