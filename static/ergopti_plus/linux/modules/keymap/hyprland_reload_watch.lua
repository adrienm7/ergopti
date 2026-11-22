--- modules/keymap/hyprland_reload_watch.lua

--- ==============================================================================
--- MODULE: Hyprland Configuration Reload Watch (Linux)
--- DESCRIPTION:
--- Hyprland's runtime input:kb_layout, which the layout manager sets with
--- `hyprctl keyword`, lasts until Hyprland reads its configuration file again:
--- `hyprctl reload`, or any save of hyprland.conf, puts the file's layout back.
--- Hyprland announces each reload on its event socket
--- ($XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock) as a
--- `configreloaded>>` line; this watch calls its owner back on each one, and
--- the layout manager selects the recorded layout again.
---
--- FEATURES & RATIONALE:
--- 1. On the daemon's event loop: a libuv pipe connected to the socket, read
---    asynchronously, never a polling timer or a thread.
--- 2. One owner: start() once per session, shutdown() with the layout manager;
---    a second start() is a programming error and raises.
--- 3. Fail fast: a missing socket identity, a refused connection, a read error
---    or Hyprland closing the socket ends the watch for the session with one
---    error or warning, never a reconnect loop.
--- 4. Our own `hyprctl keyword` writes are no reload: Hyprland reports
---    `configreloaded` only when it reads the file, so the re-selection cannot
---    feed itself.
--- 5. The native side is a port: tests replace the environment and the pipe.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")

local LOG = "modules.keymap.hyprland_reload_watch"
-- The event Hyprland sends after reading its configuration file.
M.RELOAD_EVENT = "configreloaded"
-- Event lines carry window titles of any length; a partial line longer than
-- this is no reload event and is dropped up to its newline.
local MAX_PENDING_BYTES = 4096

--- The event socket of the running Hyprland instance.
--- @param getenv function getenv(name) -> string|nil
--- @return string|nil path
--- @return string|nil problem Why there is none.
function M.socket_path(getenv)
	local runtime, signature = getenv("XDG_RUNTIME_DIR"), getenv("HYPRLAND_INSTANCE_SIGNATURE")
	if type(runtime) ~= "string" or runtime == "" then return nil, "XDG_RUNTIME_DIR is not set" end
	if type(signature) ~= "string" or signature == "" or signature:find("/", 1, true) then
		return nil, "HYPRLAND_INSTANCE_SIGNATURE is not set"
	end
	return runtime .. "/hypr/" .. signature .. "/.socket2.sock", nil
end

--- The production collaborators.
--- @return table
local function production()
	return {
		getenv = os.getenv,
		new_pipe = function() return require("luv").new_pipe(false) end,
	}
end

--- Builds one watch owner.
--- @param ports table { getenv, new_pipe } (tests replace them).
--- @return table owner { start, shutdown, status }
function M.new(ports)
	if type(ports) ~= "table" or type(ports.getenv) ~= "function" or type(ports.new_pipe) ~= "function" then
		error("The Hyprland reload watch needs getenv and new_pipe ports.", 2)
	end
	local owner = {}
	local status = "idle"
	local pipe, on_reload = nil, nil
	local pending, dropping = "", false

	local function close_pipe()
		local handle = pipe
		pipe = nil
		if handle ~= nil and not handle:is_closing() then
			pcall(handle.read_stop, handle)
			handle:close()
		end
	end

	--- Ends the watch; `problem` names why when it was not asked for.
	local function stop(problem, level)
		if status == "stopped" then return end
		local was_watching = status == "watching"
		status = "stopped"
		close_pipe()
		if problem == nil then
			Logger.info(LOG, "Hyprland configuration reload watch stopped.")
		elseif was_watching then
			Logger[level or "error"](LOG, "Hyprland configuration reloads are no longer watched: %s.", problem)
		else
			Logger.error(LOG, "Hyprland configuration reloads cannot be watched: %s.", problem)
		end
	end

	local function consume(line)
		if line:match("^([^>]*)>>") ~= M.RELOAD_EVENT then return end
		Logger.info(LOG, "Hyprland read its configuration again.")
		local called, err = pcall(on_reload)
		if not called then Logger.error(LOG, "The reload handler failed: %s.", tostring(err)) end
	end

	local function on_read(err, chunk)
		if status ~= "watching" then return end
		if err then stop("read failed: " .. tostring(err)); return end
		if chunk == nil then stop("Hyprland closed its event socket", "warn"); return end
		pending = pending .. chunk
		while status == "watching" do
			local newline = pending:find("\n", 1, true)
			if not newline then break end
			local line = pending:sub(1, newline - 1)
			pending = pending:sub(newline + 1)
			if dropping then dropping = false else consume(line) end
		end
		if #pending > MAX_PENDING_BYTES then
			Logger.debug(LOG, "Dropped an event line longer than %d bytes.", MAX_PENDING_BYTES)
			pending, dropping = "", true
		end
	end

	--- Connects to Hyprland's event socket and calls `handler` on each reload.
	--- @param handler function Called with no argument after each reload.
	--- @return boolean started False when the socket cannot be reached (logged).
	function owner.start(handler)
		if type(handler) ~= "function" then error("The Hyprland reload watch needs a handler.", 2) end
		if status ~= "idle" then error("The Hyprland reload watch was already started.", 2) end
		status = "connecting"
		on_reload = handler
		Logger.start(LOG, "Connecting to Hyprland's event socket…")
		local path, problem = M.socket_path(ports.getenv)
		if path == nil then stop(problem); return false end
		local created, handle = pcall(ports.new_pipe)
		if not created or handle == nil then stop("no pipe: " .. tostring(handle)); return false end
		pipe = handle
		local dispatched, dispatch_err = pcall(handle.connect, handle, path, function(err)
			if status ~= "connecting" then return end
			if err then stop("connection to " .. path .. " refused: " .. tostring(err)); return end
			local reading, read_err = pcall(handle.read_start, handle, on_read)
			if not reading then stop("read refused: " .. tostring(read_err)); return end
			status = "watching"
			Logger.success(LOG, "Watching Hyprland's configuration reloads (%s).", path)
		end)
		if not dispatched then stop("connect refused: " .. tostring(dispatch_err)); return false end
		return status ~= "stopped"
	end

	--- Ends the watch for the session.
	function owner.shutdown() stop(nil) end

	--- idle, connecting, watching or stopped.
	--- @return string
	function owner.status() return status end

	return owner
end

local _shared = nil

--- Starts the production watch (the layout manager's hook), once per session.
--- @param handler function
--- @return boolean started
function M.start(handler)
	if _shared ~= nil then error("The Hyprland reload watch was already started.", 2) end
	_shared = M.new(production())
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
