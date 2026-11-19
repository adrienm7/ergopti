--- tests/unit/core/ui/tooltip/test_category_glyph_preview.lua

--- ==============================================================================
--- MODULE: Category Glyph in the Hotstring Preview
--- DESCRIPTION:
--- Each preview row shows its category's glyph beside the trigger label, so a
--- reader who cannot tell the tints apart still tells the categories apart (the
--- maintainer's decision of 2026-11-19). These cases pin the row, the label the
--- renderer measures and draws, the glyphs switch, and the text AT-SPI reads.
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

local CANDIDATES = {
	{ trigger = "btw", replacement = "by the way", group = "autocorrection", fires = true },
	{ trigger = "sig", replacement = "Signature", group = "personal", fires = false },
}

--- A Pango stand-in that records every text it is asked to measure.
--- @return table binding, table measured
local function fake_binding()
	local measured = {}
	local description = { set_size = function() end }
	local binding = {
		Pango = { FontDescription = { from_string = function() return description end } },
	}
	local layout = {
		set_font_description = function() end,
		set_text = function(_, text) measured[#measured + 1] = text end,
		get_pixel_size = function() return 10, 10 end,
	}
	return binding, measured, layout
end

local STYLE = {
	fonts = { main = "Sans" },
	sizes = { main = 13, hint = 11 },
	layout = { label_gap = 8, line_spacing = 2, pad_x = 10, pad_y = 6, llm_max_content_width = 400 },
}

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

	helpers.it("measures the glyph beside the trigger label, in the label's size", function()
		local Renderer = helpers.load_module("core.ui.adapters.graphics_renderer")
		local binding, measured, layout = fake_binding()
		Renderer._set_binding_for_test(binding)
		local rows = preview().build_rows(CANDIDATES, { kind = "autocorrect" })
		Renderer.measure_rows(rows, STYLE, layout)
		Renderer._set_binding_for_test(nil)
		helpers.assert_eq(measured[2], "✓ ↵", "the first row's label is its glyph then its key")
		helpers.assert_eq(Renderer.row_label({ label = "↵" }), "↵", "a row without a glyph keeps its bare label")
	end)

	helpers.it("names the category in the text a screen reader is told", function()
		local Renderer = helpers.load_module("core.ui.adapters.graphics_renderer")
		local I18n = require("core.i18n.engine.i18n")
		local rows = preview().build_rows(CANDIDATES, { kind = "autocorrect" })
		local text = Renderer.accessible_text(rows)
		helpers.assert_eq(text, "by the way ↵, " .. I18n.get("hs_config.cat_autocorrection"),
			"the fired row, its key and its category; never the glyph itself")
	end)
end)
