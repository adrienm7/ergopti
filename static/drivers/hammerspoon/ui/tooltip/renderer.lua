--- ui/tooltip/renderer.lua

--- ==============================================================================
--- MODULE: Tooltip Renderer
--- DESCRIPTION:
--- Handles UI canvas creation and screen coordinate resolution.
---
--- FEATURES & RATIONALE:
--- 1. Pure Engine: No domain logic, handles only drawing and positioning.
--- 2. Crash Resilience: Wrapped in pcalls to prevent OS rendering locks.
--- ==============================================================================

local M = {}
local hs = hs
local Logger = require("lib.logger")
local LOG = "tooltip_renderer"
local Config = require("ui.tooltip.config")

local ok_bridge, vscode_bridge = pcall(require, "lib.vscode_bridge")
if not ok_bridge then vscode_bridge = nil end





-- ===============================
-- ===============================
-- ======= 1/ Canvas Setup =======
-- ===============================
-- ===============================

M.canvas = hs.canvas.new({ x = 0, y = 0, w = 0, h = 0 })
if M.canvas then
	M.canvas:level(hs.canvas.windowLevels.cursor)
	M.canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
	M.canvas:appendElements(
		{ type = "rectangle", action = "fill", roundedRectRadii = { xRadius = 7, yRadius = 7 } },
		{ type = "rectangle", action = "strokeAndFill", fillColor = { white = 0, alpha = 0 }, strokeColor = { white = 1, alpha = 0.13 }, strokeWidth = 1, roundedRectRadii = { xRadius = 7, yRadius = 7 } },
		{ type = "text" },
		{ type = "rectangle" },
		{ type = "text" },
		{ type = "text" }
	)
end





-- ====================================
-- ====================================
-- ======= 2/ Anchor Resolution =======
-- ====================================
-- ====================================

--- Generates a dark background color while injecting a slight tint hue if permitted.
--- @param requested_tint table|nil Requested RGBA color tint.
--- @return table The resolved background color object.
function M.apply_tint(requested_tint)
	if not Config.settings.colorization_enabled then
		return Config.colors.bg
	end

	if not requested_tint or type(requested_tint) ~= "table" then 
		return Config.colors.bg 
	end

	local r = math.max(0, math.min(1, requested_tint.red or 0))
	local g = math.max(0, math.min(1, requested_tint.green or 0))
	local b = math.max(0, math.min(1, requested_tint.blue or 0))

	local max_c = math.max(r, g, b)
	local min_c = math.min(r, g, b)
	local delta = max_c - min_c

	local hue = 0
	if delta > 0.0001 then
		if max_c == r then hue = ((g - b) / delta) % 6
		elseif max_c == g then hue = (b - r) / delta + 2
		else hue = (r - g) / delta + 4
		end
		hue = hue / 6
	end

	local lightness = 0.10
	local saturation = 0.40

	local c = (1 - math.abs(2 * lightness - 1)) * saturation
	local x = c * (1 - math.abs((hue * 6) % 2 - 1))
	local m = lightness - c / 2
	local h6 = hue * 6
	local nr, ng, nb
	
	if h6 < 1 then nr, ng, nb = c, x, 0
	elseif h6 < 2 then nr, ng, nb = x, c, 0
	elseif h6 < 3 then nr, ng, nb = 0, c, x
	elseif h6 < 4 then nr, ng, nb = 0, x, c
	elseif h6 < 5 then nr, ng, nb = x, 0, c
	else nr, ng, nb = c, 0, x
	end

	return {
		red   = math.max(0, math.min(1, nr + m)),
		green = math.max(0, math.min(1, ng + m)),
		blue  = math.max(0, math.min(1, nb + m)),
		alpha = Config.colors.bg_alpha,
	}
end

