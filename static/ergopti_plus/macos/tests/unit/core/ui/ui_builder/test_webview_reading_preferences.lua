--- tests/unit/core/ui/ui_builder/test_webview_reading_preferences.lua

--- ==============================================================================
--- MODULE: The Pages Carry the Reading Preferences (macOS)
--- DESCRIPTION:
--- Replays the shared reading-preference vectors and builds a real shared
--- page through ui/ui/builder.lua: the reader's font and spacing must reach
--- the page before a11y_prefs.js, the font inlined because the page has no
--- base URL, and a page built for one choice is never served for another.
--- ==============================================================================

local helpers = require("tests.helpers")
local Contract = require("tests.lua.reading_preferences_contract")
Contract.register(helpers, helpers.shared(""))

--- Builds the action picker page with a fresh builder cache.
--- @return string html
local function build()
	local saved_locale, saved_i18n = package.loaded["core.i18n.engine.locale"], package.loaded["core.i18n.engine.i18n"]
	package.loaded["core.i18n.engine.locale"] = { catalogue = function() return { ["probe"] = "Probe" } end }
	package.loaded["core.i18n.engine.i18n"] = { get_locale = function() return "en" end }
	local builder = require("core.ui.ui.builder")
	local ok, html = pcall(builder.build_injected_html, helpers.shared("ui/action_picker/"), "index.html")
	package.loaded["core.i18n.engine.locale"], package.loaded["core.i18n.engine.i18n"] = saved_locale, saved_i18n
	assert(ok, tostring(html))
	return html
end

package.loaded["core.ui.ui.builder"] = nil
Contract.register_host(helpers, "the macOS page builder", build)

helpers.describe("the macOS windows follow a reading choice at once (reading-preferences-live)", function()
	helpers.it("pushes the choice into every open window and drops a closed one", function()
		local builder = require("core.ui.ui.builder")
		local scripts, refused = {}, 0
		local open = { evaluateJavaScript = function(_, script) scripts[#scripts + 1] = script end }
		local closed = { evaluateJavaScript = function() refused = refused + 1; error("deleted webview") end }
		local Views = require("core.ui.ui.reading_views")
		Views.track(open)
		Views.track(closed)
		Contract.with_store({ ["script.reading_font"] = "dyslexic", ["script.reading_spacing"] = "wide" }, function()
			local reached = builder.push_reading_preferences()
			helpers.assert_true(type(reached) == "number" and reached >= 1, "the open window is reached")
			helpers.assert_eq(#scripts, 1, "one push per open window")
			helpers.assert_true(scripts[1]:find("receiveHost", 1, true) ~= nil, "the page applies the push")
			helpers.assert_true(scripts[1]:find('"font":"dyslexic"', 1, true) ~= nil, "the push names the font")
			helpers.assert_true(scripts[1]:find("data:font/woff2;base64,", 1, true) ~= nil, "the font comes inline")
			builder.push_reading_preferences()
		end)
		helpers.assert_eq(#scripts, 2, "the open window takes every push")
		helpers.assert_eq(refused, 1, "a closed window is dropped after its first refusal")
	end)
end)
