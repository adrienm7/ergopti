--- adapters/app_launcher.lua

--- ==============================================================================
--- MODULE: AppLauncher Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the AppLauncher port contract defined in
--- static/ergopti_plus/_shared/core/ports/AppLauncher.spec.js. Wraps hs.application and
--- hs.execute to launch applications and query process existence without
--- coupling domain modules to hs-specific APIs.
---
--- FEATURES & RATIONALE:
--- 1. Argument-aware launch: launchWithArgs separates executable path from
---    arguments and passes them directly to the asynchronous native task.
--- 2. Boolean process check: isRunning returns a boolean so callers can branch
---    on process existence without parsing PID integers or catching exceptions.
--- 3. Fire-and-forget semantics: launches do not block waiting for the process.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("core.logger.engine.logger")
local ShellRunner = require("core.process.adapters.shell_runner")
local RunningApplication = require("platform.focus.running_application")

local LOG = "adapters.app_launcher"




-- =========================================
-- =========================================
-- ======= 1/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Launches an application by its executable path or bundle name.
--- @param app_path string Absolute path, bundle ID, or app name recognised by macOS.
--- @return boolean True when Hammerspoon accepted the launch/focus request.
function M.launch(app_path)
	local ok, result = pcall(function()
		if hs.application.launchOrFocus(app_path) == true then return true end
		-- Bundle identifiers use a separate Hammerspoon API from names/paths.
		if type(hs.application.launchOrFocusByBundleID) ~= "function" then return false end
		return hs.application.launchOrFocusByBundleID(app_path) == true
	end)
	local err = result
	if not ok then
		Logger.error(LOG, "launch(): failed to launch %q — %s", tostring(app_path), tostring(err))
	end
	return ok and result == true
end

--- Launches an application with command-line arguments without blocking the run loop.
--- The shared task runner owns the native process until its completion callback.
--- @param app_path string Absolute path to the executable.
--- @param args string|table Single argument or list of arguments.
function M.launchWithArgs(app_path, args)
	local ok, err = pcall(function()
		local argv = { "-a", tostring(app_path), "--args" }
		if type(args) == "table" then
			for _, value in ipairs(args) do argv[#argv + 1] = tostring(value) end
		else
			argv[#argv + 1] = tostring(args or "")
		end
		local handle = ShellRunner.spawn("/usr/bin/open", argv, function(exit_code)
			if exit_code ~= 0 then
				Logger.error(LOG, "launchWithArgs(): open exited with status %s.", tostring(exit_code))
			end
		end)
		if handle.start() ~= true then error("open task did not start") end
	end)
	if not ok then
		Logger.error(LOG, "launchWithArgs(): failed — %s", tostring(err))
	end
end

--- Returns true when at least one process with the given name is running.
--- @param process_name string Process name as shown by the OS task list.
--- @return boolean
function M.isRunning(process_name)
	local ok, result = pcall(function()
		-- Never hs.application.get: for a process that is not running it searches
		-- every window of every application on the main thread.
		local app = RunningApplication.by_name(process_name)
		return app ~= nil
	end)
	if not ok then
		Logger.error(LOG, "isRunning(): error checking %q — %s", tostring(process_name), tostring(result))
		return false
	end
	return result == true
end

return M
