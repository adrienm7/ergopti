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
