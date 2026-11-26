--- tests/unit/core/ui/tooltip/test_preview_announcements.lua

--- ==============================================================================
--- MODULE: Preview Screen-Reader Switch (regression)
--- DESCRIPTION:
--- The hotstring previews and the finished AI predictions were spoken through
--- VoiceOver whenever it ran, with no way to silence them. The menu's
--- hotstrings.preview_announcements switch (2026-11-21) now gates the
--- renderer's announce path: on by default, off says nothing while the
--- preview is still drawn.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.tooltip_renderer_fixture")

--- A canvas double holding `count` elements.
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

helpers.describe("tooltip preview: screen-reader switch", function()
	Fixture.it("speaks a drawn preview with the switch on and nothing with it off", function()
		local renderer = Fixture.load()
		local Config = require("core.ui.ui.tooltip.config")
		-- The renderer holds the fixture's adapter table: recording on it sees
		-- every announcement the render hands over.
		local said = {}
		package.loaded["core.ui.adapters.system_accessibility"].announce = function(text)
			said[#said + 1] = text
			return true
		end
		local function render(text)
			renderer.stacked_canvas = make_canvas(#renderer._build_stacked_elements(1))
			helpers.assert_eq(renderer.render_stacked({ { text = text, trigger_label = "★" } }, {}, function() end), true,
				"the preview is drawn either way")
		end
		local ok, err = pcall(function()
			helpers.assert_eq(Config.settings.announcements_enabled, true, "the notices are on by default")
			render("bonjour")
			helpers.assert_eq(said, { "bonjour ★" }, "switch on: VoiceOver is told the preview")
			Config.set_announcements_enabled(false)
			render("bonsoir")
			helpers.assert_eq(said, { "bonjour ★" }, "switch off: nothing more is spoken")
			helpers.assert_eq(renderer.announce("salut"), false, "switch off: the announce path refuses")
		end)
		Config.set_announcements_enabled(true)
		assert(ok, err)
	end)
end)
