--- ui/menu/start_at_login.lua

--- ==============================================================================
--- MODULE: Login Startup Menu
--- DESCRIPTION:
--- Queries the operating system's startup entry and changes it only in response
--- to an explicit menu click. The current daemon is never stopped by this setting.
--- ==============================================================================

local M = {}
local ShellRunner = require("core.process.adapters.shell_runner")
local Paths = require("core.fs.engine.paths")
local Logger = require("core.logger.engine.shim")

local LOG = "ui.menu.start_at_login"

--- Calls the installed startup helper, retaining external failure as a failure.
--- @param action string
--- @param run function|nil
--- @return boolean, string
local function invoke(action, run)
	return (run or ShellRunner.exec_checked)("/bin/bash "
		.. ShellRunner.quote(Paths.driver_root() .. "/install/start_at_login.sh") .. " " .. action)
end

local last_read_failure = nil

--- Reads the helper's answer: enabled, disabled, other or stale, or nil after a
--- logged failure. Each menu rebuild reads it, so one failure, or one stale
--- entry, is logged once until the answer changes.
--- @param run function|nil
--- @return string|nil
local function read_state(run)
	local ok, output, err = invoke("status", run)
	local state = ok and type(output) == "string" and output:match("^(%a+)%s*$") or nil
	if state == "stale" then
		-- The entry names a launcher that no longer exists (a moved or deleted
		-- checkout): nothing starts at login. Enabling rewrites it (SAD-1).
		if last_read_failure ~= state then
			last_read_failure = state
			Logger.warn(LOG, "The login startup entry names a launcher that no longer exists: "
				.. "nothing starts at login until startup is enabled again.")
		end
		return state
	end
	if state == "enabled" or state == "disabled" or state == "other" then
		last_read_failure = nil
		return state
	end
	local detail = ok and "unexpected answer" or tostring(err or "query failed")
	if last_read_failure ~= detail then
		last_read_failure = detail
		Logger.warn(LOG, "Startup state could not be read: %s.", detail)
	end
	return nil
end

--- Returns the effective startup state, or nil if the query failed.
--- @param run function|nil
--- @return boolean|nil
function M.enabled(run)
	local state = read_state(run)
	if state == "enabled" then return true end
	if state == "disabled" or state == "stale" then return false end
	return nil
end

--- Returns false only when the native entry proves a different startup command.
--- Unknown query failures remain unknown, never a claim of another installation.
--- @param run function|nil
--- @return boolean|nil
function M.command_available(run)
	local state = read_state(run)
	if state == "other" then return false end
	if state == "enabled" or state == "disabled" or state == "stale" then return true end
	return nil
end

--- Toggles startup only after a successful query and confirms the final state.
--- @param run function|nil
--- @return boolean
function M.toggle(run)
	local enabled = M.enabled(run)
	if enabled == nil then
		Logger.error(LOG, "Startup setting not changed: its state is unknown.")
		return false
	end
	local action = enabled and "disable" or "enable"
	local changed, _, err = invoke(action, run)
	if not changed then
		Logger.error(LOG, "Startup %s failed: %s.", action, tostring(err or "helper failed"))
		return false
	end
	if M.enabled(run) ~= not enabled then
		Logger.error(LOG, "Startup %s was not confirmed by the next read.", action)
		return false
	end
	Logger.info(LOG, "Startup %sd.", action)
	return true
end

return M
