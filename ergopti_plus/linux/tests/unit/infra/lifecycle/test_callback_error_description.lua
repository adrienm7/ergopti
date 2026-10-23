--- tests/unit/infra/lifecycle/test_callback_error_description.lua
--- ==============================================================================
--- MODULE: Callback Error Description Regression Tests
--- DESCRIPTION:
--- Checks pure shared diagnostic text and registers each genuine native callback
--- failure/control as an isolated child. No timer backend or clock is simulated.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("linux-callback-error-description", function()
	for _, case in ipairs({ { name = "string", value = "ordinary callback error" },
		{ name = "empty string", value = "" }, { name = "integer", value = 42 },
		{ name = "fraction", value = -0.125 }, { name = "false", value = false },
		{ name = "true", value = true }, { name = "nil" } }) do
		helpers.it("linux-callback-error-description: preserves " .. case.name .. " text", function()
			local policy = require("error_description")
			helpers.assert_eq(policy.describe(case.value), tostring(case.value))
		end)
	end
	for _, throwing in ipairs({ false, true }) do
		helpers.it("linux-callback-error-description: never runs a " .. (throwing and "throwing" or "successful") .. " object formatter", function()
			local policy = require("error_description")
			local calls = 0
			local failure = setmetatable({}, { __tostring = function()
				calls = calls + 1
				if throwing then error("owned formatter failure") end
				return "custom failure details"
			end })
			helpers.assert_eq(policy.describe(failure), "error object (table)")
			helpers.assert_eq(calls, 0, "reporting must not invoke foreign formatting code")
		end)
	end
	helpers.it("linux-callback-error-description: describes functions and threads without invocation", function()
		local policy = require("error_description")
		local calls = 0
		local function failure() calls = calls + 1 end
		helpers.assert_eq(policy.describe(failure), "error object (function)")
		helpers.assert_eq(policy.describe(coroutine.create(failure)), "error object (thread)")
		helpers.assert_eq(calls, 0)
	end)
	helpers.it("linux-callback-error-description: describes actual userdata by type", function()
		local policy = require("error_description")
		local file = assert(io.tmpfile())
		local description = policy.describe(file)
		assert(file:close())
		helpers.assert_eq(description, "error object (userdata)")
	end)
	local native_ok = pcall(require, "luv")
	if native_ok and package.config:sub(1, 1) == "/" then
		for _, kind in ipairs({ "object", "string" }) do
			helpers.it("linux-callback-error-description: completed " .. kind .. " callback retires an overdue watchdog", function()
				local executable = assert(arg and arg[-1], "running Lua interpreter must be identifiable")
				local fixture = helpers.driver_root() .. "/tests/fixtures/native_callback_error_description.lua"
				local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
				local result = os.execute(quote(executable) .. " " .. quote(fixture) .. " after " .. quote(kind) .. " blocked_callback")
				helpers.assert_true(result == true or result == 0,
					"the actual successful sibling must acknowledge watchdog retirement before stopping the loop")
			end)
		end
		for _, kind in ipairs({ "object", "string" }) do
			helpers.it("linux-callback-error-description: slow setup preserves the " .. kind .. " callback watchdog budget", function()
				local executable = assert(arg and arg[-1], "running Lua interpreter must be identifiable")
				local fixture = helpers.driver_root() .. "/tests/fixtures/native_callback_error_description.lua"
				local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
				local result = os.execute(quote(executable) .. " " .. quote(fixture) .. " after "
					.. quote(kind) .. " blocked_callback delayed_setup")
				helpers.assert_true(result == true or result == 0,
					"setup before loop admission must not spend the actual callback watchdog budget")
			end)
		end
		for _, scenario in ipairs({ "after", "every", "idle", "periodic", "registered idle", "deferred" }) do
			for _, kind in ipairs({ "object", "string" }) do
				helpers.it("linux-callback-error-description: actual " .. scenario .. " isolates " .. kind .. " failure", function()
					local executable = assert(arg and arg[-1], "running Lua interpreter must be identifiable")
					local fixture = helpers.driver_root() .. "/tests/fixtures/native_callback_error_description.lua"
					local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
					local result = os.execute(quote(executable) .. " " .. quote(fixture)
						.. " " .. quote(scenario) .. " " .. quote(kind))
					helpers.assert_true(result == true or result == 0,
						"actual native callback isolation, continuation and resource assertions must succeed")
				end)
			end
		end
	end
end)

helpers.describe("linux-http-callback-error-description", function()
	--- Loads the curl engine with a recording logger.
	--- @return table client, table logs Formatted error lines.
	local function recorded_client()
		local logs = {}
		local logger = helpers.make_logger_stub()
		logger.error = function(_, message, ...) logs[#logs + 1] = string.format(message, ...) end
		local previous_logger, previous_client = package.loaded["logger.shim"], package.loaded["adapters.curl_http_client"]
		package.loaded["logger.shim"], package.loaded["adapters.curl_http_client"] = logger, nil
		local loaded, client = pcall(require, "adapters.curl_http_client")
		package.loaded["logger.shim"], package.loaded["adapters.curl_http_client"] = previous_logger, previous_client
		if not loaded then error(client, 0) end
		return client, logs
	end
	for _, throwing in ipairs({ false, true }) do
		helpers.it("linux-http-callback-error-description: a refused request reports a " .. (throwing and "throwing" or "successful")
			.. " formatter object without running it", function()
			local client, logs = recorded_client()
			local formatted, delivered = 0, 0
			local failure = setmetatable({}, { __tostring = function()
				formatted = formatted + 1
				if throwing then error("owned formatter failure") end
				return "private callback details"
			end })
			local called, dispatched = pcall(client.post, "https://example.invalid/\0refused", {}, "",
				function(result)
					delivered = delivered + 1
					helpers.assert_eq(result.ok, false)
					error(failure)
				end)
			helpers.assert_true(called, "a caller's failing callback cannot escape the refusal boundary: " .. tostring(dispatched))
			helpers.assert_eq(dispatched, false)
			helpers.assert_eq(delivered, 1)
			helpers.assert_eq(formatted, 0, "reporting must not invoke foreign formatting code")
			helpers.assert_eq(logs[#logs], "HTTP rejection callback raised: error object (table).")
		end)
	end
	helpers.it("linux-http-callback-error-description: a string failure keeps its text", function()
		local client, logs = recorded_client()
		helpers.assert_eq(client.post("https://example.invalid/\0refused", {}, "", function() error("plain failure", 0) end), false)
		helpers.assert_eq(logs[#logs], "HTTP rejection callback raised: plain failure.")
	end)
end)
