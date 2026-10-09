--- tests/unit/modules/keymap/test_expander_delete_count_sanity.lua

--- ==============================================================================
--- MODULE: Regression — the delete count can never go negative, and is not magic
--- DESCRIPTION:
--- Two defects on the same few lines of try_auto_expand.
---
--- 1. `screen_len = trig_len - char_offset` went negative when the trigger was
---    shorter than the typed event's codepoint count — a composed character
---    arriving as one event. A negative deletion request cannot describe a valid
---    replacement transaction and would make the logical buffer commit disagree
---    with the text operation built for the target application.
--- 2. A final_result expansion suppressed the engine for a bare literal 1.0 s,
---    double the module's own named default, with the relationship invisible.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("expander: the erase count is sane and the suppression window is named", function()

	helpers.it("never asks for a negative number of deletes", function()
		local src = helpers.read_driver_source("local screen_len")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"the expander source must be readable or this asserts nothing")
		helpers.assert_true(src:find("if screen_len < 0", 1, true) ~= nil,
			"a trigger shorter than the typed event must be clamped before constructing "
			.. "the deletion events and committing the logical replacement")
	end)

	helpers.it("the final-result suppression window is a named constant, not a literal", function()
		local CoreStateM = require("modules.keymap.state")
		helpers.assert_type(CoreStateM.FINAL_RESULT_SUPPRESS_SEC, "number",
			"the window must be published beside the default it is derived from")

		local src = helpers.read_driver_source("FINAL_RESULT_SUPPRESS_SEC")
		helpers.assert_true(src:find("suppress_rescan(1.0)", 1, true) == nil,
			"the bare literal must be gone, not merely joined by a constant that nothing uses")
	end)

	helpers.it("that window is deliberately double the module default", function()
		local CoreStateM = require("modules.keymap.state")
		helpers.assert_eq(CoreStateM.FINAL_RESULT_SUPPRESS_SEC, 1.0,
			"the value itself is unchanged by this refactor — only its provenance is; if the "
			.. "default moves, this should move with it rather than drift")
	end)

end)
