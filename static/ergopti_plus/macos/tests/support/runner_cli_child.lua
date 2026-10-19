--- tests/support/runner_cli_child.lua

--- ==============================================================================
--- MODULE: Bounded Runner CLI Child
--- DESCRIPTION:
--- Executes the actual runner in a fresh process with two synthetic modules.
--- Discovery and reporting are ports; argument parsing, selection and process
--- exit remain production code. An invalid CLI can never start the real suite.
--- ==============================================================================

local root = assert(arg[1], "driver root required")
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
local actual_require = require
local selector = actual_require("tests.support.only_selector")
local groups = actual_require("tests.support.module_groups")
local arguments = {}
for index = 2, #arg do arguments[index - 1] = arg[index] end
local result = { passed = 0, failed = 0, failures = {} }
local filter
local reporter = {
	initialize_timing = function() end,
	reset_results = function() end,
	get_results = function() return result end,
	timing_failed = function() return false end,
	set_only_filter = function(value) filter = value end,
	measure_module = function(name, callback)
		print("CLI_EXECUTED " .. name)
		return pcall(callback)
	end,
}
local filesystem = {
	dir = function(path)
		print("CLI_DISCOVERY " .. path)
		local name = path:match("/tests/meta$") and "test_cli_alpha.lua" or "test_cli_beta.lua"
		local delivered = false
		return function()
			if delivered then return nil end
			delivered = true
			return name
		end
	end,
	attributes = function() return { mode = "file" } end,
}
local ports = {
	["tests.helpers"] = reporter,
	["text_utils"] = { shell_quote = function(value) return value end },
	["tests.support.module_isolation"] = { purge = function() end },
	["tests.support.only_selector"] = selector,
	["tests.support.module_groups"] = groups,
	["tests.support.command_lines"] = {},
	["tests.stubs.hs"] = {},
	["lfs"] = filesystem,
}
local cases = {
	["tests.meta.test_cli_alpha"] = "alpha sentinel",
	["tests.unit.test_cli_beta"] = "beta sentinel",
}
local environment = setmetatable({
	arg = arguments,
	_G = {},
	package = { path = package.path, config = package.config },
	require = function(name)
		if ports[name] then return ports[name] end
		local case = assert(cases[name], "unexpected fixture module: " .. name)
		if not filter or case:find(filter, 1, true) then result.passed = result.passed + 1 end
		return true
	end,
}, { __index = _G })
assert(loadfile(root .. "/tests/run.lua", "t", environment))()
