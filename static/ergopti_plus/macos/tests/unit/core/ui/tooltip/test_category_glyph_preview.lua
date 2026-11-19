--- tests/unit/core/ui/tooltip/test_category_glyph_preview.lua

--- ==============================================================================
--- MODULE: Hotstring Preview Category Glyph (regression)
--- DESCRIPTION:
--- The preview tints sit at one lightness, so a colour-blind reader told the
--- categories apart by nothing. Each row now draws its category glyph beside the
--- trigger label, in the label's font and colour; the glyph switch removes it,
--- and VoiceOver hears the category's name.
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

--- Renders one row and returns the label element's text. A renderer load reads
--- the shared tooltip TOML, which is slow on a mounted drive, so the cases share one.
--- @param renderer table A loaded renderer.
--- @param row table A stacked row.
--- @return string|nil label
local function rendered_label(renderer, row)
	renderer.stacked_canvas = make_canvas(5)
	helpers.assert_eq(renderer.render_stacked({ row }, {}, function() end), true, "the row renders")
	-- Row 1 owns elements 1..4: background, cap, text, label.
	return renderer.stacked_canvas[4].text
end

helpers.describe("tooltip preview: category glyph", function()
	Fixture.it("draws the glyph beside the trigger label, and the bare label without one", function()
		local renderer = Fixture.load()
		helpers.assert_eq(rendered_label(renderer, { text = "déjà", trigger_label = "↵", glyph = "✓" }), "✓ ↵")
		helpers.assert_eq(rendered_label(renderer, { text = "déjà", trigger_label = "★" }), "★")
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
			helpers.assert_eq(rendered_label(renderer, { text = "déjà", trigger_label = "↵", glyph = glyph }), "↵",
				"switch off: the bare trigger label")
		end)
		Config.set_category_glyphs_enabled(true)
		package.loaded["hotstrings.engine.catalogue.config"] = previous
		assert(ok, err)
	end)

	Fixture.it("names the category in the screen-reader notice", function()
		local renderer = Fixture.load()
		-- Swapped after the load: the notice reads the accessor when it speaks.
		package.loaded["core.i18n.engine.i18n"] = {
			get = function(key) return key == "hs_config.cat_autocorrection" and "Autocorrection" or key end,
		}
		helpers.assert_eq(renderer.announcement_for_stacked({
			{ text = "déjà", trigger_label = "↵", glyph = "✓", glyph_name_key = "hs_config.cat_autocorrection" },
			{ text = "deja", trigger_label = "↵", glyph = "✓", glyph_name_key = "hs_config.cat_autocorrection", dimmed = true },
		}), "déjà ↵, Autocorrection")
		helpers.assert_eq(renderer.announcement_for_stacked({ { text = "déjà", trigger_label = "↵" } }), "déjà ↵",
			"a row without a glyph names no category")
	end)
end)
