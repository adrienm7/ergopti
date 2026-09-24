--- ui/wpm/wpm_widget.lua

--- ==============================================================================
--- MODULE: WPM Floating Widget UI
--- DESCRIPTION:
--- Renders a floating canvas showing the current typing speed (WPM), with an
--- optional real-time line graph of recent history.
---
--- FEATURES & RATIONALE:
--- 1. Pure Canvas: Uses hs.canvas for high-performance, low-overhead rendering
---    without the need for an embedded webview.
--- 2. Autonomous Polling: Manages its own lifecycle and history array.
--- 3. Dynamic Styling: Visual feedback changes color based on the typing source.
--- 4. Effective WPM: Displays the net typing speed, visualizing productivity spikes.
--- ==============================================================================

local M = {}

local hs         = hs
local keylogger  = require("modules.keylogger")
local WPMShared  = require("ui.wpm.shared")
local Logger     = require("infra.logger")
local Paths      = require("infra.paths")
local GraphicsRenderer = require("adapters.graphics_renderer")
local Storage = require("adapters.storage")
local TimerScheduler = require("adapters.timer_scheduler")
local Timings = require("infra.timings")
local TomlCodec = require("toml_codec")
-- What the readouts decide — colours, frames, the graph, the default place —
-- shared with the Linux driver.
local WPMModel = require("wpm_widget.model")

local LOG = "wpm_widget"

--- Returns true when the given path exists and is a readable file.
--- @param path string File path.
--- @return boolean
local function file_exists(path)
	if type(path) ~= "string" or path == "" then return false end
	local f = io.open(path, "r")
	if not f then return false end
	f:close()
	return true
end

--- Resolves an absolute shared constants path.
--- Priority: module-relative -> hs.configdir-relative -> upward search.
--- Resolves the absolute path to a shared resource file (fail-fast).
--- Priority: module-relative > upward search > ERROR
--- Passes the first path that exists; logs ERROR and returns nil if none found.
--- @param rel string Relative path under static/ergopti_plus/_shared/.
--- @return string|nil Absolute path if found, nil if missing (ERROR logged).
local function resolve_shared_constants_path(rel)
	-- Resolved through the single shared-tree resolver (Paths.shared), which
	-- performs the dual-root upward walk — robust to dev checkouts, packaged
	-- .app builds and symlinked ~/.hammerspoon setups alike.
	local path = Paths.shared(rel)
	if path and file_exists(path) then
		Logger.debug(LOG, "resolve_shared_constants_path('%s'): resolved via Paths.shared.", rel)
		return path
	end

	-- FAIL FAST: path not found — do not silently degrade.
	Logger.error(LOG, "resolve_shared_constants_path('%s'): file not found after all attempts.", rel)
	return nil
end





-- ================================
-- ================================
-- ======= 1/ Configuration =======
-- ================================
-- ================================

-- Reads the shared canon (_shared/modules/wpm_widget/constants.toml, checked
-- key by key by the shared model) and the refresh, hold and idle timings.
-- Fails SOFT per field: an unusable canon logs an ERROR and leaves every canon
-- field nil rather than raising at module load, where the require-time pcall in
-- menu_metrics would silently drop the whole widget.
local function _load_shared_const()
	local path = resolve_shared_constants_path("modules/wpm_widget/constants.toml")
	local canon, err = nil, "not found"
	if path then canon, err = WPMModel.load(path, TomlCodec.decode) end
	if not canon then
		Logger.error(LOG, "_load_shared_const: the WPM canon is unusable (%s) — widget non-functional.", tostring(err))
	end

	local function timing_s(key)
		local ok, value = pcall(Timings.sec, "ui", key)
		if not ok then
			Logger.error(LOG, "_load_shared_const: missing timing [ui].%s — leaving nil.", key)
			return nil
		end
		return value
	end

	local compact = canon and canon.compact or {}
	local colors  = canon and canon.colors or {}
	return {
		canon                 = canon,
		compact_width         = compact.width,
		compact_height_number = compact.height_number,
		compact_height_gap    = compact.height_gap,
		compact_height_unit   = compact.height_unit,
		compact_unit_darken   = compact.unit_strip_darken_factor,
		color_bg_manual       = colors.bg_manual,
		color_bg_idle         = colors.bg_idle,
		color_txt_active_alpha = canon and canon.transparency.alpha_active / 255 or nil,
		idle_hide_s           = timing_s("wpm_widget_idle_hide_ms"),
		source_color_duration = timing_s("wpm_color_hold_ms"),
		update_s              = timing_s("wpm_widget_update_ms"),
	}
