--- tests/unit/menu/test_profile_label.lua

--- ==============================================================================
--- MODULE: LLM Profile Label Formatter Unit Tests
--- DESCRIPTION:
--- Guards ui/menu/menu_llm/profile_label.lua — the single source of truth that
--- turns a raw locale profile label into the menu string by substituting the
--- "{n}" (prediction count) and "{s}" (plural marker) placeholders.
---
--- REGRESSION CONTEXT:
--- The "Batch Avancé" profile label used to leak a literal "%d prédiction%s" into
--- the menu: the locale string carried printf "%d"/"%s" tokens while the menu
--- formatter only ever substituted brace "{n}"/"{s}" placeholders. These tests pin
--- the brace convention and, end to end, assert the real locale label formats with
--- no leftover placeholder of EITHER style — so the bug can never silently return.
--- ==============================================================================

local helpers = require("tests.helpers")

-- profile_label requires modules.llm only for the canonical default prediction
-- count (DEFAULT_STATE). Inject a stub with a DISTINCTIVE default (3) so the
-- fallback path is unambiguous — a leftover hardcoded "1" would not match.
-- get_current_model is called unconditionally by prediction_engine.lua's
-- module-level code; without it, any later test whose require chain reaches
-- prediction_engine while this stub is still cached crashes with
-- "attempt to call a nil value (field 'get_current_model')".
package.loaded["modules.llm"] = {
	DEFAULT_STATE = { llm_num_predictions = 3 },
	get_current_model = function() return "stub-model" end,
}
package.loaded["ui.menu.menu_llm.profile_label"] = nil
local ProfileLabel = require("ui.menu.menu_llm.profile_label")

--- Reads the raw text of a shared locale file.
--- @param code string Locale code (e.g. "fr").
--- @return string|nil Raw file contents, or nil when unreadable.
local function read_locale(code)
	local path = helpers.shared("data/locales/" .. code .. ".json")
	local fh = io.open(path, "r")
	if not fh then return nil end
	local raw = fh:read("*a")
	fh:close()
	return raw
end

--- Extracts a single i18n value from raw locale JSON without a full decode.
--- @param raw string Raw locale JSON.
--- @param key string Dot-notation key.
--- @return string|nil The value, or nil when the key is absent.
local function locale_value(raw, key)
	if type(raw) ~= "string" then return nil end
	local pattern = '"' .. key:gsub("%.", "%%.") .. '"%s*:%s*"([^"]*)"'
	return raw:match(pattern)
end




-- =====================================
-- =====================================
-- ======= 1/ Placeholder substitution =
-- =====================================
-- =====================================

helpers.describe("ProfileLabel.format — placeholder substitution", function()
	helpers.it("substitutes {n} with the prediction count", function()
		helpers.assert_eq(ProfileLabel.format("avec {n} prédiction{s}", 5), "avec 5 prédictions")
	end)

	helpers.it("uses singular (empty {s}) when n == 1", function()
		helpers.assert_eq(ProfileLabel.format("avec {n} prédiction{s}", 1), "avec 1 prédiction")
	end)

	helpers.it("uses plural 's' for {s} when n > 1", function()
		helpers.assert_eq(ProfileLabel.format("{n} suggestion{s}", 2), "2 suggestions")
	end)

	helpers.it("accepts a numeric string for num_preds", function()
		helpers.assert_eq(ProfileLabel.format("{n}x", "4"), "4x")
	end)

	helpers.it("falls back to DEFAULT_STATE.llm_num_predictions when num_preds is nil", function()
		-- Stubbed default is 3 → plural, no hardcoded 1.
		helpers.assert_eq(ProfileLabel.format("{n} mot{s}", nil), "3 mots")
	end)

	helpers.it("falls back to the configured default for a non-numeric num_preds", function()
		helpers.assert_eq(ProfileLabel.format("{n} mot{s}", "abc"), "3 mots")
	end)

	helpers.it("returns empty string for a non-string label", function()
		helpers.assert_eq(ProfileLabel.format(nil, 2), "")
		helpers.assert_eq(ProfileLabel.format(123, 2), "")
	end)

	helpers.it("leaves a label without placeholders untouched", function()
		helpers.assert_eq(ProfileLabel.format("●○○ Basique", 4), "●○○ Basique")
	end)
end)




-- =====================================
-- =====================================
-- ======= 2/ Root-cause regression ====
-- =====================================
-- =====================================

helpers.describe("ProfileLabel.format — no leftover placeholder (regression)", function()
	helpers.it("never leaves a {n}/{s} brace placeholder behind", function()
		for _, n in ipairs({ 1, 2, 7 }) do
			local out = ProfileLabel.format("x {n} y {s} z", n)
			helpers.assert_true(out:find("{n}", 1, true) == nil, "{n} must be substituted (n=" .. n .. ")")
			helpers.assert_true(out:find("{s}", 1, true) == nil, "{s} must be substituted (n=" .. n .. ")")
		end
	end)

	helpers.it("formats the REAL fr batch_advanced label with no leftover placeholder", function()
		-- End-to-end reproduction of the reported bug: load the actual French
		-- locale string and run it through the exact formatter the menu uses.
		local raw = read_locale("fr")
		helpers.assert_true(raw ~= nil, "fr.json must be readable")
		local label = locale_value(raw, "llm.profile.batch_advanced.label")
		helpers.assert_true(type(label) == "string" and label ~= "", "batch_advanced label must exist in fr.json")

		local out = ProfileLabel.format(label, 5)
		-- The configured count must appear…
		helpers.assert_true(out:find("5 prédictions", 1, true) ~= nil,
			"expected '5 prédictions' in formatted label, got: " .. out)
		-- …and NO placeholder of either convention may remain.
		helpers.assert_true(out:find("{n}", 1, true) == nil, "leftover {n} in: " .. out)
		helpers.assert_true(out:find("{s}", 1, true) == nil, "leftover {s} in: " .. out)
		helpers.assert_true(out:find("%d", 1, true) == nil, "leftover %d in: " .. out)
		helpers.assert_true(out:find("%s", 1, true) == nil, "leftover %s in: " .. out)
	end)

	helpers.it("singular form of the real fr batch_advanced label drops the plural mark", function()
		local raw = read_locale("fr")
		local label = locale_value(raw, "llm.profile.batch_advanced.label")
		local out = ProfileLabel.format(label, 1)
		helpers.assert_true(out:find("1 prédiction", 1, true) ~= nil,
			"expected '1 prédiction' (singular) in: " .. out)
		helpers.assert_true(out:find("prédictions", 1, true) == nil,
			"singular form must not pluralise: " .. out)
	end)
end)
