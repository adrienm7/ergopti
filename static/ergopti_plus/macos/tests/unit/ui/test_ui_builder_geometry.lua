--- tests/unit/ui/test_ui_builder_geometry.lua

--- ==============================================================================
--- MODULE: UI Builder Geometry Single-Source Test
--- DESCRIPTION:
--- Verifies ui_builder.get_app_geometry() resolves each webview's size from the
--- shared manifest (_shared/ui/apps.manifest.json) so macOS opens every window at
--- the one canonical size (SSoT, P0-A) instead of a hardcoded per-module constant.
---
--- ROOT CAUSE ENCODED:
--- Geometry used to be hardcoded per driver and had drifted — the hotstring editor
--- was 960x640 on Windows but 760x640 on macOS, the changelog 580 vs 560 tall, etc.
--- Wiring macOS through this resolver removed the macOS literals; this test proves
--- the resolver actually returns the manifest values (a wrong key or a regression
--- back to a literal would change them) and fails loud on an unknown id (§5.3/§5.4).
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===============================================================
-- ===============================================================
-- ======= 1/ Behavioural: geometry resolves from manifest =======
-- ===============================================================
-- ===============================================================

helpers.describe("ui_builder.get_app_geometry: single-sources window size from the shared manifest", function()
	helpers.it("returns the manifest width/height for a known app id", function()
		local ui_builder = helpers.load_with_stubs("ui.ui_builder")
		helpers.assert_true(type(ui_builder.get_app_geometry) == "function",
			"ui_builder must expose get_app_geometry")
		local geo = ui_builder.get_app_geometry("hotstring_editor")
		helpers.assert_true(type(geo) == "table", "geometry must be a table for a known id")
		-- Canonical hotstring_editor size in _shared/ui/apps.manifest.json.
		helpers.assert_eq(geo.width, 960, "hotstring_editor width must come from the manifest")
		helpers.assert_eq(geo.height, 640, "hotstring_editor height must come from the manifest")
	end)

	helpers.it("returns nil (fail-loud) for an unknown app id", function()
		local ui_builder = helpers.load_with_stubs("ui.ui_builder")
		local geo = ui_builder.get_app_geometry("does_not_exist")
		helpers.assert_nil(geo, "unknown app id must resolve to nil, never a hardcoded fallback")
	end)
end)

helpers.describe("webview factory native capability", function()
	helpers.it("reports the real creation port without allocating a native window", function()
		local builder = helpers.load_with_stubs("ui.ui_builder")
		local native = hs
		local previous = native.webview
		local calls = 0
		native.webview = { new = function() calls = calls + 1; return nil end }
		local available = builder.can_create_webview()
		local observed = calls
		native.webview = previous
		helpers.assert_eq(available, true)
		helpers.assert_eq(observed, 0)
	end)

	helpers.it("refuses missing or invalid native constructors before factory effects", function()
		local builder = helpers.load_with_stubs("ui.ui_builder")
		local native = hs
		local previous = native.webview
		local observations = {}
		for _, port in ipairs({ false, {}, { new = true }, { new = "constructor" } }) do
			native.webview = port
			local ok, result = pcall(builder.show_webview, { frame = {} })
			observations[#observations + 1] = { available = builder.can_create_webview(), ok = ok, result = result }
		end
		native.webview = previous
		for _, observation in ipairs(observations) do
			helpers.assert_eq(observation.available, false)
			helpers.assert_eq(observation.ok, true)
			helpers.assert_eq(observation.result, nil)
		end
	end)
end)
