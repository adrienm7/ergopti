--- tests/unit/core/ui/tooltip/test_category_glyph_preview.lua

--- ==============================================================================
--- MODULE: Category Glyph in the Hotstring Preview
--- DESCRIPTION:
--- Each preview row shows its category's glyph, so a reader who cannot tell the
--- tints apart still tells the categories apart (the maintainer's decision of
--- 2026-11-19). The glyph is the row's first cell, at its far left, on a filled
--- chip that ends before the output, so it reads as an annotation and
--- not as typed text (his request of the same day; a chip since 2026-11-20).
--- These cases pin the row, the drawn order and chip, the glyphs switch, and the
--- text AT-SPI reads.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A config whose tint categories carry the glyphs the shared resolver gives.
--- @return table
local function fake_config()
	local GLYPHS = {
		magickey = { "✦", "hs_config.cat_magickey" },
		autocorrection = { "✓", "hs_config.cat_autocorrection" },
		personal = { "✎", "hs_config.cat_personal" },
	}
	return {
		resolve = function(category)
			local glyph = GLYPHS[category] or { "•", "hs_config.cat_other" }
			return { delay = 0.75, color = "#1e88e5", show_tooltip = true, has_override = false,
				glyph = glyph[1], glyph_name_key = glyph[2] }
		end,
	}
end

--- @return table The preview module, initialised with the config above.
local function preview()
	local P = helpers.load_module("core.ui.ui.tooltip.preview")
	P.init({ style = { positioning = { window_bottom_inset = 0 } }, config = fake_config() })
	return P
end

-- The chip grey of the test style.
local CHIP_WHITE = 0.667

local CANDIDATES = {
	{ trigger = "btw", replacement = "by the way", group = "autocorrection", fires = true },
	{ trigger = "sig", replacement = "Signature", group = "personal", fires = false },
}

