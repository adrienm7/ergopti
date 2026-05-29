--- linux/adapters/app_launcher.lua

--- ==============================================================================
--- MODULE: AppLauncher Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the AppLauncher port contract defined in
--- static/ergopti_plus/shared/ports/AppLauncher.spec.js. Wraps pgrep/nohup
--- to launch applications and query process existence without coupling domain
--- modules to platform-specific APIs.
---
--- FEATURES & RATIONALE:
--- 1. nohup fire-and-forget: launched processes are detached from the parent so
---    they survive if the ergopti daemon exits.
--- 2. Boolean process check: AL_IsRunning wraps pgrep so callers branch on a
---    boolean without parsing PID integers.
--- 3. Argument-aware launch: AL_LaunchWithArgs appends the args string verbatim
---    after the executable path; quoting is the caller's responsibility.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "adapters.app_launcher"




-- =========================================
-- =========================================
-- ======= 1/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Launches an application by its executable path or name via nohup.
--- @param app_path string Absolute path or name resolvable via PATH.
function M.AL_Launch(app_path)
	if type(app_path) ~= "string" or app_path == "" then
		Logger.warn(LOG, "AL_Launch(): empty app_path — ignored.")
		return
	end
	local ok, err = pcall(function()
		os.execute(string.format("nohup %s >/dev/null 2>&1 &", app_path))
	end)
	if not ok then
		Logger.error(LOG, "AL_Launch(): failed to launch %q — %s", app_path, tostring(err))
	end
end

--- Launches an application with command-line arguments.
--- @param app_path string Absolute path to the executable.
--- @param args     string Command-line argument string to append.
function M.AL_LaunchWithArgs(app_path, args)
	if type(app_path) ~= "string" or app_path == "" then
		Logger.warn(LOG, "AL_LaunchWithArgs(): empty app_path — ignored.")
		return
	end
	local ok, err = pcall(function()
		local cmd = string.format("nohup %s %s >/dev/null 2>&1 &",
			app_path, tostring(args or ""))
		os.execute(cmd)
	end)
	if not ok then
		Logger.error(LOG, "AL_LaunchWithArgs(): failed — %s", tostring(err))
	end
end

--- Returns true when at least one process with the given name is running.
--- @param process_name string Process name as shown by pgrep.
--- @return boolean
function M.AL_IsRunning(process_name)
	if type(process_name) ~= "string" or process_name == "" then return false end
	local ok, result = pcall(function()
		local code = os.execute(
			string.format("pgrep -x %q >/dev/null 2>&1", process_name))
		-- os.execute returns true/0 on success in Lua 5.2+ (LuaJIT compat: integer)
		return code == true or code == 0
	end)
	if not ok then
		Logger.error(LOG, "AL_IsRunning(): error checking %q — %s",
			process_name, tostring(result))
		return false
	end
	return result == true
end

return M
