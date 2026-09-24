--- tests/unit/infra/test_logger_error_observer.lua

--- ==============================================================================
--- MODULE: Shared Logger Core Error Observer (Linux)
--- DESCRIPTION:
--- The Linux error window learns of every logged ERROR through the shared
--- logger core's error observer, installed by the daemon:
--- 1. an accepted ERROR reaches it with its module, its UNFORMATTED template
---    and its formatted body; a WARNING never does;
--- 2. a line swallowed by the dedup window is not observed, as it is not
---    logged;
--- 3. an observer that raises cannot break the logging call.
--- ==============================================================================

local helpers = require("tests.helpers")

local Core = require("logger")

--- Runs a body with an observer installed, the core at its lowest level and a
--- fresh dedup streak, restoring all three afterwards.
--- @param observer function
--- @param body function
local function with_observer(observer, body)
	local level = Core.get_level()
	Core.set_level(Core.LEVELS.DEBUG)
	Core.reset_dedup()
	Core.set_error_observer(observer)
	local ok, err = pcall(body)
	Core.set_error_observer(nil)
	Core.reset_dedup()
	Core.set_level(level)
	if not ok then error(err, 0) end
end

helpers.describe("logger core: error observer (error-dialog-linux)", function()
	helpers.it("hands an accepted ERROR over with its template (error-dialog-linux)", function()
		local seen = {}
		with_observer(function(module_name, template, body)
			seen[#seen + 1] = { module_name, template, body }
		end, function()
			Core.warn("mod", "not an error %s", "x")
			Core.error("keylogger", "Flush failed: %s (%d)", "disk full", 3)
			Core.error("menu", "Plain failure")
		end)
		helpers.assert_eq(seen, {
			{ "keylogger", "Flush failed: %s (%d)", "Flush failed: disk full (3)" },
			{ "menu", "Plain failure", "Plain failure" },
		})
	end)

	helpers.it("does not observe a line the dedup window swallowed (error-dialog-linux)", function()
		local count = 0
		with_observer(function() count = count + 1 end, function()
			for _ = 1, 3 do Core.error("mod", "same failure") end
		end)
		helpers.assert_eq(count, 1, "a suppressed duplicate is not logged, so it is not observed")
	end)

	helpers.it("an observer that raises cannot break the logging call (error-dialog-linux)", function()
		local line
		with_observer(function() error("observer boom") end, function()
			line = Core.error("mod", "still logged")
		end)
		helpers.assert_true(type(line) == "string" and line:find("still logged", 1, true) ~= nil,
			"the ERROR is still logged and returned")
	end)
end)
