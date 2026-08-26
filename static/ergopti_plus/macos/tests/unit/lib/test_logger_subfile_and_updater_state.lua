--- tests/unit/lib/test_logger_subfile_and_updater_state.lua

--- ==============================================================================
--- MODULE: Regression — topical logger handles remain owned
--- DESCRIPTION:
--- The topical sub-file fan-out opened, wrote and closed a file handle PER
---    LINE. The main handle is deliberately level-aware — it buffers DEBUG and
---    flushes on a count, precisely because DEBUG lines come off the keystroke
---    path — and the fan-out ignored that entirely, so every matching DEBUG line
---    paid an open+write+close inside the eventtap callback. The comment claimed
---    the cost was "negligible vs. the operations logged", which is true of the
---    operations and not of a keystroke.
--- The updater regression formerly colocated here now runs behaviorally in
--- test_updater_install_ownership.lua instead of scanning source spelling.
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