--- A Pango and cairo stand-in that records every text it draws and every
--- rectangle it fills in the chip grey, in order, with where it was drawn. A
--- text is measured as 10 px per character, 12 px high.
--- @return table binding, table ops, table layout, table cr
local function fake_binding()
	local ops = {}
	local description = { set_size = function() end }
	local layout = { text = "" }
	function layout:set_font_description() end
	function layout:set_text(text) self.text = text end
	function layout:get_pixel_size()
		local count = 0
		for _ in self.text:gmatch("[^\128-\191]") do count = count + 1 end
		return count * 10, 12
	end
	function layout:set_width() end
	function layout:set_ellipsize() end
	local cr = { x = 0, y = 0, path = nil }
	function cr:set_operator() end
	function cr:set_source_rgba(r, g, b, a) self.color = { r, g, b, a } end
	function cr:paint() end
	function cr:new_sub_path() self.path = nil end
	function cr:arc() end
	function cr:close_path() end
	function cr:fill_preserve() end
	-- A rectangle filled in the chip grey is a chip; the accent bars have the
	-- category's colour.
	function cr:fill()
		local path, c = self.path, self.color
		if path and path.w and c[1] == CHIP_WHITE and c[2] == CHIP_WHITE and c[3] == CHIP_WHITE then
			ops[#ops + 1] = { kind = "chip", x = path.x, y = path.y, w = path.w, h = path.h, alpha = c[4] }
		end
		self.path = nil
	end
	function cr:set_line_width(width) self.line_width = width end
	function cr:rectangle(x, y, w, h) self.path = { x = x, y = y, w = w, h = h } end
	function cr:stroke() self.path = nil end
	function cr:move_to(x, y) self.x, self.y = x, y end
	function cr:line_to() end
	local binding = {
		Pango = { FontDescription = { from_string = function() return description end } },
		PangoCairo = {
			create_layout = function() return layout end,
			show_layout = function(context)
				local w, h = layout:get_pixel_size()
				ops[#ops + 1] = { kind = "text", text = layout.text, x = context.x, y = context.y, w = w, h = h }
			end,
		},
	}
	return binding, ops, layout, cr
end

local STYLE = {
	fonts = { main = "Sans" },
	sizes = { main = 13, hint = 11 },
	layout = { label_gap = 8, line_spacing = 2, pad_x = 10, pad_y = 6, llm_max_content_width = 400,
		corner_radius = 4, glyph_badge_pad_x = 3, glyph_badge_pad_y = 1, glyph_badge_gap = 8 },
	colors = { canvas_alpha = 1, border_white = 1, border_alpha = 0.13, glyph_badge_white = CHIP_WHITE },
}

--- Measures then paints rows on the recording context.
--- @param rows table
--- @return table ops The drawn texts and stroked frames, in order.
local function painted(rows)
	local Renderer = helpers.load_module("core.ui.adapters.graphics_renderer")
	local binding, ops, layout, cr = fake_binding()
	Renderer._set_binding_for_test(binding)
	local ok, err = pcall(function()
		local size, metrics = Renderer.measure_rows(rows, STYLE, layout)
		Renderer._paint_for_test(cr, rows, metrics, STYLE, size, { red = 0, green = 0, blue = 0, alpha = 1 })
	end)
	Renderer._set_binding_for_test(nil)
	assert(ok, err)
	return ops
end

--- The first drawn op matching a predicate, or nil.
local function find(ops, predicate)
	for _, op in ipairs(ops) do
		if predicate(op) then return op end
	end
	return nil
end

local function text_op(ops, text)
	return find(ops, function(op) return op.kind == "text" and op.text == text end)
end

helpers.describe("preview: category glyph", function()
	helpers.it("gives each row the glyph and name of the category its tint follows", function()
		local rows = preview().build_rows(CANDIDATES, { kind = "autocorrect" })
		helpers.assert_eq(rows[1].glyph, "✓", "an end-char row wears the autocorrection glyph")
		helpers.assert_eq(rows[1].glyph_name_key, "hs_config.cat_autocorrection")
		helpers.assert_eq(rows[2].glyph, "✎", "a personal entry keeps its own glyph")
	end)

	helpers.it("drops every glyph when the glyphs switch is off, and keeps the colour", function()
		local P = preview()
		P.set_enabled("glyphs", false)
		local rows = P.build_rows(CANDIDATES, { kind = "autocorrect" })
		P.set_enabled("glyphs", true)
		for index, row in ipairs(rows) do
			helpers.assert_nil(row.glyph, "row " .. index .. " has no glyph")
			assert(row.accent ~= nil, "row " .. index .. " keeps its tint")
		end
		helpers.assert_eq(P.is_enabled("glyphs"), true, "the switch is one of the preview toggles")
		helpers.assert_eq(P.build_rows(CANDIDATES, { kind = "autocorrect" })[1].glyph, "✓",
			"switched back on, the glyph returns")
	end)

	helpers.it("draws the glyph first, on a chip, before the output; the label alone at the right", function()
		local rows = preview().build_rows(CANDIDATES, { kind = "autocorrect" })
		local ops = painted(rows)
		local first_text = find(ops, function(op) return op.kind == "text" end)
		helpers.assert_eq(first_text and first_text.text, "✓", "the row's glyph is the first thing drawn")
		local glyph, output, label = text_op(ops, "✓"), text_op(ops, "by the way"), text_op(ops, "↵")
		assert(output and label, "the output and the bare trigger label are drawn")
		assert(glyph.x < output.x, "the glyph is drawn left of the output")
		local chip = find(ops, function(op)
			return op.kind == "chip" and op.x <= glyph.x and op.y <= glyph.y
				and op.x + op.w >= glyph.x + glyph.w and op.y + op.h >= glyph.y + glyph.h
		end)
		assert(chip, "a chip lies under the whole glyph")
		assert(chip.alpha > 0, "the chip is visible")
		assert(chip.x + chip.w < output.x, "the chip ends before the output, with a gap")
		assert(label.x > output.x, "the trigger label stays right of the output")
		local struck_output = text_op(ops, "Signature")
		helpers.assert_eq(struck_output.x, output.x, "every output starts after the one badge column")
		local dimmed_chip = find(ops, function(op) return op.kind == "chip" and op ~= chip end)
		assert(dimmed_chip and dimmed_chip.alpha < chip.alpha, "a dimmed row dims its chip")
	end)

	helpers.it("draws no badge and leaves no gap without a glyph", function()
		local P = preview()
		P.set_enabled("glyphs", false)
		local rows = P.build_rows(CANDIDATES, { kind = "autocorrect" })
		P.set_enabled("glyphs", true)
		local ops = painted(rows)
		helpers.assert_nil(find(ops, function(op) return op.kind == "chip" end), "no chip is filled")
		helpers.assert_eq(text_op(ops, "by the way").x, STYLE.layout.pad_x, "the output keeps the padding")
	end)

	helpers.it("names the category first in the text a screen reader is told", function()
		local Renderer = helpers.load_module("core.ui.adapters.graphics_renderer")
		local I18n = require("core.i18n.engine.i18n")
		local rows = preview().build_rows(CANDIDATES, { kind = "autocorrect" })
		local text = Renderer.accessible_text(rows)
		helpers.assert_eq(text, I18n.get("hs_config.cat_autocorrection") .. ", by the way ↵",
			"the category first, as the badge comes first, then the fired row and its key; never the glyph")
	end)
end)
