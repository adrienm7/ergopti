--- tests/support/release_swap_ports.lua

--- ==============================================================================
--- MODULE: Release Swap Native Observation Port
--- DESCRIPTION:
--- Keeps real Darwin stat in native runs and maps its device argv to actual
--- host metadata on Linux. File moves, directories and failures stay physical.
--- ==============================================================================

local M = {}

--- Returns the explicit test-only native rename port, never a production fallback.
--- @return string command Shell-quoted command retaining actual host syscalls.
function M.command()
	local quote = require("infra.text_utils").shell_quote
	return "python3 -B " .. quote(require("tests.helpers").driver_root() .. "tests/support/release_rename_physical_port.py")
end

--- Adapts only Darwin stat's command-line syntax for the portable Lua suite.
--- @param script string Actual emitted swap program.
--- @param dir string Exact scenario-owned directory for the executable port.
--- @return string script Program retaining the production filesystem checks.
function M.observe(script, dir)
	local quote = require("infra.text_utils").shell_quote
	local executable = dir .. "/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus"
	assert(os.execute("mkdir -p " .. quote(dir .. "/ErgoptiPlus.app/Contents/MacOS")))
	local launcher = assert(io.open(executable, "wb"))
	assert(launcher:write("#!/bin/sh\nexec " .. M.command() .. ' "$@"\n'))
	assert(launcher:close())
	assert(os.execute("chmod 700 " .. quote(executable)))
	local pipe = assert(io.popen("uname -s"))
	local host = assert(pipe:read("*l"))
	assert(pipe:close())
	if host == "Darwin" then return script end
	assert(host == "Linux", "Release swap physical controls require a POSIX host")
	local path = dir .. "/device-observer"
	local probe = require("tests.helpers").driver_root() .. "tests/support/release_swap_physical_probe.py"
	local file = assert(io.open(path, "wb"))
	assert(file:write("#!/bin/sh\nexec python3 -B " .. quote(probe) .. ' stat "$@"\n'))
	assert(file:close())
	assert(os.execute("chmod 700 " .. quote(path)))
	return (script:gsub("/usr/bin/stat", function() return quote(path) end))
end

return M
