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
local Logger     = require("lib.logger")
local Paths      = require("lib.paths")
local GraphicsRenderer = require("adapters.graphics_renderer")

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

-- Reads a flat key=value pair from a raw TOML line (no section header handling needed here).
local function _toml_num(line, key)
	local v = line:match("^" .. key .. "%s*=%s*([%d%.]+)")
	return v and tonumber(v) or nil
end

-- Loads _shared/modules/wpm_widget/constants.toml and _shared/modules/timings/constants.toml at runtime.
-- Returns a config table; logs an error and returns a safe-default stub on failure.
local function _load_shared_const()
	local wpm_path     = resolve_shared_constants_path("modules/wpm_widget/constants.toml")
	local timings_path = resolve_shared_constants_path("modules/timings/constants.toml")

	local function read_toml(path)
		if not path then return {} end
		local fh = io.open(path, "r")
		if not fh then return {} end
		local section, t = "", {}
		for line in fh:lines() do
			local s = line:match("^%[(.-)%]$")
			if s then section = s; t[section] = t[section] or {} end
			local k, v = line:match("^([%w_]+)%s*=%s*(.*)")
			if k and section ~= "" then
				t[section][k] = tonumber(v) or v:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
			elseif k then
				t[k] = tonumber(v) or v:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
			end
		end
		fh:close()
		return t
	end

	local wc = read_toml(wpm_path)
	local tc = read_toml(timings_path)

	if not wpm_path then
		Logger.error(LOG, "_load_shared_const: _shared/modules/wpm_widget/constants.toml not found — widget non-functional.")
	end

	local compact    = wc.compact    or {}
	local colors     = wc.colors     or {}
	local transp     = wc.transparency or {}

	-- Strip leading '#' from hex strings for hs.canvas compatibility.
	local function hex(s) return (s or ""):gsub("^#", "") end

	-- Scale a TOML value, failing SOFT (per field) when the key is missing/renamed.
	-- A bare `nil / 255` (etc.) would raise at module load and the require-time pcall
	-- in menu_metrics would silently drop the ENTIRE widget; instead yield nil and
	-- surface the drift loudly (rule 5.3). Downstream consumers tolerate a nil here.
	local function scaled(v, divisor, key)
		if type(v) ~= "number" then
			Logger.error(LOG, "_load_shared_const: missing/non-numeric '%s' — leaving nil.", key)
			return nil
		end
		return v / divisor
	end

	-- No literal fallbacks below: the shared TOML is the single source of truth
	-- (rules 5.2 / 5.4), mirroring the AHK WPMWidgetConst sentinel/fail-fast class.
	-- A missing TOML is already logged as an ERROR above; a missing key then
	-- surfaces loud (nil) rather than silently masking drift behind a re-typed
	-- default. Covered by test_wpm_shared_constants.
	return {
		-- Compact layout — _shared/modules/wpm_widget/constants.toml [compact]
		compact_width         = compact.width,
		compact_height_number = compact.height_number,
		compact_height_gap    = compact.height_gap,
		compact_height_unit   = compact.height_unit,
		compact_number_size   = compact.number_font_size,
		compact_unit_size     = compact.unit_font_size,
		compact_padding_x     = compact.padding_x,
		compact_unit_darken   = compact.unit_strip_darken_factor,

		-- Colors — _shared/modules/wpm_widget/constants.toml [colors]
		color_bg_manual       = "#" .. hex(colors.bg_manual),
		color_bg_idle         = "#" .. hex(colors.bg_idle),
		color_txt_active_alpha = scaled(transp.alpha_active, 255, "[transparency].alpha_active"),
		-- HSL target to normalise hotstring accent hues to the same brightness as bg_manual.
		widget_hsl_l          = tonumber(colors.widget_hsl_l),
		widget_hsl_s          = tonumber(colors.widget_hsl_s),

		-- Idle hide and color-hold durations — _shared/modules/timings/constants.toml [ui]
		idle_hide_s           = scaled(tc.ui and tc.ui.wpm_widget_idle_hide_ms, 1000, "[ui].wpm_widget_idle_hide_ms"),
		source_color_duration = scaled(tc.ui and tc.ui.wpm_color_hold_ms,      1000, "[ui].wpm_color_hold_ms"),

		-- Graph mode (HS-only, not in shared TOML)
		use_fixed_scale       = true,
		fixed_scale_max       = 120,
		bg_color              = { white = 0, alpha = 0.8 },
		border_color          = { white = 1, alpha = 0.4 },
		border_width          = 1,
		text_color            = { white = 1, alpha = 1 },
		text_size             = 14,
		graph_fill_alpha      = 0.2,
		graph_line_width      = 2,
	}
