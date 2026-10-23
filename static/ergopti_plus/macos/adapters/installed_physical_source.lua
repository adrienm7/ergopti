--- adapters/installed_physical_source.lua

--- ==============================================================================
--- MODULE: Installed Physical Source Task Port (Hammerspoon)
--- DESCRIPTION:
--- Gives the physical capture owner (modules/keystats/physical_capture.lua) the
--- task port it spawns its three native steps through, over the signed native
--- module `ergopti_installed_source_native` instead of the shell runner. The
--- module's owner starts the launcher's `--installed-physical-source` role, and
--- that role, not Lua, acquires, starts and retires the runtime's Console user
--- server and relays the authenticated capture stream (ADR 011, decision 8).
---
--- FEATURES & RATIONALE:
--- 1. One Console Owner: this port never spawns a Console. A second Console next
---    to the launcher's would fight it for the owned sockets, so the stream task
---    is the only way a Console exists, and it ends with the stream.
--- 2. Closed Task Set: only the pinned-requirement check (the real codesign), the
---    clock query and the stream are served. Any other executable or argument
---    vector is refused with a settled handle, never run.
--- 3. Native Clock: the clock answer is the native owner's own timebase, taken
---    in the same process that later converts the stream's hardware ticks.
--- 4. Pull Transport: the native module has no callbacks, so a short repeating
---    timer reads the stream, flushes the acknowledgement backlog and watches
---    for the child's exit. A read failure revokes the stream, never retries it.
--- 5. Settlement Is Native: a handle is settled only when the module says the
---    exact child, its pipes and its image are retired, never when a timer
---    elapses or a stop was merely requested.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")

local LOG = "adapters.installed_physical_source"

--- The launcher role that owns the Console and the capture stream.
M.STREAM_ROLE = "--installed-physical-source"
--- The step that asks for the native timebase.
M.CLOCK_ROLE = "--hs274-clock"
--- The only external executable this port forwards to the shell runner.
M.CODESIGN = "/usr/bin/codesign"
--- The loadable module's name inside the bundle and its entry point.
M.MODULE_RELATIVE = "/Contents/Resources/static/ergopti_plus/macos/adapters/native/installed_physical_source.so"
M.MODULE_ENTRY = "luaopen_ergopti_installed_source_native"
--- Seconds between two pumps of an open stream. The producer polls every 25 ms.
M.PUMP_INTERVAL_SEC = 0.025
--- The native module refuses a single acknowledgement larger than this.
M.ACKNOWLEDGEMENT_LIMIT = 65536

local LAUNCHER_SUFFIX = "/Contents/MacOS/ErgoptiPlus"





-- =============================
-- =============================
-- ======= 1/ Resolution =======
-- =============================
-- =============================

