--- adapters/app_launcher.lua

--- ==============================================================================
--- MODULE: AppLauncher Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the AppLauncher port contract defined in
--- static/ergopti_plus/shared/ports/AppLauncher.spec.js. Wraps hs.application and
--- hs.execute to launch applications and query process existence without
--- coupling domain modules to hs-specific APIs.
---
--- FEATURES & RATIONALE:
--- 1. Argument-aware launch: AL_LaunchWithArgs separates executable path from
---    arguments so the adapter can quote them correctly for macOS shell semantics.
--- 2. Boolean process check: AL_IsRunning returns a boolean so callers can branch
---    on process existence without parsing PID integers or catching exceptions.
--- 3. Fire-and-forget semantics: launches do not block waiting for the process.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")

local LOG = "adapters.app_launcher"




-- =========================================
-- =========================================
-- ======= 1/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Launches an application by its executable path or bundle name.
--- @param app_path string Absolute path, bundle ID, or app name recognised by macOS.
function M.AL_Launch(app_path)
	local ok, err = pcall(function()
		hs.application.launchOrFocus(app_path)
	end)
	if not ok then
		Logger.error(LOG, "AL_Launch(): failed to launch %q — %s", tostring(app_path), tostring(err))
	end
end

--- Launches an application with command-line arguments via the macOS shell.
--- @param app_path string Absolute path to the executable.
--- @param args     string Command-line argument string to append.
function M.AL_LaunchWithArgs(app_path, args)
	local ok, err = pcall(function()
		local cmd = string.format("open -a %q --args %s", app_path, tostring(args or ""))
		hs.execute(cmd)
	end)
	if not ok then
		Logger.error(LOG, "AL_LaunchWithArgs(): failed — %s", tostring(err))
	end
end

--- Returns true when at least one process with the given name is running.
--- @param process_name string Process name as shown by the OS task list.
--- @return boolean
function M.AL_IsRunning(process_name)
	local ok, result = pcall(function()
		local app = hs.application.get(process_name)
		return app ~= nil
	end)
	if not ok then
		Logger.error(LOG, "AL_IsRunning(): error checking %q — %s", tostring(process_name), tostring(result))
		return false
	end
	return result == true
end

return M