--- Resolves the best screen coordinates to display the tooltip.
--- @return table|nil Table containing x, y, and optionally h and type.
function M.resolve_anchor()
	if vscode_bridge and type(vscode_bridge.is_vscode) == "function" and vscode_bridge.is_vscode() then
		local ok_estimate, position = pcall(vscode_bridge.estimate_position)
		if ok_estimate and type(position) == "table" then return position end
	end

	local ok_ax, position_ax = pcall(function()
		local ax_engine = require("hs.axuielement")
		local focused_element = ax_engine.systemWideElement():attributeValue("AXFocusedUIElement")
		if not focused_element then return nil end

		local text_range = focused_element:attributeValue("AXSelectedTextRange")
		if text_range and type(text_range) == "table" then
			local bounds = focused_element:parameterizedAttributeValue("AXBoundsForRange", { location = text_range.location, length = 0 })
			if bounds and type(bounds) == "table" and bounds.x and bounds.y and bounds.h and bounds.h > 0 and bounds.h < Config.layout.max_caret_height then
				return { x = bounds.x, y = bounds.y, h = bounds.h, type = "caret" }
			end
		end

		local line_number = focused_element:attributeValue("AXInsertionPointLineNumber")
		if line_number then
			local line_range = focused_element:parameterizedAttributeValue("AXRangeForLine", line_number)
			if line_range then
				local bounds = focused_element:parameterizedAttributeValue("AXBoundsForRange", line_range)
				if bounds and type(bounds) == "table" and bounds.x and bounds.y and bounds.h and bounds.h > 0 and bounds.h < Config.layout.max_caret_height then
					return { x = bounds.x, y = bounds.y, h = bounds.h, type = "caret" }
				end
			end
		end

		local container_frame = focused_element:attributeValue("AXFrame")
		if container_frame and type(container_frame) == "table" and container_frame.x and container_frame.y and container_frame.w and container_frame.h then
			return { x = container_frame.x + container_frame.w / 2, y = container_frame.y + container_frame.h, h = 0, type = "input_box" }
		end

		return nil
	end)

	if ok_ax and type(position_ax) == "table" then return position_ax end

	local active_window = hs.window.focusedWindow()
	if active_window then
		local ok_frame, window_frame = pcall(function() return active_window:frame() end)
		if ok_frame and window_frame and type(window_frame) == "table" then
			return { x = window_frame.x + window_frame.w / 2, y = window_frame.y + window_frame.h - Config.layout.window_bottom_inset, h = 0, type = "window" }
		end
	end

	return nil
end





-- ====================================
-- ====================================
-- ======= 3/ Dynamic Rendering =======
-- ====================================
-- ====================================

