--- platform/remap/runtime_activation.lua

--- ==============================================================================
--- MODULE: Owned Runtime Activation Rule
--- DESCRIPTION:
--- The one place that decides whether Ergopti's own Karabiner runtime runs.
--- The maintainer's rule of 2026-10-31 (ADR 011 decision 3, as revised) ties it
--- to Ergopti running, not to any menu switch:
---   - Ergopti running and not paused: its own runtime is active, and a user
---     Karabiner-Elements that runs is closed through Karabiner's own quit
---     while the user's consent (the Tap-Holds row, on by default) holds;
---     without it the owner reports `other_karabiner_running` and ours waits;
---   - Ergopti paused or quit: its runtime stops, and the user's Karabiner is
---     given back if, and only if, Ergopti closed it.
---
--- FEATURES & RATIONALE:
--- 1. One Predicate: `wanted` is running and not paused; no feature switch.
--- 2. Only What We Closed: the closer given to the runtime owner is wrapped so
---    that a successful close writes a persisted marker and tells the user;
---    the restore runs only when that marker exists and clears it once
---    Karabiner's own registration step succeeded. A user who never ran
---    Karabiner, or quit it themselves, never sees it started by Ergopti.
--- 3. Crash Safe: the marker is a file, so after a crash or a forced quit the
---    next start still knows that the user's Karabiner is Ergopti's to give
---    back, at the next pause or quit.
--- 4. One Capture Per Lua VM: the launcher's capture session cannot start twice
---    in one Lua VM (ADR 011 decision 8), so a resume after a stop asks for a
---    reload, and the reloaded driver starts the runtime as it starts on boot.
--- 5. Ports Only: the owner, the closer, the marker, the notifier and the
---    reload are ports, so the whole rule is tested with fakes.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")

local LOG = "remap.runtime_activation"

local ACTIVE = { starting = true, admitted = true, peers_starting = true, ready = true, stopping = true }

--- Whether the owned runtime should run.
--- @param lifecycle table|nil { running = boolean, paused = boolean }.
--- @return boolean wanted
function M.wanted(lifecycle)
	return type(lifecycle) == "table" and lifecycle.running == true and lifecycle.paused ~= true
end

--- Wraps a closer so that a successful close is remembered and announced.
--- @param close function fn(callback(ok)) Karabiner's own quit.
--- @param marker table { set } port.
--- @param announce function|nil fn() telling the user their Karabiner was closed.
--- @return function close Same contract.
function M.remembering_close(close, marker, announce)
	assert(type(close) == "function", "Missing Karabiner closer")
	assert(type(marker) == "table" and type(marker.set) == "function", "Missing closed-Karabiner marker")
	assert(announce == nil or type(announce) == "function", "Invalid closed-Karabiner announcement")
	return function(callback)
		close(function(ok)
			if ok == true then
				if marker.set() ~= true then
					Logger.error(LOG, "The user's Karabiner was closed but the marker could not be written; "
						.. "it will not be restored automatically.")
				else
					Logger.info(LOG, "Recorded that Ergopti closed the user's Karabiner.")
				end
				if announce then
					local shown, failure = pcall(announce)
					if not shown then Logger.error(LOG, "The closed-Karabiner notice failed: %s.", tostring(failure)) end
				end
			end
			callback(ok)
		end)
	end
end

--- Creates the activation rule bound to its ports.
--- Port contracts:
---   owner: platform/remap/runtime_owner.lua (start, stop, status);
---   restore(fn(ok)): Karabiner's own registration of its core agents;
---   marker: { get() -> boolean, clear() -> boolean };
---   reload(): asks for a reload of the driver, the only way to start a second capture;
---   close_other_instances() -> boolean: the user's consent, the Tap-Holds row.
--- @param ports table owner, restore, marker, reload, close_other_instances.
--- @return table activation { reconcile, restore_if_closed }.
function M.new(ports)
	assert(type(ports) == "table", "Missing activation ports")
	assert(type(ports.owner) == "table" and type(ports.owner.start) == "function"
		and type(ports.owner.stop) == "function" and type(ports.owner.status) == "function", "Missing runtime owner")
	assert(type(ports.restore) == "function", "Missing Karabiner restore port")
	assert(type(ports.marker) == "table" and type(ports.marker.get) == "function"
		and type(ports.marker.clear) == "function", "Missing closed-Karabiner marker")
	assert(type(ports.reload) == "function", "Missing driver reload port")
	assert(type(ports.close_other_instances) == "function", "Missing close consent port")
	local activation = {}
	local restoring = false
	local started_once = false

	--- Gives the user's Karabiner back when Ergopti closed it.
	--- @param callback function|nil fn(restored|nil): true restored, false refused, nil nothing to do.
	function activation.restore_if_closed(callback)
		local done = callback or function() end
		if ports.marker.get() ~= true or restoring then return done(nil) end
		restoring = true
		Logger.start(LOG, "Restoring the user's Karabiner, which Ergopti closed…")
		ports.restore(function(ok)
			restoring = false
			if ok ~= true then
				Logger.error(LOG, "The user's Karabiner could not be restored; it stays closed until opened.")
				return done(false)
			end
			if ports.marker.clear() ~= true then
				Logger.error(LOG, "The user's Karabiner was restored but the marker could not be cleared.")
			end
			Logger.success(LOG, "Restored the user's Karabiner.")
			done(true)
		end)
	end

	--- Brings the runtime in line with the lifecycle.
	--- @param wanted boolean Result of M.wanted.
	--- @param on_admitted function|nil fn() called once when a start is admitted.
	--- @return string action `start`, `starting`, `reload`, `stop` or `idle`.
	function activation.reconcile(wanted, on_admitted)
		local state = ports.owner.status().state
		if wanted then
			if ACTIVE[state] and state ~= "stopping" then return "starting" end
			if started_once then
				-- This VM already ran a capture: only a reloaded driver can start one.
				Logger.info(LOG, "Ergopti resumes: reloading to start its own Karabiner runtime again.")
				ports.reload()
				return "reload"
			end
			Logger.info(LOG, "Ergopti runs: starting its own Karabiner runtime.")
			local accepted = ports.owner.start({ close_other_instances = ports.close_other_instances() == true },
				function(admitted)
					if admitted ~= true then return end
					-- Only an admitted runtime goes on to its capture, the part that cannot start twice.
					started_once = true
					if on_admitted then on_admitted() end
				end)
			if accepted ~= true then Logger.error(LOG, "The owned runtime refused to start in state %s.", state) end
			return "start"
		end
		if ACTIVE[state] then
			Logger.info(LOG, "Ergopti pauses: stopping its own Karabiner runtime.")
			-- The owner calls this once its capture is observed retired, even when that is at once.
			ports.owner.stop(function() activation.restore_if_closed() end)
			return "stop"
		end
		activation.restore_if_closed()
		return "idle"
	end

	return activation
end

return M
