--- modules/keymap/kde_layout_watch.lua

--- ==============================================================================
--- MODULE: KDE Active Layout Watch (Linux)
--- DESCRIPTION:
--- KWin switches the active layout of a Plasma session by moving the group of
--- the one keymap it compiled from kxkbrc; nothing in the keymap tells the
--- daemon. The Plasma keyboard daemon announces each switch on the session bus
--- (org.kde.KeyboardLayouts.layoutChanged, and layoutListChanged when the list
--- itself changes); this watch follows those signals through one
--- `gdbus monitor` child and calls its owner back on each, and the daemon
--- resolves the keymap again on the layout now active
--- (adapters/keyboard_layout.lua asks getLayout on every resolve).
---
--- FEATURES & RATIONALE:
--- 1. On the daemon's event loop: a libuv child whose stdout is read
---    asynchronously, never a polling timer.
--- 2. One owner: start() once per session, shutdown() with the layout manager;
---    a second start() is a programming error and raises.
--- 3. Fail fast: a missing gdbus, a refused spawn, a read error or the child
---    ending stops the watch for the session with one error or warning, never
---    a respawn loop. The resolve at each start still reads the active layout.
--- 4. The native side is a port: tests replace the spawn.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local Timings = require("core.timing.engine.timings")

local LOG = "modules.keymap.kde_layout_watch"
-- What gdbus prints for the two signals that change the active layout.
M.SIGNALS = { "org.kde.KeyboardLayouts.layoutChanged", "org.kde.KeyboardLayouts.layoutListChanged" }
M.MONITOR_ARGS = { "monitor", "--session", "--dest", "org.kde.keyboard", "--object-path", "/Layouts" }
-- A monitor line is one signal with its arguments; a longer partial line is
-- no layout signal and is dropped up to its newline.
local MAX_MONITOR_LINE_BYTES = Timings.count("limits", "kde_layout_monitor_line_bytes")

--- The production spawn: gdbus monitor with its stdout on a libuv pipe.
--- @param on_exit function on_exit(code, signal)
--- @return table|nil child { process, stdout }
--- @return string|nil problem
local function production_spawn(on_exit)
	-- gdbus ships with GLib, which a minimal Arch, Fedora or openSUSE image
	-- lacks: name the missing tool instead of a bare spawn ENOENT.
	if not require("core.process.adapters.shell_runner").has_command("gdbus", true) then
		return nil, "gdbus is not installed"
	end
	local uv = require("luv")
	local stdout = uv.new_pipe(false)
	local process, problem = uv.spawn("gdbus", { args = M.MONITOR_ARGS, stdio = { nil, stdout, nil } }, on_exit)
	if not process then
		stdout:close()
		return nil, tostring(problem)
	end
	return { process = process, stdout = stdout }, nil
end

--- Builds one watch owner.
--- @param ports table { spawn(on_exit) -> child|nil, problem } (tests replace it).
--- @return table owner { start, shutdown, status }
function M.new(ports)
	if type(ports) ~= "table" or type(ports.spawn) ~= "function" then
		error("The KDE layout watch needs a spawn port.", 2)
	end
	local owner = {}
	local status = "idle"
	local child, on_change = nil, nil
	local pending, dropping = "", false

	local function close_child()
		local current = child
		child = nil
		if current == nil then return end
		if current.stdout and not current.stdout:is_closing() then
			pcall(current.stdout.read_stop, current.stdout)
			current.stdout:close()
		end
		if current.process and not current.process:is_closing() then
			pcall(current.process.kill, current.process, "sigterm")
			current.process:close()
		end
	end

	--- Ends the watch; `problem` names why when it was not asked for.
	local function stop(problem, level)
		if status == "stopped" then return end
		local was_watching = status == "watching"
		status = "stopped"
		close_child()
		if problem == nil then
			Logger.info(LOG, "KDE active layout watch stopped.")
		elseif was_watching then
			Logger[level or "error"](LOG, "KDE layout switches are no longer followed: %s.", problem)
		else
			Logger.error(LOG, "KDE layout switches cannot be followed: %s.", problem)
		end
	end

	local function consume(line)
		for _, signal in ipairs(M.SIGNALS) do
			if line:find(signal, 1, true) then
				Logger.info(LOG, "KDE switched the active layout.")
				local called, err = pcall(on_change)
				if not called then Logger.error(LOG, "The layout switch handler failed: %s.", tostring(err)) end
				return
			end
		end
	end

	local function on_read(err, chunk)
		if status ~= "watching" then return end
		if err then stop("read failed: " .. tostring(err)); return end
		if chunk == nil then stop("gdbus monitor closed its output", "warn"); return end
		pending = pending .. chunk
		while status == "watching" do
			local newline = pending:find("\n", 1, true)
			if not newline then break end
			local line = pending:sub(1, newline - 1)
			pending = pending:sub(newline + 1)
			if dropping then dropping = false else consume(line) end
		end
		if #pending > MAX_MONITOR_LINE_BYTES then pending, dropping = "", true end
	end

	--- Starts gdbus monitor and calls `handler` after each layout switch.
	--- @param handler function Called with no argument.
	--- @return boolean started False when the child cannot run (logged).
	function owner.start(handler)
		if type(handler) ~= "function" then error("The KDE layout watch needs a handler.", 2) end
		if status ~= "idle" then error("The KDE layout watch was already started.", 2) end
		status = "starting"
		on_change = handler
		Logger.start(LOG, "Following KDE layout switches…")
		local spawned, started, problem = pcall(ports.spawn, function(code, signal)
			if status == "watching" or status == "starting" then
				stop(string.format("gdbus monitor ended (code %s, signal %s)", tostring(code), tostring(signal)), "warn")
			end
		end)
		if not spawned then stop("gdbus monitor refused: " .. tostring(started)); return false end
		if started == nil then stop("gdbus monitor did not start: " .. tostring(problem)); return false end
		child = started
		local reading, read_err = pcall(child.stdout.read_start, child.stdout, on_read)
		if not reading then stop("read refused: " .. tostring(read_err)); return false end
		status = "watching"
		Logger.success(LOG, "Following KDE layout switches (gdbus monitor).")
		return true
	end

	--- Ends the watch for the session.
	function owner.shutdown() stop(nil) end

	--- idle, starting, watching or stopped.
	--- @return string
	function owner.status() return status end

	return owner
end

local _shared = nil

--- Starts the production watch, once per session.
--- @param handler function
--- @return boolean started
function M.start(handler)
	if _shared ~= nil then error("The KDE layout watch was already started.", 2) end
	_shared = M.new({ spawn = production_spawn })
	return _shared.start(handler)
end

--- Ends the production watch, when one was started.
function M.shutdown()
	if _shared ~= nil then _shared.shutdown() end
end

--- The production owner's state, "idle" before start.
--- @return string
function M.status() return _shared ~= nil and _shared.status() or "idle" end

--- Forgets the production owner (tests only).
function M._reset_for_test() _shared = nil end

return M
