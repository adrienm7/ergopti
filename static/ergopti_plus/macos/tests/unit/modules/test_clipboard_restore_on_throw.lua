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
		local next_function = src:find("function M.emit_tokens", at, true)
		helpers.assert_not_nil(next_function, "perform_paste must remain a bounded unit")
		local body = src:sub(at, next_function - 1)
		local ownership_at = body:find("_paste_owns_clipboard = true", 1, true)
		local write_at = body:find("pcall(hs.pasteboard.setContents", 1, true)
		local rejected_at = body:find("not ok_write or write_result ~= true", 1, true)
		local restore_at = rejected_at and body:find("restore_owned_clipboard()", rejected_at, true)
		local timer_at = body:find("local restore_armed", 1, true)

		helpers.assert_true(ownership_at ~= nil and write_at ~= nil and rejected_at ~= nil
			and restore_at ~= nil and timer_at ~= nil,
			"the keymap paste must retain ownership, inspect throw/false, restore, then arm output")
		helpers.assert_true(ownership_at < write_at and write_at < rejected_at
			and rejected_at < restore_at and restore_at < timer_at,
			"ownership must precede the possibly mutating native write, whose throw/false path "
			.. "must restore before any Cmd+V restore timer can be committed")
	end)

	helpers.it("the sibling that was already fixed still restores", function()
		local src = helpers.read_driver_source("local function schedule_restore()")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"the text sender source must be readable or this asserts nothing")
		local send_at = src:find("function M.send", 1, true)
		local ownership_at = send_at and src:find("_paste_owns_clipboard = true", send_at, true)
		local write_at = send_at and src:find("pcall(function() return Clipboard.write(text) end)", send_at, true)
		local rejected_at = write_at and src:find("not ok_write or written ~= true", write_at, true)
		local restore_at = rejected_at and src:find("restore_clipboard()", rejected_at, true)
		local timer_at = restore_at and src:find("local restore_armed", restore_at, true)
		helpers.assert_true(ownership_at ~= nil and write_at ~= nil and rejected_at ~= nil
			and restore_at ~= nil and timer_at ~= nil,
			"the text sender sibling must retain and restore around its native write")
		helpers.assert_true(ownership_at < write_at and write_at < rejected_at
			and rejected_at < restore_at and restore_at < timer_at,
			"the text sender must restore a possibly mutated clipboard before publishing Cmd+V")
	end)

end)
