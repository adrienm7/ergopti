--- tests/unit/modules/shortcuts/test_clipboard_and_timer_lifecycles.lua

--- ==============================================================================
--- MODULE: Regression — two lifecycles that outlived what owned them
--- DESCRIPTION:
--- 1. wrap_selection had no in-flight guard, unlike _transform_in_flight twenty
---    lines above it in the same file. A second wrap fired while the first still
---    held the clipboard snapshotted the text the FIRST had just written, then
---    "restored" it 250 ms later — replacing the user's real clipboard with a
---    wrapped fragment of their own selection, permanently.
--- 2. The keep-awake cursor-return timer was never cancelled, so switching the
---    feature off still teleported the pointer back up to its full delay later:
---    a cursor moving by itself once nothing is supposed to be moving it.
---
--- ROOT CAUSE ENCODED:
--- Both are "the guard exists for the sibling and not for this one". The
--- assertions are on the SOURCE invariant because both paths are driven by real
--- pasteboard and mouse hardware; what is checkable without them is that the
--- guard and the cancellation exist where their siblings already are.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("shortcuts: the clipboard wrap serialises like its sibling", function()

	helpers.it("wrap_selection refuses re-entry while a wrap is outstanding", function()
		local src = helpers.read_driver_source("wrap_selection")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"the text actions source must be readable or this asserts nothing")
		local at = src:find("function M.wrap_selection", 1, true)
		helpers.assert_not_nil(at, "wrap_selection must exist")
		local body = src:sub(at, at + 900)
		helpers.assert_true(body:find("_wrap_in_flight", 1, true) ~= nil,
			"a second wrap started while the first still holds the clipboard snapshots the "
			.. "text the first one wrote and then restores THAT — the user's clipboard is gone")
	end)

	helpers.it("and releases the guard only after the restore", function()
		local src = helpers.read_driver_source("wrap_selection")
		local at  = src:find("function M.wrap_selection", 1, true)
		local body = src:sub(at, at + 1200)
		local restore = body:find("pasteboard.clearContents", 1, true)
		local release = body:find("_wrap_in_flight = false", 1, true)
		helpers.assert_true(restore ~= nil and release ~= nil,
			"both the restore and the release must be present")
		helpers.assert_true(release > restore,
			"releasing before the restore reopens exactly the window the guard exists to close")
	end)

end)

helpers.describe("shortcuts: keep-awake cancels its pending cursor return", function()

	helpers.it("toggle_awake stops the return timer, not only the tick timer", function()
		local src = helpers.read_driver_source("toggle_awake")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"the system actions source must be readable or this asserts nothing")
		local at = src:find("function M.toggle_awake", 1, true)
		helpers.assert_not_nil(at, "toggle_awake must exist")
		local body = src:sub(at, at + 1400)
		helpers.assert_true(body:find("_awake_return_timer", 1, true) ~= nil,
			"stopping only the tick timer leaves a scheduled cursor teleport firing after the "
			.. "user switched the feature off")
	end)

end)
