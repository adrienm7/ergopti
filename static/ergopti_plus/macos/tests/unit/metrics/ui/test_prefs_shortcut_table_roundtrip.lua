--- tests/unit/metrics/ui/test_prefs_shortcut_table_roundtrip.lua

--- ==============================================================================
--- MODULE: Regression — preferences flatten_from_disk restores table-valued scalars
--- DESCRIPTION:
--- Guards against the bug where metrics_shortcut and apps_time_shortcut were
--- silently dropped on every reload. These flat keys map to top-level section
--- entries (KEY_MAP entry with sec+key, no path), but their on-disk TOML value
--- is a structured table {mods={...}, key="..."}. flatten_from_disk entered the
--- type(disk_val)=="table" branch and fell through to the sub-path handler which
--- iterated {mods, key} as inner keys and found nothing in _reverse_scalar.
---
--- Fix (2026-06-19): in the table branch, check _reverse_scalar[sec:disk_key]
--- first (top_scalar_fk). If found, store the whole table value and skip the
--- sub-path walk. Those two shortcuts are retired, so the case below drives the
--- public flatten_document with a table at another owned top-level scalar: the
--- owner must judge it, where the sub-path walk dropped it without a word.
--- ==============================================================================

local helpers = require("tests.helpers")
local MetricsState = require("metrics.engine.state_keys")




-- ==========================================================================
-- ==========================================================================
-- ======= 1/ flatten_from_disk hands table values to their scalar owner ===
-- ==========================================================================
-- ==========================================================================

helpers.describe("preferences flatten_from_disk: table-valued scalar keys", function()
	helpers.it("judges a table stored at an owned top-level scalar instead of dropping it", function()
		-- A {mods, key} table at an owned section:key must reach that scalar's
		-- owner. Without the early scalar lookup it falls into the sub-path walk,
		-- which finds no inner owner and drops it with no outdated report, so the
		-- setting silently reverts to its default at every boot.
		local prefs = helpers.load_with_stubs("settings.engine.preferences.preferences")
		local flat
		local reports = require("settings.engine.migration.outdated").collect_reports(function()
			flat = prefs.flatten_document({ hotstrings = { trigger_char = { mods = { "cmd" }, key = "x" } } })
		end)
		helpers.assert_eq(reports["hotstrings.trigger_char"], true,
			"the owner must judge the table and report it outdated")
		helpers.assert_nil(flat.trigger_char, "a table is not a trigger character")
	end)

	helpers.it("keeps retired dashboard paths out of the preference owner", function()
		local prefs = helpers.load_with_stubs("settings.engine.preferences.preferences")
		helpers.assert_nil(prefs.flat_key_for("metrics.shortcut"))
		helpers.assert_nil(prefs.flat_key_for("metrics.apps_shortcut"))
		helpers.assert_eq(prefs.flat_key_for("metrics.enabled"), MetricsState.ENABLED)
	end)
end)
