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

-- Corner arc radius for ALL tooltip rounding (single + stacked canvases). Read
-- from the shared cross-driver source (_shared/modules/tooltip/constants.toml → Config)
-- so macOS and Windows round identically — never hardcode it here.
local CORNER_RADIUS = Config.layout.corner_radius

local ok_bridge, vscode_bridge = pcall(require, "lib.vscode_bridge")
if not ok_bridge then vscode_bridge = nil end





-- ===============================
-- ===============================
-- ======= 1/ Canvas Setup =======
-- ===============================
-- ===============================

-- Canvas element index map (single source of truth — used by both render() and
-- the partial-update setters that mutate elements without re-rendering the whole
-- canvas, which is what avoids flicker during streaming).
M.ELEM_BG          = 1  -- Filled rounded background (tinted)
M.ELEM_BORDER      = 2  -- Stroked rounded border
M.ELEM_PREDS       = 3  -- Predictions block (variable zone — streamed text)
M.ELEM_SEPARATOR   = 4  -- Thin horizontal separator above hint/info
M.ELEM_HINT        = 5  -- Hint line (or hint+info combined when they fit on one row)
M.ELEM_INFO        = 6  -- Info bar (variable zone — TTFT/TTLT timing line)
M.ELEM_MODEL_INFO  = 7  -- Stable "model + prompt" header (FIXED zone — render once per chain)

M.canvas = hs.canvas.new({ x = 0, y = 0, w = 0, h = 0 })
if M.canvas then
	M.canvas:level(hs.canvas.windowLevels.cursor)
	M.canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
	M.canvas:appendElements(
		{ type = "rectangle", action = "fill", roundedRectRadii = { xRadius = CORNER_RADIUS, yRadius = CORNER_RADIUS } },
		{ type = "rectangle", action = "strokeAndFill", fillColor = { white = 0, alpha = 0 }, strokeColor = Config.colors.border, strokeWidth = 1, roundedRectRadii = { xRadius = CORNER_RADIUS, yRadius = CORNER_RADIUS } },
		{ type = "text" },
		{ type = "rectangle" },
		{ type = "text" },
		{ type = "text" },
		{ type = "text", action = "skip" }
	)
end