end

-- Exposed for the shared-constants regression test (test_wpm_shared_constants):
-- it asserts every value is sourced from the shared TOML, with no re-typed
-- literal default in this loader (rules 5.2 / 5.4).
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
local _SETTINGS_X = "ergopti.wpm_widget.pos_x"
local _SETTINGS_Y = "ergopti.wpm_widget.pos_y"
-- Coerce with tonumber: a corrupt / hand-edited plist can return a STRING here,
-- which is only guarded by `if not _pos_x` downstream (a non-empty string passes)
-- and then flows into arithmetic (_pos_x + compact_w …) and hs.canvas geometry,
-- raising in the timer/layout callback (swallowed to the HS Console). tonumber
-- yields nil for a non-numeric value so the existing default-recompute fires.
local _pos_x      = tonumber(hs.settings.get(_SETTINGS_X))
local _pos_y      = tonumber(hs.settings.get(_SETTINGS_Y))

-- Drag state.
local _drag_start_mouse = nil
local _drag_start_frame = nil





-- ===================================
-- ===================================
-- ======= 3/ Canvas Rendering =======
-- ===================================
-- ===================================

-- Re-projects a hex accent color onto the widget HSL target (L, S from CONFIG)
-- so every hotstring/AI/AC hue is as vivid as the manual blue.
-- Returns a "#rrggbb" string; falls back to fallback_hex on bad input.
local function _wpm_normalise_hex(accent_hex, fallback_hex)
	local h = (accent_hex or ""):gsub("^#", "")
	if #h ~= 6 then return fallback_hex end
	local r = tonumber(h:sub(1, 2), 16) / 255.0
	local g = tonumber(h:sub(3, 4), 16) / 255.0
	local b = tonumber(h:sub(5, 6), 16) / 255.0
	if not r or not g or not b then return fallback_hex end

	local max_c = math.max(r, g, b)
	local min_c = math.min(r, g, b)
	local delta = max_c - min_c
	if delta <= 0.0001 then return fallback_hex end  -- achromatic

	local hue
	if max_c == r then
		hue = ((g - b) / delta + 6) % 6
	elseif max_c == g then
		hue = (b - r) / delta + 2
	else
		hue = (r - g) / delta + 4
	end
	hue = hue / 6

	local L  = CONFIG.widget_hsl_l
	local S  = CONFIG.widget_hsl_s
	local C  = (1 - math.abs(2 * L - 1)) * S
	local h6 = hue * 6
	local X  = C * (1 - math.abs(h6 % 2 - 1))
	local m  = L - C / 2
	local nr, ng, nb
	if     h6 < 1 then nr, ng, nb = C, X, 0
	elseif h6 < 2 then nr, ng, nb = X, C, 0
	elseif h6 < 3 then nr, ng, nb = 0, C, X
	elseif h6 < 4 then nr, ng, nb = 0, X, C
	elseif h6 < 5 then nr, ng, nb = X, 0, C
	else                nr, ng, nb = C, 0, X
	end
	return string.format("#%02x%02x%02x",
		math.max(0, math.min(255, math.floor((nr + m) * 255 + 0.5))),
		math.max(0, math.min(255, math.floor((ng + m) * 255 + 0.5))),
		math.max(0, math.min(255, math.floor((nb + m) * 255 + 0.5))))
end

