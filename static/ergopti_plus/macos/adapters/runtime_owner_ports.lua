--- adapters/runtime_owner_ports.lua

--- ==============================================================================
--- MODULE: Owned Runtime Ports (Hammerspoon)
--- DESCRIPTION:
--- The real Mac side of platform/remap/runtime_owner.lua: file existence,
--- read-only launchd and system extension queries, a count of other active
--- Karabiner processes, and the spawn of the owned Console process. Only
--- required when the user opts in to the owned runtime.
---
--- FEATURES & RATIONALE:
--- 1. Read-Only Observation: launchd is only ever asked to print a job and the
---    system extension tool only to list; the privileged jobs belong to the
---    installer.
--- 2. Stock Karabiner Is Counted, Never Touched: the coexistence port detects
---    the official application by name and binds no closer. The owner therefore
---    reports an explicit unavailable state instead of quitting a user's own
---    Karabiner until a reviewed closer exists.
--- 3. Artifact Not Shipped: no pinned runtime manifest exists yet (WP5), so the
---    artifact port says so, and the owner stays unavailable with that reason
---    rather than guessing a driver version or a capture executable.
--- 4. One Command Runner: bounded commands reuse the field check's runner.
--- ==============================================================================

local M = {}

local FileSystem = require("adapters.file_system")
local FieldCheckPorts = require("adapters.field_check_ports")
local ShellRunner = require("adapters.shell_runner")

-- Seconds an observation may take before it is a failure rather than an answer.
local COMMAND_TIMEOUT = 5
-- launchctl's exit status for a service that is not loaded.
local UNKNOWN_SERVICE_STATUS = 113

--- Counts the non-empty lines of a command output.
--- @param text any Command output.
--- @return integer
local function count_lines(text)
	local count = 0
	for line in tostring(text or ""):gmatch("[^\r\n]+") do
		if line:match("%S") then count = count + 1 end
	end
	return count
end

--- The ports of the real Mac.
--- @return table ports For platform.remap.runtime_owner.init.
function M.new()
	local exec = FieldCheckPorts.exec
	return {
		fs = {
			exists = FileSystem.exists,
			expand = FileSystem.expand_path,
		},
		launchd = {
			loaded = function(label, callback)
				exec("/bin/launchctl", { "print", "system/" .. label }, COMMAND_TIMEOUT, function(code)
					if code == 0 then return callback(true) end
					if code == UNKNOWN_SERVICE_STATUS then return callback(false) end
					callback(nil)
				end)
			end,
		},
		system_extensions = {
			listing = function(callback)
				exec("/usr/sbin/systemextensionsctl", { "list" }, COMMAND_TIMEOUT, function(code, output)
					callback(code == 0 and output or nil)
				end)
			end,
		},
		coexistence = {
			detect = function(callback)
				exec("/usr/bin/pgrep", { "-f", "Karabiner-Elements" }, COMMAND_TIMEOUT, function(code, output)
					-- pgrep exits 1 when nothing matches; a timeout or any other status is unknown.
					if code == 0 then return callback(count_lines(output)) end
					callback(code == 1 and 0 or nil)
				end)
			end,
		},
		process = {
			owner_pid = function() return hs.processInfo.processID end,
			spawn = function(executable, arguments, environment, on_exit)
				return ShellRunner.spawn(executable, arguments, function(code) on_exit(code) end, nil, environment)
			end,
		},
		artifact = {
			pinned = function()
				return nil, "no runtime artifact manifest ships with this build"
			end,
		},
	}
end

return M
