--- infra/restart_pause.lua

--- ==============================================================================
--- MODULE: Restart Pause Handoff
--- DESCRIPTION:
--- Preserves the live pause across complete Linux restarts, including systemd
--- which does not inherit new launcher arguments. The bootstrap sidecar stays
--- put when the configuration editor changes the user's configuration directory.
--- ==============================================================================

local M = {}
local Files = require("adapters.file_system")
local Storage = require("adapters.storage")
local Shell = require("adapters.shell_runner")
local Writer = require("toml_codec.writer")
local Native = require("luv")
local sequence = 0

local function marker_path()
	return Storage.path() .. ".restart-pause"
end

local function source_owner(path, content)
	return { path = path, content = content,
		files = { read_with_status = Files.read_with_status, delete = Files.delete } }
end

--- Retires only the image admitted by this restart attempt.
--- @param lease table The preparation receipt.
--- @return boolean retired
function M.rollback(lease)
	local ok, removed = pcall(Writer.remove_if_unchanged, lease.path, lease.files,
		{ status = "ok", content = lease.content })
	return ok and removed == true
end

--- Publishes a one-shot, explicit live pause state before restart dispatch.
--- A pending handoff belongs to a startup that has not applied it yet; refuse
--- another restart rather than erase that request or silently resume it.
--- @param paused boolean The current controller state.
--- @return table|nil lease
--- @return string|nil detail
function M.prepare(paused)
	if type(paused) ~= "boolean" then return nil, "restart pause must be a boolean" end
	local ok, path = pcall(marker_path)
	if not ok then return nil, tostring(path) end
	local read, _, status = pcall(Files.read_with_status, path)
	if not read or status ~= "absent" then return nil, "restart pause handoff is pending or unreadable" end
	local parent = path:match("^(.*)/[^/]+$")
	local made, acknowledged = pcall(Shell.run, "mkdir -p -- " .. Shell.quote(parent) .. " 2>/dev/null")
	if not made or acknowledged ~= true then return nil, "restart pause directory could not be prepared" end
	sequence = sequence + 1
	local content = string.format("ERGOPTI_RESTART_PAUSE_V1\npaused=%s\nowner=%d:%.0f:%d\n",
		tostring(paused), Native.os_getpid(), Native.hrtime(), sequence)
	local lease = source_owner(path, content)
	local published, result = pcall(Files.write_if_unchanged, path, content, { status = "absent" })
	if published and result == true then return lease end
	M.rollback(lease)
	return nil, "restart pause publication was not acknowledged"
end

--- Applies a pending handoff through the normal transition before capture.
--- Consumption follows acknowledged application, so a failed startup can retry
--- without losing the user's pause. Failure must stop startup before watchers.
--- @param controller table The newly constructed script actions controller.
--- @return boolean restored
--- @return string|nil detail
function M.restore(controller)
	local located, path = pcall(marker_path)
	if not located then return false, tostring(path) end
	local read, content, status = pcall(Files.read_with_status, path)
	if read and status == "absent" then return true end
	if not read or status ~= "ok" then return false, "restart pause handoff is unreadable" end
	local paused = type(content) == "string"
		and content:match("^ERGOPTI_RESTART_PAUSE_V1\npaused=(%a+)\nowner=%d+:%d+:%d+\n$")
	if paused ~= "true" and paused ~= "false" then return false, "restart pause handoff is invalid" end
	local lease = source_owner(path, content)
	local applied, result = pcall(function()
		if controller.is_paused() ~= false then return false end
		if paused == "false" then return true end
		return controller.toggle_pause() == true and controller.is_paused() == true
	end)
	if not applied or result ~= true then return false, "restart pause transition was not acknowledged" end
	if not M.rollback(lease) then return false, "restart pause handoff could not be consumed" end
	return true
end

return M
