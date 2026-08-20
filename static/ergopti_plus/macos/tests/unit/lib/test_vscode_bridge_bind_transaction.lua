--- tests/unit/lib/test_vscode_bridge_bind_transaction.lua

--- ==============================================================================
--- MODULE: VS Code Bridge Bind Transaction Regression Tests
--- DESCRIPTION:
--- Exercises the real bridge lifecycle against native-shaped HTTP server doubles.
--- Every construction, configuration, activation, bind-verification, and teardown
--- boundary must fail closed while retaining the exact cleanup owner for retry.
--- ==============================================================================

local helpers = require("tests.helpers")

local BRIDGE_PORT = 7878
local RESTORED_MODULES = {
	"hs",
	"tests.stubs.hs",
	"infra.logger",
	"infra.vscode_bridge",
}





-- =====================================
-- =====================================
-- ======= 1/ Lifecycle Test Rig =======
-- =====================================
-- =====================================

--- Formats one captured logger invocation without making logging break the test.
--- @param format_value any Log format or value.
--- @param ... any Format arguments.
--- @return string message Formatted message.
local function format_log(format_value, ...)
	if select("#", ...) == 0 then return tostring(format_value) end
	local ok, message = pcall(string.format, tostring(format_value), ...)
	return ok and message or tostring(format_value)
end

--- Counts captured log messages containing one literal fragment.
--- @param messages table Captured messages.
--- @param fragment string Literal fragment.
--- @return number count Match count.
local function count_messages(messages, fragment)
	local count = 0
	for _, message in ipairs(messages) do
		if message:find(fragment, 1, true) then count = count + 1 end
	end
	return count
end

--- Builds one faithful chainable HTTP server with injectable native outcomes.
--- @param behavior table Failure modes and stop sequence.
--- @return table server Native-shaped server double.
local function make_server(behavior)
	local server = {
		desired_port = 0,
		listening_port = 0,
		callback = nil,
		calls = {
			set_port = 0,
			set_callback = 0,
			start = 0,
			get_port = 0,
			stop = 0,
		},
	}

	--- Configures the requested listening port.
	--- @param port number Requested port.
	--- @return table|boolean result Native self or refusal.
	function server:setPort(port)
		self.calls.set_port = self.calls.set_port + 1
		if behavior.set_port == "throw" then error("setPort exploded", 0) end
		if behavior.set_port == "false" then return false end
		self.desired_port = port
		return self
	end

	--- Configures the request callback.
	--- @param callback function Request callback.
	--- @return table|boolean result Native self or refusal.
	function server:setCallback(callback)
		self.calls.set_callback = self.calls.set_callback + 1
		if behavior.set_callback == "throw" then error("setCallback exploded", 0) end
		if behavior.set_callback == "false" then return false end
		self.callback = callback
		return self
	end

	--- Starts the native server and returns the native server object.
	--- @return table|boolean result Native self or refusal.
	function server:start()
		self.calls.start = self.calls.start + 1
		if behavior.start == "throw" then error("start exploded", 0) end
		if behavior.start == "false" then return false end
		if behavior.start ~= "unbound" then self.listening_port = self.desired_port end
		return self
	end

	--- Returns the actual native listening port, not the configured request.
	--- @return number port Native listening port.
	function server:getPort()
		self.calls.get_port = self.calls.get_port + 1
		if behavior.get_port == "throw_once" and self.calls.get_port == 1 then
			error("getPort exploded", 0)
		end
		return self.listening_port
	end

	--- Stops the native server according to the next injected settlement.
	--- @return table|boolean result Native self or refusal.
	function server:stop()
		self.calls.stop = self.calls.stop + 1
		local action = (behavior.stop_sequence or {})[self.calls.stop] or "success"
		if action == "throw" then error("stop exploded", 0) end
		if action == "false" then return false end
		if action ~= "live" then self.listening_port = 0 end
		return self
	end

	return server
end

