--- modules/keystats/topology_watcher.lua

--- ==============================================================================
--- MODULE: Window Topology And Capture Presence (macOS)
--- DESCRIPTION:
--- Records the focused window's moves, resizes, state and monitor changes as
--- the Windows events_window_topo rows (keystats_window_topology.ahk), and the
--- presence of a screen-capture or conferencing application as its events_av
--- rows screen_recording_start / screen_recording_end (keystats_av_state.ahk).
---
--- FEATURES & RATIONALE:
--- 1. One reducer for every driver: classification and debounce live in
---    _shared/metrics/engine/system/window_topology.lua and capture_presence.lua.
--- 2. No timer of its own: the keystats maintenance tick calls tick(), which
---    reads topology at the shared [keystats] topo_tick_ms and the application
---    list at av_state_slow_tick_ms, through adapters/window_info (no fork).
--- 3. A private window records nothing and breaks the comparison, as the
---    Windows MF_ShouldFilter guard does; the caller owns pause and consent.
--- 4. Explicit lifecycle: start() binds the recorder once; stop() closes an
---    open capture interval, as Windows KL_AV_Stop does, and forgets the state.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.logger")
local Timings = require("core.timing.engine.timings")
local Topology = require("metrics.engine.system.window_topology")
local Capture = require("metrics.engine.capture_presence")

local LOG = "keystats.topology_watcher"

-- The bound session, nil while stopped.
local _session = nil

--- The production ports: the focused-window adapter and the monotonic clock.
--- @return table ports
local function default_ports()
	local WindowInfo = require("platform.focus.window_info")
	local TimerScheduler = require("core.events.timer_scheduler")
	return {
		focused = WindowInfo.focused_topology,
		running_bundle_ids = WindowInfo.running_bundle_ids,
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
---   ports { focused, running_bundle_ids, now_ms } default to adapters.window_info and the timer adapter.
--- @return boolean started
function M.start(opts)
	if _session then
		Logger.warn(LOG, "start() called while running — ignoring duplicate call.")
		return false
	end
	assert(type(opts) == "table" and type(opts.append) == "function" and type(opts.app) == "function"
		and type(opts.private) == "function", "the topology watcher needs a recorder, an app and a privacy predicate")
	Logger.start(LOG, "Starting window topology and capture-application presence…")
	local ports = opts.ports or default_ports()
	local function emit(kind, fields)
		-- Windows' KL_AppendLog refuses every entry while the context is filtered.
		if opts.private() then return end
		local entry = { type = kind, app = opts.app() or "Unknown" }
		for key, value in pairs(fields) do if key ~= "app" then entry[key] = value end end
		opts.append(entry)
	end
	_session = {
		ports = ports, private = opts.private, app = opts.app,
		reducer = Topology.new(emit), tracker = Capture.new(emit),
		programs = Capture.program_set("macos"),
		topo_ms = Timings.ms("keystats", "topo_tick_ms"), scan_ms = Timings.ms("keystats", "av_state_slow_tick_ms"),
		next_topo = 0, next_scan = 0,
	}
	Logger.success(LOG, "Window topology and capture-application presence are recorded.")
	return true
end

--- Stops recording; closes an open capture interval first.
function M.stop()
	if not _session then return end
	local ok, reason = pcall(_session.tracker.close, "")
	if not ok then Logger.error(LOG, "The open capture interval was not closed: %s.", tostring(reason)) end
	_session = nil
	Logger.debug(LOG, "Window topology and capture-application presence are no longer recorded.")
end

--- Whether a session is running.
--- @return boolean
function M.is_running() return _session ~= nil end




-- ==============================
-- ==============================
-- ======= 2/ Tick ==============
-- ==============================
-- ==============================

--- Runs the due readings. Called from the maintenance tick.
function M.tick()
	local s = _session
	if not s then return end
	local now = s.ports.now_ms()
	if now >= s.next_topo then
		s.next_topo = now + s.topo_ms
		if s.private() then
			s.reducer.reset()
		else
			local observation = s.ports.focused()
			-- No answer is no change: the next answer compares with the last one.
			if type(observation) == "table" then s.reducer.observe(observation, "") end
		end
	end
	if now >= s.next_scan then
		s.next_scan = now + s.scan_ms
		if not s.tracker.observe(Capture.sample(s.ports.running_bundle_ids(), s.programs), "") then
			Logger.debug(LOG, "The application list is unreadable; the capture state is kept.")
		end
	end
end

return M
