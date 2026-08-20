--- tests/unit/ui/test_wpm_config_missing_key.lua

--- ==============================================================================
--- MODULE: Regression — wpm_widget config loader survives a missing TOML key
--- DESCRIPTION:
--- Audit finding F-M5. _load_shared_const() did arithmetic directly on raw TOML
--- lookups — `transp.alpha_active / 255`, `(tc.ui and tc.ui.wpm_widget_idle_hide_ms)
--- / 1000`, etc. A dropped/renamed section or key made the lookup nil, and `nil /
--- 255` raises "attempt to perform arithmetic on a nil value" at MODULE LOAD. The
--- require-time pcall in menu_metrics then silently dropped the ENTIRE WPM widget.
--- Fix: scale through a guard that fails soft (nil + a logged ERROR) per field.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("wpm_widget._load_shared_const survives a missing/renamed TOML key", function()
	helpers.it("returns a table (no nil-arithmetic crash) when keys are absent", function()
		local wpm = helpers.load_with_stubs("ui.wpm.wpm_widget", {})
		helpers.assert_true(type(wpm._load_shared_const) == "function",
			"wpm_widget must expose _load_shared_const")

		-- Point the shared-constants resolver at a non-existent file so read_toml
		-- yields {} (every key missing) — the exact drift the loader must survive.
		-- Paths is captured by reference, so mutating the stub's shared() reaches it.
		package.loaded["infra.paths"].shared = function() return "/__ergopti_nonexistent__/constants.toml" end

		local ok, cfg = pcall(wpm._load_shared_const)
		helpers.assert_true(ok, "loader must NOT raise on a missing/renamed TOML key (nil arithmetic)")
		helpers.assert_true(type(cfg) == "table", "loader must still return a table")
		-- The previously-crashing conversions now yield nil instead of throwing.
		helpers.assert_nil(cfg.color_txt_active_alpha)
		helpers.assert_nil(cfg.idle_hide_s)
		helpers.assert_nil(cfg.source_color_duration)

		package.loaded["ui.wpm.wpm_widget"] = nil
		package.loaded["infra.paths"]         = nil
	end)
end)
