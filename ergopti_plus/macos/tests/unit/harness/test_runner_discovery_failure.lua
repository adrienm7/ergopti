--- tests/unit/harness/test_runner_discovery_failure.lua

--- ==============================================================================
--- MODULE: Test Discovery Failure Regressions
--- DESCRIPTION:
--- Failed enumeration and empty trees must never certify a passing test suite.
--- Child probes retain the real entry point, reporter and process exit boundary.
--- ==============================================================================

local helpers = require("tests.helpers")
local text_utils = require("infra.text_utils")

--- Runs the real entry point against one controlled discovery outcome.
--- @param mode string Discovery failure injected by the probe.
--- @return boolean success True only for process success.
--- @return string output Complete child diagnostic.
local function run_probe(mode)
	local windows = package.config:sub(1, 1) == "\\"
	local function quote(value)
		if not windows then return text_utils.shell_quote(value) end
		assert(not value:find('"', 1, true), "Windows probe paths cannot contain quotes")
		return '"' .. value .. '"'
	end
	local command = quote(os.getenv("LUA") or "lua") .. " "
		.. quote(helpers.driver_root() .. "tests/support/discovery_runner_probe.lua")
		.. " " .. mode .. " 2>&1"
	if windows then command = 'cmd /d /s /c "' .. command .. '"' end
	local pipe = assert(io.popen(command, "r"), "discovery probe must start")
	local output = assert(pipe:read("*a"))
	local closed, _, status = pipe:close()
	return closed == true or status == 0, output
end

helpers.describe("Runner refuses incomplete discovery", function()
	local scenarios = {
		{ mode = "empty", diagnostic = "no test modules discovered" },
		{ mode = "native-empty", diagnostic = "no test modules discovered" },
		{ mode = "failed", diagnostic = "command output did not complete: exit 23" },
		{ mode = "refused", diagnostic = "controlled discovery refusal" },
		{ mode = "group-empty", diagnostic = 'no test modules discovered for group "ui"' },
	}
	for _, scenario in ipairs(scenarios) do
		helpers.it("(discovery-fail-closed) rejects " .. scenario.mode .. " inventories", function()
			local success, output = run_probe(scenario.mode)
			helpers.assert_eq(success, false, "discovery failure must fail the real runner: " .. output)
			helpers.assert_true(output:find(scenario.diagnostic, 1, true) ~= nil,
				"retain the discovery failure reason: " .. output)
			helpers.assert_nil(output:find("[OK] All Lua unit tests passed.", 1, true),
				"an incomplete inventory must never produce the success receipt")
			if scenario.mode == "failed" then
				helpers.assert_true(output:find("DISCOVERY PIPE CLOSED failed", 1, true) ~= nil,
					"a failed enumeration must still release its process handle")
			end
			if scenario.mode == "failed" or scenario.mode == "group-empty" then
				helpers.assert_nil(output:find(">>> Loading", 1, true),
					"incomplete coverage must be rejected before any test module executes")
			end
		end)
	end
end)
