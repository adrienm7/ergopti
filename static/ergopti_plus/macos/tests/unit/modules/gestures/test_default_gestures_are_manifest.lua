--- tests/unit/modules/gestures/test_default_gestures_are_manifest.lua

--- ==============================================================================
--- MODULE: Recommended Gesture Actions Come From The Manifest
--- DESCRIPTION:
--- DEFAULT_GESTURES is what « Restaurer les valeurs conseillées » and the factory
--- reset put back, and what a session starts from. It was a hand-written table
--- that had drifted from the manifest's macOS values (the two-finger left swipe
--- and the three horizontal axes), so a fresh configuration and a restore gave
--- two different trackpads. It is built from the manifest now: every slot the
--- module iterates carries exactly the manifest's macOS value.
---
--- The expected values are read from the generated manifest file directly, not
--- through the reader the module uses, so the check does not grade itself.
--- ==============================================================================

local helpers = require("tests.helpers")

--- The macOS gesture action defaults of the generated manifest, by slot.
--- @return table slot -> action
local function manifest_actions()
	local chunk = assert(loadfile(helpers.driver_root() .. "/_generated/features_manifest.lua"))
	local manifest = chunk()
	local actions = {}
	for _, entry in ipairs(manifest.features) do
		if entry.section == "gestures" and entry.type == "action" then
			actions[entry.id] = entry.default
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
		local expected = manifest_actions()

		local slots = {}
		for _, slot in ipairs(Gestures.SINGLE_SLOTS) do slots[#slots + 1] = slot end
		for _, slot in ipairs(Gestures.AXIS_SLOTS) do slots[#slots + 1] = slot end
		helpers.assert_true(#slots >= 39, "the module must list every slot, got " .. #slots)

		local count = 0
		for _ in pairs(Gestures.DEFAULT_GESTURES) do count = count + 1 end
		helpers.assert_eq(count, #slots, "DEFAULT_GESTURES must hold exactly the single and axis slots")

		for _, slot in ipairs(slots) do
			helpers.assert_eq(Gestures.DEFAULT_GESTURES[slot], expected[slot],
				"gestures." .. slot .. " must be the manifest's macOS recommended action")
		end
	end)
end)
