--- tests/unit/gestures/engine/actions/test_background_commands.lua

--- ==============================================================================
--- MODULE: Observed Background Commands Tests
--- DESCRIPTION:
--- A real POSIX shell runs each command in the background, as the daemon does.
--- The background child's own exit status and stderr used to go to /dev/null:
--- a failing pactl or gio left no line in the log (LDS-001). Each case waits
--- for the real result receipt and checks what the central logger received.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads a fresh runner whose logger records its error lines.
--- @return table runner
--- @return table errors Formatted error lines, appended as they are logged.
local function fresh_runner()
	local errors = {}
	local logger = helpers.make_logger_stub()
	logger.error = function(_, format, ...) errors[#errors + 1] = string.format(format, ...) end
	local runner = helpers.load_module_with_dependency("gestures.engine.background_commands", "core.logger.engine.shim", logger)
	return runner, errors
end

--- Collects until every started command has reported, within two seconds.
--- @param runner table
local function settle(runner)
	local uv = require("luv")
	local deadline = uv.hrtime() + 2e9
	while runner.pending_count() > 0 and uv.hrtime() < deadline do
		runner._collect_now()
		if runner.pending_count() > 0 then uv.sleep(20) end
	end
	helpers.assert_eq(runner.pending_count(), 0, "every background command must report its result")
end

helpers.describe("Observed background commands (background-child-lds-001)", function()
	local cached = package.loaded["gestures.engine.background_commands"]

	helpers.it("(background-child-lds-001) a failing child is logged with its exit and stderr", function()
		local runner, errors = fresh_runner()
		helpers.assert_true(runner.run("echo 'pactl: no such source' >&2; exit 37", "mic_mute_toggle"))
		settle(runner)
		helpers.assert_eq(#errors, 1, "the child's failure must reach the log")
		helpers.assert_contains(errors[1], "mic_mute_toggle")
		helpers.assert_contains(errors[1], "exit 37")
		helpers.assert_contains(errors[1], "pactl: no such source")
	end)

	helpers.it("(background-child-lds-001) a healthy child logs nothing", function()
		local runner, errors = fresh_runner()
		helpers.assert_true(runner.run("echo working; exit 0", "show_desktop"))
		settle(runner)
		helpers.assert_eq(#errors, 0)
	end)

	helpers.it("(background-child-lds-001) a private command's stderr stays out of the log", function()
		local runner, errors = fresh_runner()
		helpers.assert_true(runner.run("echo '/home/ana/secret.sh: denied' >&2; exit 1",
			"make_executable_selection", true))
		settle(runner)
		helpers.assert_eq(#errors, 1)
		helpers.assert_contains(errors[1], "exit 1")
		helpers.assert_true(not errors[1]:find("secret", 1, true), "a user path must not be logged: " .. errors[1])
	end)

	helpers.it("(background-child-lds-001) the command never blocks the caller", function()
		local runner, errors = fresh_runner()
		local uv = require("luv")
		local started = uv.hrtime()
		helpers.assert_true(runner.run("sleep 1; exit 3", "sleep_displays"))
		helpers.assert_true(uv.hrtime() - started < 5e8, "the daemon must not wait for the command")
		helpers.assert_eq(runner.pending_count(), 1)
		settle(runner)
		helpers.assert_contains(errors[1], "exit 3")
	end)

	package.loaded["gestures.engine.background_commands"] = cached
end)
