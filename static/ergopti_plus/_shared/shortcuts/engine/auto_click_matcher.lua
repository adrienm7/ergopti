--- _shared/shortcuts/engine/auto_click_matcher.lua

--- ==============================================================================
--- MODULE: Auto-Click Template Matcher — Shared Lua Implementation
--- DESCRIPTION:
--- Finds a library image (a button the user captured or imported) inside a
--- capture of the foreground window, for the auto-clicker of the anti-sleep
--- mode (Ctrl+M, sg_actions.activity_simulation). The macOS and Linux drivers
--- match through this module; the Windows driver runs a twin pinned by the same
--- corpus.
---
--- FEATURES & RATIONALE:
--- 1. Deterministic: zero-mean normalised cross-correlation on grayscale
---    pixels, computed from integer sums, so every driver scores a window the
---    same way and a tolerance means the same on each OS. Ties keep the first
---    position in row-major order (smallest y, then smallest x).
--- 2. Multi-scale: a button captured on a Retina or HiDPI screen is twice the
---    size of the same button on a 1x screen, so each template is also tried
---    at half and double size (power-of-two factors only: a box average halves,
---    a pixel copy doubles, both exact in integers).
--- 3. Coarse to fine: the template is halved while it stays large enough to
---    carry detail, the window is halved as often at every pixel phase (so the
---    halved template lines up exactly with one of them wherever the button
---    lies), every position of those small images is scored, and only the
---    strongest candidates within a margin of the tolerance are refined at full
---    size. Each level divides the work of a 700 ms tick by four.
--- 4. A uniform template (a flat colour) matches everything and is refused
---    with a reason: the library import rejects it.
---
--- 5. Lua 5.1 syntax: LuaJIT (Linux) has no integer division operator, so
---    every rounding is math.floor of an exact quotient.
---
--- Pinned by _shared/tests/corpus/keep_awake/auto_click_match_vectors.json.
--- ==============================================================================

local M = {}




-- =============================================
-- =============================================
-- ======= 1/ Images ===========================
-- =============================================
-- =============================================

--- The luminance of one pixel, in integers so every driver rounds alike
--- (ITU-R BT.601 weights, the ones every OS screenshot tool uses for gray).
--- @param r integer Red, 0 to 255.
--- @param g integer Green, 0 to 255.
--- @param b integer Blue, 0 to 255.
--- @return integer gray 0 to 255.
function M.gray(r, g, b)
	return math.floor((r * 299 + g * 587 + b * 114 + 500) / 1000)
end

--- Validates a grayscale image: { width, height, pixels } with pixels a
--- row-major array of width * height integers from 0 to 255, index 1 at the
--- top-left corner.
--- @param image table The image.
--- @param what string Its role, for the error message.
local function check_image(image, what)
	assert(type(image) == "table", what .. " must be an image table")
	local w, h = image.width, image.height
	assert(type(w) == "number" and w >= 1 and w % 1 == 0, what .. " needs a positive integer width")
	assert(type(h) == "number" and h >= 1 and h % 1 == 0, what .. " needs a positive integer height")
	assert(type(image.pixels) == "table" and #image.pixels == w * h,
		what .. " needs width * height pixels")
end

