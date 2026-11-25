--- apps/adapters/launcher.lua

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
--- 4. Program names only: a launch, a refusal and a failure are logged with the
---    program's name or URI scheme, never the full target or its arguments,
---    which can name a user document or carry a search (as AL_ProgramName on
---    Windows).
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("core.logger.engine.logger")
local ShellRunner = require("core.process.adapters.shell_runner")
local RunningApplication = require("platform.focus.running_application")

local LOG = "apps.adapters.launcher"




-- =========================================
-- =========================================
-- ======= 1/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Names what is being launched without exposing its arguments or directory.
--- @param target any Path, bundle ID, application name or URI.
--- @return string The base name, the URI scheme followed by ":", or "unknown".
function M.program_name(target)
	local text = tostring(target or ""):gsub('^[%s"]+', ""):gsub('[%s"]+$', "")
	-- A URI (https:, x-apple.systempreferences:) is named by its scheme: the rest can be a query.
	local scheme = text:match("^([A-Za-z][A-Za-z0-9+.-]+):")
	if scheme then return scheme .. ":" end
	local name = text:gsub("/+$", ""):match("([^/]+)$")
	return (name ~= nil and name ~= "") and name or "unknown"
end

--- Replaces every literal occurrence of a value in a text.
--- @param text string
--- @param literal string Non-empty value to hide.
--- @param replacement string
--- @return string
local function replace_literal(text, literal, replacement)
	local out, from = {}, 1
	while true do
		local at, last = text:find(literal, from, true)
		if not at then break end
		out[#out + 1] = text:sub(from, at - 1) .. replacement
		from = last + 1
	end
	out[#out + 1] = text:sub(from)
	return table.concat(out)
end

--- Rewrites a native error so it names the program, never its target or arguments.
--- @param message any Error raised by a native call.
--- @param target any The launched target.
--- @param args table|nil Arguments that must not reach the log.
--- @return string
local function redact(message, target, args)
	local text = tostring(message)
	-- Longest first, so an argument that contains another is hidden whole.
	local hidden = {}
	for _, value in ipairs(args or {}) do
		local literal = tostring(value)
		if literal ~= "" then hidden[#hidden + 1] = literal end
	end
	table.sort(hidden, function(a, b) return #a > #b end)
	for _, literal in ipairs(hidden) do text = replace_literal(text, literal, "<argument>") end
	local literal = tostring(target or "")
	if literal ~= "" then text = replace_literal(text, literal, M.program_name(target)) end
	return text
end

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
	local name = M.program_name(app_path)
	if not ok then
		Logger.error(LOG, "Launch of '%s' failed: %s.", name, redact(result, app_path))
		return false
	end
	if result ~= true then
		-- A refusal used to return false in silence, so a shortcut that "does
		-- nothing" left no trace; callers that try a list of names see each one.
		Logger.warn(LOG, "No application accepted the launch of '%s'.", name)
		return false
	end
	Logger.info(LOG, "Launched '%s'.", name)
	return true
end

--- Launches an application with command-line arguments without blocking the run loop.
--- The shared task runner owns the native process until its completion callback.
--- @param app_path string Absolute path to the executable.
--- @param args string|table Single argument or list of arguments.
function M.launchWithArgs(app_path, args)
	local name = M.program_name(app_path)
	local count = 0
	local ok, err = pcall(function()
		local argv = { "-a", tostring(app_path), "--args" }
		if type(args) == "table" then
			for _, value in ipairs(args) do argv[#argv + 1] = tostring(value) end
		else
			argv[#argv + 1] = tostring(args or "")
		end
		count = #argv - 3
		local handle = ShellRunner.spawn("/usr/bin/open", argv, function(exit_code)
			if exit_code ~= 0 then
				Logger.error(LOG, "Launch of '%s' with arguments failed: open exited with status %s.",
					name, tostring(exit_code))
			end
		end)
		if handle.start() ~= true then error("open task did not start") end
	end)
	if not ok then
		-- Arguments can carry user text (a search, a path), so only the program is named.
		Logger.error(LOG, "Launch of '%s' with arguments failed: %s.", name,
			redact(err, app_path, type(args) == "table" and args or { args }))
		return
	end
	Logger.info(LOG, "Launched '%s' with %d argument(s).", name, count)
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
