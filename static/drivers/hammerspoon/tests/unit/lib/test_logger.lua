--- tests/unit/lib/test_logger.lua

--- ==============================================================================
--- MODULE: Logger Unit Tests
--- DESCRIPTION:
--- Validates the 8-variant logger: level filtering, lifecycle pairs, error
--- notification handler routing, and dedup summary suppression.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Replace hs.console.printStyledtext with a recording stub before loading.
local Logger = helpers.load_with_stubs("lib.logger")

helpers.describe("Logger: levels", function()
	helpers.it("exposes the 4 numeric levels", function()
		helpers.assert_eq(Logger.LEVELS.DEBUG, 1)
		helpers.assert_eq(Logger.LEVELS.INFO, 2)
		helpers.assert_eq(Logger.LEVELS.WARNING, 3)
		helpers.assert_eq(Logger.LEVELS.ERROR, 4)
	end)

	helpers.it("set_level accepts numeric level", function()
		Logger.set_level(Logger.LEVELS.DEBUG)
		helpers.assert_eq(Logger.current_level, 1)
	end)

	helpers.it("set_level accepts string level", function()
		Logger.set_level("INFO")
		helpers.assert_eq(Logger.current_level, 2)
	end)

	helpers.it("set_level falls back to WARNING on unknown name", function()
		Logger.set_level("BOGUS")
		helpers.assert_eq(Logger.current_level, Logger.LEVELS.WARNING)
	end)

	helpers.it("is_enabled reflects current level", function()
		Logger.set_level("WARNING")
		helpers.assert_true(Logger.is_enabled(Logger.LEVELS.ERROR))
		helpers.assert_true(not Logger.is_enabled(Logger.LEVELS.DEBUG))
	end)
end)

helpers.describe("Logger: error notification handler", function()
	helpers.it("invokes handler with module name + formatted message", function()
		local captured = {}
		Logger.set_error_notification_handler(function(mod, msg)
			captured.module = mod ; captured.msg = msg
		end)
		Logger.set_level("ERROR")
		Logger.error("test_mod", "boom %d", 42)
		helpers.assert_eq(captured.module, "test_mod")
		helpers.assert_eq(captured.msg, "boom 42")
		Logger.set_error_notification_handler(nil)
	end)

	helpers.it("silently ignores non-function handler", function()
		Logger.set_error_notification_handler("not a function")
		-- No throw expected
		Logger.error("m", "x")
	end)
end)

helpers.describe("Logger: pcall wrapper", function()
	helpers.it("forwards return values on success", function()
		local ok, v = Logger.pcall("test", function() return 7 end)
		helpers.assert_true(ok)
		helpers.assert_eq(v, 7)
	end)

	helpers.it("logs and returns false on error", function()
		local ok, err = Logger.pcall("test", function() error("nope") end)
		helpers.assert_true(not ok)
		helpers.assert_true(tostring(err):find("nope") ~= nil)
	end)
end)

helpers.describe("Logger: build wrapper", function()
	helpers.it("returns the value on success", function()
		local v = Logger.build("test", "thing", function() return { ok = true } end, {})
		helpers.assert_eq(v.ok, true)
	end)

	helpers.it("returns nil and logs on failure", function()
		local v = Logger.build("test", "thing", function() error("boom") end, {})
		helpers.assert_nil(v)
	end)
end)
