--- _shared/lua/keystats/window_topology.lua

--- ==============================================================================
--- MODULE: Window Topology Reducer
--- DESCRIPTION:
--- The pure classifier behind the events_window_topo rows of the Lua drivers:
--- one observed geometry of the focused window in, at most one window_move,
--- window_resize or window_state_change and one monitor_focus_change out. It
--- is the port of the Windows KL_Topo_ProcessObservation and
--- KL_Topo_ProcessMonitorObservation (keystats_window_topology.ahk), whose
--- constants it mirrors.
---
--- FEATURES & RATIONALE:
--- 1. Same vocabulary and metadata keys as Windows, so the three drivers' rows
---    merge in one dashboard. virtual_desktop_switch is left out on purpose:
---    Windows guesses it from focus changes, while macOS and Linux X11 read the
---    real current desktop and record it as space_change.
--- 2. Debounced as on Windows: a change must persist DEBOUNCE_TICKS polls, so a
---    drag in progress is one event, not one per poll. Monitor identity has its
---    own debounce, or a cross-monitor drag's move would consume it.
--- 3. A new window is a new baseline, never a resize: geometry is comparable
---    only within one window identity.
--- 4. No OS calls and no clock: the drivers own the reads, the poll cadence (the
---    shared timing [keystats] topo_tick_ms) and the recorder, which applies
---    the collection consent.
--- ==============================================================================

local M = {}

--- Minimum position shift (px) classified as a move rather than jitter.
M.MOVE_THRESHOLD_PX = 10

--- Minimum size change (px) classified as a resize.
M.RESIZE_THRESHOLD_PX = 8

--- A window this close to half its monitor's width is snapped.
M.SNAP_TOLERANCE_PX = 4

--- Consecutive polls a change must persist before it is recorded.
M.DEBOUNCE_TICKS = 2

--- The events_window_topo kinds and the metadata keys each carries, as Windows writes them.
M.KINDS = {
	window_state_change = { "from_state", "to_state", "x", "y", "w", "h" },
	window_resize = { "old_w", "old_h", "new_w", "new_h" },
	window_move = { "from_x", "from_y", "to_x", "to_y" },
	monitor_focus_change = { "from_monitor", "to_monitor" },
}

--- The window states a driver may report before the snap inference.
local RAW_STATES = { normal = true, maximized = true, minimized = true }

--- The Windows state of a window: a normal window half its monitor's width is snapped.
--- @param raw_state string "normal", "maximized" or "minimized".
--- @param width number Window width in pixels.
--- @param monitor_width number|nil Width of the monitor holding the window.
--- @return string state
function M.classify_state(raw_state, width, monitor_width)
	assert(RAW_STATES[raw_state], "unknown window state: " .. tostring(raw_state))
	if raw_state ~= "normal" or type(monitor_width) ~= "number" or monitor_width <= 0 then return raw_state end
	if math.abs(width - math.floor(monitor_width / 2)) <= M.SNAP_TOLERANCE_PX then return "snapped" end
	return "normal"
end

--- Creates one reducer.
--- @param emit fun(kind:string, fields:table) Receives each settled change.
--- @return table reducer { observe(observation, app), reset() }
function M.new(emit)
	assert(type(emit) == "function", "the topology reducer needs a recorder")
	local s = {}
	local self = {}

	function self.reset()
		s.window, s.x, s.y, s.w, s.h, s.state = nil, nil, nil, 0, 0, ""
		s.monitor = ""
		s.pending_type, s.pending_data, s.pending_ticks = "", nil, 0
		s.monitor_from, s.monitor_to, s.monitor_ticks = "", "", 0
	end

	local function observe_monitor(monitor_id, app)
		if monitor_id == "" or monitor_id == s.monitor then
			s.monitor_from, s.monitor_to, s.monitor_ticks = "", "", 0
			return
		end
		if s.monitor_from == s.monitor and s.monitor_to == monitor_id then
			s.monitor_ticks = s.monitor_ticks + 1
		else
			s.monitor_from, s.monitor_to, s.monitor_ticks = s.monitor, monitor_id, 1
		end
		if s.monitor_ticks < M.DEBOUNCE_TICKS then return end
		-- A window first seen without a monitor has no origin to leave.
		if s.monitor ~= "" then
			emit("monitor_focus_change", { app = app, from_monitor = s.monitor, to_monitor = monitor_id })
		end
		s.monitor = monitor_id
		s.monitor_from, s.monitor_to, s.monitor_ticks = "", "", 0
	end

	--- Feeds one observation of the focused window.
	--- @param o table { window, x, y, w, h, state, monitor = { id, width }|nil }
	--- @param app string Application name the rows carry.
	function self.observe(o, app)
		assert(type(o) == "table" and o.window ~= nil, "a topology observation names its window")
		for _, key in ipairs({ "x", "y", "w", "h" }) do
			assert(type(o[key]) == "number", "a topology observation needs its " .. key)
		end
		local monitor = type(o.monitor) == "table" and o.monitor or {}
		local monitor_id = type(monitor.id) == "string" and monitor.id or ""
		local state = M.classify_state(o.state, o.w, monitor.width)
		if s.w == 0 or o.window ~= s.window then
			self.reset()
			s.window, s.x, s.y, s.w, s.h, s.state, s.monitor = o.window, o.x, o.y, o.w, o.h, state, monitor_id
			return
		end

		local kind, data = nil, { app = app }
		if state ~= s.state then
			kind = "window_state_change"
			data.from_state, data.to_state = s.state, state
			data.x, data.y, data.w, data.h = o.x, o.y, o.w, o.h
		elseif math.abs(o.w - s.w) > M.RESIZE_THRESHOLD_PX or math.abs(o.h - s.h) > M.RESIZE_THRESHOLD_PX then
			kind = "window_resize"
			data.old_w, data.old_h, data.new_w, data.new_h = s.w, s.h, o.w, o.h
		elseif math.abs(o.x - s.x) > M.MOVE_THRESHOLD_PX or math.abs(o.y - s.y) > M.MOVE_THRESHOLD_PX then
			kind = "window_move"
			data.from_x, data.from_y, data.to_x, data.to_y = s.x, s.y, o.x, o.y
		end

		if kind == nil then
			s.pending_ticks = 0
			s.x, s.y, s.w, s.h, s.state = o.x, o.y, o.w, o.h, state
		else
			if kind == s.pending_type then
				s.pending_ticks = s.pending_ticks + 1
				s.pending_data = data
			else
				s.pending_type, s.pending_data, s.pending_ticks = kind, data, 1
			end
			if s.pending_ticks >= M.DEBOUNCE_TICKS then
				emit(kind, s.pending_data)
				s.pending_type, s.pending_data, s.pending_ticks = "", nil, 0
				s.x, s.y, s.w, s.h, s.state = o.x, o.y, o.w, o.h, state
			end
		end
		observe_monitor(monitor_id, app)
	end

	self.reset()
	return self
end

return M
