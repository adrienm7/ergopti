--- ui/menu/start_at_login.lua

--- ==============================================================================
--- MODULE: Login Startup Menu
--- DESCRIPTION:
--- Queries the operating system's startup entry and changes it only in response
--- to an explicit menu click. The current daemon is never stopped by this setting.
--- ==============================================================================

local M = {}
local ShellRunner = require("adapters.shell_runner")
local Paths = require("infra.paths")

--- Calls the installed startup helper, retaining external failure as a failure.
--- @param action string
--- @param run function|nil
--- @return boolean, string
local function invoke(action, run)
	return (run or ShellRunner.exec_checked)("/bin/bash "
		.. ShellRunner.quote(Paths.driver_root() .. "/install/start_at_login.sh") .. " " .. action)
end

--- Returns the effective startup state, or nil if the query failed.
--- @param run function|nil
--- @return boolean|nil
function M.enabled(run)
	local ok, output = invoke("status", run)
	if not ok then return nil end
	if output:match("^enabled%s*$") then return true end
	if output:match("^disabled%s*$") then return false end
	return nil
end

--- Returns false only when the native entry proves a different startup command.
--- Unknown query failures remain unknown, never a claim of another installation.
--- @param run function|nil
--- @return boolean|nil
function M.command_available(run)
	local ok, output = invoke("status", run)
	if not ok then return nil end
	if output:match("^other%s*$") then return false end
	if output:match("^enabled%s*$") or output:match("^disabled%s*$") then return true end
	return nil
end

--- Toggles startup only after a successful query and confirms the final state.
--- @param run function|nil
--- @return boolean
function M.toggle(run)
	local enabled = M.enabled(run)
	if enabled == nil then return false end
	if not invoke(enabled and "disable" or "enable", run) then return false end
	return M.enabled(run) == not enabled
end

return M
