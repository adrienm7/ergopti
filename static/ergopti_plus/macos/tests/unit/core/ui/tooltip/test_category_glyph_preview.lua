--- tests/unit/core/ui/tooltip/test_category_glyph_preview.lua

--- ==============================================================================
--- MODULE: Hotstring Preview Category Glyph (regression)
--- DESCRIPTION:
--- The preview tints sit at one lightness, so a colour-blind reader told the
--- categories apart by nothing. Each row now draws its category glyph first, at
--- its far left, in a filled chip that ends before the output, so the glyph
--- reads as an annotation and not as typed text; the glyph switch removes the
--- badge and its gap, and VoiceOver hears the category's name first.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.tooltip_renderer_fixture")

--- A canvas double holding `count` elements that records what is written.
--- @param count integer
--- @return table canvas
local function make_canvas(count)
	local canvas = { showing = false }
	for index = 1, count do canvas[index] = {} end
	function canvas:minimumTextSize() return { w = 40, h = 16 } end
	function canvas:frame(value)
		if value ~= nil then self.native_frame = value end
		return self.native_frame or { x = 0, y = 0, w = 100, h = 20 }
	end
	function canvas:show() self.showing = true; return self end
	function canvas:hide() self.showing = false; return self end
	function canvas:isShowing() return self.showing end
	return canvas
end

--- Renders one row and returns its slots. A renderer load reads the shared
--- tooltip TOML, which is slow on a mounted drive, so the cases share one.
--- @param renderer table A loaded renderer.
--- @param row table A stacked row.
--- @return table { frame, glyph, output, label } The row's elements.
local function rendered_row(renderer, row)
	renderer.stacked_canvas = make_canvas(#renderer._build_stacked_elements(1))
	helpers.assert_eq(renderer.render_stacked({ row }, {}, function() end), true, "the row renders")
	-- Row 1 owns elements 1..6: background, cap, badge frame, glyph, output, label.
	local canvas = renderer.stacked_canvas
	return { frame = canvas[3], glyph = canvas[4], output = canvas[5], label = canvas[6] }
end

--- Asserts the glyph is the row's first cell, on a chip that ends
--- before the output, and the trigger label alone at the right.
--- @param slots table From rendered_row.
--- @param glyph string
--- @param label string
local function assert_badge_first(slots, glyph, label)
	helpers.assert_eq(slots.glyph.text, glyph, "the glyph has a slot of its own")
	helpers.assert_eq(slots.glyph.action, "fill", "the glyph is drawn")
	helpers.assert_eq(slots.frame.action, "fill", "a chip is filled under the glyph")
	assert(type(slots.frame.fillColor) == "table" and slots.frame.fillColor.alpha > 0, "the chip is visible")
	local f, g, o = slots.frame.frame, slots.glyph.frame, slots.output.frame
	assert(f.x <= g.x and f.y <= g.y and f.x + f.w >= g.x + g.w and f.y + f.h >= g.y + g.h,
		"the chip lies under the whole glyph")
	assert(g.x < o.x, "the glyph is drawn before the output, at the left of the row")
	assert(f.x + f.w < o.x, "the chip ends before the output, with a gap")
	helpers.assert_eq(slots.label.text, label, "the trigger label stays alone")
	assert(slots.label.frame.x > o.x, "the trigger label stays right of the output")
end

helpers.describe("tooltip preview: category glyph", function()
	Fixture.it("draws the glyph first, on a chip, before the output; none without one", function()
		local renderer = Fixture.load()
		local Config = require("core.ui.ui.tooltip.config")
		assert_badge_first(rendered_row(renderer, { text = "déjà", trigger_label = "↵", glyph = "✓" }), "✓", "↵")
		local bare = rendered_row(renderer, { text = "déjà", trigger_label = "★" })
		helpers.assert_eq(bare.frame.action, "skip", "no glyph, no chip")
		helpers.assert_eq(bare.glyph.action, "skip", "no glyph, no glyph slot")
		helpers.assert_eq(bare.output.frame.x, Config.layout.pad_x, "the output keeps the padding, with no gap")
		helpers.assert_eq(bare.label.text, "★", "the bare trigger label")
	end)

	Fixture.it("dims the badge with a dimmed row", function()
		local renderer = Fixture.load()
		local Config = require("core.ui.ui.tooltip.config")
		local slots = rendered_row(renderer, { text = "deja", trigger_label = "↵", glyph = "✓", dimmed = true })
		assert(slots.frame.fillColor.alpha < Config.colors.glyph_badge.alpha, "the chip dims with the row")
	end)

	Fixture.it("hands no glyph to the rows while the glyph switch is off", function()
		local renderer = Fixture.load()
		local Config = require("core.ui.ui.tooltip.config")
		local previous = package.loaded["hotstrings.engine.catalogue.config"]
		package.loaded["hotstrings.engine.catalogue.config"] = {
			resolve = function(category)
				helpers.assert_eq(category, "autocorrection", "the tint's category")
				return { glyph = "✓", glyph_name_key = "hs_config.cat_autocorrection" }
			end,
		}
		local ok, err = pcall(function()
			Config.set_category_glyphs_enabled(true)
			local glyph, name_key = Config.glyph("hotstring_autocorrect")
			helpers.assert_eq(glyph, "✓", "switch on: the category's glyph")
			helpers.assert_eq(name_key, "hs_config.cat_autocorrection", "switch on: its name")
			Config.set_category_glyphs_enabled(false)
			glyph = Config.glyph("hotstring_autocorrect")
			helpers.assert_eq(glyph, nil, "switch off: no glyph")
			local slots = rendered_row(renderer, { text = "déjà", trigger_label = "↵", glyph = glyph })
			helpers.assert_eq(slots.frame.action, "skip", "switch off: no badge")
			helpers.assert_eq(slots.output.frame.x, Config.layout.pad_x, "switch off: no gap before the output")
		end)
		Config.set_category_glyphs_enabled(true)
		package.loaded["hotstrings.engine.catalogue.config"] = previous
		assert(ok, err)
	end)

	Fixture.it("names the category first in the screen-reader notice", function()
		local renderer = Fixture.load()
		-- Swapped after the load: the notice reads the accessor when it speaks.
		package.loaded["core.i18n.engine.i18n"] = {
			get = function(key) return key == "hs_config.cat_autocorrection" and "Autocorrection" or key end,
		}
		helpers.assert_eq(renderer.announcement_for_stacked({
			{ text = "déjà", trigger_label = "↵", glyph = "✓", glyph_name_key = "hs_config.cat_autocorrection" },
			{ text = "deja", trigger_label = "↵", glyph = "✓", glyph_name_key = "hs_config.cat_autocorrection", dimmed = true },
		}), "Autocorrection, déjà ↵")
		helpers.assert_eq(renderer.announcement_for_stacked({ { text = "déjà", trigger_label = "↵" } }), "déjà ↵",
			"a row without a glyph names no category")
	end)
end)