-- Returns a hex color darkened by the given factor (each RGB channel × factor).
-- Input may include a leading "#"; output always includes it.
-- hex ultimately traces back to a hotstring group's TOML _meta.color, which the
-- user can freely edit (ui/wpm/shared.lua resolve_source_hex) — a shorthand
-- "#fff", a bare color name, or plain garbage would otherwise reach the
-- tonumber(h:sub(...), 16) arithmetic below and either raise (nil arithmetic)
-- or silently produce a nonsense strip color. Mirrors the same length/format
-- guard already applied a few lines above in _wpm_normalise_hex.
local function _wpm_darken_hex(hex, factor, fallback_hex)
	local h = (hex or ""):gsub("^#", "")
	if #h ~= 6 then return fallback_hex end
	local r = tonumber(h:sub(1, 2), 16)
	local g = tonumber(h:sub(3, 4), 16)
	local b = tonumber(h:sub(5, 6), 16)
	if not r or not g or not b then return fallback_hex end

	-- Round-half-up (floor(x + 0.5)) is the single canonical rounding shared with
	-- the AHK driver (Round()) and with _wpm_normalise_hex above, so the darkened
	-- unit strip is byte-identical across drivers instead of drifting by ±1/255.
	return string.format("#%02x%02x%02x",
		math.floor(r * factor + 0.5), math.floor(g * factor + 0.5), math.floor(b * factor + 0.5))
