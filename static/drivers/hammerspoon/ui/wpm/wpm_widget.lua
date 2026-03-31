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
--- ==============================================================================

local M = {}
local hs = hs
local keylogger = require("modules.keylogger")





-- ================================
-- ================================
-- ======= 1/ Configuration =======
-- ================================
-- ================================

local CONFIG = {
	source_color_duration = 3.0,
	
	use_fixed_scale       = true,
	fixed_scale_max       = 120,
	
	bg_color              = { white = 0, alpha = 0.8 },
	border_color          = { white = 1, alpha = 0.4 },
	border_width          = 1,
	text_color            = { white = 1, alpha = 1 },
	text_size             = 14, -- Taille de la police modifiable ici
	
	color_manual          = { hex = "#007aff", alpha = 0.8 },
	color_hotstring       = { hex = "#ff3b30", alpha = 0.8 },
	color_llm             = { hex = "#af52de", alpha = 0.8 },
	
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





-- ===================================
-- ===================================
-- ======= 3/ Canvas Rendering =======
-- ===================================
-- ===================================

--- Polls the engine and redraws the canvas.
local function update_widget()
	local stats = keylogger.get_live_stats()
	local display_wpm = stats.wpm or 0
	local source = stats.source or "none"
	local source_time = stats.source_time or 0
	local now = hs.timer.absoluteTime() / 1000000000
	
	local active_source = "none"
	if source ~= "none" and (now - source_time) <= CONFIG.source_color_duration then
		active_source = source
	end
	
	local ok_tooltip, tooltip = pcall(require, "ui.tooltip")
	local tooltip_visible = false
	if ok_tooltip and type(tooltip) == "table" and type(tooltip.is_visible) == "function" then
		tooltip_visible = tooltip.is_visible()
	end
	
	local wpm_str = string.format("%d MPM", display_wpm)
	
	table.insert(_wpm_history, { v = display_wpm, s = active_source })
	if #_wpm_history > 60 then table.remove(_wpm_history, 1) end
	
	-- Garde le widget visible pendant la frappe, si un tooltip IA est affiché, ou si une IA vient d'être injectée
	if display_wpm > 0 or tooltip_visible or (active_source ~= "none") then
		local screen = hs.screen.mainScreen()
		local full_frame = screen:fullFrame()
		local work_frame = screen:frame()
		
		local dock_height = (full_frame.y + full_frame.h) - (work_frame.y + work_frame.h)
		if dock_height < 20 then dock_height = 60 end
		
		local canvas_width, canvas_height, target_x, target_y
		local graph_margin = 5
		local graph_padding = 8
		
		if _show_graph then
			canvas_height = dock_height - graph_margin
			canvas_width  = canvas_height * 3
			target_x = full_frame.x + full_frame.w - canvas_width - graph_margin
			target_y = full_frame.y + full_frame.h - canvas_height - graph_margin
		else
			canvas_height = dock_height * 0.6
			canvas_width  = canvas_height * 3
			
			target_y = full_frame.y + full_frame.h - (dock_height / 2) - (canvas_height / 2)
			
			local margin_bottom = full_frame.y + full_frame.h - (target_y + canvas_height)
			target_x = full_frame.x + full_frame.w - canvas_width - margin_bottom
		end
		
		local bg_radius = 10 -- Standard macOS window radius
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
			
			-- La couleur ne change QUE si active_source correspond à une injection effective (et non pas juste l'apparition du tooltip)
			local current_color = CONFIG.color_manual
			if active_source == "hotstring" then current_color = CONFIG.color_hotstring
			elseif active_source == "llm" then current_color = CONFIG.color_llm end
			
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
			local text_y = (canvas_height - text_size - 6) / 2
			table.insert(elements, { type = "text", text = wpm_str, textColor = CONFIG.text_color, textSize = text_size, textAlignment = "center", frame = { x = 0, y = text_y, w = canvas_width, h = text_size + 6 } })
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
	_show_graph = show_graph or false
	if not _timer then _timer = hs.timer.new(0.2, update_widget) end
	_timer:start()
	update_widget()
end

--- Halts the widget and clears the screen.
function M.stop()
	if _timer then _timer:stop(); _timer = nil end
	if _canvas then _canvas:delete(); _canvas = nil end
end

return M
