--- clipboard/adapters/wayland_selection_counter.lua

--- ==============================================================================
--- MODULE: Wayland Clipboard Change Counter (Linux)
--- DESCRIPTION:
--- A change counter for the Wayland clipboard, so the tap-hold copy check can
--- confirm a copy there as it does on X11, Windows and macOS. One long-lived
--- `wl-paste --watch` child prints a line each time the clipboard changes
--- hands; the counter is the number of lines seen.
---
--- WHY A WATCHER:
--- Wayland gives a client no selection timestamp to read. Only a data-control
--- client sees each new selection, which is what `wl-paste --watch` is. A
--- compositor without data-control (GNOME) makes it exit at once: the counter
--- is then unsupported and the copy goes unchecked, said once in the log.
---
--- FEATURES & RATIONALE:
--- 1. Content never kept: the watched command drains the offered data to
---    /dev/null, so the source application's write completes, and prints a bare
---    newline. Nothing of the clipboard reaches the daemon.
--- 2. Explicit lifecycle: platform/remap/tap_hold_manager.lua starts it with
---    the copy owner and stops it with the copy owner; a second start is refused.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")

local LOG = "clipboard.adapters.wayland_selection_counter"
local OUTPUT_TAIL_BYTES = 64
local WATCH_COMMAND = "cat >/dev/null; echo"

local _operation = nil
local _count = 0
local _running = false

--- Starts the watcher.
--- @param ports table|nil { start_process = fn(executable, args, options, callback), has_command = fn(name) } for tests.
--- @return boolean started
function M.start(ports)
	if _operation ~= nil then error("wayland selection counter already started") end
	ports = ports or {}
	local has_command = ports.has_command or require("core.process.adapters.shell_runner").has_command
	if not has_command("wl-paste") then
		Logger.info(LOG, "wl-paste is not installed: Wayland copies cannot be confirmed.")
		return false
	end
	local start_process = ports.start_process or require("core.process.adapters.owned_process").start
	_count, _running = 0, true
	local operation = start_process("wl-paste", { "--watch", "sh", "-c", WATCH_COMMAND }, {
		owner = "wayland-selection-counter", capture_tail = true, max_output_bytes = OUTPUT_TAIL_BYTES,
		on_output = function(chunk, kind)
			if kind ~= "stdout" then return end
			local _, lines = chunk:gsub("\n", "")
			_count = _count + lines
		end,
	}, function()
		if _running then
			_running = false
			Logger.info(LOG, "wl-paste --watch ended: this compositor offers no clipboard watch (data-control).")
		end
	end)
	if type(operation) ~= "table" or operation.started ~= true then
		_running = false
		Logger.warn(LOG, "wl-paste --watch could not start: %s.", tostring(type(operation) == "table" and operation.error))
		return false
	end
	_operation = operation
	Logger.info(LOG, "Watching the Wayland clipboard for the tap-hold copy check.")
	return true
end

--- Stops the watcher; the counter becomes unsupported again.
function M.stop()
	local operation = _operation
	_operation, _running = nil, false
	if operation and type(operation.cancel) == "function" then pcall(operation.cancel, operation) end
end

--- The number of clipboard changes seen since the start.
--- @return number|nil counter
--- @return string|nil reason "unsupported" while no watcher runs.
function M.read()
	if not _operation or not _running then return nil, "unsupported" end
	if type(_operation.is_running) == "function" and not _operation:is_running() then
		_running = false
		return nil, "unsupported"
	end
	return _count
end

return M
