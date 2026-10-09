--- _shared/lua/wpm_widget/model.lua

--- ==============================================================================
--- MODULE: WPM Readouts — What To Draw (Shared)
--- DESCRIPTION:
--- Everything the typing-speed readouts decide, for every Lua driver: the
--- pill's colours and text, the graph's curve, the menu bar label, when the
--- widget shows, and where it sits by default. A driver keeps only its drawing
--- surface.
---
--- FEATURES & RATIONALE:
--- 1. One canon, read and checked here. _shared/modules/wpm_widget/constants.toml
---    is validated key by key when it is loaded; a missing key refuses the
---    whole canon rather than drawing with a guess.
--- 2. Pure. Every function takes the time and the stats it needs, so the whole
---    behaviour — colour holds, idle hiding, the curve — is testable without a
---    screen, on both drivers, against the same file.
--- 3. The macOS behaviour is the reference: the drivers used to differ on the
---    strip's darkening (one of them kept 60 % of each channel where the others
---    kept 40 %), on the graph's corners and history, and on whether the unit
---    was translated. Each of those is now one line here.
--- ==============================================================================

local M = {}




-- =========================================
-- =========================================
-- ======= 1/ The canon ====================
-- =========================================
-- =========================================

-- Every key a driver reads, and the type it must have. A key is listed here
-- only if some surface draws with it.
local REQUIRED = {
	compact = {
		width = "number", height = "number", height_number = "number", height_gap = "number",
		height_unit = "number", number_font_size = "number", unit_font_size = "number",
		unit_strip_darken_factor = "number", corner_radius = "number",
		number_text_alpha = "number", unit_text_alpha = "number", edge_margin = "number",
	},
	graph = {
		width = "number", height = "number", corner_radius = "number", padding = "number",
		history_samples = "number", scale_max = "number", background = "string",
		background_alpha = "number", border = "string", border_alpha = "number",
		border_width = "number", line_width = "number", line_alpha = "number",
		fill_alpha = "number", text_color = "string", text_size = "number",
	},
	menubar = {
		font_size = "number", background_alpha = "number", text_color = "string",
		neutral_background = "string",
	},
	colors = {
		bg_manual = "string", bg_ai = "string", bg_idle = "string", text_active = "string",
		text_idle = "string", fallback_accent = "string",
	},
	transparency = { alpha_active = "number", alpha_idle = "number" },
	neutral_sources = { none = "boolean", manual = "boolean" },
}

--- Checks a decoded canon.
--- @param canon table|nil
--- @return table|nil canon, string|nil error
function M.validate(canon)
	if type(canon) ~= "table" then return nil, "the canon is not a table" end
	for section, keys in pairs(REQUIRED) do
		if type(canon[section]) ~= "table" then return nil, "missing [" .. section .. "]" end
		for key, kind in pairs(keys) do
			local value = canon[section][key]
			if type(value) ~= kind then
				return nil, string.format("[%s].%s must be a %s", section, key, kind)
			end
			-- Every string the canon holds is a colour.
			if kind == "string" and not value:match("^#%x%x%x%x%x%x$") then
				return nil, string.format("[%s].%s is not a #RRGGBB colour", section, key)
			end
		end
	end
	return canon
end

--- Reads and checks the canon.
--- @param path string The constants.toml path, resolved by the driver.
--- @param decode function TOML text → table.
--- @return table|nil canon, string|nil error
function M.load(path, decode)
	if type(path) ~= "string" or path == "" then return nil, "no canon path" end
	local fh = io.open(path, "r")
	if not fh then return nil, "cannot open " .. path end
	local text = fh:read("*a")
	fh:close()
	local ok, decoded = pcall(decode, text)
	if not ok then return nil, "cannot parse " .. path .. ": " .. tostring(decoded) end
	return M.validate(decoded)
end




-- =========================================
-- =========================================
-- ======= 2/ Colours ======================
-- =========================================
-- =========================================

--- "#RRGGBB" → { red, green, blue } in 0..1, or nil.
--- @param hex string|nil
--- @return table|nil
function M.rgb(hex)
	if type(hex) ~= "string" then return nil end
	local r, g, b = hex:match("^#?(%x%x)(%x%x)(%x%x)$")
	if not r then return nil end
	return { red = tonumber(r, 16) / 255, green = tonumber(g, 16) / 255, blue = tonumber(b, 16) / 255 }
end

