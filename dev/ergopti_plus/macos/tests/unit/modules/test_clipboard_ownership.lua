--- tests/unit/modules/test_clipboard_ownership.lua

--- ==============================================================================
--- MODULE: Regression — nothing may leave the user's clipboard holding our data
---         (clipboard-ownership)
--- DESCRIPTION:
--- Three paths borrow the clipboard, and each could hand it back wrong.
---
--- ROOT CAUSE ENCODED:
---   1. text_sender wrote the payload, sent Cmd+V, then armed the restore timer.
---      A throw in between — Clipboard.write failing, the keystroke raising —
---      left our payload on the clipboard permanently, with the saved original
---      still held so the next send would not even re-capture. The surrounding
---      pcall caught and logged the error, which is exactly why nobody connected
---      it to a clipboard that had been eaten.
---   2. search_web snapshotted the clipboard unconditionally. Two gestures in
---      quick succession made the second snapshot what the FIRST had just
---      copied — the selection, not the user's clipboard — and then "restored"
---      it, so the real contents were gone for good.
---   3. do_transform released its in-flight lock ONLY from a 2 s failsafe. A
---      transform finishing in half a second still blocked the next one for the
---      remaining second and a half, so deliberate repeat transforms were
---      dropped — while a long selection legitimately outlived that delay and
---      had its lock released mid-transform, re-opening the race the flag
---      exists to close.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ================================================================
-- ================================================================
-- ======= 1/ A failed send returns the clipboard =================
-- ================================================================
-- ================================================================

helpers.describe("text_sender: a throw mid-send does not keep the clipboard", function()
	helpers.it("restores the original when the paste raises", function()
		local src = helpers.read_driver_source("PASTE_MODIFIER")
		helpers.assert_true(src ~= nil and src ~= "", "text_sender must be locatable")

		local code = src:gsub("%-%-[^\n]*", "")
		local write_at = code:find("Clipboard.write(text)", 1, true)
		helpers.assert_true(write_at ~= nil, "the clipboard send must still write the payload")

		-- Bounded by the restore TIMER, not by a byte count. That timer already
		-- calls Clipboard.restore on the happy path, so any window wide enough to
		-- reach it reports the unfixed file as fixed.
		local timer_at = code:find("doAfter(CLIPBOARD_RESTORE_DELAY_S", write_at, true)
		helpers.assert_true(timer_at ~= nil, "the restore timer must still be armed")

		local between = code:sub(write_at, timer_at)
		helpers.assert_true(between:find("Clipboard.restore", 1, true) ~= nil,
			"a failure between writing the payload and arming the restore timer must hand the "
				.. "clipboard back BEFORE that timer exists — it is never armed on this path. "
				.. "Left alone, our payload stays on the clipboard for the rest of the session")
		helpers.assert_true(between:find("_paste_saved_original = nil", 1, true) ~= nil,
			"and it must clear the saved original, or the next send treats OUR payload as the "
				.. "user's clipboard")
	end)
end)




-- ================================================================
-- ================================================================
-- ======= 2/ search_web keeps the first snapshot =================
-- ================================================================
-- ================================================================

helpers.describe("search_web: a second gesture does not snapshot the first's copy", function()
	helpers.it("captures only when no capture is in flight", function()
		local src = helpers.read_driver_source("search_web")
		helpers.assert_true(src ~= nil and src ~= "", "the gesture actions must be locatable")

		local code = src:gsub("%-%-[^\n]*", "")
		local at = code:find('sg("search_web"', 1, true)
		helpers.assert_true(at ~= nil, "the search_web action must exist")

		local body = code:sub(at, at + 1200)
		helpers.assert_true(body:find("_search_capture_in_flight", 1, true) ~= nil,
			"the snapshot must be skipped while a capture is already in flight. Unguarded, the "
				.. "second gesture snapshots what the first just copied — the selection — and "
				.. "restores that as the user's clipboard, destroying the real contents")

		-- Declared above the closure that reads it: a local declared below binds a
		-- nil global instead, and the failure surfaces only inside a timer callback
		-- where the file logger never sees it.
		local decl_at = code:find("local _search_capture_in_flight", 1, true)
		helpers.assert_true(decl_at ~= nil and decl_at < at,
			"the capture state must be declared ABOVE the action closure — below it, the closure "
				.. "binds a nil global and the guard silently does nothing")
	end)
end)




-- ================================================================
-- ================================================================
-- ======= 3/ do_transform releases when it finishes ==============
-- ================================================================
-- ================================================================

helpers.describe("do_transform: the lock follows the transform, not a fixed delay", function()
	helpers.it("releases at every terminal point", function()
		local src = helpers.read_driver_source("_transform_in_flight")
		helpers.assert_true(src ~= nil and src ~= "", "the text actions must be locatable")

		local code = src:gsub("%-%-[^\n]*", "")

		local releases = 0
		for _ in code:gmatch("release%(%)") do releases = releases + 1 end
		helpers.assert_true(releases >= 4,
			"the lock must be released on completion and on both aborts, not only by the "
				.. "failsafe (found " .. releases .. " release site(s)). Released only after 2 s, "
				.. "a transform finishing in half a second still blocked the next one")

		helpers.assert_true(code:find("_transform_generation", 1, true) ~= nil,
			"and the failsafe must be generation-checked: a long selection legitimately outlives "
				.. "the 2 s delay — the re-select walks the text one keystroke at a time — so an "
				.. "unguarded failsafe unlocks the clipboard mid-transform and re-opens the race")

		local at = code:find("local function release", 1, true)
		helpers.assert_true(at ~= nil, "the release helper must exist")
		local body = code:sub(at, at + 240)
		helpers.assert_true(body:find("my_generation ~= _transform_generation", 1, true) ~= nil,
			"release must verify this transform still owns the lock before clearing it, or it "
				.. "unlocks a NEWER transform that has barely started")
	end)
end)
