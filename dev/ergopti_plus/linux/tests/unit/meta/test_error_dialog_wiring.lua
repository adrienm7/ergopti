--- tests/unit/meta/test_error_dialog_wiring.lua

--- ==============================================================================
--- MODULE: The Daemon Hands Its Errors To The Error Window
--- DESCRIPTION:
--- The error window learns of a logged ERROR only through the shared logger
--- core's error observer, and the daemon is the one place that installs it:
--- 1. the observer is installed, with the bridge's on_error, and only after
---    the bridge initialised (an uninitialised bridge has no policy);
--- 2. both happen before main() runs, so the boot's own errors count;
--- 3. the newest crash dump is announced from the loop's first tick.
---
--- WHY A SOURCE-ORDER SCAN: the daemon's entry point cannot run headless, and
--- both halves of a wrong wiring succeed on their own: a bridge that is never
--- installed, or installed before it has a policy, logs nothing and opens
--- nothing. Only the order in this one file tells them apart.
--- ==============================================================================

local helpers = require("tests.helpers")

--- The daemon entry point's source, comment lines removed so prose cannot
--- stand in for code.
--- @return string
local function daemon_code()
	local handle = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
	local lines = {}
	for line in handle:lines() do
		if not line:match("^%s*%-%-") then lines[#lines + 1] = line end
	end
	handle:close()
	return table.concat(lines, "\n")
end

helpers.describe("daemon wiring: the error window observes logged errors (error-dialog-linux)", function()
	helpers.it("installs the observer after the bridge initialised, before main() (error-dialog-linux)", function()
		local src = daemon_code()
		local init_pos = src:find("ErrorDialog.init()", 1, true)
		local observer_pos = src:find("Logger.set_error_observer(ErrorDialog.on_error)", 1, true)
		local main_pos = src:find("local function main()", 1, true)
		helpers.assert_true(init_pos ~= nil, "the daemon must initialise the error window")
		helpers.assert_true(observer_pos ~= nil, "the daemon must install the error window as the logger's error observer")
		helpers.assert_true(main_pos ~= nil, "main() must still be findable, or this test compares nothing")
		helpers.assert_true(init_pos < observer_pos, "the observer must be installed once the bridge has its policy")
		helpers.assert_true(observer_pos < main_pos, "the observer must be installed before main(), so boot errors count")
	end)

	helpers.it("announces the last crash from the new loop's first tick (error-dialog-linux)", function()
		local src = daemon_code()
		local notice_pos = src:find("ErrorDialog.notify_last_crash(CrashReporter.get_crash_dir())", 1, true)
		local defer_pos = src:find("event_loop.defer(function() ErrorDialog.notify_last_crash", 1, true)
		local run_pos = src:find("event_loop.run({", 1, true)
		helpers.assert_true(notice_pos ~= nil, "the daemon must announce a crash found in the crash reporter's folder")
		helpers.assert_true(defer_pos ~= nil, "the notice must be deferred onto the loop, where a window can open")
		helpers.assert_true(run_pos ~= nil, "the event loop must still be findable, or this test compares nothing")
		helpers.assert_true(defer_pos < run_pos, "the notice is queued before the loop starts, so it runs on its first tick")
	end)
end)
