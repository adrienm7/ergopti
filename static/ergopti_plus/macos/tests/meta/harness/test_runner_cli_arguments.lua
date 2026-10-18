--- tests/meta/harness/test_runner_cli_arguments.lua

--- ==============================================================================
--- MODULE: Runner CLI Argument Admission
--- DESCRIPTION:
--- A real subprocess runs the production CLI over at most two fixture modules.
--- Missing values and unsupported arguments must fail before discovery, while
--- documented exact-module, group and historical case filters remain usable.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Quotes one process argument for the selected host shell.
--- @param value string Literal argument.
--- @return string quoted Shell argument.
local function quote(value)
	if package.config:sub(1, 1) == "\\" then return '"' .. value:gsub('"', '""') .. '"' end
	return "'" .. value:gsub("'", "'\\''") .. "'"
end

--- Runs actual argument admission with bounded discovery ports in a new process.
--- @param arguments string[] CLI arguments after tests/run.lua.
--- @return boolean success Actual child exit success.
--- @return string output Combined child diagnostics.
--- @return integer|nil status Actual child exit status.
local function run(arguments)
	local root = helpers.driver_root():gsub("[/\\]$", "")
	local command = { quote(os.getenv("LUA") or "lua"),
		quote(root .. "/tests/support/runner_cli_child.lua"), quote(root) }
	for _, value in ipairs(arguments) do command[#command + 1] = quote(value) end
	local pipe = assert(io.popen(table.concat(command, " ") .. " 2>&1", "r"))
	local output = pipe:read("*a")
	local closed, _, status = pipe:close()
	return closed == true or status == 0, output, status
end

helpers.describe("runner CLI refuses incomplete or unknown selection", function()
	for _, arguments in ipairs({
		{ "--only=tests.meta.test_cli_alpha", "--module" },
		{ "--only=" },
		{ "--only" },
		{ "--module=" },
		{ "--module" },
		{ "--only", "--module=meta" },
		{ "--module", "--only=alpha" },
		{ "--group=meta" },
		{ "--onyl=alpha" },
		{ "unexpected-positional" },
	}) do
		helpers.it("rejects invalid runner arguments: " .. table.concat(arguments, " | "), function()
			local success, output, status = run(arguments)
			helpers.assert_eq(success, false, output)
			helpers.assert_eq(status, 2, output)
			helpers.assert_true(output:find("tests/run.lua:", 1, true) ~= nil, output)
			helpers.assert_nil(output:find("CLI_DISCOVERY", 1, true), output)
			helpers.assert_nil(output:find("CLI_EXECUTED", 1, true), output)
		end)
	end
	for _, arguments in ipairs({
		{ "--only=tests.meta.test_cli_alpha" },
		{ "--only", "tests.meta.test_cli_alpha" },
		{ "--only=tests/meta/test_cli_alpha.lua" },
		{ "--module=meta" },
		{ "--module", "meta" },
		{ "--module=meta", "--only=alpha sentinel" },
		{ "--only", "beta sentinel" },
	}) do
		helpers.it("preserves valid runner arguments: " .. table.concat(arguments, " | "), function()
			local success, output = run(arguments)
			helpers.assert_true(success, output)
			helpers.assert_true(output:find("Passed tests:  1", 1, true) ~= nil, output)
			helpers.assert_true(output:find("Failed tests:  0", 1, true) ~= nil, output)
			local _, executions = output:gsub("CLI_EXECUTED", "")
			helpers.assert_true(executions >= 1 and executions <= 2, output)
		end)
	end
end)
