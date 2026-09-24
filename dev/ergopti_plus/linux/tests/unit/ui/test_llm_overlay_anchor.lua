--- tests/unit/ui/test_llm_overlay_anchor.lua

--- ==============================================================================
--- MODULE: Where The AI Suggestions Appear
--- DESCRIPTION:
--- The daemon initialised the suggestion overlay with a style only, so it had
--- no anchor and drew centred on an assumed 1920x1080 screen, wherever the
--- user was typing and whatever the real screen. It now takes the hotstring
--- preview's anchor and screen, like the preview itself.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("AI overlay: placed like the hotstring preview", function()

	helpers.it("draws at the anchor and on the screen it is given", function()
		local drawn
		local overlay = helpers.load_module("ui.tooltip.llm")
		overlay.init({
			style = {},
			renderer = { show = function(_, opts) drawn = opts; return true end, hide = function() end },
			anchor_provider = function() return { type = "window", x = 300, y = 700, h = 0 } end,
			screen_provider = function() return { x = 0, y = 0, w = 2560, h = 1440 } end,
		})
		overlay.show({ { to_type = "que tout va bien", deletes = 0 } }, {})
		helpers.assert_eq(drawn.anchor.x, 300)
		helpers.assert_eq(drawn.screen.w, 2560)
	end)

	helpers.it("is given the preview's anchor and screen by the daemon", function()
		local fh = assert(io.open("ergopti_hotstrings.lua", "r"))
		local source = fh:read("*a")
		fh:close()
		local init = source:match("llm_overlay%.init(%b())")
		helpers.assert_true(init ~= nil, "the daemon initialises the overlay")
		helpers.assert_true(init:find("anchor_provider%s*=%s*tooltip_preview%.resolve_anchor") ~= nil, init)
		helpers.assert_true(init:find("screen_provider%s*=%s*tooltip_preview%.screen_frame") ~= nil, init)
	end)

end)