--- Loads the real bridge with one observable native server factory.
--- @param behavior table Failure modes and stop sequence.
--- @return table fixture Bridge, candidate, counters, and logs.
local function load_fixture(behavior)
	local logs = { debug = {}, info = {}, warn = {}, error = {} }
	local logger = helpers.make_logger_stub()
	for _, level in ipairs({ "debug", "info", "warn", "error" }) do
		local captured_level = level
		logger[level] = function(_module_name, format_value, ...)
			logs[captured_level][#logs[captured_level] + 1] = format_log(format_value, ...)
		end
	end
	package.loaded["infra.logger"] = logger

	local candidate = nil
	local constructor_calls = 0
	local bridge = helpers.load_with_stubs("infra.vscode_bridge", {
		httpserver = {
			new = function()
				constructor_calls = constructor_calls + 1
				if behavior.constructor == "throw" then error("constructor exploded", 0) end
				if behavior.constructor == "nil" then return nil end
				candidate = make_server(behavior)
				return candidate
			end,
		},
	})

	return {
		bridge = bridge,
		candidate = function() return candidate end,
		constructor_calls = function() return constructor_calls end,
		logs = logs,
	}
end

--- Runs assertions with every replaced module and global restored exactly once.
--- @param body function Assertion body.
local function with_restored_runtime(body)
	local saved_hs = _G.hs
	local saved = {}
	for _, name in ipairs(RESTORED_MODULES) do saved[name] = package.loaded[name] end
	local ok, err = xpcall(body, debug.traceback)
	_G.hs = saved_hs
	for _, name in ipairs(RESTORED_MODULES) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

--- Asserts one startup failure is contained, logged, and never published.
--- @param behavior table Failure mode.
--- @param label string Diagnostic label.
--- @return table fixture Loaded fixture.
local function assert_start_failure(behavior, label)
	local fixture = load_fixture(behavior)
	local call_ok, result = xpcall(fixture.bridge.start_server, debug.traceback)
	helpers.assert_true(call_ok, label .. " must not escape the lifecycle boundary")
	helpers.assert_eq(result, false, label .. " must return exact false")
	helpers.assert_true(#fixture.logs.error >= 1, label .. " must emit a contextual error")
	helpers.assert_eq(count_messages(fixture.logs.info, "started successfully"), 0,
		label .. " must not publish a success log")
	return fixture
end





-- ==========================================
-- ==========================================
-- ======= 2/ Transactional Contract ========
-- ==========================================
-- ==========================================

helpers.describe("vscode_bridge HTTP ownership", function()
	helpers.it("HS-014 VS Code bridge server lifecycle is transactional", function()
		with_restored_runtime(function()
			for _, case in ipairs({
				{ label = "nil constructor", behavior = { constructor = "nil" } },
				{ label = "throwing constructor", behavior = { constructor = "throw" } },
				{ label = "throwing setPort", behavior = { set_port = "throw" } },
				{ label = "throwing setCallback", behavior = { set_callback = "throw" } },
				{ label = "refusing setPort", behavior = { set_port = "false" } },
				{ label = "refusing setCallback", behavior = { set_callback = "false" } },
				{ label = "throwing start", behavior = { start = "throw" } },
				{ label = "refusing start", behavior = { start = "false" } },
				{ label = "start self with port zero", behavior = { start = "unbound" } },
				{ label = "throwing getPort", behavior = { get_port = "throw_once" } },
			}) do
				local fixture = assert_start_failure(case.behavior, case.label)
				local candidate = fixture.candidate()
				if candidate then
					helpers.assert_eq(candidate.calls.stop, 1,
						case.label .. " must attempt exact candidate cleanup")
					helpers.assert_true(fixture.bridge.stop_server(),
						case.label .. " successful cleanup must leave no hidden owner")
					helpers.assert_eq(candidate.calls.stop, 1,
						case.label .. " must clear ownership only after proven settlement")
				end
			end

			for _, first_stop in ipairs({ "throw", "false", "live" }) do
				local fixture = assert_start_failure({
					get_port = "throw_once",
					stop_sequence = { first_stop, "success" },
				}, "unverified candidate with " .. first_stop .. " rollback")
				local candidate = fixture.candidate()
				helpers.assert_eq(candidate.calls.stop, 1,
					"failed candidate cleanup must retain the exact first stop attempt")
				helpers.assert_eq(fixture.bridge.stop_server(), true,
					"failed candidate cleanup debt must retry on the same handle")
				helpers.assert_eq(candidate.calls.stop, 2)
				helpers.assert_eq(candidate.listening_port, 0)
			end

			for _, first_stop in ipairs({ "throw", "false", "live" }) do
				local fixture = load_fixture({ stop_sequence = { first_stop, "success" } })
				helpers.assert_eq(fixture.bridge.start_server(), true,
					"the stop retry fixture must first bind the native port")
				local candidate = fixture.candidate()
				helpers.assert_eq(candidate.listening_port, BRIDGE_PORT)
				helpers.assert_eq(fixture.bridge.stop_server(), false,
					first_stop .. " stop must retain exact cleanup ownership")
				helpers.assert_eq(candidate.calls.stop, 1)
				helpers.assert_eq(fixture.bridge.stop_server(), true,
					first_stop .. " stop debt must be retryable on the same handle")
				helpers.assert_eq(candidate.calls.stop, 2)
				helpers.assert_eq(candidate.listening_port, 0)
			end

			local success = load_fixture({})
			helpers.assert_eq(success.bridge.start_server(), true)
			helpers.assert_eq(success.constructor_calls(), 1)
			local candidate = success.candidate()
			helpers.assert_eq(candidate.listening_port, BRIDGE_PORT)
			helpers.assert_eq(candidate.calls.get_port, 1,
				"success must be proven from the actual native listening port")
			helpers.assert_eq(count_messages(success.logs.info, "started successfully"), 1)
			helpers.assert_eq(success.bridge.stop_server(), true)
			helpers.assert_eq(success.bridge.stop_server(), true,
				"an already-settled stop remains an exact idempotent success")
			helpers.assert_eq(candidate.calls.stop, 1)
		end)
	end)
end)
