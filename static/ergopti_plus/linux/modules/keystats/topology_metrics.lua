--- modules/keystats/topology_metrics.lua

--- ==============================================================================
--- MODULE: Window Topology And Capture Presence (Linux)
--- DESCRIPTION:
--- Records the focused window's moves, resizes, state and monitor changes as
--- the Windows events_window_topo rows (keystats_window_topology.ahk), and the
--- presence of a screen-capture or conferencing program as its events_av rows
--- screen_recording_start / screen_recording_end (keystats_av_state.ahk).
---
--- FEATURES & RATIONALE:
--- 1. One reducer for every driver: the classification and debounce live in
---    _shared/metrics/engine/system/window_topology.lua and capture_presence.lua.
--- 2. No fork on the poll. Topology is read from the X server in this process
---    (adapters/x11_focus.lua, libxcb) at the shared [keystats] topo_tick_ms;
---    the program list is /proc/<pid>/comm, read every av_state_slow_tick_ms
---    and bounded at MAX_PROCESSES entries.
--- 3. Wayland grants a client no other window's geometry: topology is then not
---    measured, records nothing, and the Metrics menu names it with its reason
---    (window_topology_availability), as for desktop changes. Capture presence
---    reads /proc and is measured on every session.
--- 4. The keystats recorder applies the collection consent, the pause and the
---    excluded applications, and stamps the focused application.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local Timings = require("infra.timings")
local Topology = require("metrics.engine.system.window_topology")
local Capture = require("metrics.engine.capture_presence")

local LOG = "modules.keystats.topology_metrics"

--- Most /proc entries one capture scan reads.
M.MAX_PROCESSES = 4096

--- The default reason topology is not measured.
local NEEDS_X11 = "platform_reason.window_topology_needs_x11"

-- The bound topology reader and, without one, why. Set by bind_topology_source.
local _source = { read = nil, reason = NEEDS_X11 }




-- ==============================
-- ==============================
-- ======= 1/ Sources ===========
-- ==============================
-- ==============================

--- Binds the focused-window topology reader, or none with the reason.
--- @param read function|nil Returns { window, x, y, w, h, state, monitor } or nil.
--- @param reason string|nil i18n key of why topology is not measured.
function M.bind_topology_source(read, reason)
	assert(read == nil or type(read) == "function", "a topology source is a function")
	_source = { read = read, reason = read == nil and (reason or NEEDS_X11) or nil }
	if M._daemon then M._daemon.set_topology(read) end
end

--- Whether window topology is measured.
--- @return table { measured = boolean, reason = string|nil }
function M.window_topology_availability()
	return { measured = _source.read ~= nil, reason = _source.reason }
end

--- The names of the running processes from procfs, without forking.
--- @param root string The proc directory.
--- @param list fun(path):table|nil Directory entries { name, kind }.
--- @param read fun(path):string|nil First line of a file.
--- @return table|nil names nil when the directory cannot be listed.
function M.process_names(root, list, read)
	local entries = list(root)
	if entries == nil then return nil end
	local names = {}
	for index, entry in ipairs(entries) do
		if index > M.MAX_PROCESSES then break end
		if entry.name:match("^%d+$") then
			-- A process that exited between the listing and the read has no name.
			local name = read(root .. "/" .. entry.name .. "/comm")
			if name and name ~= "" then names[#names + 1] = name end
		end
	end
	return names
end




-- ==============================
-- ==============================
-- ======= 2/ Sampler ===========
-- ==============================
-- ==============================

--- Creates the sampler.
--- @param opts table { record fun(kind, fields), topology fun():table|nil, processes fun():table|nil, now_ms fun():number }
--- @return table sampler { tick, close, set_topology }
function M.new(opts)
	assert(type(opts) == "table" and type(opts.record) == "function", "the topology sampler needs a recorder")
	assert(type(opts.processes) == "function" and type(opts.now_ms) == "function", "the topology sampler needs its ports")
	local topo_ms = Timings.ms("keystats", "topo_tick_ms")
	local scan_ms = Timings.ms("keystats", "av_state_slow_tick_ms")
	local programs = Capture.program_set("linux")
	local reducer = Topology.new(opts.record)
	local tracker = Capture.new(opts.record)
	local state = { topology = opts.topology, next_topo = 0, next_scan = 0 }
	local self = {}

	function self.set_topology(read)
		state.topology = read
		reducer.reset()
	end

	--- Runs the due readings. The recorder stamps the application itself.
	function self.tick()
		local now = opts.now_ms()
		if state.topology and now >= state.next_topo then
			state.next_topo = now + topo_ms
			local read, observation = pcall(state.topology)
			-- No answer is no change: the next answer compares with the last one.
			if read and type(observation) == "table" then reducer.observe(observation, "") end
		end
		if now >= state.next_scan then
			state.next_scan = now + scan_ms
			local read, names = pcall(opts.processes)
			if not tracker.observe(Capture.sample(read and names or nil, programs), "") then
				Logger.debug(LOG, "The process list is unreadable; the capture state is kept.")
			end
		end
	end

	--- Closes an open capture interval, as the Windows collector does when it stops.
	function self.close() tracker.close("") end

	return self
end

--- The daemon's ports: the bound X11 reader and procfs.
--- @param record fun(kind, fields) The keystats recorder.
--- @return table sampler
function M.start(record)
	local NativeDirectory = require("infra.native_directory")
	local function read(path)
		local handle = io.open(path, "rb")
		if not handle then return nil end
		local line = handle:read("*l")
		handle:close()
		return line
	end
	local sampler = M.new({
		record = record,
		topology = _source.read,
		processes = function()
			return M.process_names("/proc", function(path) return NativeDirectory.entries(path) end, read)
		end,
		now_ms = function() return require("infra.monotonic").now_ms() end,
	})
	if _source.read then
		Logger.info(LOG, "Window topology and capture-program presence are recorded.")
	else
		Logger.info(LOG, "Capture-program presence is recorded; window topology is not measured (%s).", _source.reason)
	end
	return sampler
end

--- The daemon's tick: starts the one sampler on first use, then runs it.
--- @param record fun(kind, fields) The keystats recorder.
function M.daemon_tick(record)
	if M._disabled then return end
	local ok, reason = pcall(function()
		M._daemon = M._daemon or M.start(record)
		M._daemon.tick()
	end)
	if not ok then
		-- Once, rather than one error per daemon tick.
		M._disabled = true
		Logger.error(LOG, "Window topology and capture presence are no longer recorded: %s.", tostring(reason))
	end
end

--- Closes the daemon's open capture interval at shutdown.
function M.daemon_stop()
	if not M._daemon then return end
	local ok, reason = pcall(M._daemon.close)
	if not ok then Logger.error(LOG, "The open capture interval was not closed: %s.", tostring(reason)) end
	M._daemon = nil
end

--- Restores the module's initial state (tests).
function M._reset()
	_source = { read = nil, reason = NEEDS_X11 }
	M._daemon, M._disabled = nil, nil
end

return M
