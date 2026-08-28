--- tests/unit/adapters/test_task_lifecycle.lua

--- ==============================================================================
--- MODULE: Native task lifecycle contract tests
--- DESCRIPTION:
--- Proves that task construction and start success are separate contracts.
--- Every nil, throw, and false outcome must return a literal failure and emit a
--- central ERROR; a truthy task return is the only committed launch.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===========================================================
-- ===========================================================
-- ======= 1/ Strict Construction and Start ==================
-- ===========================================================
-- ===========================================================

--- Loads a fresh adapter and captures central error messages.
--- @return table adapter, table errors
local function load_adapter()
	local errors = {}
	local logger = helpers.make_logger_stub()
	logger.error = function(_module, fmt, ...)
		local ok, rendered = pcall(string.format, fmt, ...)
		errors[#errors + 1] = ok and rendered or tostring(fmt)
	end
	package.loaded["infra.logger"] = logger
	package.loaded["adapters.task_lifecycle"] = nil
	return require("adapters.task_lifecycle"), errors
end

helpers.describe("task_lifecycle: only a real native start commits", function()
	helpers.it("rejects nil and throwing construction (task-lifecycle-create-contract)", function()
		local adapter, errors = load_adapter()
		helpers.assert_nil(adapter.create(function() return nil end, "nil probe"))
		helpers.assert_nil(adapter.create(function() error("constructor exploded") end,
			"throwing probe"))
		helpers.assert_eq(2, #errors,
			"both construction failure modes must be visible in the file logger")
	end)

	helpers.it("rejects false and throwing start (task-lifecycle-start-contract)", function()
		local adapter, errors = load_adapter()
		helpers.assert_eq(false, adapter.start({ start = function() return false end },
			"refused probe"))
		helpers.assert_eq(false, adapter.start({ start = function() error("start exploded") end },
			"throwing probe"))
		helpers.assert_eq(2, #errors,
			"both start failure modes must be visible in the file logger")
	end)

	helpers.it("accepts the native task object returned by start", function()
		local adapter, errors = load_adapter()
		local task = {}
		task.start = function() return task end
		helpers.assert_eq(true, adapter.start(task, "healthy probe"))
		helpers.assert_eq(0, #errors)
	end)

	helpers.it("models the canonical hs.task start return contract", function()
		package.loaded["tests.stubs.hs"] = nil
		local hs_stub = require("tests.stubs.hs")
		local task = hs_stub.task.new("/bin/echo", function() end, { "hello" })
		helpers.assert_not_nil(task, "the canonical task stub must construct a handle")
		helpers.assert_eq(task, task:start(),
			"hs.task:start() must return its accepted task handle, never nil")
	end)

	helpers.it("logs callback throws and preserves successful multi-returns", function()
		local errors = {}
		local logger = helpers.make_logger_stub()
		logger.error = function(_module, fmt, ...)
			local ok, rendered = pcall(string.format, fmt, ...)
			errors[#errors + 1] = ok and rendered or tostring(fmt)
		end
		package.loaded["infra.logger"] = logger
		package.loaded["adapters.task_lifecycle"] = nil
		local lifecycle = require("adapters.task_lifecycle")

		local good = lifecycle.guard_callback(function() return "a", nil, "c" end,
			"good callback")
		local a, b, c = good()
		helpers.assert_eq("a", a)
		helpers.assert_nil(b)
		helpers.assert_eq("c", c)

		local bad = lifecycle.guard_callback(function() error("callback exploded") end,
			"bad callback")
		helpers.assert_eq(false, bad(), "a throwing stream callback must request termination")
		helpers.assert_eq(1, #errors, "the swallowed native exception must reach ERROR")
		helpers.assert_true(errors[1]:find("callback exploded", 1, true) ~= nil,
			"the callback traceback must preserve the cause")
	end)

	helpers.it("native wraps both completion and streaming callbacks before hs.task sees them", function()
		local original_new = hs.task.new
		local captured_done, captured_stream, captured_args
		local native_environment = { HOME = "/Users/tester" }
		local native_task = {
			environment = function()
				local copy = {}
				for key, value in pairs(native_environment) do copy[key] = value end
				return copy
			end,
			setEnvironment = function(self, candidate)
				native_environment = candidate
				return self
			end,
		}
		hs.task.new = function(_path, on_done, on_stream, args)
			captured_done = on_done
			captured_stream = on_stream
			captured_args = args
			return native_task
		end

		local ok, err = xpcall(function()
			local adapter, errors = load_adapter()
			local task = adapter.native("guarded native", "/bin/echo",
				function() error("completion escaped") end,
				function() error("stream escaped") end,
				{ "hello" })
			helpers.assert_eq(native_task, task)
			helpers.assert_eq("hello", captured_args[1])
			helpers.assert_eq(false, captured_done(0, "", ""),
				"a throwing native completion must be contained")
			helpers.assert_eq(false, captured_stream(nil, "chunk", ""),
				"a throwing stream callback must stop streaming without escaping")
			helpers.assert_eq(2, #errors,
				"both native callback failures must reach the central file logger")
		end, debug.traceback)
		hs.task.new = original_new
		if not ok then error(err) end
	end)
end)
