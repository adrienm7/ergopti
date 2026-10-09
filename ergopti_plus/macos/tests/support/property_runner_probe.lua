--- tests/support/property_runner_probe.lua

--- ==============================================================================
--- MODULE: Property Runner Integration Probe
--- DESCRIPTION:
--- Exercises real runner verdicts with bounded successful or failing properties.
--- ==============================================================================

local mode = assert(arg[1], "a probe mode is required")
assert(mode == "success" or mode == "failure" or mode == "error", "invalid probe mode")
local source = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local root = assert(source:match("^(.*)/tests/support/property_runner_probe%.lua$"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
	.. root .. "/../_shared/lua/?.lua;" .. root .. "/../_shared/lua/?/init.lua;" .. package.path

local pbt = require("tests.lib.pbt")
local check = pbt.check
local calls, failed_checks, backend_errors = 0, 0, 0
pbt.check = function(label)
	calls = calls + 1
	if mode == "error" and calls == 1 then
		backend_errors = backend_errors + 1
		error("controlled property backend failure")
	end
	local result = check(label, { generate = function() return nil end }, function()
		return mode ~= "failure" or calls ~= 1
	end, { runs = 1, seed = 42 })
	if not result then failed_checks = failed_checks + 1 end
	return result
end

-- Keep the real runner's exit verdict, checking probe receipts before forwarding it.
local exit = os.exit
local marker, exit_code = {}, nil
os.exit = function(code) exit_code = code; error(marker, 0) end
arg = { "--only", "tests/unit/modules/keymap/test_hotstring_properties.lua" }
local ok, reason = pcall(dofile, root .. "/tests/run.lua")
os.exit = exit
assert(not ok and reason == marker, "the real runner must reach its terminal boundary")
print(string.format("PROBE calls=%d failed_checks=%d backend_errors=%d", calls, failed_checks, backend_errors))
exit(exit_code)
