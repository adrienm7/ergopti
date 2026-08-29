--- tests/unit/adapters/test_task_environment_sanitization.lua

--- ==============================================================================
--- MODULE: Native task environment sanitization regression tests
--- DESCRIPTION:
--- Proves that every asynchronous child loses the launcher-only logger authority
--- before native start. Both production task construction owners are exercised;
--- a refused environment rewrite must fail closed without launching the child.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===========================================================
-- ===========================================================
-- ======= 1/ Faithful Native Task Double ====================
-- ===========================================================
-- ===========================================================

local MANAGED_KEYS = {
	"ERGOPTI_LAUNCHER_PID",
	"ERGOPTI_LAUNCHER_BUNDLE_ID",
	"ERGOPTI_LOG_PORT",
	"ERGOPTI_LOG_TOKEN",
}

local function copy_table(source)
	local result = {}
	for key, value in pairs(source or {}) do result[key] = value end
	return result
end

local function make_task_factory(set_result)
	local state = {
		starts = 0,
		start_environment = nil,
		set_calls = 0,
	}
	local task_environment = {
		HOME = "/Users/tester",
		PATH = "/usr/bin:/bin",
		ERGOPTI_LAUNCHER_PID = "321",
		ERGOPTI_LAUNCHER_BUNDLE_ID = "com.ergopti.launcher",
		ERGOPTI_LOG_PORT = "42424",
		ERGOPTI_LOG_TOKEN = "secret-transport-token",
	}
	local task = {}

	function task:environment()
		return copy_table(task_environment)
	end

	function task:setEnvironment(candidate)
		state.set_calls = state.set_calls + 1
		if set_result == "throw" then error("synthetic environment refusal") end
		if set_result == false then return false end
		if set_result == "nil" then return nil end
		if set_result == "ignore" then return self end
		task_environment = copy_table(candidate)
		return self
	end

	function task:start()
		state.starts = state.starts + 1
		state.start_environment = copy_table(task_environment)
		return self
	end

	function task:terminate() return self end

	return function() return task end, state
end

local function assert_sanitized_start(state)
	helpers.assert_eq(1, state.set_calls,
		"the child environment must be rewritten exactly once before start")
	helpers.assert_eq(1, state.starts)
	helpers.assert_eq("/Users/tester", state.start_environment.HOME)
	helpers.assert_eq("/usr/bin:/bin", state.start_environment.PATH)
	for _, key in ipairs(MANAGED_KEYS) do
		helpers.assert_nil(state.start_environment[key],
			key .. " is launcher-only authority and must not reach a child")
	end
end





-- ===========================================================
-- ===========================================================
-- ======= 2/ Production Construction Owners ================
-- ===========================================================
-- ===========================================================

helpers.describe("native task environment: launcher authority never reaches children", function()
	helpers.it("owns one exact launcher-only key list and preserves ordinary variables", function()
		package.loaded["infra.launcher_environment"] = nil
		local policy = require("infra.launcher_environment")
		local sanitized, detail = policy.child_copy({
			HOME = "/Users/tester",
			ERGOPTI_LAUNCHER_PID = "321",
			ERGOPTI_LAUNCHER_BUNDLE_ID = "com.ergopti.launcher",
			ERGOPTI_LOG_PORT = "42424",
			ERGOPTI_LOG_TOKEN = "secret-transport-token",
		})
		helpers.assert_nil(detail)
		helpers.assert_eq("/Users/tester", sanitized.HOME)
		for _, key in ipairs(MANAGED_KEYS) do helpers.assert_nil(sanitized[key]) end
		local keys = policy.managed_keys()
		helpers.assert_eq(#MANAGED_KEYS, #keys)
		for index, key in ipairs(MANAGED_KEYS) do helpers.assert_eq(key, keys[index]) end
	end)

	helpers.it("sanitizes ShellRunner children before native start", function()
		local factory, state = make_task_factory(true)
		local ShellRunner = helpers.load_with_stubs("adapters.shell_runner", {
			task = { new = factory },
		})
		local handle = ShellRunner.spawn("/usr/bin/true", {}, function() end)
		helpers.assert_true(handle.start())
		assert_sanitized_start(state)
	end)

	helpers.it("sanitizes TaskLifecycle children before native start", function()
		local factory, state = make_task_factory(true)
		local saved_hs = rawget(_G, "hs")
		local saved_logger = package.loaded["infra.logger"]
		local saved_lifecycle = package.loaded["adapters.task_lifecycle"]
		_G.hs = { task = { new = factory } }
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["adapters.task_lifecycle"] = nil

		local ok, err = xpcall(function()
			local lifecycle = require("adapters.task_lifecycle")
			local task = lifecycle.native("environment probe", "/usr/bin/true",
				function() end, {})
			helpers.assert_not_nil(task)
			helpers.assert_true(lifecycle.start(task, "environment probe"))
			assert_sanitized_start(state)
		end, debug.traceback)

		_G.hs = saved_hs
		package.loaded["infra.logger"] = saved_logger
		package.loaded["adapters.task_lifecycle"] = saved_lifecycle
		if not ok then error(err) end
	end)

	for _, case in ipairs({
		{ label = "false", result = false },
		{ label = "nil", result = "nil" },
		{ label = "throw", result = "throw" },
		{ label = "success without readback", result = "ignore" },
	}) do
		helpers.it("refuses ShellRunner start when sanitization returns " .. case.label, function()
			local factory, state = make_task_factory(case.result)
			local ShellRunner = helpers.load_with_stubs("adapters.shell_runner", {
				task = { new = factory },
			})
			local handle = ShellRunner.spawn("/usr/bin/true", {}, function() end)
			helpers.assert_eq(false, handle.start())
			helpers.assert_eq(0, state.starts,
				"an unsanitized child must never cross the native start boundary")
		end)
	end

	helpers.it("refuses TaskLifecycle construction after a silent native non-write", function()
		local factory, state = make_task_factory("ignore")
		local saved_hs = rawget(_G, "hs")
		local saved_logger = package.loaded["infra.logger"]
		local saved_lifecycle = package.loaded["adapters.task_lifecycle"]
		_G.hs = { task = { new = factory } }
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["adapters.task_lifecycle"] = nil

		local ok, err = xpcall(function()
			local lifecycle = require("adapters.task_lifecycle")
			helpers.assert_nil(lifecycle.native("environment refusal", "/usr/bin/true",
				function() end, {}))
			helpers.assert_eq(0, state.starts)
		end, debug.traceback)

		_G.hs = saved_hs
		package.loaded["infra.logger"] = saved_logger
		package.loaded["adapters.task_lifecycle"] = saved_lifecycle
		if not ok then error(err) end
	end)
end)
