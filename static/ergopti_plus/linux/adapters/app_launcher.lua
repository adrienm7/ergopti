--- adapters/app_launcher.lua

--- ==============================================================================
--- MODULE: AppLauncher Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the AppLauncher port contract defined in
--- static/ergopti_plus/_shared/core/ports/AppLauncher.spec.js. Wraps pgrep/nohup
--- to launch applications and query process existence without coupling domain
--- modules to platform-specific APIs.
---
--- FEATURES & RATIONALE:
--- 1. nohup fire-and-forget: launched processes are detached from the parent so
---    they survive if the ergopti daemon exits.
--- 2. Boolean process check: AL_IsRunning wraps pgrep so callers branch on a
---    boolean without parsing PID integers.
--- 3. Argument-aware launch: AL_LaunchWithArgs appends the args string verbatim
---    after the executable path; quoting is the caller's responsibility. The
---    executable path itself is NOT the caller's responsibility — it is one
---    word by contract, so the adapter quotes it through shell_runner.
--- 4. shell_runner quoting: the executable path was interpolated raw into
---    "nohup %s", so a path with a space started the wrong program and a path
---    with a metacharacter ran it; the pgrep probe used string.format("%q"),
---    which emits a DOUBLE-quoted word where $, ` and $( ) remain live.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Shell  = require("adapters.shell_runner")

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
		Shell.run(string.format("nohup %s >/dev/null 2>&1 &", Shell.quote(app_path)))
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
		-- args stays verbatim by contract: callers pass a ready-made argument
		-- string ("--new-window -e echo hi") that quoting would collapse into
		-- one meaningless argument.
		local cmd = string.format("nohup %s %s >/dev/null 2>&1 &",
			Shell.quote(app_path), tostring(args or ""))
		Shell.run(cmd)
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
		return Shell.run(
			string.format("pgrep -x %s >/dev/null 2>&1", Shell.quote(process_name)))
	end)
	if not ok then
		Logger.error(LOG, "AL_IsRunning(): error checking %q — %s",
			process_name, tostring(result))
		return false
	end
	return result == true
end

return M
