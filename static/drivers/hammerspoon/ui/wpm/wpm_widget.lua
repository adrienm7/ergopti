--- ui/wpm/wpm_widget.lua

--- ==============================================================================
--- MODULE: WPM Floating Widget UI
--- DESCRIPTION:
--- Renders a floating canvas showing the current typing speed (WPM), with an
--- optional real-time line graph of recent history.
---
--- FEATURES & RATIONALE:
--- 1. Pure Canvas: Uses hs.canvas for high-performance, low-overhead rendering
---    without the need for an embedded webview (no HTML/CSS/JS required).
--- 2. Autonomous Polling: Manages its own lifecycle and history array by
---    requesting data from the core engine.
--- 3. Dynamic Scaling: Sizes itself relative to the exact macOS dock height.
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
	width_graph      = 180,
	width_simple     = 110,
	height_simple    = 36,
	graph_margin     = 5,
	bg_color         = { white = 0, alpha = 0.8 },
	bg_radius        = 8,
	graph_fill_color = { hex = "#007aff", alpha = 0.3 },
	graph_line_color = { hex = "#007aff", alpha = 0.8 },
	graph_line_width = 2,
	text_color       = { white = 1, alpha = 1 },
	text_size        = 14
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
	local wpm_str = string.format("%d MPM", display_wpm)
	
	table.insert(_wpm_history, display_wpm)
	if #_wpm_history > 60 then table.remove(_wpm_history, 1) end
	
	if display_wpm > 0 then
		local screen = hs.screen.mainScreen()
		local full_frame = screen:fullFrame()
		local work_frame = screen:frame()
		
		-- Isolate the bottom dock height precisely
		local dock_height = (full_frame.y + full_frame.h) - (work_frame.y + work_frame.h)
		if dock_height < 20 then dock_height = 60 end
		
		local canvas_width, canvas_height, target_x, target_y
		
		if _show_graph then
			canvas_height = dock_height - CONFIG.graph_margin
			canvas_width  = CONFIG.width_graph
			target_x = full_frame.x + full_frame.w - canvas_width - CONFIG.graph_margin
			target_y = full_frame.y + full_frame.h - canvas_height - CONFIG.graph_margin
		else
			canvas_height = CONFIG.height_simple
			canvas_width  = CONFIG.width_simple
			
			-- Center vertically within the exact dock area
			target_y = full_frame.y + full_frame.h - (dock_height / 2) - (canvas_height / 2)
			
			-- Set right margin equal to bottom margin to ensure perfect visual balance
			local margin_bottom = full_frame.y + full_frame.h - (target_y + canvas_height)
			target_x = full_frame.x + full_frame.w - canvas_width - margin_bottom
		end
		
		if not _canvas then
			_canvas = hs.canvas.new({ x = target_x, y = target_y, w = canvas_width, h = canvas_height })
			_canvas:level(hs.drawing.windowLevels.cursor)
			_canvas:behavior({ "canJoinAllSpaces", "stationary" })
		else
			_canvas:frame({ x = target_x, y = target_y, w = canvas_width, h = canvas_height })
		end
		
		local elements = {}
		table.insert(elements, { type = "rectangle", action = "fill", fillColor = CONFIG.bg_color, roundedRectRadii = { xRadius = CONFIG.bg_radius, yRadius = CONFIG.bg_radius } })
		
		if _show_graph then
			local max_val = 10
			for _, v in ipairs(_wpm_history) do if v > max_val then max_val = v end end
			
			local graph_w = canvas_width - 10
			local graph_h = canvas_height - 30 
			
			local path = {}
			table.insert(path, { x = 5, y = canvas_height - 5 })
			local step = graph_w / math.max(1, #_wpm_history - 1)
			for i, v in ipairs(_wpm_history) do 
				table.insert(path, { x = 5 + (i - 1) * step, y = canvas_height - 5 - ((v / max_val) * graph_h) }) 
			end
			table.insert(path, { x = canvas_width - 5, y = canvas_height - 5 })
			table.insert(elements, { type = "segments", coordinates = path, action = "fill", fillColor = CONFIG.graph_fill_color })
			
			local line_path = {}
			for i, v in ipairs(_wpm_history) do 
				table.insert(line_path, { x = 5 + (i - 1) * step, y = canvas_height - 5 - ((v / max_val) * graph_h) }) 
			end
			table.insert(elements, { type = "segments", coordinates = line_path, action = "stroke", strokeColor = CONFIG.graph_line_color, strokeWidth = CONFIG.graph_line_width })
			
			-- Draw text at the top of the graph widget
			table.insert(elements, { type = "text", text = wpm_str, textColor = CONFIG.text_color, textSize = CONFIG.text_size, textAlignment = "center", frame = { x = 0, y = 5, w = canvas_width, h = 20 } })
		else
			-- Center the text mathematically within the simple box
			local text_y = (canvas_height - 20) / 2
			table.insert(elements, { type = "text", text = wpm_str, textColor = CONFIG.text_color, textSize = CONFIG.text_size, textAlignment = "center", frame = { x = 0, y = text_y, w = canvas_width, h = 20 } })
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
	if not _timer then _timer = hs.timer.new(1.0, update_widget) end
	_timer:start()
	update_widget()
end

--- Halts the widget and clears the screen.
function M.stop()
	if _timer then _timer:stop(); _timer = nil end
	if _canvas then _canvas:delete(); _canvas = nil end
end

return M
