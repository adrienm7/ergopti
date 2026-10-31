--- platform/remap/runtime_activation.lua

--- ==============================================================================
--- MODULE: Owned Runtime Activation Rule
--- DESCRIPTION:
--- The one place that decides whether Ergopti's own Karabiner runtime runs
--- (ADR 011 decisions 2 and 3, confirmed by the maintainer on 2026-10-27 and
--- 2026-10-31):
---   - Tap-Hold on: Ergopti closes the user's own Karabiner-Elements through
---     its consented closer and runs its own runtime;
---   - Tap-Hold off: Ergopti never activates its runtime, and the user's own
---     Karabiner stays untouched;
---   - turning Tap-Hold off (or Ergopti stopping) restores the user's Karabiner
---     if, and only if, Ergopti closed it.
---
--- FEATURES & RATIONALE:
--- 1. One Predicate: `wanted` is the single definition of « Tap-Hold on »:
---    « Ergopti uses Karabiner » and the Tap-Hold switch are both on.
--- 2. Only What We Closed: the closer given to the runtime owner is wrapped so
---    that a successful close writes a persisted marker; the restore runs only
---    when that marker exists and clears it once Karabiner's own registration
---    step succeeded. A user who never ran Karabiner, or quit it themselves,
---    never sees it started by Ergopti.
--- 3. Crash Safe: the marker is a file, so a boot after a crash with Tap-Hold
---    off still gives the user their Karabiner back.
--- 4. Ports Only: the owner, the closer, the marker and the options are ports,
---    so the whole rule is tested with fakes.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")

local LOG = "remap.runtime_activation"

--- Whether the owned runtime should run for these settings.
--- @param state table|nil Bridge settings ({ enabled, tap_holds_enabled }).
--- @return boolean wanted
function M.wanted(state)
	return type(state) == "table" and state.enabled == true and state.tap_holds_enabled ~= false
end

--- Wraps a closer so that a successful close is remembered in the marker.
--- @param close function fn(callback(ok)) Karabiner's own quit.
--- @param marker table { set } port.
--- @return function close Same contract.
function M.remembering_close(close, marker)
	assert(type(close) == "function", "Missing Karabiner closer")
	assert(type(marker) == "table" and type(marker.set) == "function", "Missing closed-Karabiner marker")
	return function(callback)
		close(function(ok)
			if ok == true then
				if marker.set() ~= true then
					Logger.error(LOG, "The user's Karabiner was closed but the marker could not be written; "
						.. "it will not be restored automatically.")
				else
					Logger.info(LOG, "Recorded that Ergopti closed the user's Karabiner.")
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
---   close_other_instances() -> boolean, the user's consent.
--- @param ports table owner, restore, marker, close_other_instances.
--- @return table activation { reconcile, restore_if_closed }.
function M.new(ports)
	assert(type(ports) == "table", "Missing activation ports")
	assert(type(ports.owner) == "table" and type(ports.owner.start) == "function"
		and type(ports.owner.stop) == "function" and type(ports.owner.status) == "function", "Missing runtime owner")
	assert(type(ports.restore) == "function", "Missing Karabiner restore port")
	assert(type(ports.marker) == "table" and type(ports.marker.get) == "function"
		and type(ports.marker.clear) == "function", "Missing closed-Karabiner marker")
	assert(type(ports.close_other_instances) == "function", "Missing close option port")
	local activation = {}
	local restoring = false

	--- Gives the user's Karabiner back when Ergopti closed it.
	--- @param callback function|nil fn(restored|nil): true restored, false refused, nil nothing to do.
	function activation.restore_if_closed(callback)
		local done = callback or function() end
		if ports.marker.get() ~= true then return done(nil) end
		if restoring then return done(nil) end
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

	--- Brings the runtime in line with the settings.
	--- @param wanted boolean Result of M.wanted for the current settings.
	--- @param on_admitted function|nil fn() called once when a start is admitted.
	--- @return string action `start`, `starting`, `stop` or `idle`.
	function activation.reconcile(wanted, on_admitted)
		local state = ports.owner.status().state
		if wanted then
			if state == "starting" or state == "admitted" or state == "peers_starting" or state == "ready" then
				return "starting"
			end
			Logger.info(LOG, "Tap-Hold is on: running Ergopti's own Karabiner runtime.")
			local accepted = ports.owner.start({ close_other_instances = ports.close_other_instances() == true },
				function(admitted)
					if admitted == true and on_admitted then on_admitted() end
				end)
			if accepted ~= true then Logger.error(LOG, "The owned runtime refused to start in state %s.", state) end
			return "start"
		end
		local active = state ~= "idle" and state ~= "stopped" and state ~= "uninitialized"
			and state ~= "unavailable" and state ~= "failed"
		if active then
			Logger.info(LOG, "Tap-Hold is off: stopping Ergopti's own Karabiner runtime.")
			-- The owner calls this once its capture is observed retired, even when that is at once.
			ports.owner.stop(function() activation.restore_if_closed() end)
			return "stop"
		end
		-- Nothing of ours runs; a crash may still have left the user's Karabiner closed.
		activation.restore_if_closed()
		return "idle"
	end

	return activation
end

return M
