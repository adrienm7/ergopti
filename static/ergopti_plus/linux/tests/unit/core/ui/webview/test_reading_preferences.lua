--- tests/unit/core/ui/webview/test_reading_preferences.lua

--- ==============================================================================
--- MODULE: The Pages Carry the Reading Preferences (Linux)
--- DESCRIPTION:
--- Replays the shared reading-preference vectors and builds a real shared
--- page through core/ui/ui/webkit_host.lua: the reader's font and spacing
--- must reach the page before a11y_prefs.js, the font inlined because
--- WebKitGTK loads the page with no base URL.
--- ==============================================================================

local helpers = require("tests.helpers")
local Contract = require("tests.lua.reading_preferences_contract")
Contract.register(helpers, helpers.driver_root() .. "/../_shared")

local WebkitHost = helpers.load_module("core.ui.ui.webkit_host")
Contract.register_host(helpers, "the Linux page builder", function()
	return WebkitHost.build_app_html(helpers.driver_root(), "action_picker", "en", { probe = "Probe" })
end)
