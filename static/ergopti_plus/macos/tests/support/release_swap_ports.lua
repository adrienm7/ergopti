--- tests/support/release_swap_ports.lua

--- ==============================================================================
--- MODULE: Release Swap Native Observation Port
--- DESCRIPTION:
--- Keeps real Darwin stat in native runs and maps its device argv to actual
--- host metadata on Linux. File moves, directories and failures stay physical.
--- ==============================================================================

local M = {}

--- Adapts only Darwin stat's command-line syntax for the portable Lua suite.
--- @param script string Actual emitted swap program.
--- @param dir string Exact scenario-owned directory for the executable port.
--- @return string script Program retaining the production filesystem checks.
function M.observe(script, dir)
	local pipe = assert(io.popen("uname -s"))
	local host = assert(pipe:read("*l"))
	assert(pipe:close())
	if host == "Darwin" then return script end
	assert(host == "Linux", "Release swap physical controls require a POSIX host")
	local quote = require("infra.text_utils").shell_quote
	local path = dir .. "/device-observer"
	local probe = require("tests.helpers").driver_root() .. "tests/support/release_swap_physical_probe.py"
	local file = assert(io.open(path, "wb"))
	assert(file:write("#!/bin/sh\nexec python3 -B " .. quote(probe) .. ' stat "$@"\n'))
	assert(file:close())
	assert(os.execute("chmod 700 " .. quote(path)))
	return (script:gsub("/usr/bin/stat", function() return quote(path) end))
end

return M
