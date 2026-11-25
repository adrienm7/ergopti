--- platform/input/hook_supervisor.lua

--- ==============================================================================
--- MODULE: Keyboard Hook Supervisor (Linux)
--- DESCRIPTION:
--- Decides what the daemon does when the keyboard hook is no longer running
--- while nobody asked it to stop: log the cause, then start the hook again a
--- bounded number of times, each after a longer pause.
---
--- WHY THIS EXISTS:
--- The daemon's idle tick used to request a run-time failure the moment the
--- hook was not running. Any retired capture transaction (a refused watchdog
--- tick, a dialog's restoration, an output failure) therefore ended the whole
--- daemon, with « keyboard hook stopped » as the only reason in the log. Under
--- systemd the unit came back three seconds later; started from the AppImage,
--- nothing did, and the user's tray icon, hotstrings and layout were simply gone.
---
--- FEATURES & RATIONALE:
--- 1. A deliberate stop (the shutdown coordinator's) is never restarted: the
---    hook's last_stop() says which kind of stop it was.
--- 2. Retries are bounded by RESTART_BACKOFF_MS, one pause per attempt. A hook
---    that stays up for STABLE_RESET_MS earns its whole budget back, so one
---    stop a day never exhausts it, while a hook that dies at every start cannot
---    grab and release the keyboard in a loop.
--- 3. Once the budget is spent the caller is told so ("exhausted") and keeps
---    the existing run-time failure exit, which a service manager can act on.
--- 4. Pure: the clock, the hook and the restart are injected, so the whole
---    policy runs under the unit suite.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local Timings = require("core.timing.engine.timings")
local LOG = "adapters.hook_supervisor"




-- =====================================
-- =====================================
-- ======= 1/ Policy Constants =========
-- =====================================
-- =====================================

--- The pause before each restart attempt, in milliseconds; its length is the
--- number of attempts allowed before the supervisor gives up. Each pause
--- doubles the one before it (constants.toml [adapters]).
M.RESTART_BACKOFF_MS = {}
do
	local first = Timings.ms("adapters", "hook_restart_first_backoff_ms")
	for attempt = 1, Timings.count("adapters", "hook_restart_attempts") do
		M.RESTART_BACKOFF_MS[attempt] = first * 2 ^ (attempt - 1)
	end
end

--- How long a restarted hook must stay up before its retry budget is restored.
M.STABLE_RESET_MS = Timings.ms("adapters", "hook_restart_stable_ms")

-- What every supervisor of this process saw since it started, for the field
-- run's session check: an outage the user never noticed still counts.
local _lifetime = { outages = 0, restarts = 0, exhausted = 0 }




-- =====================================
-- =====================================
-- ======= 2/ Supervisor ===============
-- =====================================
-- =====================================

--- Creates the supervisor of one keyboard hook.
--- @param options table {
---   hook = table      the keyboard hook (isRunning, isRecovering, last_stop),
---   restart = function() -> boolean started, string|nil reason,
---   now_ms = function() -> number   monotonic clock }
--- @return table supervisor { poll, attempts }
function M.new(options)
	if type(options) ~= "table" then error("hook_supervisor: options are required", 2) end
	local hook, restart, now_ms = options.hook, options.restart, options.now_ms
	if type(hook) ~= "table" or type(hook.isRunning) ~= "function" or type(hook.isRecovering) ~= "function"
		or type(hook.last_stop) ~= "function" then
		error("hook_supervisor: hook must expose isRunning, isRecovering and last_stop", 2)
	end
	if type(restart) ~= "function" then error("hook_supervisor: restart must be a function", 2) end
	if type(now_ms) ~= "function" then error("hook_supervisor: now_ms must be a function", 2) end

	local backoff = M.RESTART_BACKOFF_MS
	local supervisor = {}
	local attempts, outage, restarted_at, exhausted = 0, nil, nil, false

	--- The restart attempts spent since the hook last proved stable.
	--- @return integer
	function supervisor.attempts()
		return attempts
	end

	--- Observes the hook once; called from the daemon's idle tick whenever the
	--- hook is not running, so it costs nothing while the hook is up. The
	--- stability of the last restart is judged when the next outage begins.
	--- @return string state "running" | "stopped" (deliberate) | "waiting"
	---   | "restarted" | "exhausted"
	function supervisor.poll()
		local now = now_ms()
		if hook.isRunning() or hook.isRecovering() then
			outage = nil
			return "running"
		end
		if exhausted then return "exhausted" end
		if not outage then
			local stop = hook.last_stop()
			if stop and stop.deliberate then return "stopped" end
			if attempts > 0 and restarted_at and now - restarted_at >= M.STABLE_RESET_MS then
				Logger.info(LOG, "The last restart held for %.0f s; the restart budget is restored.",
					(now - restarted_at) / 1000)
				attempts = 0
			end
			restarted_at = nil
			outage = { due = now + backoff[attempts + 1] }
			_lifetime.outages = _lifetime.outages + 1
			Logger.error(LOG, "Keyboard hook stopped unexpectedly (%s) — restarting it in %.1f s (attempt %d of %d).",
				tostring(stop and (stop.detail or stop.reason) or "no cause recorded"), backoff[attempts + 1] / 1000,
				attempts + 1, #backoff)
			return "waiting"
		end
		if now < outage.due then return "waiting" end
		attempts = attempts + 1
		local called, started, reason = pcall(restart)
		if called and started == true and hook.isRunning() then
			outage, restarted_at = nil, now
			_lifetime.restarts = _lifetime.restarts + 1
			Logger.success(LOG, "Keyboard hook restarted (attempt %d of %d).", attempts, #backoff)
			return "restarted"
		end
		local why = called and tostring(reason or "start refused") or ("restart raised: " .. tostring(started))
		if attempts >= #backoff then
			exhausted = true
			_lifetime.exhausted = _lifetime.exhausted + 1
			Logger.error(LOG, "Keyboard hook restart failed (%s); giving up after %d attempt(s).", why, attempts)
			return "exhausted"
		end
		outage.due = now + backoff[attempts + 1]
		Logger.error(LOG, "Keyboard hook restart failed (%s) — next attempt in %.1f s (%d of %d).",
			why, backoff[attempts + 1] / 1000, attempts + 1, #backoff)
		return "waiting"
	end

	return supervisor
end

--- The outages, restarts and spent budgets every supervisor of this process
--- recorded since it started.
--- @return table figures { outages, restarts, exhausted } (a copy).
function M.lifetime()
	return { outages = _lifetime.outages, restarts = _lifetime.restarts, exhausted = _lifetime.exhausted }
end

--- Forgets the lifetime figures (test seam).
function M._reset_lifetime_for_test()
	_lifetime = { outages = 0, restarts = 0, exhausted = 0 }
end

return M