--- Builds a grayscale image from rows of RGB or gray values.
--- @param rows table Rows top to bottom; each row is an array of gray integers.
--- @return table image
function M.from_rows(rows)
	assert(type(rows) == "table" and #rows >= 1, "an image needs at least one row")
	local width = #rows[1]
	local pixels, n = {}, 0
	for y = 1, #rows do
		assert(#rows[y] == width, "every row of an image has the same width")
		for x = 1, width do
			n = n + 1
			pixels[n] = rows[y][x]
		end
	end
	return { width = width, height = #rows, pixels = pixels }
end

--- Halves an image with a 2x2 box average, rounded to nearest, starting at
--- a phase of 0 or 1 pixel on each axis; a column or row left over is dropped.
--- @param image table
--- @param ox integer|nil Horizontal phase, 0 by default.
--- @param oy integer|nil Vertical phase, 0 by default.
--- @return table image
function M.halve(image, ox, oy)
	ox, oy = ox or 0, oy or 0
	local w = math.floor((image.width - ox) / 2)
	local h = math.floor((image.height - oy) / 2)
	assert(w >= 1 and h >= 1, "an image this small cannot be halved")
	local sw, src = image.width, image.pixels
	local pixels, n = {}, 0
	for y = 0, h - 1 do
		local row_a = (2 * y + oy) * sw + ox
		local row_b = row_a + sw
		for x = 0, w - 1 do
			local c = 2 * x + 1
			n = n + 1
			pixels[n] = math.floor((src[row_a + c] + src[row_a + c + 1] + src[row_b + c] + src[row_b + c + 1] + 2) / 4)
		end
	end
	return { width = w, height = h, pixels = pixels }
end

--- Doubles an image by copying each pixel into a 2x2 block.
--- @param image table
--- @return table image
function M.double(image)
	local sw, sh, src = image.width, image.height, image.pixels
	local w = sw * 2
	local pixels = {}
	for y = 0, sh - 1 do
		for x = 0, sw - 1 do
			local value = src[y * sw + x + 1]
			local top = (2 * y) * w + 2 * x + 1
			pixels[top], pixels[top + 1] = value, value
			pixels[top + w], pixels[top + w + 1] = value, value
		end
	end
	return { width = w, height = sh * 2, pixels = pixels }
end

--- Resizes an image by a power-of-two factor.
--- @param image table
--- @param factor number 0.5, 1 or 2 (any power of two).
--- @return table image
function M.scale(image, factor)
	assert(type(factor) == "number" and factor > 0, "a scale factor must be a positive number")
	local out = image
	local f = factor
	while f > 1 do out = M.double(out); f = f / 2 end
	while f < 1 do out = M.halve(out); f = f * 2 end
	assert(f == 1, "a scale factor must be a power of two")
	return out
end




-- =============================================
-- =============================================
-- ======= 2/ Correlation ======================
-- =============================================
-- =============================================

--- Summed-area tables of the pixels and of their squares, one row and one
--- column of zeros ahead so a window sum needs no edge case.
--- @param image table
--- @return table sum, table squares
local function integrals(image)
	local w, h, src = image.width, image.height, image.pixels
	local stride = w + 1
	local sum, sq = {}, {}
	for i = 1, stride do sum[i], sq[i] = 0, 0 end
	for y = 1, h do
		local row_sum, row_sq = 0, 0
		sum[y * stride + 1], sq[y * stride + 1] = 0, 0
		for x = 1, w do
			local v = src[(y - 1) * w + x]
			row_sum = row_sum + v
			row_sq = row_sq + v * v
			local at = y * stride + x + 1
			sum[at] = sum[at - stride] + row_sum
			sq[at] = sq[at - stride] + row_sq
		end
	end
	return sum, sq
end

--- The sum of a window from a summed-area table.
local function window_sum(table_, stride, x, y, w, h)
	local top, bottom = y * stride, (y + h) * stride
	return table_[bottom + x + w + 1] - table_[top + x + w + 1] - table_[bottom + x + 1] + table_[top + x + 1]
end

--- Precomputes what a template contributes to every score.
--- @param template table
--- @return table|nil prepared, string|nil reason "template_uniform" for a flat template.
local function prepare(template)
	local n, s, ss = template.width * template.height, 0, 0
	for i = 1, n do
		local v = template.pixels[i]
		s = s + v
		ss = ss + v * v
	end
	local variance = n * ss - s * s
	if variance <= 0 then return nil, "template_uniform" end
	return { image = template, n = n, sum = s, variance = variance }
end

--- The normalised cross-correlation of the template at one window position.
--- Integer sums until the square root, then floats: Lua 5.4 would wrap the
--- product of two variances as integers.
local function score_at(image, sum, sq, stride, prepared, x, y)
	local t = prepared.image
	local tw, th, tp, ip, iw = t.width, t.height, t.pixels, image.pixels, image.width
	local cross = 0
	for row = 0, th - 1 do
		local base_i = (y + row) * iw + x
		local base_t = row * tw
		for col = 1, tw do
			cross = cross + ip[base_i + col] * tp[base_t + col]
		end
	end
	local n = prepared.n
	local si = window_sum(sum, stride, x, y, tw, th)
	local window_variance = n * window_sum(sq, stride, x, y, tw, th) - si * si
	if window_variance <= 0 then return 0 end
	local numerator = n * cross - si * prepared.sum
	return numerator / math.sqrt((window_variance * 1.0) * prepared.variance)
end

--- Scores every position of a region and keeps the ones at or above a floor.
local function scan(image, prepared, x0, y0, x1, y1, floor_score)
	local sum, sq = integrals(image)
	local stride = image.width + 1
	local found = {}
	for y = y0, y1 do
		for x = x0, x1 do
			local score = score_at(image, sum, sq, stride, prepared, x, y)
			if score >= floor_score then found[#found + 1] = { x = x, y = y, score = score } end
		end
	end
	return found
end




-- =============================================
-- =============================================
-- ======= 3/ Public API =======================
-- =============================================
-- =============================================

--- Finds the best match of one template in an image, across scales.
--- @param image table Grayscale capture of the window.
--- @param template table Grayscale library image.
--- @param options table {
---   threshold         number  least score of a match, 0 to 1;
---   scales            table   power-of-two factors tried on the template, in order;
---   coarse_min_px     integer least side of the halved template in the coarse pass;
---   coarse_margin     number  how far under the threshold a coarse candidate may score;
---   coarse_candidates integer most coarse candidates refined at full size }
--- @return table|nil match { x, y, width, height, score, scale } in image pixels,
---   0-based top-left corner; nil when no position reaches the threshold.
--- @return string|nil reason "template_uniform" when the template cannot match.
function M.find(image, template, options)
	check_image(image, "the capture")
	check_image(template, "the template")
	assert(type(options) == "table", "the matcher needs its options")
	local threshold = options.threshold
	assert(type(threshold) == "number" and threshold > 0 and threshold <= 1, "the threshold is a number in ]0, 1]")
	assert(type(options.scales) == "table" and #options.scales >= 1, "the matcher needs at least one scale")
	assert(type(options.coarse_min_px) == "number" and options.coarse_min_px >= 2, "coarse_min_px is at least 2")
	assert(type(options.coarse_margin) == "number" and options.coarse_margin >= 0, "coarse_margin is not negative")
	assert(type(options.coarse_candidates) == "number" and options.coarse_candidates >= 1,
		"coarse_candidates is at least 1")

	-- The window's sums and halvings serve every scale of the template.
	local cache = { variants = {} }
	local best, uniform = nil, false
	for _, factor in ipairs(options.scales) do
		local scaled_ok, scaled = pcall(M.scale, template, factor)
		if scaled_ok and scaled.width <= image.width and scaled.height <= image.height then
			local prepared, reason = prepare(scaled)
			if not prepared then
				uniform = uniform or reason == "template_uniform"
			else
				local match = M.find_at_scale(image, prepared, threshold, options, cache)
				if match and (not best or match.score > best.score) then
					match.scale = factor
					best = match
				end
			end
		end
	end
	if best then return best end
	if uniform then return nil, "template_uniform" end
	return nil
end

--- Every halving of an image down a number of levels, one per pixel phase,
--- each with the full-size offset of its first pixel. A template halved at
--- phase 0 lines up exactly with one of them wherever it lies, so a thin
--- stroke at an odd position is not averaged away.
--- @param image table
--- @param levels integer
--- @param min_w integer Least width a variant keeps.
--- @param min_h integer Least height a variant keeps.
--- @return table variants { image, ox, oy }
local function phase_variants(image, levels, min_w, min_h)
	if levels == 0 then return { { image = image, ox = 0, oy = 0 } } end
	local out = {}
	for oy = 0, 1 do
		for ox = 0, 1 do
			if math.floor((image.width - ox) / 2) >= min_w and math.floor((image.height - oy) / 2) >= min_h then
				local half = M.halve(image, ox, oy)
				for _, v in ipairs(phase_variants(half, levels - 1, min_w, min_h)) do
					out[#out + 1] = { image = v.image, ox = ox + 2 * v.ox, oy = oy + 2 * v.oy }
				end
			end
		end
	end
	return out
end

--- Coarse-to-fine search of one prepared template at its own size.
--- @param image table
--- @param prepared table As prepare returns it.
--- @param threshold number
--- @param options table See M.find.
--- @param cache table|nil Sums and halvings of the image shared across scales.
--- @return table|nil match
function M.find_at_scale(image, prepared, threshold, options, cache)
	cache = cache or { variants = {} }
	local t = prepared.image
	local tw, th = t.width, t.height
	-- Halve the template while it keeps its least side.
	local levels, factor = 0, 1
	local small_template = t
	while math.floor(math.min(small_template.width, small_template.height) / 2) >= options.coarse_min_px do
		small_template = M.halve(small_template)
		levels, factor = levels + 1, factor * 2
	end

	local max_x, max_y = image.width - tw, image.height - th
	local candidates
	if levels == 0 then
		candidates = { { x0 = 0, y0 = 0, x1 = max_x, y1 = max_y } }
	else
		local coarse_prepared = prepare(small_template)
		if not coarse_prepared then return nil end
		local found = {}
		local key = levels .. ":" .. small_template.width .. ":" .. small_template.height
		cache.variants[key] = cache.variants[key]
			or phase_variants(image, levels, small_template.width, small_template.height)
		for _, v in ipairs(cache.variants[key]) do
			local hits = scan(v.image, coarse_prepared, 0, 0,
				v.image.width - small_template.width, v.image.height - small_template.height,
				threshold - options.coarse_margin)
			for _, hit in ipairs(hits) do
				found[#found + 1] = { x = v.ox + hit.x * factor, y = v.oy + hit.y * factor, score = hit.score }
			end
		end
		-- Strongest first, row-major order on a tie, so the refine budget is
		-- spent the same way on every driver.
		table.sort(found, function(a, b)
			if a.score ~= b.score then return a.score > b.score end
			if a.y ~= b.y then return a.y < b.y end
			return a.x < b.x
		end)
		candidates = {}
		for i = 1, math.min(#found, options.coarse_candidates) do
			local c = found[i]
			candidates[i] = { x0 = c.x - 1, y0 = c.y - 1, x1 = c.x + 1, y1 = c.y + 1 }
		end
	end

	local best
	if not cache.sum then cache.sum, cache.sq = integrals(image) end
	local sum, sq = cache.sum, cache.sq
	local stride = image.width + 1
	for _, c in ipairs(candidates) do
		for y = math.max(0, c.y0), math.min(max_y, c.y1) do
			for x = math.max(0, c.x0), math.min(max_x, c.x1) do
				local score = score_at(image, sum, sq, stride, prepared, x, y)
				if score >= threshold and (not best or score > best.score
					or (score == best.score and (y < best.y or (y == best.y and x < best.x)))) then
					best = { x = x, y = y, width = tw, height = th, score = score }
				end
			end
		end
	end
	return best
end

--- Validates a library image at import: refuses a flat template.
--- @param template table Grayscale image.
--- @return boolean ok, string|nil reason
function M.check_template(template)
	check_image(template, "the template")
	local prepared, reason = prepare(template)
	if not prepared then return false, reason end
	return true
end

--- The screen point a match is clicked at: its centre, converted from
--- capture pixels to screen points.
--- @param frame table { x, y } top-left of the captured window in screen points.
--- @param capture_scale number Capture pixels per screen point (2 on Retina).
--- @param match table As M.find returns it.
--- @return integer x, integer y
function M.click_point(frame, capture_scale, match)
	assert(type(capture_scale) == "number" and capture_scale > 0, "the capture scale is a positive number")
	local cx = (match.x + match.width / 2) / capture_scale
	local cy = (match.y + match.height / 2) / capture_scale
	return math.floor(frame.x + cx), math.floor(frame.y + cy)
end

return M