end

-- Exposed for the shared-constants regression test (test_wpm_shared_constants):
-- it asserts every value is sourced from the shared canon, with no re-typed
-- literal default in this loader.
M._load_shared_const = _load_shared_const

local CONFIG     = _load_shared_const()
local IDLE_HIDE_S = CONFIG.idle_hide_s
-- Minimum interval between mouseMoved updates of _last_mouse_sec.
-- Each mouseMoved fires hundreds of times/sec; without throttling, every
-- move re-enters the Lua VM, adding jitter to the input pipeline.
-- Non-move events (clicks, scrollWheel) bypass the throttle and always win.
local MOUSE_MOVE_THROTTLE_SEC = 0.2





-- ========================
-- ========================
-- ======= 2/ State =======
-- ========================
-- ========================

local _canvas            = nil
local _timer             = nil
local _mouse_tap         = nil   -- hs.eventtap watching mouse/touchpad events
local _running           = false -- true between start() and stop(); guards redundant restarts
-- A failed pause rollback can leave the runtime stopped while the pre-pause
-- intent is still owed. Keep that ownership outside `_running` so a later
-- pause transaction inventories this surface again and can finish restoring it.
local _pause_restore_pending = false
local _generation        = 0
local _wpm_history       = {}
local _show_graph        = false
local _use_source_colors = true
local _last_active_sec   = 0    -- wall clock of the last keystroke seen by this widget
local _last_mouse_sec    = 0    -- wall clock of the last mouse/touchpad event

-- Current-cycle canvas geometry, shared with the mouseCallback closure below.
-- The closure is created ONCE, the first time update_widget_body() creates
-- _canvas — but canvas_width/compact_w/compact_h are plain locals re-declared
-- on every subsequent call. A closure that captured those locals directly
-- would keep reading the values from the single call that happened to create
-- the canvas, forever — including after the user toggles graph mode, at which
-- point a drag's mouseUp position math (target compact-anchor conversion)
-- would use stale dimensions from a completely different mode. Routing both
-- the read (mouseCallback) and the write (every update_widget_body cycle)
-- through this same table keeps the closure's view of geometry current.
local _canvas_geom = { canvas_width = 0, canvas_height = 0, compact_w = 0, compact_h = 0 }

-- Saved position: top-left of the compact mode widget; nil = recalculate default.
-- Persisted across sessions via hs.settings so drag survives a Hammerspoon reload.
local _SETTINGS_X = "wpm_widget.pos_x"
local _SETTINGS_Y = "wpm_widget.pos_y"
-- Coerce with tonumber: a corrupt / hand-edited plist can return a STRING here,
-- which is only guarded by `if not _pos_x` downstream (a non-empty string passes)
-- and then flows into arithmetic (_pos_x + compact_w …) and hs.canvas geometry,
-- raising in the timer/layout callback (swallowed to the HS Console). tonumber
-- yields nil for a non-numeric value so the existing default-recompute fires.
local _pos_x      = tonumber(Storage.get(_SETTINGS_X))
local _pos_y      = tonumber(Storage.get(_SETTINGS_Y))

-- Drag state.
local _drag_start_mouse = nil
local _drag_start_frame = nil

--- Revokes a drag whose mouseUp belongs to the current canvas lifecycle.
local function clear_drag_lease()
	_drag_start_mouse = nil
	_drag_start_frame = nil
end





-- ===================================
-- ===================================
-- ======= 3/ Canvas Rendering =======
-- ===================================
-- ===================================

