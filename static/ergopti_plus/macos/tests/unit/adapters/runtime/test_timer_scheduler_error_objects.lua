--- tests/unit/adapters/runtime/test_timer_scheduler_error_objects.lua

--- ==============================================================================
--- MODULE: TimerScheduler error-object isolation regression tests
--- DESCRIPTION:
--- A callback may raise a table whose __tostring itself raises. The scheduler
--- reported every caught failure with an unprotected tostring(), so that second
--- error escaped the callback guard: later settlement observers were dropped
--- and the native timer callback raised (timer-error-object-2026-10-21). The
--- description now comes from the shared ErrorDescription owner, which never
--- runs foreign formatting code.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.adapters.runtime.timer_scheduler_fixture"] = nil
local Fixture = require("tests.support.adapters.runtime.timer_scheduler_fixture")

--- Returns an error object whose formatter raises and records each call.
--- @param calls table Counter table.
--- @return table
local function hostile_error(calls)
	return setmetatable({}, {
		__tostring = function()
			calls.formatted = (calls.formatted or 0) + 1
			error(setmetatable({}, { __tostring = function() error("formatter failure") end }))
		end,
	})
end

--- Loads the scheduler with a timer double and a recording logger.
--- @return table TS, table timer_stub, table logs
local function load_scheduler()
	local logs = {}
	local timer_stub = Fixture.make_timer_stub()
	package.loaded["infra.logger"] = nil
	helpers.load_with_stubs("adapters.timer_scheduler", { timer = timer_stub })
	local logger = helpers.make_logger_stub()
	logger.error = function(_, template, ...) logs[#logs + 1] = string.format(template, ...) end
	package.loaded["infra.logger"] = logger
	package.loaded["adapters.timer_scheduler"] = nil
	return require("adapters.timer_scheduler"), timer_stub, logs
end


helpers.describe("TimerScheduler: a hostile error object stays inside the guard (timer-error-object-2026-10-21)", function()
	helpers.it("logs a one-shot failure without running the object's formatter", function()
		local TS, timer_stub, logs = load_scheduler()
		local calls = {}
		TS.after(1, function() error(hostile_error(calls)) end)
		local ok, failure = pcall(timer_stub.fire, 1)
		helpers.assert_true(ok, "the native timer callback must not raise: " .. tostring(ok or type(failure)))
		helpers.assert_eq(calls.formatted, nil, "foreign formatting code must not run while reporting")
		helpers.assert_eq(#logs, 1)
		helpers.assert_true(logs[1]:find("error object (table)", 1, true) ~= nil, logs[1])
	end)

	helpers.it("keeps a repeating timer reporting each failure", function()
		local TS, timer_stub, logs = load_scheduler()
		local calls = {}
		TS.every(1, function() error(hostile_error(calls)) end)
		local ticks = { (pcall(timer_stub.fire, 1)), (pcall(timer_stub.fire, 1)) }
		helpers.assert_eq(ticks, { true, true }, "each tick's failure must stay inside the guard")
		helpers.assert_eq(#logs, 2, "each contained failure must still be reported")
	end)

	helpers.it("delivers every settlement observer after one raises a hostile object", function()
		local TS, timer_stub = load_scheduler()
		local handle = TS.after(1, function() end)
		local delivered = {}
		TS.onSettled(handle, function() error(hostile_error({})) end)
		TS.onSettled(handle, function() delivered[#delivered + 1] = "second" end)
		local contained = pcall(timer_stub.fire, 1)
		helpers.assert_eq({ contained, delivered }, { true, { "second" } },
			"a failing observer must neither escape nor drop its successors")
	end)

	helpers.it("keeps primitive failure text", function()
		local TS, timer_stub, logs = load_scheduler()
		TS.after(1, function() error("plain failure", 0) end)
		timer_stub.fire(1)
		helpers.assert_true(logs[1]:find("plain failure", 1, true) ~= nil, logs[1])
	end)
end)
