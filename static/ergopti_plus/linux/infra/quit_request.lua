--- infra/quit_request.lua

--- ==============================================================================
--- MODULE: Tray Quit Request (Linux)
--- DESCRIPTION:
--- The daemon's answer to the tray's Quit. It follows the shared quit admission
--- (`_shared/lua/quit_admission.lua`, also read by the macOS menu): Quit wins over
--- a reload in flight, waits for a running configuration write or hotstring
--- publication, and is refused only when an exit already owns the process. The
--- tray row tells the user of a refusal with the one `notify.quit_refused` notice.
---
--- FEATURES & RATIONALE:
--- 1. Quit Wins Over Reload: a restart in flight is cancelled (the pending systemd
---    restart is replaced by a stop, the relay is told not to start the launcher)
---    and the shutdown starts, so no successor follows a Quit.
--- 2. Writes Finish First: any registered scope write or rollback, the global
---    composition and a pending hotstring publication are waited for, polled up to
---    the user-quit deadline; a wait that expires is refused with the notice.
--- 3. Refusal Before Effect: the pause layout is applied only once Quit is
---    admitted, so a refused click cannot leave the keyboard on the pause layout
---    of a daemon that keeps running.
--- 4. Facts From Ports: every fact is read from an owner injected here, and a
---    missing owner fails at construction instead of reading as "not busy".
--- 5. No Rollback For A Quit: a daemon that an update watcher started has not
---    reported ready yet during the watcher's wait; an admitted Quit tells the
---    watcher first, so it keeps the update instead of restoring and starting
---    the previous daemon (infra/updater_boot_ready.lua).
--- ==============================================================================

local QuitAdmission = require("quit_admission")
local Logger = require("logger.shim")

local M = {}

local LOG = "infra.quit_request"

--- Builds the tray Quit handler.
--- @param ports table
---   shutdown            table    { is_requested = fn, request = fn(reason) -> boolean }
---   reload_in_flight    function Whether a reload restart already owns the process.
---   abandon_reload      function Cancels that restart; returns false and a detail on failure.
---   writer_active       function Whether a scope write, rollback or the global composition is pending.
---   publication_pending function Whether a hotstring publication is pending.
---   apply_pause_layout  function Applies the pause layout; its failure never blocks the quit.
---   report_update_quit  function (reason) Tells a waiting update watcher that the user quit; its failure never blocks the quit.
---   schedule            function (seconds, callback) -> boolean, arms a one-shot timer.
---   now                 function Monotonic seconds.
---   timeout             number   Seconds a deferred Quit may wait (the user-quit deadline).
---   poll                number   Seconds between two reads while waiting.
---   notify_refused      function (decision) Tells the user of a refusal that comes after the click returned.
--- @return function on_quit (reason?) Returns true when the quit started or is waiting, false when
---   refused at once. Every user Quit (tray row, shortcut, gesture) passes through it; reason names
---   the source and defaults to "tray quit".
function M.new(ports)
	assert(type(ports) == "table", "the quit request needs its ports")
	assert(type(ports.shutdown) == "table" and type(ports.shutdown.is_requested) == "function"
		and type(ports.shutdown.request) == "function", "the quit request needs the shutdown owner")
	for _, name in ipairs({ "reload_in_flight", "abandon_reload", "writer_active", "publication_pending",
		"apply_pause_layout", "report_update_quit", "schedule", "now", "notify_refused" }) do
		assert(type(ports[name]) == "function", "the quit request needs the " .. name .. " port")
	end
	assert(type(ports.timeout) == "number" and type(ports.poll) == "number", "the quit request needs its bounds")

	--- Starts the shutdown for an admitted quit.
	--- @param decision table Admitted decision.
	--- @return boolean started
	local function start(decision, reason)
		if decision.abandon_reload then
			local called, err = pcall(ports.abandon_reload)
			if not called then Logger.error(LOG, "Reload cancellation raised: %s.", tostring(err)) end
		end
		local reported, report_err = pcall(ports.report_update_quit, reason)
		if not reported then Logger.error(LOG, "Update watcher Quit report raised: %s.", tostring(report_err)) end
		if not ports.shutdown.is_requested() then
			local called, err = pcall(ports.apply_pause_layout)
			if not called then Logger.error(LOG, "Quit layout switch raised: %s.", tostring(err)) end
		end
		local accepted = ports.shutdown.request(reason)
		-- A relay restart had already started the shutdown: abandoning it left the
		-- exit running with nothing to follow it, which is what Quit asked for.
		return accepted or (decision.abandon_reload and ports.shutdown.is_requested())
	end

	return function(reason)
		if reason == nil then reason = "tray quit" end
		assert(type(reason) == "string" and reason ~= "", "a user Quit names its source")
		local returned = false
		local result = false
		local state = QuitAdmission.await({
			facts = function()
				local reloading = ports.reload_in_flight() == true
				return {
					owner_available = true,
					exit_pending = ports.shutdown.is_requested() == true and not reloading,
					reload_pending = reloading,
					writer_active = ports.writer_active() == true,
					publication_pending = ports.publication_pending() == true,
				}
			end,
			schedule = ports.schedule,
			now = ports.now,
			timeout = ports.timeout,
			poll = ports.poll,
			warn = function(fmt, ...) Logger.warn(LOG, fmt, ...) end,
			on_admitted = function(decision) result = start(decision, reason) == true end,
			on_refused = function(decision)
				if not decision.timed_out then Logger.warn(LOG, "%s", decision.message) end
				result = false
				if returned then ports.notify_refused(decision) end
			end,
		})
		returned = true
		return state == "waiting" or result
	end
end

--- Wraps a Quit handler for a caller with no row of its own to answer (a
--- shortcut, a gesture, the degraded tray row): a refusal at once is told with
--- the same notice the handler gives a refusal that comes later, as the tray
--- row and Windows' quit admission do (NUI-001).
--- @param on_quit function The handler M.new returned.
--- @param notify_refused function Tells the user of the refusal.
--- @return function quit (reason) -> accepted
function M.notifying(on_quit, notify_refused)
	assert(type(on_quit) == "function" and type(notify_refused) == "function",
		"a notifying Quit needs its handler and its notice")
	return function(reason)
		local accepted = on_quit(reason)
		if accepted == false then notify_refused() end
		return accepted
	end
end

return M
