--- modules/keystats/network_watcher.lua

--- ==============================================================================
--- MODULE: Connectivity Transitions (macOS)
--- DESCRIPTION:
--- Records Internet reachability and VPN transitions as the Windows
--- events_network rows (keystats_network.ahk): internet_up / internet_down and
--- vpn_connected / vpn_disconnected with the same `adapter` sentinel.
---
--- FEATURES & RATIONALE:
--- 1. Same kinds, reducer and sampler as Linux: _shared/metrics/engine/
---    network_transitions.lua; this module only supplies the macOS probes.
--- 2. Nothing blocks the run loop and nothing needs a permission: the system
---    resolver answers the Windows NCSI host's reachability by callback, and
---    the tunnel interfaces (utun, ipsec, ppp) are read by an asynchronous
---    ifconfig, both through adapters.network_info.
--- 3. The shared cadences: the reachability answer is kept as it arrives and
---    reduced every [keystats] network_reach_tick_ms; the tunnels are read every
---    network_vpn_tick_ms. Until the resolver answers, the state is unknown and
---    Windows' starting state (Internet up) holds.
--- 4. No timer of its own: the keystats maintenance tick calls tick().
--- 5. Explicit lifecycle: start() binds the recorder and the reachability watch
---    once; stop() releases the watch and forgets the state.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.logger")
local Timings = require("infra.timings")
local Transitions = require("metrics.engine.system.network_transitions")

local LOG = "keystats.network_watcher"

-- The bound session, nil while stopped.
local _session = nil

--- The production ports: the network adapter and the monotonic clock.
--- @return table ports
local function default_ports()
	local NetworkInfo = require("core.network.adapters.info")
	local TimerScheduler = require("core.events.timer_scheduler")
	return {
		watch_reachability = NetworkInfo.watch_host_reachability,
		probe_vpn = NetworkInfo.probe_vpn_status,
		now_ms = function() return TimerScheduler.now_ns() / 1000000 end,
	}
end




-- ==============================
-- ==============================
-- ======= 1/ Lifecycle =========
-- ==============================
-- ==============================

--- Starts recording.
--- @param opts table { append fun(entry), app fun():string, private fun():boolean, ports table|nil }
---   ports { watch_reachability, probe_vpn, now_ms } default to adapters.network_info and the timer adapter.
--- @return boolean started
function M.start(opts)
	if _session then
		Logger.warn(LOG, "start() called while running — ignoring duplicate call.")
		return false
	end
	assert(type(opts) == "table" and type(opts.append) == "function" and type(opts.app) == "function"
		and type(opts.private) == "function", "the network watcher needs a recorder, an app and a privacy predicate")
	Logger.start(LOG, "Starting connectivity transitions…")
	local ports = opts.ports or default_ports()
	local session = { reachability = "unknown" }
	session.watch = ports.watch_reachability(Transitions.NCSI_HOST, function(status)
		session.reachability = status
	end)
	session.sampler = Transitions.new({
		record = function(kind, fields)
			-- A tunnel read started before stop() answers into a closed session.
			if _session ~= session then return end
			-- Windows' KL_AppendLog refuses every entry while the context is filtered.
			if opts.private() then return end
			local entry = { type = kind, app = opts.app() or "Unknown" }
			for _, key in ipairs(Transitions.KINDS[kind]) do entry[key] = fields[key] end
			opts.append(entry)
		end,
		reach = function(answer) answer(session.reachability) end,
		vpn = function(answer)
			if not ports.probe_vpn(answer) then error("ifconfig did not start", 0) end
		end,
		now_ms = ports.now_ms,
		reach_ms = Timings.ms("keystats", "network_reach_tick_ms"),
		vpn_ms = Timings.ms("keystats", "network_vpn_tick_ms"),
		on_error = function(message) Logger.error(LOG, "Connectivity: %s.", message) end,
	})
	_session = session
	Logger.success(LOG, "Connectivity transitions are recorded.")
	return true
end

--- Stops recording and releases the reachability watch.
function M.stop()
	if not _session then return end
	local ok, reason = pcall(_session.watch.stop)
	if not ok then Logger.error(LOG, "The reachability watch was not released: %s.", tostring(reason)) end
	_session = nil
	Logger.debug(LOG, "Connectivity transitions are no longer recorded.")
end

--- Whether a session is running.
--- @return boolean
function M.is_running() return _session ~= nil end




-- ==============================
-- ==============================
-- ======= 2/ Tick ==============
-- ==============================
-- ==============================

--- Runs the due probes. Called from the maintenance tick.
function M.tick()
	if _session then _session.sampler.tick() end
end

return M
