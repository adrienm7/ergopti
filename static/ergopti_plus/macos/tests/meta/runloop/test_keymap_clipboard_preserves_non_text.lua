--- tests/meta/runloop/test_keymap_clipboard_preserves_non_text.lua

--- ==============================================================================
--- MODULE: Keymap clipboard preserves non-text data (meta)
--- DESCRIPTION:
--- The paste path saves and restores every clipboard UTI, not only plain text.
--- Source-scan guard split out of the audit-named regression file it came from.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Reads the one production unit containing a unique symbol.
--- @param selector string
--- @return string source
local function read_unit(selector)
	local src, err = helpers.read_driver_unit(selector)
	helpers.assert_not_nil(src, err)
	return src
end


--- @param source string
--- @return string code
local function strip_line_comments(source)
	return (source:gsub("%-%-[^\n]*", ""))
end


--- @param source string
--- @param needle string
--- @return integer count
local function count_literal(source, needle)
	local count, cursor = 0, 1
	while true do
		local found = source:find(needle, cursor, true)
		if not found then return count end
		count = count + 1
		cursor = found + #needle
	end
end

helpers.describe("modules/keymap/utils.lua: clipboard preserves non-text data (audit-v6-bug3)", function()
	helpers.it("clipboard save uses readAllData() instead of getContents()", function()
		local src = read_unit("local function invalidate_ignored_win_cache")
		helpers.assert_true(
			src:find("hs.pasteboard.readAllData()", 1, true) ~= nil,
			"paste must save images, RTF, files, and text")
	end)

	helpers.it("clipboard restore uses writeAllData() instead of setContents()", function()
		local src = read_unit("local function invalidate_ignored_win_cache")
		helpers.assert_true(
			src:find("hs.pasteboard.writeAllData", 1, true) ~= nil,
			"paste must restore every saved clipboard UTI")
	end)

	helpers.it("plain-text clipboard reads are absent from paste save paths", function()
		local src = read_unit("local function invalidate_ignored_win_cache")
		helpers.assert_true(
			src:find("_paste_saved_original = hs.pasteboard.getContents()", 1, true) == nil,
			"the original clipboard must never be truncated to plain text")
	end)

	helpers.it("the asynchronous restore retains writeAllData", function()
		local src = read_unit("local function invalidate_ignored_win_cache")
		local timer_pos = src:find("local function schedule_paste_restore", 1, true)
		local timer_end = timer_pos and src:find(
			"\n--- Retains autonomous recovery after a restore failure", timer_pos, true)
		helpers.assert_not_nil(timer_pos,
			"the clipboard restore scheduler transaction must remain present")
		helpers.assert_not_nil(timer_end,
			"the clipboard restore scheduler transaction must remain independently bounded")
		local restore = src:sub(timer_pos, timer_end - 1)
		helpers.assert_true(restore:find("TimerScheduler.after", 1, true) ~= nil,
			"the restore must use the retained scheduler owner, not an untracked native timer")
		helpers.assert_true(restore:find("timer_committed ~= true", 1, true) ~= nil,
			"an uncommitted restore timer must be rejected before publication")
		helpers.assert_true(
			restore:find("_paste_pending_timer = timer_or_error", 1, true) ~= nil,
			"the exact committed timer must remain retained until callback or cancellation")
		helpers.assert_true(restore:find("restore_owned_clipboard", 1, true) ~= nil,
			"the timer must delegate to the retained exact-restore helper")
		local code = strip_line_comments(src)
		local declaration = "local function restore_owned_clipboard()"
		local boundary = "\nlocal queue_paste_restore_retry"
		helpers.assert_eq(count_literal(code, declaration), 1,
			"the exact restore helper declaration must be unique and locatable")
		helpers.assert_eq(count_literal(code, boundary), 1,
			"the exact restore helper boundary must be unique and locatable")
		local helper_pos = code:find(declaration, 1, true)
		local helper_end = code:find(boundary, 1, true)
		helpers.assert_true(helper_pos ~= nil and helper_end ~= nil
			and helper_end > helper_pos + #declaration,
			"the exact restore helper bounds must remain ordered and nonempty")
		local helper = code:sub(helper_pos + #declaration, helper_end - 1)
			:match("^(.-)%s+end%s*$")
		helpers.assert_true(type(helper) == "string" and helper:find("%S") ~= nil,
			"the exact restore helper body must remain nonempty")
		helpers.assert_true(helper:find("writeAllData", 1, true) ~= nil,
			"the shared restore helper must preserve every clipboard UTI")
		helpers.assert_true(helper:find("restore_result ~= true", 1, true) ~= nil,
			"a false/nil native restore must retain ownership for retry")
	end)
end)