--- Each channel × factor, rounded half up — the rounding the AHK driver uses.
--- @param hex string
--- @param factor number
--- @return string|nil "#rrggbb"
function M.darken_hex(hex, factor)
	local h = type(hex) == "string" and hex:gsub("^#", "") or ""
	if not h:match("^%x%x%x%x%x%x$") then return nil end
	local channels = {}
	for index = 1, 5, 2 do
		channels[#channels + 1] = math.floor(tonumber(h:sub(index, index + 1), 16) * factor + 0.5)
	end
	return string.format("#%02x%02x%02x", channels[1], channels[2], channels[3])
end

--- Which source colours the readouts now: the last source, for `hold_s` after it.
--- @param stats table|nil { source, source_variant, source_time (s) }
--- @param hold_s number
--- @param now_s number
--- @return string The source, or "none".
function M.active_source(stats, hold_s, now_s)
	if type(stats) ~= "table" then return "none" end
	local source = stats.source_variant or stats.source or "none"
	if source == "none" then return "none" end
	if (now_s - (tonumber(stats.source_time) or 0)) > hold_s then return "none" end
	return source
end

--- The colour a source paints with.
--- @param canon table
--- @param source string
--- @param resolve function|nil group name → "#rrggbb"|nil (the hotstring group's colour).
--- @return string "#rrggbb"
function M.source_hex(canon, source, resolve)
	if source == "llm" then return canon.colors.bg_ai end
	if canon.neutral_sources[source] == true or type(source) ~= "string" then
		return canon.colors.bg_manual
	end
	if type(resolve) == "function" then
		local ok, hex = pcall(resolve, source)
		if ok and type(hex) == "string" then
			local normalised = (hex:sub(1, 1) == "#") and hex or ("#" .. hex)
			if normalised:match("^#%x%x%x%x%x%x$") then return normalised:lower() end
		end
	end
	return canon.colors.fallback_accent
end




-- =========================================
-- =========================================
-- ======= 3/ Frames =======================
-- =========================================
-- =========================================

--- The colour the readouts use now.
--- @param canon table
--- @param stats table|nil
--- @param opts table { now_s, hold_s, use_colors, resolve }
--- @return string hex, string source
local function current_colour(canon, stats, opts)
	local source = M.active_source(stats, opts.hold_s, opts.now_s)
	if not opts.use_colors or source == "none" then return canon.colors.bg_manual, source end
	return M.source_hex(canon, source, opts.resolve), source
end

--- The compact pill: the number over a darker strip holding the unit.
--- @param canon table
--- @param stats table|nil
--- @param opts table { now_s, hold_s, use_colors, resolve, unit }
--- @return table
function M.compact_frame(canon, stats, opts)
	local c = canon.compact
	local background, source = current_colour(canon, stats, opts)
	return {
		mode = "compact",
		width = c.width,
		height = c.height_number + c.height_gap + c.height_unit,
		radius = c.corner_radius,
		number = tostring(math.floor(tonumber(stats and stats.wpm) or 0)),
		unit = opts.unit,
		background = background,
		strip = M.darken_hex(background, c.unit_strip_darken_factor),
		alpha = canon.transparency.alpha_active / 255,
		text = canon.colors.text_active,
		number_alpha = c.number_text_alpha,
		unit_alpha = c.unit_text_alpha,
		number_font_size = c.number_font_size,
		unit_font_size = c.unit_font_size,
		height_number = c.height_number,
		strip_y = c.height_number + c.height_gap,
		height_unit = c.height_unit,
		source = source,
	}
end

--- Appends one sample to the graph's history, keeping the canon's count.
--- @param canon table
--- @param history table Array of { wpm, source }.
--- @param wpm number
--- @param source string
function M.push_history(canon, history, wpm, source)
	history[#history + 1] = { wpm = math.floor(tonumber(wpm) or 0), source = source }
	while #history > canon.graph.history_samples do table.remove(history, 1) end
end

--- The graph panel: "123 MPM" over the curve of the recent samples.
--- @param canon table
--- @param history table Array of { wpm, source }, oldest first.
--- @param stats table|nil
--- @param opts table { now_s, hold_s, use_colors, resolve, unit }
--- @return table
function M.graph_frame(canon, history, stats, opts)
	local g = canon.graph
	local colour, source = current_colour(canon, stats, opts)
	local inner_w = g.width - 2 * g.padding
	local inner_h = g.height - 2 * g.text_size
	local bottom = g.height - g.padding
	local step = inner_w / math.max(1, #history - 1)
	local points = {}
	for index, sample in ipairs(history) do
		local ratio = math.min(1, sample.wpm / g.scale_max)
		points[#points + 1] = { x = g.padding + (index - 1) * step, y = bottom - ratio * inner_h }
	end
	return {
		mode = "graph",
		width = g.width,
		height = g.height,
		radius = g.corner_radius,
		padding = g.padding,
		bottom = bottom,
		background = g.background,
		background_alpha = g.background_alpha,
		border = g.border,
		border_alpha = g.border_alpha,
		border_width = g.border_width,
		line = colour,
		line_width = g.line_width,
		line_alpha = g.line_alpha,
		fill_alpha = g.fill_alpha,
		points = points,
		label = M.readout_label(stats and stats.wpm, opts.unit),
		text = g.text_color,
		text_size = g.text_size,
		source = source,
	}
end

--- "123 MPM", the text of the graph and of the menu bar readout.
--- @param wpm number|nil
--- @param unit string
--- @return string
function M.readout_label(wpm, unit)
	return string.format("%d %s", math.floor(tonumber(wpm) or 0), unit)
end

--- The menu bar / tray readout.
--- @param canon table
--- @param stats table|nil
--- @param opts table { now_s, hold_s, use_colors, resolve, unit }
--- @return table { label, background|nil, background_alpha, text, font_size, source }
function M.menubar_frame(canon, stats, opts)
	local source = M.active_source(stats, opts.hold_s, opts.now_s)
	local coloured = opts.use_colors and source ~= "none"
	return {
		label = M.readout_label(stats and stats.wpm, opts.unit),
		number = tostring(math.floor(tonumber(stats and stats.wpm) or 0)),
		background = coloured and M.source_hex(canon, source, opts.resolve) or nil,
		background_alpha = canon.menubar.background_alpha,
		neutral_background = canon.menubar.neutral_background,
		text = canon.menubar.text_color,
		font_size = canon.menubar.font_size,
		source = source,
	}
end




-- =========================================
-- =========================================
-- ======= 4/ Showing and placing ==========
-- =========================================
-- =========================================

--- Whether the menu bar readout shows: while typing, while a hotstring
--- preview is up, or while a source still colours it.
--- @param stats table|nil
--- @param source string From active_source().
--- @param tooltip_visible boolean
--- @return boolean
function M.menubar_visible(stats, source, tooltip_visible)
	return (tonumber(stats and stats.wpm) or 0) > 0 or tooltip_visible == true or source ~= "none"
end

--- Whether the floating widget shows, and the new "last active" time.
---
--- It shows while text is appearing or a preview is up, and for
--- timings [ui] wpm_widget_idle_hide_ms after — unless the mouse moved since
--- the last keystroke, which means the user went back to pointing.
--- @param ctx table { wpm, source, tooltip_visible, now_s, last_active_s, last_mouse_s, idle_hide_s }
--- @return boolean show, number last_active_s
function M.widget_visible(ctx)
	local last_active = ctx.last_active_s or 0
	if (ctx.wpm or 0) > 0 or (ctx.source or "none") ~= "none" then last_active = ctx.now_s end
	local keyboard_idle = last_active > 0 and (ctx.now_s - last_active) >= ctx.idle_hide_s
	local mouse_active = (ctx.last_mouse_s or 0) > last_active
	local recently_active = last_active > 0 and not keyboard_idle and not mouse_active
	return ((ctx.wpm or 0) > 0 or ctx.tooltip_visible == true or recently_active), last_active
end

--- The pill's default top-left corner: the screen's bottom-right, inset.
--- @param canon table
--- @param screen table { x, y, w, h } — the full screen.
--- @return number x, number y
function M.default_anchor(canon, screen)
	local c = canon.compact
	local height = c.height_number + c.height_gap + c.height_unit
	return screen.x + screen.w - c.width - c.edge_margin, screen.y + screen.h - height - c.edge_margin
end

--- Where a frame's top-left goes for the pill anchored at (x, y): the graph
--- shares the pill's bottom-right corner.
--- @param canon table
--- @param frame table From compact_frame() or graph_frame().
--- @param anchor_x number
--- @param anchor_y number
--- @return number x, number y
function M.frame_origin(canon, frame, anchor_x, anchor_y)
	if frame.mode ~= "graph" then return anchor_x, anchor_y end
	local c = canon.compact
	local pill_h = c.height_number + c.height_gap + c.height_unit
	return anchor_x + c.width - frame.width, anchor_y + pill_h - frame.height
end

--- The pill anchor for a frame whose top-left the user dragged to (x, y).
--- @param canon table
--- @param frame table
--- @param x number
--- @param y number
--- @return number anchor_x, number anchor_y
function M.anchor_from_origin(canon, frame, x, y)
	if frame.mode ~= "graph" then return x, y end
	local c = canon.compact
	local pill_h = c.height_number + c.height_gap + c.height_unit
	return x + frame.width - c.width, y + frame.height - pill_h
end

return M
