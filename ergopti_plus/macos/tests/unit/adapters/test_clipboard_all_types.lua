--- tests/unit/adapters/test_clipboard_all_types.lua

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
--- ==============================================================================

local helpers = require("tests.helpers")




-- =========================================================================
-- =========================================================================
-- ======= 1/ Clipboard adapter uses all-type API ==========================
-- =========================================================================
-- =========================================================================

helpers.describe("clipboard: save/restore uses all pasteboard types", function()
	helpers.it("save() uses readAllData, not getContents", function()
		local src_path = debug.getinfo(1, "S").source:match("^@(.+)$")
		local base = src_path:match("^(.+)[/\\]tests[/\\]") or ""
		local src_file = base .. "/adapters/clipboard.lua"

		local fh = io.open(src_file, "r")
		helpers.assert_true(fh ~= nil, "Cannot open adapters/clipboard.lua")
		local src = fh:read("*a")
		fh:close()

		-- save() must use readAllData
		helpers.assert_true(
			src:find("readAllData", 1, true) ~= nil,
			"Clipboard.save() must use readAllData() to preserve non-text clipboard types"
		)
		-- Must NOT use getContents inside save()
		local save_start = src:find("function M.save()", 1, true)
		local restore_start = src:find("function M.restore(", 1, true)
		helpers.assert_true(save_start ~= nil, "function M.save() must exist")
		helpers.assert_true(restore_start ~= nil, "function M.restore() must exist")
		local save_body = src:sub(save_start, restore_start)
		helpers.assert_true(
			save_body:find("getContents", 1, true) == nil,
			"Clipboard.save() must not use getContents() (text-only, destroys non-text clipboard)"
		)
	end)

	helpers.it("restore() uses writeAllData, not setContents", function()
		local src_path = debug.getinfo(1, "S").source:match("^@(.+)$")
		local base = src_path:match("^(.+)[/\\]tests[/\\]") or ""
		local src_file = base .. "/adapters/clipboard.lua"

		local fh = io.open(src_file, "r")
		helpers.assert_true(fh ~= nil, "Cannot open adapters/clipboard.lua")
		local src = fh:read("*a")
		fh:close()

		-- restore() must use writeAllData
		helpers.assert_true(
			src:find("writeAllData", 1, true) ~= nil,
			"Clipboard.restore() must use writeAllData() to preserve all pasteboard types"
		)
		-- Must NOT use setContents inside restore()
		local restore_start = src:find("function M.restore(", 1, true)
		helpers.assert_true(restore_start ~= nil, "function M.restore() must exist")
		local restore_body = src:sub(restore_start)
		helpers.assert_true(
			restore_body:find("setContents", 1, true) == nil,
			"Clipboard.restore() must not use setContents() (text-only)"
		)
	end)
end)
