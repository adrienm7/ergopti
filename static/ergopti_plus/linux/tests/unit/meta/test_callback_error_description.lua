--- tests/unit/meta/test_callback_error_description.lua
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
