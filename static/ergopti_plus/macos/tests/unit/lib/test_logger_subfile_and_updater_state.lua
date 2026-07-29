--- tests/unit/lib/test_logger_subfile_and_updater_state.lua

--- ==============================================================================
--- MODULE: Regressions — a per-line file handle, and a gate that hid an update
--- DESCRIPTION:
--- 1. The topical sub-file fan-out opened, wrote and closed a file handle PER
---    LINE. The main handle is deliberately level-aware — it buffers DEBUG and
---    flushes on a count, precisely because DEBUG lines come off the keystroke
---    path — and the fan-out ignored that entirely, so every matching DEBUG line
---    paid an open+write+close inside the eventtap callback. The comment claimed
---    the cost was "negligible vs. the operations logged", which is true of the
---    operations and not of a keystroke.
--- 2. notify_new_version early-returned when the tag matched the last notified
---    one — skipping not just the notification but `_update_state = "available"`
---    and the menu refresh. After a channel or interval change the "Update to vX"
---    entry silently disappeared while a release was still cached.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("logger: the sub-file fan-out keeps its handles open", function()

	helpers.it("does not open and close a handle per line", function()
		local src = helpers.read_driver_source("Fan-out to topical sub-files")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"the logger source must be readable or this asserts nothing")
		local at = src:find("Fan-out to topical sub-files", 1, true)
		local block = src:sub(at, at + 1800)
		helpers.assert_true(block:find("_sub_handles", 1, true) ~= nil,
			"the main handle is level-aware because DEBUG lines come off the keystroke path; "
			.. "a fan-out that opens and closes a file per line reintroduces exactly the "
			.. "blocking I/O that policy exists to avoid")
	end)

end)

helpers.describe("updater: a suppressed notification must not suppress the state", function()

	helpers.it("records availability even when the tag was already notified", function()
		local src = helpers.read_driver_source("notify_new_version")
		local at  = src:find("local function notify_new_version", 1, true)
		helpers.assert_not_nil(at, "notify_new_version must exist")
		local body = src:sub(at, at + 900)
		local guard = body:find("_last_notified_tag", 1, true)
		local state = body:find('_update_state = "available"', 1, true)
		helpers.assert_not_nil(guard, "the repeat-notification guard must exist")
		helpers.assert_not_nil(state, "the availability state must be recorded")
		helpers.assert_true(state < guard,
			"the state and the menu refresh must happen BEFORE the notification is "
			.. "suppressed; gating them on the same check makes the 'Update to vX' entry "
			.. "vanish after a channel change while a release is still cached")
	end)

end)
