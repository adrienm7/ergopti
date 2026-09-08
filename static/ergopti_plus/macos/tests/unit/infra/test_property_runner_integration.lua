--- tests/unit/infra/test_property_runner_integration.lua

--- ==============================================================================
--- MODULE: Property Runner Verdict Regressions
--- DESCRIPTION:
--- A failed property must affect the real focused runner's count and exit status.
--- ==============================================================================

local helpers = require("tests.helpers")
local text_utils = require("infra.text_utils")

--- Replays the actual property module in an isolated, bounded child process.
--- @param mode string Success, false property or backend exception.
local function check_verdict(mode)
	local windows = package.config:sub(1, 1) == "\\"
	local function quote(value)
		if not windows then return text_utils.shell_quote(value) end
		assert(not value:find('"', 1, true), "Windows executable and file paths cannot contain quotes")
		return '"' .. value .. '"'
	end
	local command = quote(os.getenv("LUA") or "lua") .. " "
		.. quote(helpers.driver_root() .. "tests/support/property_runner_probe.lua") .. " " .. mode .. " 2>&1"
	if windows then command = 'cmd /d /s /c "' .. command .. '"' end
	local pipe = assert(io.popen(command, "r"), "property probe must start")
	local output = assert(pipe:read("*a"))
	local closed, _, status = pipe:close()
	local code = closed and 0 or status
	local failed = mode ~= "success"
	helpers.assert_eq(code, failed and 1 or 0, output)
	local calls, failed_checks, backend_errors = output:match("PROBE calls=(%d+) failed_checks=(%d+) backend_errors=(%d+)")
	calls = tonumber(calls)
	helpers.assert_true(calls ~= nil and calls >= 14, "exercise the complete property set: " .. output)
	helpers.assert_eq(tonumber(failed_checks), mode == "failure" and 1 or 0)
	helpers.assert_eq(tonumber(backend_errors), mode == "error" and 1 or 0)
	helpers.assert_true(output:find("Passed tests:  " .. tostring(calls - (failed and 1 or 0)), 1, true) ~= nil,
		"property successes must reach the main reporter: " .. output)
	helpers.assert_true(output:find("Failed tests:  " .. (failed and "1" or "0"), 1, true) ~= nil,
		"property failures must reach the main reporter: " .. output)
	if mode == "failure" then
		helpers.assert_true(output:find("predicate returned false", 1, true) ~= nil, "preserve the real property diagnostic")
	elseif mode == "error" then
		helpers.assert_true(output:find("controlled property backend failure", 1, true) ~= nil, "preserve the backend error")
	end
end

helpers.describe("property tests contribute to the runner verdict", function()
	for _, mode in ipairs({ "success", "failure", "error" }) do
		helpers.it("(property-runner-verdict) " .. mode, function()
			check_verdict(mode)
		end)
	end
end)