-- Forward declaration: update_widget() (the pcall wrapper) is defined before its
-- body so the body can be a plain local function referenced by name below.
local update_widget_body

--- Polls the engine and redraws the canvas.
--- Wrapped end-to-end in a pcall (mirrors tooltip_hotstring.lua / tooltip_llm.lua):
--- this runs on a bare hs.timer callback with no caller to catch a raised error,
--- and there is no hs.uncaughtErrorHandler anywhere in the tree, so an unguarded
--- fault here would silently kill the 0.2 s timer with nothing in the file logger.
local function update_widget()
	local ok, err = pcall(update_widget_body)
	if not ok then Logger.error(LOG, "Crash during widget update: " .. tostring(err) .. ".") end
end

--- Actual widget-update body, wrapped by update_widget() above.
update_widget_body = function()
	local stats = keylogger.get_live_stats()
	local display_wpm = stats.wpm or 0
	local now = hs.timer.absoluteTime() / 1000000000
	local active_source = WPMShared.get_active_source(stats, CONFIG.source_color_duration, now)

	local ok_tooltip, tooltip = pcall(require, "ui.tooltip")
	local tooltip_visible = false
	if ok_tooltip and type(tooltip) == "table" and type(tooltip.is_visible) == "function" then
		tooltip_visible = tooltip.is_visible()
	end

	local canon = CONFIG.canon
	if not canon then return end
	local frame_opts = {
		now_s = now,
		hold_s = CONFIG.source_color_duration,
		use_colors = _use_source_colors,
		resolve = WPMShared.resolve_group_hex,
		unit = WPMShared.unit_label(),
	}

	-- One sample per refresh for the graph, and the shared rule for showing:
	-- while text appears or a preview is up, and briefly after — unless the
	-- mouse moved since the last keystroke.
	WPMModel.push_history(canon, _wpm_history, display_wpm, active_source)
	local show
	show, _last_active_sec = WPMModel.widget_visible({
		wpm = display_wpm, source = active_source, tooltip_visible = tooltip_visible, now_s = now,
		last_active_s = _last_active_sec, last_mouse_s = _last_mouse_sec, idle_hide_s = IDLE_HIDE_S,
	})

	if show then
		-- hs.screen.mainScreen() is documented as possibly returning nil (e.g. no
		-- display attached, or a display-reconfiguration race) — dereferencing it
		-- unconditionally would raise inside this pcall-wrapped body every 0.2 s
		-- until a screen reappears. Skip this cycle instead of crashing.
		local screen = hs.screen.mainScreen()
		if not screen then
			Logger.error(LOG, "update_widget: hs.screen.mainScreen() returned nil — skipping this cycle.")
			return
		end
		local full_frame = screen:fullFrame()
		local frame = _show_graph and WPMModel.graph_frame(canon, _wpm_history, stats, frame_opts)
			or WPMModel.compact_frame(canon, stats, frame_opts)
		local canvas_width, canvas_height = frame.width, frame.height
		local compact_w = canon.compact.width
		local compact_h = canon.compact.height_number + canon.compact.height_gap + canon.compact.height_unit

		-- Publish this cycle's geometry for the mouseCallback closure (see the
		-- _canvas_geom declaration in section 2 for why this indirection exists).
		_canvas_geom.canvas_width  = canvas_width
		_canvas_geom.canvas_height = canvas_height
		_canvas_geom.compact_w     = compact_w
		_canvas_geom.compact_h     = compact_h

		-- The pill's top-left is the anchor; the graph keeps its bottom-right.
		if not _pos_x then _pos_x, _pos_y = WPMModel.default_anchor(canon, full_frame) end
		local target_x, target_y = WPMModel.frame_origin(canon, frame, _pos_x, _pos_y)

		if not _canvas then
			_canvas = GraphicsRenderer.createWindow({
				x = target_x, y = target_y, w = canvas_width, h = canvas_height,
				clickThrough = false, alwaysOnTop = false,
			})
			if _canvas == 0 then
				_canvas = nil
				Logger.error(LOG, "update_widget_body(): failed to allocate the widget canvas.")
				return
			end
			_canvas:level(hs.drawing.windowLevels.cursor)
			_canvas:behavior({ "canJoinAllSpaces", "stationary" })
			local callback_canvas = _canvas
			local callback_generation = _generation
			-- Drag: mouseCallback fires on left-button down inside the canvas.
			_canvas:mouseCallback(function(c, event, id, x, y)
				-- Native canvas callbacks may already be queued when stop()/pause
				-- deletes the surface. Fence the retained closure both while PAUSED
				-- and after a later start creates a different canvas generation.
				if not _running or callback_generation ~= _generation
					or c ~= callback_canvas or _canvas ~= callback_canvas then
					return
				end
				if event == "mouseDown" then
					_drag_start_mouse = hs.mouse.absolutePosition()
					_drag_start_frame = c:frame()
				elseif event == "mouseUp" then
					clear_drag_lease()
					-- Persist final compact-anchor position.
					-- Read geometry from the live _canvas_geom table, not the plain
					-- canvas_width/compact_w/compact_h locals from the update cycle
					-- that first created this canvas — those locals are frozen at
					-- creation time, while _canvas_geom is refreshed on every
					-- update_widget_body() cycle and reflects the CURRENT mode
					-- (e.g. after the user toggled graph mode post-creation).
					local f = c:frame()
					if _show_graph then
						_pos_x = f.x + _canvas_geom.canvas_width  - _canvas_geom.compact_w
						_pos_y = f.y + _canvas_geom.canvas_height - _canvas_geom.compact_h
					else
						_pos_x = f.x
						_pos_y = f.y
					end
					Storage.set(_SETTINGS_X, _pos_x)
					Storage.set(_SETTINGS_Y, _pos_y)
				elseif event == "mouseMove" and _drag_start_mouse then
					local cur = hs.mouse.absolutePosition()
					local dx  = cur.x - _drag_start_mouse.x
					local dy  = cur.y - _drag_start_mouse.y
					c:frame({
						x = _drag_start_frame.x + dx,
						y = _drag_start_frame.y + dy,
						w = _drag_start_frame.w,
						h = _drag_start_frame.h,
					})
				end
			end)
		else
			-- Only reposition when not dragging.
			if not _drag_start_mouse then
				_canvas:frame({ x = target_x, y = target_y, w = canvas_width, h = canvas_height })
			end
		end

		-- The frame the shared model computed, as hs.canvas elements.
		local elements = {}
		local radii = { xRadius = frame.radius, yRadius = frame.radius }
		if frame.mode == "graph" then
			table.insert(elements, { type = "rectangle", action = "fill",
				fillColor = { hex = frame.background, alpha = frame.background_alpha }, roundedRectRadii = radii })
			table.insert(elements, { type = "rectangle", action = "stroke",
				strokeColor = { hex = frame.border, alpha = frame.border_alpha },
				strokeWidth = frame.border_width, roundedRectRadii = radii })
			if #frame.points > 0 then
				local area = { { x = frame.padding, y = frame.bottom } }
				for _, point in ipairs(frame.points) do area[#area + 1] = point end
				area[#area + 1] = { x = frame.width - frame.padding, y = frame.bottom }
				table.insert(elements, { type = "segments", coordinates = area, action = "fill",
					fillColor = { hex = frame.line, alpha = frame.fill_alpha } })
				table.insert(elements, { type = "segments", coordinates = frame.points, action = "stroke",
					strokeColor = { hex = frame.line, alpha = frame.line_alpha }, strokeWidth = frame.line_width })
			end
			table.insert(elements, { type = "text", text = frame.label,
				textColor = { hex = frame.text, alpha = 1 }, textSize = frame.text_size, textAlignment = "center",
				frame = { x = 0, y = frame.padding, w = frame.width, h = frame.text_size + 6 } })
		else
			-- Two zones: the number over a darker strip holding the unit.
			table.insert(elements, { type = "rectangle", action = "fill",
				fillColor = { hex = frame.background, alpha = frame.alpha }, roundedRectRadii = radii })
			table.insert(elements, { type = "rectangle", action = "fill",
				fillColor = { hex = frame.strip, alpha = frame.alpha },
				frame = { x = 0, y = frame.strip_y, w = frame.width, h = frame.height_unit } })
			table.insert(elements, { type = "text", text = frame.number,
				textColor = { hex = frame.text, alpha = frame.number_alpha },
				textSize = frame.number_font_size, textAlignment = "center",
				frame = { x = 0, y = 0, w = frame.width, h = frame.height_number } })
			table.insert(elements, { type = "text", text = frame.unit,
				textColor = { hex = frame.text, alpha = frame.unit_alpha },
				textSize = frame.unit_font_size, textAlignment = "center",
				frame = { x = 0, y = frame.strip_y, w = frame.width, h = frame.height_unit } })
		end

		_canvas:replaceElements(elements)
		_canvas:show()
	else
		if _canvas then _canvas:hide() end
	end
end

--- Releases the exact recurring timer while retaining refused cleanup debt.
--- @return boolean settled True only when no native timer remains owned.
local function release_timer()
	if not _timer then return true end
	local handle = _timer
	local ok, settled = xpcall(function()
		return TimerScheduler.cancel(handle)
	end, debug.traceback)
	if not ok or settled ~= true then
		Logger.error(LOG, "WPM widget timer cleanup failed; exact handle retained: %s.",
			tostring(ok and settled or settled))
		return false
	end
	if _timer == handle then _timer = nil end
	return true
end

--- Releases the exact mouse eventtap while retaining refused cleanup debt.
--- @return boolean settled True only when no native eventtap remains owned.
local function release_mouse_tap()
	if not _mouse_tap then return true end
	local tap = _mouse_tap
	local ok, stopped = xpcall(function()
		if type(tap.stop) ~= "function" then error("mouse eventtap has no stop method") end
		tap:stop()
		if type(tap.isEnabled) ~= "function" then error("mouse eventtap has no state probe") end
		return tap:isEnabled()
	end, debug.traceback)
	if not ok or stopped ~= false then
		Logger.error(LOG, "WPM widget mouse eventtap cleanup failed; exact handle retained: %s.",
			tostring(ok and stopped or stopped))
		return false
	end
	if _mouse_tap == tap then _mouse_tap = nil end
	return true
end

--- Releases both runtime capabilities without hiding a sibling cleanup failure.
--- @return boolean settled True only when both exact capabilities were released.
local function release_runtime()
	local timer_stopped = release_timer()
	local tap_stopped = release_mouse_tap()
	return timer_stopped and tap_stopped
end





-- =====================================
-- =====================================
-- ======= 4/ Public Control API =======
-- =====================================
-- =====================================

--- Starts the floating widget loop.
--- @param show_graph boolean Whether to draw the history curve.
--- @return boolean committed True only when both polling capabilities are active.
function M.start(show_graph)
	local want_graph = show_graph or false
	-- Idempotent: the menu tree rebuild re-invokes start() on every refresh. Skip the
	-- redundant timer restart and full canvas re-render when already running with the
	-- same graph mode — the 0.2 s timer already keeps the display fresh. Only a real
	-- graph-mode change falls through to redraw immediately.
	if _running and _show_graph == want_graph then
		_pause_restore_pending = false
		return true
	end
	if _running then
		_show_graph = want_graph
		_pause_restore_pending = false
		update_widget()
		return true
	end
	-- A destroyed canvas cannot deliver the mouseUp that closes its drag. Never
	-- let that lease gate positioning or move a later canvas generation.
	clear_drag_lease()
	Logger.debug(LOG, "Starting floating WPM widget…")
	if not release_runtime() then
		Logger.error(LOG, "WPM widget start refused: prior cleanup remains pending.")
		return false
	end
	_show_graph = want_graph
	_generation = _generation + 1
	local generation = _generation
	local timer_ok, timer_candidate, timer_committed = xpcall(function()
		return TimerScheduler.every(CONFIG.update_s, function()
			if not _running or generation ~= _generation then return end
			update_widget()
		end)
	end, debug.traceback)
	if type(timer_candidate) == "table" then _timer = timer_candidate end
	if not timer_ok or type(timer_candidate) ~= "table" or timer_committed ~= true then
		_generation = _generation + 1
		release_timer()
		Logger.error(LOG, "WPM widget timer acquisition failed: %s.",
			tostring(timer_ok and timer_committed or timer_candidate))
		return false
	end

	-- Watch all mouse/touchpad events to know when to hide the widget.
	local tap_ok, tap_candidate = xpcall(function()
		return hs.eventtap.new({
			hs.eventtap.event.types.mouseMoved,
			hs.eventtap.event.types.leftMouseDown,
			hs.eventtap.event.types.rightMouseDown,
			hs.eventtap.event.types.scrollWheel,
		}, function(e)
			if not _running or generation ~= _generation then return false end
			local now = hs.timer.absoluteTime() / 1000000000
			local is_move = e:getType() == hs.eventtap.event.types.mouseMoved
			-- Throttle mouseMoved: only update at most every MOUSE_MOVE_THROTTLE_SEC.
			-- Click and scroll events bypass the throttle — they must always register.
			if not is_move or (now - _last_mouse_sec) >= MOUSE_MOVE_THROTTLE_SEC then
				_last_mouse_sec = now
			end
			return false  -- do not consume the event
		end)
	end, debug.traceback)
	if not tap_ok or tap_candidate == nil or tap_candidate == false then
		_generation = _generation + 1
		release_timer()
		Logger.error(LOG, "WPM widget mouse eventtap construction failed: %s.",
			tostring(tap_candidate))
		return false
	end
	_mouse_tap = tap_candidate
	local start_ok, started = xpcall(function()
		if type(tap_candidate.start) ~= "function" then error("mouse eventtap has no start method") end
		tap_candidate:start()
		if type(tap_candidate.isEnabled) ~= "function" then error("mouse eventtap has no state probe") end
		return tap_candidate:isEnabled()
	end, debug.traceback)
	if not start_ok or started ~= true then
		_generation = _generation + 1
		release_runtime()
		Logger.error(LOG, "WPM widget mouse eventtap start failed: %s.",
			tostring(start_ok and started or started))
		return false
	end
	_running = true
	_pause_restore_pending = false
	update_widget()
	Logger.info(LOG, "Floating WPM widget started successfully.")
	return true
end

--- Halts the widget and clears the screen.
--- @return boolean settled True only when both polling capabilities were released.
function M.stop()
	clear_drag_lease()
	-- Idempotent: a menu rebuild while the widget is off re-invokes stop() repeatedly.
	-- Nothing to tear down means nothing to log — return before the start/stop banner.
	if not _running and not _timer and not _mouse_tap and not _canvas then return true end
	Logger.debug(LOG, "Stopping floating WPM widget…")
	_running = false
	_generation = _generation + 1
	local runtime_stopped = release_runtime()
	if _canvas then _canvas:delete(); _canvas = nil end
	if not runtime_stopped then
		Logger.error(LOG, "WPM widget stop incomplete: runtime cleanup remains pending.")
		return false
	end
	Logger.info(LOG, "Floating WPM widget stopped.")
	return true
end

function M.is_running()
	return _running == true or _pause_restore_pending == true
end

--- Restores a floating surface with the exact graph mode it owned before pause.
--- @return boolean committed
function M.resume_after_pause()
	_pause_restore_pending = true
	return M.start(_show_graph)
end

--- Resets the widget to its default bottom-right position.
function M.reset_position()
	_pos_x = nil
	_pos_y = nil
	Storage.delete(_SETTINGS_X)
	Storage.delete(_SETTINGS_Y)
	Logger.info(LOG, "Widget position reset to default.")
end

--- Enables or disables source-based widget coloring.
--- @param enabled boolean Whether source colors should be active.
function M.set_use_source_colors(enabled)
	_use_source_colors = enabled ~= false
end

return M
