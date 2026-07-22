--- tests/unit/ui/test_wpm_shared_constants.lua

--- Regression test: wpm_widget._load_shared_const must source every visual
--- constant from the shared TOML (_shared/modules/wpm_widget/constants.toml and
--- _shared/modules/timings/constants.toml), with NO re-typed literal default in
--- the loader (rules 5.2 / 5.4). The AHK twin (WPMWidgetConst) already uses
--- sentinel-zero + fail-fast; this pins the HS side to the same single source.
---
--- It asserts the EXACT TOML values flow through, so a reintroduced `or <lit>`
--- fallback that masks a missing/renamed key would be caught here (the value
--- would come from the literal, not the TOML, and drift would go unnoticed).

local helpers = require("tests.helpers")

local wpm = helpers.load_with_stubs("ui.wpm.wpm_widget", {})
helpers.assert_true(type(wpm._load_shared_const) == "function",
	"wpm_widget must expose _load_shared_const for this regression test")

local c = wpm._load_shared_const()

-- Compact layout — _shared/modules/wpm_widget/constants.toml [compact]
helpers.assert_eq(80, c.compact_width, "compact_width must be sourced from the shared TOML")
helpers.assert_eq(44, c.compact_height_number, "compact_height_number must be sourced from the shared TOML")
helpers.assert_eq(20, c.compact_height_unit, "compact_height_unit must be sourced from the shared TOML")
helpers.assert_eq(0.40, c.compact_unit_darken, "compact_unit_darken must be sourced from the shared TOML")

-- Colors — _shared/modules/wpm_widget/constants.toml [colors]
helpers.assert_eq("#0055cc", c.color_bg_manual, "color_bg_manual must be sourced from the shared TOML")
helpers.assert_eq("#1a1a2e", c.color_bg_idle, "color_bg_idle must be sourced from the shared TOML")
helpers.assert_eq(0.40, c.widget_hsl_l, "widget_hsl_l must be sourced from the shared TOML")
helpers.assert_eq(1.00, c.widget_hsl_s, "widget_hsl_s must be sourced from the shared TOML")

-- Timings — _shared/modules/timings/constants.toml [ui] (ms -> s)
helpers.assert_eq(3.0, c.idle_hide_s, "idle_hide_s must be sourced from the timings TOML (3000 ms)")
helpers.assert_eq(1.0, c.source_color_duration, "source_color_duration must be sourced from the timings TOML (1000 ms)")

print("[PASS] test_wpm_shared_constants")
