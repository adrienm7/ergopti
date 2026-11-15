--- modules/keep_awake.lua

--- ==============================================================================
--- MODULE: Session Idle Inhibitor (Linux)
--- DESCRIPTION:
--- Holds logind's idle inhibitor through systemd-inhibit. A private stdin pipe
--- keeps its command alive: closing the daemon also closes that pipe, so an
--- abnormal exit cannot leave a detached inhibitor behind. Normal stop retains
--- the process owner until its exit, group absence and handle closures settle.
--- ==============================================================================

local M = {}
local Logger = require("core.logger.engine.shim")
local i18n = require("core.i18n.engine.i18n")
local LOG = "modules.keep_awake"
local READY = "ERGOPTI_INHIBITED\n"
local POLL_SECONDS = 1
local STARTUP_SECONDS = 5
local _owner

--- Holds an unwritten pipe until cancellation. OwnedProcess owns its closure.
--- @return table source
local function hold_pipe()
	local source = { handle = assert(require("luv").new_pipe(false)) }
	local settled, listeners = false, {}
	function source:is_settled() return settled end
	function source:can_close() return settled end
	function source:result() return { ok = true } end
	function source:on_settled(fn)
		if settled then fn() else listeners[#listeners + 1] = fn end
		return true
	end
	function source:cancel()
		if settled then return true end
		settled = true
		for _, fn in ipairs(listeners) do fn() end
		listeners = {}
		return true
	end
	return source
end

--- Constructs one explicitly owned inhibitor; dependencies are native by default.
--- @param ports table|nil Native process, scheduler and pipe ports for tests.
--- @return table owner
function M.new(ports)
	ports = ports or {}
	local start = ports.start or require("core.process.adapters.owned_process").start
	local scheduler = ports.scheduler or require("core.events.timer_scheduler")
	local pipe = ports.pipe or hold_pipe
	local has_command = ports.has_command or require("core.process.adapters.shell_runner").has_command
	local notify = ports.notify or function(key)
		require("platform.focus.application_notifier").send(i18n.get(key))
	end
	local now_ms = ports.now_ms or require("core.logger.engine.monotonic").now_ms
	-- A finished session is the day's awake_ms, as on Windows and macOS (KMD-3).
	local record_session = ports.record_session or function(duration_ms)
		return require("modules.keystats.system_metrics").record_awake_session(duration_ms)
	end
	local current
	local owner = {}
	local listeners = {}
	local function finish(session)
		if current ~= session or not session.operation:is_settled() then return false end
		if session.timer and scheduler.cancel(session.timer) ~= true then return false end
		current = nil
		Logger.info(LOG, "Session idle inhibitor released.")
		if session.active then
			notify("shortcuts.keep_awake_off")
			local recorded, credited = pcall(record_session, math.max(0, now_ms() - session.active_since_ms))
			if not recorded or credited ~= true then
				Logger.warn(LOG, "The keep-awake session was not credited to the metrics: %s.", tostring(credited))
			end
		end
		local ready = listeners
		listeners = {}
		for _, fn in ipairs(ready) do fn() end
		return true
	end

	--- Cancels the current inhibitor and retains every unsettled native owner.
	--- @return boolean settled
	function owner.stop()
		local session = current
		if not session then return true end
		session.stopping = true
		if session.timer and scheduler.cancel(session.timer) == true then session.timer = nil end
		session.input:cancel()
		session.operation:cancel()
		return current == nil or finish(session)
	end

	--- Subscribes to actual native retirement, including a refused start's debt.
	--- @param fn function Settlement callback.
	--- @return boolean admitted
	function owner.when_settled(fn)
		if type(fn) ~= "function" then return false end
		if not current then fn(); return true end
		listeners[#listeners + 1] = fn
		return true
	end

	--- Reports confirmed inhibition, never a process launch alone.
	--- @return boolean active
	function owner.is_active()
		return current ~= nil and current.active == true and not current.stopping
	end

	--- Toggles the inhibitor; pending cleanup prevents another acquisition.
	--- @return boolean admitted
	function owner.toggle()
		if current then return owner.stop() end
		if not has_command("systemd-inhibit", true) then
			Logger.error(LOG, "Keep-awake refused: systemd-inhibit is not installed.")
			notify("notify.keep_awake_failed")
			return false
		end
		local session = { input = pipe(), output = "", waited = 0 }
		current = session
		local operation = start("systemd-inhibit", {
			"--what=idle", "--mode=block", "--who=Ergopti", "--why=" .. i18n.get("sg_actions.activity_simulation"),
			"--", "sh", "-c", "printf '" .. READY .. "'; exec cat >/dev/null",
		}, {
			owner = "keep-awake", stdin_owner = session.input,
			capture_tail = true,
			on_output = function(chunk, kind)
				if current ~= session or session.stopping or kind ~= "stdout" or session.active then return end
				session.output = (session.output .. chunk):sub(1, #READY)
				if session.output == READY then
					session.active, session.active_since_ms = true, now_ms()
					Logger.info(LOG, "Session idle inhibitor acquired.")
					notify("shortcuts.keep_awake_inhibitor_on")
				end
			end,
		}, function() end)
		session.operation = operation
		operation:on_settled(function()
			if current == session and not session.stopping then
				Logger.error(LOG, "Keep-awake lost or refused: the inhibitor process settled unexpectedly.")
				notify("notify.keep_awake_failed")
			end
			finish(session)
		end)
		if current ~= session then return false end
		if operation.started ~= true then
			Logger.error(LOG, "Keep-awake refused: inhibitor process could not start.")
			notify("notify.keep_awake_failed")
			if current then owner.stop() end
			return false
		end
		session.timer = scheduler.every(POLL_SECONDS, function()
			if current ~= session then return end
			if session.stopping then owner.stop(); return end
			session.waited = session.waited + POLL_SECONDS
			if not operation:is_running() or (not session.active and session.waited >= STARTUP_SECONDS) then
				Logger.error(LOG, "Keep-awake lost or refused: the session idle inhibitor is unavailable.")
				notify("notify.keep_awake_failed")
				owner.stop()
			end
		end)
		if not session.timer or session.timer.armed ~= true then
			Logger.error(LOG, "Keep-awake refused: inhibitor observation could not start.")
			notify("notify.keep_awake_failed")
			owner.stop()
			return false
		end
		return true
	end

	-- Whether the inhibitor ran when the driver paused, and the pause it
	-- belongs to: the resume gives it back (the maintainer's decision of
	-- 2026-11-14, as on Windows and macOS).
	local resume_after_pause, pause_generation, paused_now = false, 0, false

	--- Follows the driver's pause: a pause stops the inhibitor and remembers
	--- whether it ran, the resume starts it again once the old one settled.
	--- @param paused boolean The driver's settled pause state.
	--- @return boolean settled
	function owner.set_paused(paused)
		if type(paused) ~= "boolean" then
			error("keep_awake.set_paused() needs a boolean pause state", 2)
		end
		pause_generation = pause_generation + 1
		paused_now = paused
		if paused then
			resume_after_pause = resume_after_pause or owner.is_active()
			return owner.stop()
		end
		if not resume_after_pause then return true end
		resume_after_pause = false
		local generation = pause_generation
		return owner.when_settled(function()
			if pause_generation ~= generation or paused_now or current then return end
			if owner.toggle() ~= true then
				Logger.error(LOG, "Keep-awake could not start again on resume.")
			end
		end)
	end
	return owner
end

--- Toggles the daemon's only inhibitor.
--- @return boolean admitted
function M.toggle()
	if not _owner then _owner = M.new() end
	return _owner.toggle()
end

--- Releases the daemon's inhibitor before its event loop stops.
--- @return boolean settled
function M.stop() return not _owner or _owner.stop() end

--- Follows the driver's pause: the daemon's inhibitor stops with it and comes
--- back on resume when it ran at the pause.
--- @param paused boolean The driver's settled pause state.
--- @return boolean settled
function M.set_paused(paused)
	if type(paused) ~= "boolean" then error("keep_awake.set_paused() needs a boolean pause state", 2) end
	if not _owner then return true end
	return _owner.set_paused(paused)
end

--- Waits for the inhibitor's native cleanup receipt.
--- @param fn function Settlement callback.
--- @return boolean admitted
function M.when_settled(fn)
	if not _owner then fn(); return true end
	return _owner.when_settled(fn)
end

return M
