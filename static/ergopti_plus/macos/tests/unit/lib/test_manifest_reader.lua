--- tests/unit/lib/test_manifest_reader.lua

--- ==============================================================================
--- MODULE: Features Manifest Reader Tests (Hammerspoon)
--- DESCRIPTION:
--- A2 — macOS now reads feature defaults from the shared codegen'd manifest
--- (`_generated/features_manifest.lua`, single source `_shared/modules/features/manifest.toml`)
--- via `lib.manifest_reader`, the counterpart of the AHK `manifest_reader.ahk`
--- that the Windows driver already builds its whole `Features` map from.
---
--- These tests pin:
---   1. The reader loads the generated manifest (cwd-independent loadfile) and
---      exposes version / features / path lookup.
---   2. `default_for` is the single-source accessor and fails fast on a bad path.
---   3. A parity tripwire on the exact paths that `modules/keymap/init.lua`
---      `DEFAULT_STATE` is now wired to — so a drift in `manifest.toml` (which
---      would silently change keymap's runtime defaults) turns this red.
--- ==============================================================================

local helpers = require("tests.helpers")

-- manifest_reader logs through lib.logger; load the stub first.
package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

local Manifest = require("infra.manifest_reader")

-- The canonical values that modules/keymap/init.lua DEFAULT_STATE is wired to.
-- Mirror these in the AHK manifest too — they are the cross-driver canon.
local STAR = "★" -- magic key trigger (UTF-8 literal, as used across the .lua sources)
local KEYMAP_WIRED = {
	["hotstrings.expansion_delay"]             = 0.75,
	["hotstrings.trigger_char"]                   = STAR,
	["hotstrings.preview_star_enabled"]        = true,
	["hotstrings.preview_autocorrect_enabled"] = true,
	["hotstrings.preview_ai_enabled"]          = true,
	["hotstrings.preview_colored_tooltips"]    = true,
}




-- ============================================
-- ======= 1/ Reader load + accessors =========
-- ============================================

helpers.describe("manifest_reader: load + accessors", function()
	helpers.it("loads the generated manifest and reports the version", function()
		helpers.assert_eq(Manifest.version(), "2.0.0", "manifest version")
		helpers.assert_true(type(Manifest.features()) == "table" and #Manifest.features() > 0,
			"features() returns a non-empty array")
	end)

	helpers.it("find_entry_by_path resolves a known path and returns nil for unknown", function()
		local e = Manifest.find_entry_by_path("hotstrings.expansion_delay")
		helpers.assert_true(e ~= nil and e.default == 0.75, "known path resolves to its entry")
		helpers.assert_nil(Manifest.find_entry_by_path("does.not.exist"), "unknown path -> nil")
	end)
end)






--- ==============================================
--- ==============================================
--- ======= 2/ default_for (single source) =======
--- ==============================================
--- ==============================================

helpers.describe("manifest_reader: default_for", function()
	helpers.it("returns the declared default for a known path", function()
		helpers.assert_eq(Manifest.default_for("hotstrings.trigger_char"), STAR, "trigger_char default")
		helpers.assert_eq(Manifest.default_for("hotstrings.expansion_delay"), 0.75, "expansion_delay default")
		helpers.assert_eq(Manifest.default_for("hotstrings.preview_star_enabled"), true, "preview default")
	end)

	helpers.it("fails fast on an unknown path", function()
		local ok = pcall(function() return Manifest.default_for("nope.not.here") end)
		helpers.assert_eq(ok, false, "default_for raises on an unknown path")
	end)
end)






--- ==============================================
--- ==============================================
--- ======= 3/ keymap DEFAULT_STATE parity =======
--- ==============================================
--- ==============================================

helpers.describe("manifest_reader: keymap DEFAULT_STATE wiring parity", function()
	-- modules/keymap/init.lua DEFAULT_STATE is now `Manifest.default_for(<path>)`
	-- for each of these. Asserting the manifest still yields the canonical value
	-- pins the wired runtime defaults: if manifest.toml drifts, keymap's defaults
	-- would change silently — this turns red first.
	for path, expected in pairs(KEYMAP_WIRED) do
		helpers.it("default_for('" .. path .. "') == canonical keymap default", function()
			helpers.assert_eq(Manifest.default_for(path), expected,
				"manifest default for " .. path)
		end)
	end
end)






--- =======================================================
--- =======================================================
--- ======= 4/ Extended module DEFAULT_STATE parity =======
--- =======================================================
--- =======================================================

-- The A2 follow-up wired more macOS modules to the manifest: keylogger (the
-- cross-driver metrics filter/encrypt flags), dynamic_hotstrings (per-category
-- toggles, read via the feature toggle's `.enabled`), and gestures (space_wrap).
-- A drift in manifest.toml would silently change those runtime defaults — these
-- pin the wired source values so it turns red first.
helpers.describe("manifest_reader: extended module wiring parity", function()
	helpers.it("keylogger metrics filter / encrypt defaults", function()
		helpers.assert_eq(Manifest.default_for("metrics.private_filter_enabled"), true, "private filter")
		helpers.assert_eq(Manifest.default_for("metrics.secure_filter_enabled"), true, "secure filter")
		helpers.assert_eq(Manifest.default_for("metrics.system_auth_filter_enabled"), true, "system-auth filter")
		helpers.assert_eq(Manifest.default_for("metrics.encrypt"), false, "encrypt default")
	end)

	helpers.it("dynamic-hotstring category toggles default to enabled", function()
		local paths = {
			"hotstrings.dynamic.date", "hotstrings.dynamic.date_fr", "hotstrings.dynamic.date_long_fr",
			"hotstrings.dynamic.phone_prefixes", "hotstrings.dynamic.ssn_prefixes",
			"hotstrings.dynamic.iban_prefixes", "hotstrings.dynamic.text_expansion_personal_information",
		}
		for _, path in ipairs(paths) do
			helpers.assert_eq(Manifest.default_for(path).enabled, true, path .. ".enabled")
		end
	end)

	helpers.it("gestures space_wrap default", function()
		helpers.assert_eq(Manifest.default_for("gestures.space_wrap"), true, "space_wrap default")
	end)
end)
