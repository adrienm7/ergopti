--- tests/unit/adapters/storage/test_clipboard_all_types.lua

--- ==============================================================================
--- MODULE: Regression — clipboard save/restore uses all pasteboard types
--- DESCRIPTION:
--- Guards against the bug where Clipboard.save() used hs.pasteboard.getContents()
--- (text-only) and restore(nil) used clearContents(). When the clipboard held
--- non-text content (images, files, RTF), save() returned nil, and then
--- restore(nil) CLEARED the clipboard — destroying the user's non-text content.
---
--- Fix (2026-06-19): save() now uses readAllData() and restore() uses
--- writeAllData(), matching the approach in keymap/utils.lua.
---
--- Behaviour, not spelling: the adapter runs against a pasteboard double that
--- holds several types at once and keeps only text through its text-only calls,
--- so a save/restore round trip that goes through text loses the image and fails.
--- ==============================================================================

local helpers = require("tests.helpers")

local TEXT = "public.utf8-plain-text"
local IMAGE = "public.png"

--- Builds a pasteboard double holding a text and an image item.
--- @return table pasteboard The hs.pasteboard double.
--- @return table state Its current types, read by the assertions.
local function multi_type_pasteboard()
	local state = { types = { [TEXT] = "caption", [IMAGE] = "\137PNG\r\n" }, generation = 7 }
	local function copy(types)
		local out = {}
		for key, value in pairs(types) do out[key] = value end
		return out
	end
	local pasteboard = {
		readAllData = function() return copy(state.types) end,
		writeAllData = function(data)
			state.types, state.generation = copy(data), state.generation + 1
			return true
		end,
		-- The text-only API drops every other type, as the real one does.
		getContents = function() return state.types[TEXT] end,
		setContents = function(text)
			state.types, state.generation = { [TEXT] = text }, state.generation + 1
			return true
		end,
		clearContents = function() state.types, state.generation = {}, state.generation + 1 end,
		changeCount = function() return state.generation end,
	}
	return pasteboard, state
end




-- =========================================================================
-- =========================================================================
-- ======= 1/ Clipboard adapter round trip keeps every type ================
-- =========================================================================
-- =========================================================================

helpers.describe("clipboard: save/restore uses all pasteboard types", function()
	helpers.it("a save, a text write and a restore give back the image and the text", function()
		local pasteboard, state = multi_type_pasteboard()
		local clipboard = helpers.load_with_stubs("adapters.clipboard", { pasteboard = pasteboard })
		local saved, ok = clipboard.save()
		helpers.assert_true(ok, "save() reports success")
		helpers.assert_eq(type(saved), "table", "a clipboard holding an image is saved, not reported empty")
		-- A synthetic paste replaces the clipboard with text, as the hotstrings do.
		helpers.assert_true(clipboard.write("expansion"))
		helpers.assert_nil(state.types[IMAGE], "the double drops the image on a text write")
		helpers.assert_true(clipboard.restore(saved))
		helpers.assert_eq(state.types[IMAGE], "\137PNG\r\n", "restore() must bring the image back")
		helpers.assert_eq(state.types[TEXT], "caption", "restore() must bring the text back")
	end)

	helpers.it("an image-only clipboard is saved and restored, never cleared", function()
		local pasteboard, state = multi_type_pasteboard()
		state.types = { [IMAGE] = "\137PNG\r\n" }
		local clipboard = helpers.load_with_stubs("adapters.clipboard", { pasteboard = pasteboard })
		local saved = clipboard.save()
		helpers.assert_eq(type(saved), "table", "a clipboard without text is not empty")
		clipboard.write("expansion")
		helpers.assert_true(clipboard.restore(saved))
		helpers.assert_eq(state.types[IMAGE], "\137PNG\r\n")
	end)
end)
