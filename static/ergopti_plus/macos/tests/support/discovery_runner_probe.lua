--- tests/support/discovery_runner_probe.lua

--- ==============================================================================
--- MODULE: Test Discovery Failure Probe
--- DESCRIPTION:
--- Exercises the real runner with controlled empty or incomplete inventories.
--- Only discovery dependencies are replaced; runner reporting and exit remain real.
--- ==============================================================================

local mode = assert(arg[1], "a discovery probe mode is required")
assert(mode == "empty" or mode == "failed" or mode == "refused" or mode == "native-empty",
	"invalid discovery probe mode")
local source = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local root = assert(source:match("^(.*)/tests/support/discovery_runner_probe%.lua$"))

package.loaded.lfs = nil
package.preload.lfs = function()
	if mode == "native-empty" then
		return { dir = function() return function() return nil end end }
	end
	error("controlled unavailable LuaFileSystem", 0)
end

local popen = io.popen
io.popen = function(command, ...)
	if not command:match("^find ") and not command:match("^cmd /c dir ") then
		return popen(command, ...)
	end
	if mode == "refused" then return nil, "controlled discovery refusal" end
	local lines = {}
	if mode == "failed" then
		lines[1] = root .. "/tests/meta/harness/test_runner_fixture_selection.lua"
	end
	return {
		lines = function()
			local index = 0
			return function()
				index = index + 1
				return lines[index]
			end
		end,
		close = function()
			print("DISCOVERY PIPE CLOSED " .. mode)
			if mode == "failed" then return nil, "exit", 23 end
			return true, "exit", 0
		end,
	}
end

arg = {}
dofile(root .. "/tests/run.lua")
