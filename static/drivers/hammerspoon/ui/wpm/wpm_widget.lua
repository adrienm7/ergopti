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
local ColorUtils = require("lib.color_utils")
local Logger     = require("lib.logger")

local LOG = "wpm_widget"





-- ================================
-- ================================
-- ======= 1/ Configuration =======
-- ================================
-- ================================

local CONFIG = {
	source_color_duration = 1.0,
	
	use_fixed_scale       = true,
	fixed_scale_max       = 120,
	
	bg_color              = { white = 0, alpha = 0.8 },
	border_color          = { white = 1, alpha = 0.4 },
	border_width          = 1,
	text_color            = { white = 1, alpha = 1 },
	text_size             = 14,
	compact_padding_x     = 16,
	compact_padding_y     = 8,
	compact_color_mix     = 0.8,
	
	graph_fill_alpha      = 0.2,
	graph_line_width      = 2
}





-- ========================
-- ========================
-- ======= 2/ State =======
-- ========================
-- ========================

local _canvas      = nil
local _timer       = nil
local _wpm_history = {}
local _show_graph  = false
local _use_source_colors = true





-- ===================================
-- ===================================
-- ======= 3/ Canvas Rendering =======
-- ===================================
-- ===================================

--- Polls the engine and redraws the canvas.
local function update_widget()
	local stats = keylogger.get_live_stats()
	local display_wpm = stats.wpm or 0
	local now = hs.timer.absoluteTime() / 1000000000
	local active_source = WPMShared.get_active_source(stats, CONFIG.source_color_duration, now)
	
	local ok_tooltip, tooltip = pcall(require, "ui.tooltip")
	local tooltip_visible = false
	if ok_tooltip and type(tooltip) == "table" and type(tooltip.is_visible) == "function" then
		tooltip_visible = tooltip.is_visible()
	end
	
	local wpm_str = string.format("%d MPM", display_wpm)
	
	table.insert(_wpm_history, { v = display_wpm, s = active_source })
	if #_wpm_history > 60 then table.remove(_wpm_history, 1) end
	
	if display_wpm > 0 or tooltip_visible or (active_source ~= "none") then
		local screen = hs.screen.mainScreen()
		local full_frame = screen:fullFrame()
		local work_frame = screen:frame()
		
		local dock_height = (full_frame.y + full_frame.h) - (work_frame.y + work_frame.h)
		if dock_height < 20 then dock_height = 60 end
		
		local canvas_width, canvas_height, target_x, target_y
		local graph_margin = 5
		local graph_padding = 5
		
		if _show_graph then
			canvas_height = dock_height - graph_margin - 5
			canvas_width  = canvas_height * 3
			target_x = full_frame.x + full_frame.w - canvas_width - graph_margin
			target_y = full_frame.y + full_frame.h - canvas_height - graph_margin
		else
			local text_measure = hs.drawing.getTextDrawingSize(wpm_str, { size = CONFIG.text_size, font = ".AppleSystemUIFont" })
			local text_width = (text_measure and text_measure.w) or math.floor(#wpm_str * CONFIG.text_size * 0.62)
			local text_height = (text_measure and text_measure.h) or (CONFIG.text_size + 6)
			canvas_width  = math.floor(text_width + (CONFIG.compact_padding_x * 2))
			canvas_height = math.floor(text_height + (CONFIG.compact_padding_y * 2))
			
			target_y = full_frame.y + full_frame.h - (dock_height / 2) - (canvas_height / 2)
			local margin_bottom = full_frame.y + full_frame.h - (target_y + canvas_height)
			target_x = full_frame.x + full_frame.w - canvas_width - margin_bottom
		end
		
		local bg_radius = 10
		local text_size = CONFIG.text_size
		
		if not _canvas then
			_canvas = hs.canvas.new({ x = target_x, y = target_y, w = canvas_width, h = canvas_height })
			_canvas:level(hs.drawing.windowLevels.cursor)
			_canvas:behavior({ "canJoinAllSpaces", "stationary" })
		else
			_canvas:frame({ x = target_x, y = target_y, w = canvas_width, h = canvas_height })
		end
		
		local elements = {}
		table.insert(elements, { type = "rectangle", action = "fill", fillColor = CONFIG.bg_color, roundedRectRadii = { xRadius = bg_radius, yRadius = bg_radius } })
		table.insert(elements, { type = "rectangle", action = "stroke", strokeColor = CONFIG.border_color, strokeWidth = CONFIG.border_width, roundedRectRadii = { xRadius = bg_radius, yRadius = bg_radius } })
		
		if _show_graph then
			local max_val = CONFIG.use_fixed_scale and CONFIG.fixed_scale_max or 10
			if not CONFIG.use_fixed_scale then
				for _, d in ipairs(_wpm_history) do if d.v > max_val then max_val = d.v end end
			end
			
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
			
			table.insert(elements, { type = "text", text = wpm_str, textColor = CONFIG.text_color, textSize = text_size, textAlignment = "center", frame = { x = 0, y = 5, w = canvas_width, h = text_size + 6 } })
		else
			local text_measure = hs.drawing.getTextDrawingSize(wpm_str, { size = text_size, font = ".AppleSystemUIFont" })
			local text_height = (text_measure and text_measure.h) or (text_size + 6)
			local text_y = (canvas_height - text_height) / 2
			local compact_text_color = CONFIG.text_color
			if _use_source_colors and active_source ~= "none" then
				local source_color = WPMShared.get_source_color(active_source, 1.0)
				compact_text_color = ColorUtils.mix_hex_with_white(source_color and source_color.hex, CONFIG.compact_color_mix, 1.0)
			end
			table.insert(elements, { type = "text", text = wpm_str, textColor = compact_text_color, textSize = text_size, textAlignment = "center", frame = { x = 0, y = text_y, w = canvas_width, h = text_height } })
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
	Logger.debug(LOG, "Starting floating WPM widget…")
	_show_graph = show_graph or false
	if not _timer then _timer = hs.timer.new(0.2, update_widget) end
	_timer:start()
	update_widget()
	Logger.info(LOG, "Floating WPM widget started successfully.")
end

--- Halts the widget and clears the screen.
function M.stop()
	Logger.debug(LOG, "Stopping floating WPM widget…")
	if _timer then _timer:stop(); _timer = nil end
	if _canvas then _canvas:delete(); _canvas = nil end
	Logger.info(LOG, "Floating WPM widget stopped.")
end

--- Enables or disables source-based widget coloring.
--- @param enabled boolean Whether source colors should be active.
function M.set_use_source_colors(enabled)
	_use_source_colors = enabled ~= false
end

return M