--- Compiles the component blocks, applies layout logic, and draws the canvas.
--- @param blocks table|userdata The text payloads to draw.
--- @param state table The orchestrator state object.
--- @param start_watchers_callback function Function to execute event watchers post-render.
function M.render(blocks, state, start_watchers_callback)
	local ok, err = pcall(function()
		if not M.canvas or (type(blocks) ~= "table" and type(blocks) ~= "userdata") then return end

		local size_predictions = { w = 0, h = 0 }
		if type(blocks) == "userdata" then
			size_predictions = M.canvas:minimumTextSize(3, blocks)
			blocks = { preds = blocks }
		else
			size_predictions = M.canvas:minimumTextSize(3, blocks.preds)
		end

		local hint_styled = blocks.hint_st
		local info_styled = blocks.info_st
		local space_divider = blocks.SP or "      "

		local size_hint = hint_styled and M.canvas:minimumTextSize(3, hint_styled) or { w = 0, h = 0 }
		local size_info = info_styled and M.canvas:minimumTextSize(3, info_styled) or { w = 0, h = 0 }

		local max_width = state.fixed_width or size_predictions.w
		local is_combined_layout = false
		local combined_styled = nil

		if info_styled and hint_styled then
			local separator_styled = hs.styledtext.new(space_divider .. "|" .. space_divider, { font = { name = Config.fonts.main, size = Config.sizes.hint }, color = Config.colors.sep })
			combined_styled = hs.styledtext.new("") .. hint_styled .. separator_styled .. info_styled
			combined_styled = combined_styled:setStyle({ paragraphStyle = { alignment = "center" } }, 1, #combined_styled)

			local size_combined = M.canvas:minimumTextSize(3, combined_styled)
			if size_combined.w <= max_width then 
				is_combined_layout = true 
			end
		end

		M.canvas[1].fillColor = M.apply_tint(state.bg_color)

		local canvas_width = max_width + Config.layout.pad_x * 2
		local current_y = Config.layout.pad_y

		M.canvas[3].text  = blocks.preds
		M.canvas[3].frame = { x = Config.layout.pad_x, y = current_y, w = max_width, h = size_predictions.h }
		current_y = current_y + size_predictions.h + Config.layout.line_spacing

		if hint_styled or info_styled then
			M.canvas[4].action    = "fill"
			M.canvas[4].fillColor = Config.colors.sep
			M.canvas[4].frame     = { x = 0, y = current_y, w = canvas_width, h = 1 }
			current_y = current_y + Config.layout.line_spacing
		else
			M.canvas[4].action = "skip"
		end

		if is_combined_layout then
			local size_combined = M.canvas:minimumTextSize(3, combined_styled)
			M.canvas[5].action = "fill"
			M.canvas[5].text   = combined_styled
			M.canvas[5].frame  = { x = 0, y = current_y, w = canvas_width, h = size_combined.h }
			current_y = current_y + size_combined.h + Config.layout.line_spacing
			M.canvas[6].action = "skip"
		else
			if hint_styled then
				M.canvas[5].action = "fill"
				M.canvas[5].text   = hint_styled
				M.canvas[5].frame  = { x = 0, y = current_y, w = canvas_width, h = size_hint.h }
				current_y = current_y + size_hint.h + (info_styled and Config.layout.hint_spacing or Config.layout.line_spacing)
			else
				M.canvas[5].action = "skip"
			end

			if info_styled then
				M.canvas[6].action = "fill"
				M.canvas[6].text   = info_styled
				M.canvas[6].frame  = { x = 0, y = current_y, w = canvas_width, h = size_info.h }
				current_y = current_y + size_info.h + Config.layout.line_spacing
			else
				M.canvas[6].action = "skip"
			end
		end

		local canvas_height = current_y - Config.layout.line_spacing + Config.layout.pad_y
		local anchor = M.resolve_anchor()
		local focused_window = hs.window.focusedWindow()
		local window_screen = nil
		
		if focused_window and type(focused_window.screen) == "function" then 
			pcall(function() window_screen = focused_window:screen() end) 
		end
		local screen_frame = (window_screen or hs.screen.mainScreen()):frame()

		local pos_x, pos_y
		if anchor then
			if anchor.type == "caret" then
				pos_x = anchor.x + Config.layout.caret_offset_x
				pos_y = anchor.y + anchor.h + Config.layout.caret_offset_y
			else
				pos_x = anchor.x - canvas_width / 2
				pos_y = anchor.y + Config.layout.window_offset_y
				if pos_y + canvas_height > screen_frame.y + screen_frame.h then 
					pos_y = anchor.y - canvas_height - Config.layout.window_offset_y 
				end
			end
		else
			pos_x = screen_frame.x + (screen_frame.w - canvas_width) / 2
			pos_y = screen_frame.y + screen_frame.h - canvas_height - Config.layout.window_offset_y
		end

		pos_x = math.max(screen_frame.x + Config.layout.screen_margin, math.min(pos_x, screen_frame.x + screen_frame.w - canvas_width - Config.layout.screen_margin))
		pos_y = math.max(screen_frame.y + Config.layout.screen_margin, math.min(pos_y, screen_frame.y + screen_frame.h - canvas_height - Config.layout.screen_margin))

		M.canvas:frame({ x = pos_x, y = pos_y, w = canvas_width, h = canvas_height })
		M.canvas[2].frame = { x = 0, y = 0, w = canvas_width, h = canvas_height }
		M.canvas:show()
		
		if type(start_watchers_callback) == "function" then start_watchers_callback() end
	end)

	if not ok then Logger.error(LOG, "Crash during UI rendering: " .. tostring(err) .. ".") end
end

--- Safely hides the canvas.
function M.hide()
	pcall(function()
		if M.canvas and type(M.canvas.hide) == "function" then M.canvas:hide() end
	end)
end

return M
