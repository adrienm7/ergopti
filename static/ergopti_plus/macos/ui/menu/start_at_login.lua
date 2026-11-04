--- ui/menu/start_at_login.lua

--- ==============================================================================
--- MODULE: Login Startup Menu
--- DESCRIPTION:
--- Asks the native application to read or change its login item. Native tasks
--- stay pinned by the shell adapter; the menu never guesses success from a click.
--- ==============================================================================

local M = {}
local busy = false
local enabled = false
local pending = nil

--- Reads or changes startup without blocking the event loop.
--- @param action string
--- @param changed function|nil
--- @param deps table|nil
--- @return boolean
function M.request(action, changed, deps)
	if busy then
		if action == "toggle" then pending = { changed = changed, deps = deps } end
		return action == "toggle"
	end
	deps = deps or {}
	local resolver = deps.resolver or require("platform.remap.lease_helper")
	local shell = deps.shell or require("adapters.shell_runner")
	local logger = deps.logger or require("infra.logger")
	local function fail(detail)
		logger.error("ui.menu.start_at_login", "Startup setting failed: %s.", tostring(detail))
		if action == "toggle" then
			local i18n = deps.i18n or require("infra.i18n")
			local dialog = deps.dialog or require("infra.dialog_util")
			local shown, err = pcall(function()
				dialog.block_alert(i18n.get("menu.global.start_at_login"),
					i18n.get("dialog.start_at_login.failed"), i18n.get("button.ok"), nil, "critical")
			end)
			if not shown then logger.error("ui.menu.start_at_login", "Startup failure dialog failed: %s.", tostring(err)) end
		end
	end
	local executable, detail, environment = resolver.resolve()
	if not executable then
		if action == "toggle" then fail(detail) end
		return false
	end
	busy = true
	local function drain_pending()
		local next_request = pending
		pending = nil
		if next_request then M.request("toggle", next_request.changed, next_request.deps) end
	end
	local function complete(code, stdout)
		busy = false
		local state = type(stdout) == "string" and stdout:match("^(%a+)%s*$") or nil
		if code ~= 0 or (state ~= "enabled" and state ~= "disabled" and state ~= "approval") then
			fail("native settings query was refused")
			drain_pending()
			return
		end
		local previous = enabled
		enabled = state == "enabled"
		if action == "toggle" and state == "approval" then fail("macOS approval is required") end
		if previous ~= enabled and changed then
			local updated, err = pcall(changed)
			if not updated then logger.error("ui.menu.start_at_login", "Startup menu refresh failed: %s.", tostring(err)) end
		end
		drain_pending()
	end
	local spawned, task = pcall(shell.spawn, executable, { "--login-startup", action }, complete, nil, environment)
	local started = false
	if spawned and type(task) == "table" and type(task.start) == "function" then
		local called, result = pcall(task.start)
		started = called and result == true
	end
	if not started then
		fail("native worker could not start")
		if type(task) == "table" and type(task.isSettled) == "function"
			and type(task.onSettled) == "function" then
			local checked, settled = pcall(task.isSettled)
			if not checked or settled ~= true then
				local subscribed, accepted = pcall(task.onSettled, function()
					busy = false
					drain_pending()
				end)
				if not subscribed or accepted ~= true then
					logger.error("ui.menu.start_at_login", "Unsettled startup worker could not be observed.")
				end
				return false
			end
		end
		busy = false
		drain_pending()
		return false
	end
	return true
end

--- Returns the last confirmed native state; a query refreshes it asynchronously.
--- @return boolean
function M.enabled()
	return enabled
end

return M
