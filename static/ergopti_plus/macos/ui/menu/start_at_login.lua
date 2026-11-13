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
local last_status_failure = nil

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
	local resolver = deps.resolver or require("keyboard.adapters.karabiner.lease_helper")
	local shell = deps.shell or require("core.process.adapters.shell_runner")
	local logger = deps.logger or require("core.logger.engine.logger")
	local function alert(text_key, style)
		local i18n = deps.i18n or require("core.i18n.engine.i18n")
		local dialog = deps.dialog or require("core.ui.engine.dialog_util")
		local shown, err = pcall(function()
			dialog.block_alert(i18n.get("menu.global.start_at_login"),
				i18n.get(text_key), i18n.get("button.ok"), nil, style)
		end)
		if not shown then logger.error("ui.menu.start_at_login", "Startup dialog failed: %s.", tostring(err)) end
	end
	-- A toggle failure is told every time; a status read runs at every menu
	-- rebuild, so the same failure is logged once until a read succeeds again.
	local function fail(detail)
		detail = tostring(detail)
		if action == "toggle" then
			logger.error("ui.menu.start_at_login", "Startup setting failed: %s.", detail)
			alert("dialog.start_at_login.failed", "critical")
		elseif last_status_failure ~= detail then
			last_status_failure = detail
			logger.warn("ui.menu.start_at_login", "Startup state could not be read: %s.", detail)
		end
	end
	local executable, detail, environment = resolver.resolve()
	if not executable then
		fail(detail)
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
		if action == "status" then last_status_failure = nil end
		local previous = enabled
		enabled = state == "enabled"
		-- The native worker has already opened System Settings on Login Items:
		-- the user has one step left there, which is not a failure to report.
		if action == "toggle" and state == "approval" then
			logger.warn("ui.menu.start_at_login", "Startup waits for the user's approval in System Settings.")
			alert("dialog.start_at_login.approval", "informational")
		end
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