--- Derives the bundle's native module path from the bundle-bound launcher path.
--- @param launcher string Absolute launcher path ending in Contents/MacOS/ErgoptiPlus.
--- @return string|nil path Module path.
--- @return string|nil reason Stable refusal text.
function M.module_path(launcher)
	if type(launcher) ~= "string" or launcher:sub(-#LAUNCHER_SUFFIX) ~= LAUNCHER_SUFFIX then
		return nil, "the launcher path does not name an application bundle"
	end
	return launcher:sub(1, #launcher - #LAUNCHER_SUFFIX) .. M.MODULE_RELATIVE
end

--- Resolves the real launcher and loads the signed native module.
--- @return table|nil resolved { launcher = string, native = table }.
--- @return string|nil reason Why the installed source is unavailable.
local function resolve_real()
	local launcher, helper_reason = require("platform.remap.lease_helper").resolve()
	if not launcher then return nil, helper_reason end
	local path, path_reason = M.module_path(launcher)
	if not path then return nil, path_reason end
	local loader, load_reason = package.loadlib(path, M.MODULE_ENTRY)
	if type(loader) ~= "function" then
		return nil, "the installed source module could not be loaded: " .. tostring(load_reason)
	end
	local loaded, native = pcall(loader)
	if not loaded or type(native) ~= "table" then
		return nil, "the installed source module refused to initialize"
	end
	return { launcher = launcher, native = native }
end





-- ===========================
-- ===========================
-- ======= 2/ Handles  =======
-- ===========================
-- ===========================

--- Builds the observer list shared by every handle kind.
--- @return table observers { add = fn, settle = fn, settled = fn }.
local function settlement_observers()
	local observers, done = {}, false
	local owner = {}
	--- Registers an observer; an already-settled handle notifies it at once.
	--- @param observer function Zero-arity terminal observer.
	--- @return boolean registered
	function owner.add(observer)
		if type(observer) ~= "function" then return false end
		if done then
			local ok, failure = xpcall(observer, debug.traceback)
			if not ok then Logger.error(LOG, "A settlement observer raised: %s", tostring(failure)) end
			return true
		end
		observers[#observers + 1] = observer
		return true
	end
	--- Marks the handle settled and notifies every observer once.
	function owner.settle()
		if done then return end
		done = true
		local pending = observers
		observers = {}
		for _, observer in ipairs(pending) do
			local ok, failure = xpcall(observer, debug.traceback)
			if not ok then Logger.error(LOG, "A settlement observer raised: %s", tostring(failure)) end
		end
	end
	--- @return boolean settled
	function owner.settled() return done end
	return owner
end

--- A handle that never starts and is already settled.
--- @param why string Reason for the log.
--- @return table handle
local function refused_handle(why)
	Logger.error(LOG, "Installed source task refused: %s.", why)
	local observers = settlement_observers()
	observers.settle()
	local handle = {}
	function handle.start() return false end
	function handle.set_input() return false end
	function handle.close_input() return false end
	function handle.terminate() return true, "settled" end
	function handle.isSettled() return true end
	function handle.wasStartAttempted() return false end
	handle.onSettled = observers.add
	return handle
end

--- Serves the clock query from the native owner's timebase.
--- @param owner table Native owner.
--- @param codec table JSON codec adapter.
--- @param timer table Timer scheduler adapter.
--- @param on_done function|nil fn(exit_code, stdout, stderr).
--- @return table handle
local function clock_handle(owner, codec, timer, on_done)
	local observers = settlement_observers()
	local handle, attempted, scheduled = {}, false, nil
	function handle.start()
		if attempted then return false end
		attempted = true
		-- Completion is asynchronous, like every other task: the caller registers
		-- its observers and records the accepted start before any answer.
		local armed, committed = timer.after(0, function()
			scheduled = nil
			local information = owner:clock()
			local encoded, failure
			if type(information) == "table" then encoded, failure = codec.encode(information) end
			if type(encoded) == "string" then
				if on_done then on_done(0, encoded .. "\n", "") end
			else
				Logger.error(LOG, "The native clock was unavailable%s.", failure and (": " .. tostring(failure)) or "")
				if on_done then on_done(1, "", "") end
			end
			observers.settle()
		end)
		if committed ~= true then
			observers.settle()
			return false
		end
		scheduled = armed
		return true
	end
	function handle.set_input() return false end
	function handle.close_input() return false end
	function handle.terminate()
		-- The query owns no child; a pending answer is simply never delivered.
		if scheduled then
			timer.cancel(scheduled)
			scheduled = nil
		end
		observers.settle()
		return true, "settled"
	end
	function handle.isSettled() return observers.settled() end
	function handle.wasStartAttempted() return attempted end
	handle.onSettled = observers.add
	return handle
end

--- Serves the capture stream through the native owner.
--- @param owner table Native owner.
--- @param timer table Timer scheduler adapter.
--- @param on_done function|nil fn(exit_code, stdout, stderr).
--- @param on_chunk function|nil fn(handle, stdout_chunk, stderr_chunk).
--- @return table handle
local function stream_handle(owner, timer, on_done, on_chunk)
	local observers = settlement_observers()
	local handle = {}
	local state, pump_timer, backlog = "prepared", nil, ""
	local exit_reported, pumping = false, false

	local function settle()
		if state == "settled" then return end
		state = "settled"
		if pump_timer then timer.cancel(pump_timer); pump_timer = nil end
		observers.settle()
	end

	--- Requests the stream's retirement once and keeps the pump until it settles.
	local function request_stop()
		if state == "prepared" or state == "settled" then return end
		if state ~= "stopping" then
			state = "stopping"
			backlog = ""
			owner:request_stop()
		end
	end

	--- Writes as much of the acknowledgement backlog as the pipe accepts.
	--- @return boolean ok False when the module refused the write.
	local function flush()
		while backlog ~= "" do
			local written = owner:write(backlog)
			if type(written) ~= "number" then return false end
			if written <= 0 then return true end
			backlog = backlog:sub(written + 1)
		end
		return true
	end

	local function pump_once()
		if state == "running" then
			if not flush() then
				Logger.error(LOG, "The stream refused an acknowledgement; revoking it.")
				request_stop()
			else
				local chunk = owner:read()
				if chunk == nil then
					Logger.error(LOG, "The stream could not be read; revoking it.")
					request_stop()
				elseif chunk ~= "" and on_chunk then
					local ok, failure = xpcall(on_chunk, debug.traceback, handle, chunk, "")
					if not ok then
						Logger.error(LOG, "The stream consumer raised: %s", tostring(failure))
						request_stop()
					end
				end
			end
			local code = state == "running" and owner:completion() or nil
			if code ~= nil then
				-- The child ended by itself: report it once, then retire the rest.
				if not exit_reported then
					exit_reported = true
					if on_done then on_done(code, "", "") end
				end
				request_stop()
			end
		end
		if state == "stopping" then
			if not exit_reported then
				local code = owner:completion()
				if code ~= nil then
					exit_reported = true
					if on_done then on_done(code, "", "") end
				end
			end
			if owner:retired() == true then settle() end
		end
	end

	--- One guarded pump turn. A raising native call revokes the stream instead of
	--- leaving the pump latched.
	local function pump()
		if pumping or state == "settled" then return end
		pumping = true
		local ok, failure = pcall(pump_once)
		pumping = false
		if not ok then
			Logger.error(LOG, "The stream pump raised: %s", tostring(failure))
			local stopped, stop_failure = pcall(request_stop)
			if not stopped then Logger.error(LOG, "The stream could not be revoked: %s", tostring(stop_failure)) end
		end
	end

	function handle.start()
		if state ~= "prepared" then return false end
		local started = owner:start() == true
		-- A refused start leaves the module's owner stopping; the pump still
		-- observes its native retirement, so the handle settles only for real.
		state = started and "running" or "stopping"
		if not started then owner:request_stop() end
		local armed, committed = timer.every(M.PUMP_INTERVAL_SEC, pump)
		if committed ~= true then
			Logger.error(LOG, "The stream pump could not be scheduled; revoking the stream.")
			request_stop()
			if owner:retired() == true then settle() end
			return false
		end
		pump_timer = armed
		return started
	end

	--- Queues one framed acknowledgement; the pump delivers it.
	--- @param text string One newline-terminated protocol line.
	--- @return boolean accepted
	function handle.set_input(text)
		if state ~= "running" or type(text) ~= "string" or text == "" then return false end
		if #backlog + #text > M.ACKNOWLEDGEMENT_LIMIT then return false end
		backlog = backlog .. text
		return flush()
	end

	--- The native pipe offers no half-close.
	function handle.close_input() return false end

	--- Requests retirement; only the pump's observation of native settlement
	--- reports `settled`.
	--- @return boolean accepted
	--- @return string status `pending` or `settled`.
	function handle.terminate()
		if state == "settled" then return true, "settled" end
		if state == "prepared" then
			settle()
			return true, "settled"
		end
		request_stop()
		if owner:retired() == true then
			settle()
			return true, "settled"
		end
		return true, "pending"
	end

	function handle.isSettled() return state == "settled" end
	function handle.wasStartAttempted() return state ~= "prepared" end
	handle.onSettled = observers.add
	return handle
end





-- ===========================
-- ===========================
-- ======= 3/ The Port =======
-- ===========================
-- ===========================

--- Creates the installed-source task port.
--- @param dependencies table|nil Optional test seams: resolve() -> { launcher, native }|nil, reason;
---   timer (after, every, cancel); shell (spawn); codec (encode).
--- @return table port { spawn, available, launcher, shutdown, closed }.
function M.new(dependencies)
	dependencies = dependencies or {}
	local timer = dependencies.timer or require("adapters.timer_scheduler")
	local shell = dependencies.shell or require("adapters.shell_runner")
	local codec = dependencies.codec or require("adapters.json_codec")
	local resolve = dependencies.resolve or resolve_real
	local resolved, owner, acquired

	--- Loads the module once.
	--- @return table|nil resolved
	--- @return string|nil reason
	local function resolution()
		if resolved then return resolved end
		local value, reason = resolve()
		if type(value) ~= "table" or type(value.launcher) ~= "string" or type(value.native) ~= "table" then
			return nil, reason or "the installed source is unavailable"
		end
		resolved = value
		return resolved
	end

	--- Acquires the native owner once; it is reused by every lease of this VM.
	--- @return table|nil owner
	--- @return string|nil reason
	local function native_owner()
		if owner then return owner end
		local value, reason = resolution()
		if not value then return nil, reason end
		if acquired then return nil, "the native owner was acquired and then lost" end
		acquired = true
		local candidate = value.native.acquire()
		if candidate == nil then return nil, "the native owner refused to be acquired" end
		owner = candidate
		return owner
	end

	local port = {}

	--- Reports whether the installed source can be reached, without acquiring it.
	--- @return boolean available
	--- @return string|nil reason
	function port.available()
		local value, reason = resolution()
		return value ~= nil, reason
	end

	--- The `spawn` port physical_capture expects.
	--- @param executable string Absolute path.
	--- @param args table Argument array.
	--- @param on_done function|nil fn(exit_code, stdout, stderr).
	--- @param on_chunk function|nil fn(handle, stdout_chunk, stderr_chunk).
	--- @return table handle
	function port.spawn(executable, args, on_done, on_chunk)
		if executable == M.CODESIGN then
			if type(args) ~= "table" or args[1] ~= "--verify" then
				return refused_handle("codesign was asked for something other than a verification")
			end
			return shell.spawn(executable, args, on_done)
		end
		local value, reason = resolution()
		if not value then return refused_handle(reason) end
		if executable ~= value.launcher then
			return refused_handle("only the bundle-bound launcher may run an installed source task")
		end
		if type(args) ~= "table" or #args ~= 1 then
			return refused_handle("an installed source task takes exactly one role")
		end
		local role = args[1]
		if role ~= M.CLOCK_ROLE and role ~= M.STREAM_ROLE then
			return refused_handle("unknown installed source role")
		end
		local source, why = native_owner()
		if not source then return refused_handle(why) end
		if role == M.CLOCK_ROLE then return clock_handle(source, codec, timer, on_done) end
		return stream_handle(source, timer, on_done, on_chunk)
	end

	--- The bundle-bound launcher the stream and clock tasks run.
	--- @return string|nil launcher Absolute path.
	--- @return string|nil reason
	function port.launcher()
		local value, reason = resolution()
		return value and value.launcher or nil, reason
	end

	--- Requests the final retirement of the native owner.
	function port.shutdown()
		if owner then owner:shutdown() end
	end

	--- Reports whether the native owner released its image and publisher.
	--- @return boolean closed True when nothing was acquired or everything closed.
	function port.closed()
		if not owner then return true end
		return owner:closed() == true
	end

	return port
end

return M
