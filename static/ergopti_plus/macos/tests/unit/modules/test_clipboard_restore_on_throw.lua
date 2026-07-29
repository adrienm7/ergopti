--- tests/unit/modules/test_clipboard_restore_on_throw.lua

--- ==============================================================================
--- MODULE: Regression — every clipboard writer restores when it throws
--- DESCRIPTION:
--- cab63e623 fixed this for adapters/text_sender: between writing our payload to
--- the clipboard and arming the restore timer there is a window where a throw —
--- the write failing, the keystroke raising — leaves the user's clipboard holding
--- our text permanently, with the saved original still set so the next send does
--- not even re-capture it. The enclosing pcall caught and logged the error, which
--- is exactly why nobody noticed the clipboard had been eaten.
---
--- ROOT CAUSE ENCODED:
--- The fix landed on ONE of the two paths with that shape.
--- modules/keymap/utils.perform_paste is the other, and it is the one every real
--- hotstring paste goes through. Asserted as a class: each clipboard-writing
--- function must restore on the failure path, not just the one that was reported.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("clipboard: a write that throws must not keep the user's clipboard", function()

	helpers.it("perform_paste restores the original when the paste raises", function()
		local src = helpers.read_driver_source("local function perform_paste")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"the keymap utils source must be readable or this asserts nothing")
		local at = src:find("local function perform_paste", 1, true)
		helpers.assert_not_nil(at, "perform_paste must exist")
		local body = src:sub(at, at + 1600)

		helpers.assert_true(body:find("setContents", 1, true) ~= nil,
			"sanity: this really is the function that writes the clipboard")
		helpers.assert_true(body:find("ok_write", 1, true) ~= nil,
			"between writing our payload and arming the restore timer there is a window in "
			.. "which a throw leaves the user's clipboard holding our text permanently — the "
			.. "sibling path in adapters/text_sender was fixed for exactly this and this one, "
			.. "which every real hotstring paste goes through, was not")
	end)

	helpers.it("the sibling that was already fixed still restores", function()
		local src = helpers.read_driver_source("clipboard send failed before the restore")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"the text sender source must be readable or this asserts nothing")
		helpers.assert_true(src:find("Clipboard.restore(saved)", 1, true) ~= nil,
			"without this the assertion above could be satisfied by deleting both guards")
	end)

end)