--- Updates a single text element without redrawing the rest of the canvas.
--- Used by tooltip_llm during streaming to refresh the info bar / model header
--- without recreating the canvas — `hs.canvas` element assignment is the
--- documented anti-flicker path.
--- @param element_index integer Canvas element index (use M.ELEM_* constants).
--- @param styled_text userdata|nil Styled text to install, or nil to skip the element.
function M.set_element_text(element_index, styled_text)
	pcall(function()
		if not M.canvas then return end
		if styled_text == nil then
			M.canvas[element_index].action = "skip"
			return
		end
		M.canvas[element_index].action = "fill"
		M.canvas[element_index].text   = styled_text
	end)
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

	-- Achromatic accent carries no hue — fall back to the neutral dark background,
	-- matching the JS reference (mixTint in tint.js checks delta < 0.0001).
	if delta < 0.0001 then
		return Config.colors.bg
	end

	local hue = 0
	if max_c == r then hue = ((g - b) / delta) % 6
	elseif max_c == g then hue = (b - r) / delta + 2
	else hue = (r - g) / delta + 4
	end
	hue = hue / 6

	local lightness  = Config.tint_config.lightness
	local saturation = Config.tint_config.saturation

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
		local space_divider = blocks.SP or Config.llm_ui.footer_space_divider
		local combined_sep  = Config.llm_ui.footer_combined_sep

		local size_hint = hint_styled and M.canvas:minimumTextSize(3, hint_styled) or { w = 0, h = 0 }
		local size_info = info_styled and M.canvas:minimumTextSize(3, info_styled) or { w = 0, h = 0 }

		local max_width = state.fixed_width or size_predictions.w
		local is_combined_layout = false
		local combined_styled = nil
		-- Hoisted out of the layout decision below so the draw site can reuse it.
		-- minimumTextSize is an ObjC text-layout call; the footer text and its
		-- metrics do not change between the two points, so measuring twice simply
		-- doubled the cost of every combined-layout render.
		local size_combined = nil

		if info_styled and hint_styled then
			local separator_styled = hs.styledtext.new(space_divider .. combined_sep .. space_divider, { font = { name = Config.fonts.main, size = Config.sizes.hint }, color = Config.colors.sep })
			combined_styled = hs.styledtext.new("") .. hint_styled .. separator_styled .. info_styled
			combined_styled = combined_styled:setStyle({ paragraphStyle = { alignment = "center" } }, 1, #combined_styled)

			size_combined = M.canvas:minimumTextSize(3, combined_styled)
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

	if not ok then
		Logger.error(LOG, "Crash during UI rendering: " .. tostring(err) .. ".")
		M.hide()
	end
end

--- Safely hides the canvas. Also clears the stable model-info zone so the
--- next session starts with no stale header from a previous chain.
function M.hide()
	pcall(function()
		if M.canvas and type(M.canvas.hide) == "function" then M.canvas:hide() end
		if M.canvas then M.canvas[M.ELEM_MODEL_INFO].action = "skip" end
	end)
end





-- ============================================
-- ============================================
-- ======= 4/ Stacked hotstring tooltip =======
-- ============================================
-- ============================================

-- Reusable stacked canvas (separate from the LLM canvas so the two never
-- interfere). Created lazily on first render_stacked() call.
M.stacked_canvas = nil

-- Builds the canvas element descriptors for a `row_count`-row stacked tooltip.
-- Pure (no canvas side effects) so the structure is unit-testable even though the
-- stub hs.canvas is a no-op mock.
--
-- Each row owns its own background, so multi-row stacks carry per-row category
-- colors with NO bleed. Only the four OUTER box corners are rounded; every edge
-- between rows is a straight line. hs.canvas cannot round individual corners
-- (roundedRectRadii rounds all four) and its action="clip" is NOT honored on
-- every build (it falls back to a solid red fill — a catastrophic all-red
-- tooltip), so rounding is built WITHOUT clipping:
--   * a single-row stack is one rounded rectangle (all four corners are box
--     corners);
--   * the FIRST row draws a rounded base then a same-color square "cap" over its
--     bottom corner band, flattening the inner (separator-side) corners while the
--     top corners stay rounded;
--   * the LAST row does the mirror (rounded base, square cap over its top band);
--   * MIDDLE rows are plain squares.
-- Because each cap is the SAME color as its row, flattening a corner can never
-- reveal a different color — the bug that an earlier single-panel attempt hit.
--
-- Element layout (1-based), a uniform 4-slot block per row:
--   row i: base = (i-1)*4+1  : [base]   row background base (rounded or square)
--                              [base+1] corner-flattening cap (skipped if unused)
--                              [base+2] output styled text
--                              [base+3] trigger label styled text
--   separators               : sep_base = row_count*4 + 1, one rectangle per gap
--   border                   : last element = row_count*5, rounded stroke
function M._build_stacked_elements(row_count)
	local elements = {}
	for _ = 1, row_count do
		-- Background base + same-color corner cap, then the two text slots. The cap
		-- starts skipped (middle rows and single-row stacks never need it).
		elements[#elements + 1] = { type = "rectangle", action = "fill" }
		elements[#elements + 1] = { type = "rectangle", action = "skip" }
		elements[#elements + 1] = { type = "text", action = "fill" }
		elements[#elements + 1] = { type = "text", action = "fill" }
	end
	for _ = 1, row_count - 1 do
		elements[#elements + 1] = { type = "rectangle", action = "fill" }
	end
	-- Border: strokeAndFill with transparent fill so only the rounded stroke shows.
	elements[#elements + 1] = {
		type = "rectangle", action = "strokeAndFill",
		fillColor = { white = 0, alpha = 0 },
		strokeColor = Config.colors.border,
		strokeWidth = 1,
		roundedRectRadii = { xRadius = CORNER_RADIUS, yRadius = CORNER_RADIUS },
	}
	return elements
end

--- Decides how row `i` (1-based) of a `row_count`-row stack rounds. Only the four
--- OUTER box corners round; a row's inner (separator-side) corners are flattened
--- by a same-color cap so the edges between rows stay straight. Pure so the corner
--- logic is unit-testable without a real canvas.
--- @param i integer 1-based row index.
--- @param row_count integer Total number of rows.
--- @return table { rounded = boolean, cap = "none"|"top"|"bottom" }.
function M._row_corner_plan(i, row_count)
	local is_first = (i == 1)
	local is_last  = (i == row_count)
	if is_first and is_last then
		-- Single-row stack: the row IS the box, so all four corners are box corners.
		return { rounded = true, cap = "none" }
	elseif is_first then
		-- Top row: round the top (box) corners, flatten the bottom (separator) corners.
		return { rounded = true, cap = "bottom" }
	elseif is_last then
		-- Bottom row: round the bottom (box) corners, flatten the top (separator) corners.
		return { rounded = true, cap = "top" }
	end
	-- Middle row: fully square — every corner abuts a separator.
	return { rounded = false, cap = "none" }
end

-- Build or rebuild the stacked canvas with the correct number of elements.
local function _ensure_stacked_canvas(row_count)
	local elements = M._build_stacked_elements(row_count)
	local needed = #elements
	if M.stacked_canvas then
		local current = #M.stacked_canvas
		if current ~= needed then
			M.stacked_canvas:delete()
			M.stacked_canvas = nil
		end
	end
	if not M.stacked_canvas then
		M.stacked_canvas = hs.canvas.new({ x = 0, y = 0, w = 0, h = 0 })
		if not M.stacked_canvas then return false end
		M.stacked_canvas:level(hs.canvas.windowLevels.cursor)
		M.stacked_canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
		M.stacked_canvas:appendElements(table.unpack(elements))
	end
	return true
end

-- Memoized text measurement. canvas:minimumTextSize() is an ObjC text-layout
-- call and is the dominant per-keystroke cost of the hotstring preview — it runs
-- once per row PLUS once per trigger label on EVERY keystroke a preview is shown.
-- The measured size depends only on the string and font size (the dimmed-row
-- strikethrough does not change metrics), so cache by "<size_tag>\0<text>". The
-- two trigger labels ("★" / "↵") are measured on every render and now hit the
-- cache permanently; recurring previewed words hit it across re-renders. Bounded
-- so a long session of distinct previewed words cannot grow it without limit.
local _text_size_cache   = {}
local _text_size_cache_n = 0
local TEXT_SIZE_CACHE_MAX = 4096

--- Measures styled text via the canvas, caching the result by size_tag + text.
--- @param canvas userdata The hs.canvas used for measurement.
--- @param index integer Element index passed to minimumTextSize.
--- @param text string The raw string to measure.
--- @param size_tag string Distinguishes font sizes ("main" vs "hint").
--- @param style table The styledtext style table (used only on a cache miss).
--- @return table { w, h } size table (a private copy; safe to keep).
local function measure_styled(canvas, index, text, size_tag, style)
	local key    = size_tag .. "\0" .. text
	local cached  = _text_size_cache[key]
	if cached then return cached end
	local sz  = canvas:minimumTextSize(index, hs.styledtext.new(text, style))
	local out = { w = sz.w, h = sz.h }
	if _text_size_cache_n >= TEXT_SIZE_CACHE_MAX then
		_text_size_cache   = {}
		_text_size_cache_n = 0
	end
	_text_size_cache[key] = out
	_text_size_cache_n    = _text_size_cache_n + 1
	return out
end

-- Exposed for the memoization regression test (the stub canvas is a no-op mock,
-- so the cache behaviour is what is verifiable rather than the pixel sizes).
M._measure_styled = measure_styled

--- Renders a stack of hotstring rows into a single canvas.
--- Each row is { text: string, tint: table|nil, trigger_label: string|nil }.
--- @param rows table Array of row descriptors.
--- @param state table Must contain fixed_width (or nil) and timeout_sec.
--- @param start_watchers_callback function|nil Called after canvas is shown.
function M.render_stacked(rows, state, start_watchers_callback)
	local ok, err = pcall(function()
		if not rows or #rows == 0 then return end
		if not _ensure_stacked_canvas(#rows) then return end

		local pad_x     = Config.layout.pad_x
		local pad_y     = Config.layout.pad_y
		local label_gap = 16   -- gap between output text and trigger label
		local row_count = #rows

		-- Measure all rows to compute common width.
		local temp_canvas = M.stacked_canvas
		local max_text_w   = 0
		local max_label_w  = 0
		local row_heights  = {}
		local label_heights = {}

		-- Dimmed (non-firing) alternative rows use a gray, strikethrough style so
		-- the user can still read them but understands they will NOT be sent.
		-- 1 = NSUnderlineStyleSingle. strikethroughColor is omitted so the line
		-- inherits the foreground color, keeping the visual cue compact.
		local DIM_COLOR = { white = 0.55, alpha = 1 }

		local function build_text_style(dimmed)
			if dimmed then
				return {
					font               = { name = Config.fonts.main, size = Config.sizes.main },
					color              = DIM_COLOR,
					strikethroughStyle = 1,
				}
			end
			return {
				font  = { name = Config.fonts.main, size = Config.sizes.main },
				color = { white = 1, alpha = 1 },
			}
		end

		for _, row in ipairs(rows) do
			local sz = measure_styled(temp_canvas, 2, row.text, "main", build_text_style(row.dimmed))
			if sz.w > max_text_w then max_text_w = sz.w end
			table.insert(row_heights, sz.h)
			if row.trigger_label and row.trigger_label ~= "" then
				local lsz = measure_styled(temp_canvas, 2, row.trigger_label, "hint", {
					font  = { name = Config.fonts.main, size = Config.sizes.hint },
					color = { white = 0.45, alpha = 1 },
				})
				if lsz.w > max_label_w then max_label_w = lsz.w end
				table.insert(label_heights, lsz.h)
			else
				table.insert(label_heights, 0)
			end
		end

		local label_zone = max_label_w > 0 and (label_gap + max_label_w) or 0
		local canvas_width  = pad_x + max_text_w + label_zone + pad_x
		local total_height  = 0
		local row_top_y     = {}
		for i, rh in ipairs(row_heights) do
			row_top_y[i] = total_height
			total_height = total_height + pad_y + rh + pad_y
			if i < row_count then
				total_height = total_height + 1   -- 1 px separator
			end
		end

		-- Resolve position (same anchor cascade as render()).
		local anchor = M.resolve_anchor()
		local focused_window = hs.window.focusedWindow()
		local window_screen
		if focused_window and type(focused_window.screen) == "function" then
			pcall(function() window_screen = focused_window:screen() end)
		end
		local screen_frame = (window_screen or hs.screen.mainScreen()):frame()

		local pos_x, pos_y
		if anchor then
			if anchor.type == "caret" then
				pos_x = anchor.x + Config.layout.caret_offset_x
				pos_y = anchor.y + (anchor.h or 0) + Config.layout.caret_offset_y
			else
				pos_x = anchor.x - canvas_width / 2
				pos_y = anchor.y + Config.layout.window_offset_y
				if pos_y + total_height > screen_frame.y + screen_frame.h then
					pos_y = anchor.y - total_height - Config.layout.window_offset_y
				end
			end
		else
			pos_x = screen_frame.x + (screen_frame.w - canvas_width) / 2
			pos_y = screen_frame.y + screen_frame.h - total_height - Config.layout.window_offset_y
		end
		pos_x = math.max(screen_frame.x + Config.layout.screen_margin,
			math.min(pos_x, screen_frame.x + screen_frame.w - canvas_width - Config.layout.screen_margin))
		pos_y = math.max(screen_frame.y + Config.layout.screen_margin,
			math.min(pos_y, screen_frame.y + screen_frame.h - total_height - Config.layout.screen_margin))

		M.stacked_canvas:frame({ x = pos_x, y = pos_y, w = canvas_width, h = total_height })

		local round_radii = { xRadius = CORNER_RADIUS, yRadius = CORNER_RADIUS }

		-- Fill in per-row elements (uniform 4-slot block per row).
		for i, row in ipairs(rows) do
			local base   = (i - 1) * 4 + 1
			local top_y  = row_top_y[i]
			local row_h  = row_heights[i] + pad_y * 2
			local col    = M.apply_tint(row.tint)
			local plan   = M._row_corner_plan(i, row_count)

			-- Background base. Only the outer box corners round (plan.rounded); middle
			-- rows are square. The same-color cap below flattens the inner corners the
			-- rounded base would otherwise carry into a separator.
			M.stacked_canvas[base].action    = "fill"
			M.stacked_canvas[base].frame     = { x = 0, y = top_y, w = canvas_width, h = row_h }
			M.stacked_canvas[base].fillColor = col
			M.stacked_canvas[base].roundedRectRadii = plan.rounded and round_radii or nil

			-- Corner-flattening cap (same color as the row): a band over the bottom or
			-- top CORNER_RADIUS that squares off the inner corners. Same color as the
			-- row, so flattening can never reveal a different color.
			local cap = M.stacked_canvas[base + 1]
			if plan.cap == "bottom" then
				cap.action    = "fill"
				cap.fillColor = col
				cap.frame     = { x = 0, y = top_y + row_h - CORNER_RADIUS,
					w = canvas_width, h = CORNER_RADIUS }
			elseif plan.cap == "top" then
				cap.action    = "fill"
				cap.fillColor = col
				cap.frame     = { x = 0, y = top_y, w = canvas_width, h = CORNER_RADIUS }
			else
				cap.action = "skip"
			end

			-- Output text (gray + strikethrough when row.dimmed; see build_text_style).
			local styled_text = hs.styledtext.new(row.text, build_text_style(row.dimmed))
			M.stacked_canvas[base + 2].text  = styled_text
			M.stacked_canvas[base + 2].frame = { x = pad_x, y = top_y + pad_y,
				w = max_text_w, h = row_heights[i] }

			-- Trigger label (dim, smaller font, right-aligned in label zone).
			-- Vertically centred relative to the main text row height.
			-- The label is pulled further down (alpha 0.25 vs 0.45) on dimmed
			-- rows so the whole row reads as "disabled" together.
			if row.trigger_label and row.trigger_label ~= "" and label_zone > 0 then
				local label_x      = pad_x + max_text_w + label_gap
				local label_h      = label_heights[i] > 0 and label_heights[i] or row_heights[i]
				local label_offset = math.floor((row_heights[i] - label_h) / 2)
				local label_color  = row.dimmed and { white = 0.45, alpha = 0.55 }
					or { white = 0.45, alpha = 1 }
				M.stacked_canvas[base + 3].action = "fill"
				M.stacked_canvas[base + 3].text   = hs.styledtext.new(row.trigger_label, {
					font  = { name = Config.fonts.main, size = Config.sizes.hint },
					color = label_color,
				})
				M.stacked_canvas[base + 3].frame = { x = label_x,
					y = top_y + pad_y + label_offset,
					w = max_label_w, h = label_h }
			else
				M.stacked_canvas[base + 3].action = "skip"
			end
		end

		-- Separators between rows: a straight 1 px line in each gap.
		local sep_base = row_count * 4 + 1
		for i = 1, row_count - 1 do
			local sep_y = row_top_y[i] + row_heights[i] + pad_y * 2
			M.stacked_canvas[sep_base + i - 1].frame     = { x = 0, y = sep_y, w = canvas_width, h = 1 }
			M.stacked_canvas[sep_base + i - 1].fillColor = Config.colors.sep
			M.stacked_canvas[sep_base + i - 1].action    = "fill"
		end

		-- Rounded border on top (last element): rows + separators + border = 5*row_count.
		local border_idx = row_count * 5
		M.stacked_canvas[border_idx].frame = { x = 0, y = 0, w = canvas_width, h = total_height }

		M.stacked_canvas:show()
		if type(start_watchers_callback) == "function" then start_watchers_callback() end
	end)
	if not ok then
		Logger.error(LOG, "Crash during stacked tooltip rendering: " .. tostring(err) .. ".")
		M.hide_stacked()
	end
end

--- Hides the stacked canvas.
function M.hide_stacked()
	pcall(function()
		if M.stacked_canvas and type(M.stacked_canvas.hide) == "function" then
			M.stacked_canvas:hide()
		end
	end)
end

return M