end


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

	local wpm_number_str = tostring(display_wpm)
	local wpm_full_str   = string.format("%d MPM", display_wpm)

	if display_wpm > 0 or active_source ~= "none" then
		_last_active_sec = now
	end
	local inactive_for    = now - _last_active_sec
	local keyboard_idle   = (_last_active_sec > 0) and (inactive_for >= IDLE_HIDE_S)
	-- Hide if mouse/touchpad was used more recently than the last keystroke.
	local mouse_active    = (_last_mouse_sec > _last_active_sec)
	local recently_active = (_last_active_sec > 0) and not keyboard_idle and not mouse_active

	table.insert(_wpm_history, { v = display_wpm, s = active_source })
	if #_wpm_history > 60 then table.remove(_wpm_history, 1) end

	if display_wpm > 0 or tooltip_visible or recently_active then
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
		local work_frame = screen:frame()

		local dock_height = (full_frame.y + full_frame.h) - (work_frame.y + work_frame.h)
		if dock_height < 20 then dock_height = 60 end

		local canvas_width, canvas_height, target_x, target_y
		local graph_margin = 5

		-- Compact dimensions (shared constants).
		local compact_w = CONFIG.compact_width
		local compact_h = CONFIG.compact_height_number + CONFIG.compact_height_gap + CONFIG.compact_height_unit

		if _show_graph then
			canvas_height = dock_height - graph_margin - 5
			canvas_width  = canvas_height * 3
		else
			canvas_width  = compact_w
			canvas_height = compact_h
		end

		-- Publish this cycle's geometry for the mouseCallback closure (see the
		-- _canvas_geom declaration in section 2 for why this indirection exists).
		_canvas_geom.canvas_width  = canvas_width
		_canvas_geom.canvas_height = canvas_height
		_canvas_geom.compact_w     = compact_w
		_canvas_geom.compact_h     = compact_h

		-- Compute default compact top-left (bottom-right corner at screen edge - margin).
		if not _pos_x then
			local margin_bottom = graph_margin
			local def_y = full_frame.y + full_frame.h - compact_h - margin_bottom
			local margin_right = full_frame.y + full_frame.h - (def_y + compact_h)
			local def_x = full_frame.x + full_frame.w - compact_w - margin_right
			_pos_x = def_x
			_pos_y = def_y
		end

		-- Derive current mode top-left from compact anchor, keeping bottom-right constant.
		if _show_graph then
			target_x = _pos_x + compact_w - canvas_width
			target_y = _pos_y + compact_h - canvas_height
		else
			target_x = _pos_x
			target_y = _pos_y
		end

		local bg_radius = 10

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
			-- Drag: mouseCallback fires on left-button down inside the canvas.
			_canvas:mouseCallback(function(c, event, id, x, y)
				if event == "mouseDown" then
					_drag_start_mouse = hs.mouse.absolutePosition()
					_drag_start_frame = c:frame()
				elseif event == "mouseUp" then
					_drag_start_mouse = nil
					_drag_start_frame = nil
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
					hs.settings.set(_SETTINGS_X, _pos_x)
					hs.settings.set(_SETTINGS_Y, _pos_y)
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

		local elements = {}

		if _show_graph then
			-- ── Graph mode: original HS style ─────────────────────────────────
			local text_size = CONFIG.text_size
			table.insert(elements, { type = "rectangle", action = "fill", fillColor = CONFIG.bg_color, roundedRectRadii = { xRadius = bg_radius, yRadius = bg_radius } })
			table.insert(elements, { type = "rectangle", action = "stroke", strokeColor = CONFIG.border_color, strokeWidth = CONFIG.border_width, roundedRectRadii = { xRadius = bg_radius, yRadius = bg_radius } })

			local max_val = CONFIG.use_fixed_scale and CONFIG.fixed_scale_max or 10
			if not CONFIG.use_fixed_scale then
				for _, d in ipairs(_wpm_history) do if d.v > max_val then max_val = d.v end end
			end

			local graph_padding = graph_margin
			local graph_w = canvas_width - (graph_padding * 2)
			local graph_h = canvas_height - (text_size * 2)
			local step = graph_w / math.max(1, #_wpm_history - 1)

			local current_color = _use_source_colors
				and WPMShared.get_source_color(active_source, 0.8)
				or WPMShared.get_source_color("manual", 0.8)

			local fill_color = { hex = current_color.hex, alpha = CONFIG.graph_fill_alpha }

			local path = {}
			table.insert(path, { x = graph_padding, y = canvas_height - graph_padding })
			for i, d in ipairs(_wpm_history) do
				table.insert(path, { x = graph_padding + (i - 1) * step, y = canvas_height - graph_padding - ((d.v / max_val) * graph_h) })
			end
			table.insert(path, { x = canvas_width - graph_padding, y = canvas_height - graph_padding })
			table.insert(elements, { type = "segments", coordinates = path, action = "fill", fillColor = fill_color })

			local line_path = {}
			for i, d in ipairs(_wpm_history) do
				table.insert(line_path, { x = graph_padding + (i - 1) * step, y = canvas_height - graph_padding - ((d.v / max_val) * graph_h) })
			end
			table.insert(elements, { type = "segments", coordinates = line_path, action = "stroke", strokeColor = current_color, strokeWidth = CONFIG.graph_line_width })
			table.insert(elements, { type = "text", text = wpm_full_str, textColor = CONFIG.text_color, textSize = text_size, textAlignment = "center", frame = { x = 0, y = 5, w = canvas_width, h = text_size + 6 } })
		else
			-- ── Compact mode: two-zone pill — upper number + lower darker unit strip ──
			-- Layout mirrors _shared/modules/wpm_widget/constants.toml [compact] and AHK WPMWidget_BuildCompact.
			local source = (_use_source_colors and active_source ~= "none") and active_source or "manual"
			local source_color = WPMShared.get_source_color(source, 1.0)
			local bg_hex     = source_color.hex
			local main_alpha = CONFIG.color_txt_active_alpha

			local h_num   = CONFIG.compact_height_number
			local h_gap   = CONFIG.compact_height_gap
			local h_unit  = CONFIG.compact_height_unit
			local strip_y = h_num + h_gap

			-- Main pill background (rounded full rect).
			table.insert(elements, {
				type = "rectangle", action = "fill",
				fillColor = { hex = bg_hex, alpha = main_alpha },
				roundedRectRadii = { xRadius = bg_radius, yRadius = bg_radius },
			})

			-- Darker strip behind the unit label (square bottom — the pill rounding clips it).
			-- Falls back to the manual-mode blue (same default resolve_source_hex uses)
			-- if bg_hex is a malformed user-edited TOML color.
			local strip_hex = _wpm_darken_hex(bg_hex, CONFIG.compact_unit_darken, CONFIG.color_bg_manual)
			table.insert(elements, {
				type = "rectangle", action = "fill",
				fillColor = { hex = strip_hex, alpha = main_alpha },
				frame = { x = 0, y = strip_y, w = canvas_width, h = h_unit },
			})

			local ok_i18n, i18n = pcall(require, "lib.i18n")
			local unit_label = (ok_i18n and type(i18n.get) == "function") and i18n.get("menu.metrics.wpm_unit") or "MPM"

			-- WPM number — vertically centred in the upper zone.
			table.insert(elements, {
				type = "text", text = wpm_number_str,
				textColor = { white = 1, alpha = 1 },
				textSize = CONFIG.compact_number_size,
				textAlignment = "center",
				frame = { x = 0, y = 0, w = canvas_width, h = h_num },
			})
			-- Unit acronym label inside the strip.
			table.insert(elements, {
				type = "text", text = unit_label,
				textColor = { white = 1, alpha = 0.9 },
				textSize = CONFIG.compact_unit_size,
				textAlignment = "center",
				frame = { x = 0, y = strip_y, w = canvas_width, h = h_unit },
			})
		end

		_canvas:replaceElements(elements)
		_canvas:show()
	else
		if _canvas then _canvas:hide() end
	end
end





-- =====================================
-- =====================================
-- ======= 4/ Public Control API =======
-- =====================================
-- =====================================

--- Starts the floating widget loop.
--- @param show_graph boolean Whether to draw the history curve.
function M.start(show_graph)
	local want_graph = show_graph or false
	-- Idempotent: the menu tree rebuild re-invokes start() on every refresh. Skip the
	-- redundant timer restart and full canvas re-render when already running with the
	-- same graph mode — the 0.2 s timer already keeps the display fresh. Only a real
	-- graph-mode change falls through to redraw immediately.
	if _running and _show_graph == want_graph then return end
	Logger.debug(LOG, "Starting floating WPM widget…")
	_show_graph = want_graph
	if not _timer then _timer = hs.timer.new(0.2, update_widget) end
	_timer:start()
	-- Watch all mouse/touchpad events to know when to hide the widget.
	if not _mouse_tap then
		_mouse_tap = hs.eventtap.new({
			hs.eventtap.event.types.mouseMoved,
			hs.eventtap.event.types.leftMouseDown,
			hs.eventtap.event.types.rightMouseDown,
			hs.eventtap.event.types.scrollWheel,
		}, function(e)
			local now = hs.timer.absoluteTime() / 1000000000
			local is_move = e:getType() == hs.eventtap.event.types.mouseMoved
			-- Throttle mouseMoved: only update at most every MOUSE_MOVE_THROTTLE_SEC.
			-- Click and scroll events bypass the throttle — they must always register.
			if not is_move or (now - _last_mouse_sec) >= MOUSE_MOVE_THROTTLE_SEC then
				_last_mouse_sec = now
			end
			return false  -- do not consume the event
		end)
		_mouse_tap:start()
	end
	_running = true
	update_widget()
	Logger.info(LOG, "Floating WPM widget started successfully.")
end

--- Halts the widget and clears the screen.
function M.stop()
	-- Idempotent: a menu rebuild while the widget is off re-invokes stop() repeatedly.
	-- Nothing to tear down means nothing to log — return before the start/stop banner.
	if not _running and not _timer and not _mouse_tap and not _canvas then return end
	Logger.debug(LOG, "Stopping floating WPM widget…")
	_running = false
	if _timer then _timer:stop(); _timer = nil end
	if _mouse_tap then _mouse_tap:stop(); _mouse_tap = nil end
	if _canvas then _canvas:delete(); _canvas = nil end
	Logger.info(LOG, "Floating WPM widget stopped.")
end

--- Resets the widget to its default bottom-right position.
function M.reset_position()
	_pos_x = nil
	_pos_y = nil
	hs.settings.set(_SETTINGS_X, nil)
	hs.settings.set(_SETTINGS_Y, nil)
	Logger.info(LOG, "Widget position reset to default.")
end

--- Enables or disables source-based widget coloring.
--- @param enabled boolean Whether source colors should be active.
function M.set_use_source_colors(enabled)
	_use_source_colors = enabled ~= false
end

return M
