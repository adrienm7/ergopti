--- tests/unit/lib/test_locale_profile_labels.lua

--- ==============================================================================
--- MODULE: Locale Profile-Label Integrity Tests
--- DESCRIPTION:
--- Cross-language guard for the profile labels stored in _shared/data/locales/*.json.
---
--- THE CONTRACT (encodes the root cause of the "%d prédiction%s" bug):
--- Profile labels ("llm.profile.<id>.label") are rendered through a brace-style
--- formatter (ui/menu/menu_llm/profile_label.lua on macOS, LLM_Menu_GetProfileLabel
--- on Windows) that only understands "{n}"/"{s}". A printf "%d"/"%s" token therefore
--- can NEVER be substituted and leaks verbatim into the menu. This test fails the
--- instant any translator or edit reintroduces a printf token into a profile label,
--- in any of the 21 supported languages — and asserts the count placeholder "{n}"
--- (and its plural "{s}") survives translation in the one label that needs them.
--- Mirrored on the Windows side by windows/tests/test_llm_menu_regressions.ahk.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The 21 supported locale codes (must match lib/i18n.lua LOCALES). Hardcoded so
-- the test also fails loudly if a locale file goes missing.
local LOCALE_CODES = {
	"ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja",
	"ko", "nl", "no", "pl", "pt", "ru", "sv", "tr", "uk", "zh",
}

-- The profile label that carries the dynamic prediction-count placeholders.
local COUNT_LABEL_KEY = "llm.profile.batch_advanced.label"

--- Reads a shared locale file and extracts every "llm.profile.*.label" pair.
--- Pattern-based (no full JSON decode) so the test stays independent of the
--- decoder — exactly how lib/locale's own probe test reads raw locale text.
--- @param code string Locale code (e.g. "fr").
--- @return table|nil Map of key → value, or nil when the file is unreadable.
local function profile_labels(code)
	local path = helpers.shared("data/locales/" .. code .. ".json")
	local fh = io.open(path, "r")
	if not fh then return nil end
	local raw = fh:read("*a")
	fh:close()
	local labels = {}
	for key, val in raw:gmatch('"(llm%.profile%.[%w_]+%.label)"%s*:%s*"([^"]*)"') do
		labels[key] = val
	end
	return labels
end




-- =====================================
-- =====================================
-- ======= 1/ No printf tokens =========
-- =====================================
-- =====================================

helpers.describe("Locale profile labels — no printf placeholders", function()
	for _, code in ipairs(LOCALE_CODES) do
		helpers.it(code .. ".json: no '%d'/'%s' token in any profile label", function()
			local labels = profile_labels(code)
			helpers.assert_true(labels ~= nil, code .. ".json must be readable")
			-- Guards both the file and the extraction pattern: every locale ships
			-- the four built-in profile labels.
			local count = 0
			for _ in pairs(labels) do count = count + 1 end
			helpers.assert_true(count >= 4,
				code .. ".json must define at least 4 profile labels, found " .. count)

			for key, val in pairs(labels) do
				helpers.assert_true(val:find("%d", 1, true) == nil,
					"printf '%d' leaked into " .. key .. " (" .. code .. "): " .. val)
				helpers.assert_true(val:find("%s", 1, true) == nil,
					"printf '%s' leaked into " .. key .. " (" .. code .. "): " .. val)
				helpers.assert_true(val:find("%i", 1, true) == nil,
					"printf '%i' leaked into " .. key .. " (" .. code .. "): " .. val)
			end
		end)
	end
end)




-- =====================================
-- =====================================
-- ======= 2/ Count placeholder kept ===
-- =====================================
-- =====================================

helpers.describe("Locale profile labels — {n}/{s} survives translation", function()
	for _, code in ipairs(LOCALE_CODES) do
		helpers.it(code .. ".json: batch_advanced label keeps {n} and {s}", function()
			local labels = profile_labels(code)
			helpers.assert_true(labels ~= nil, code .. ".json must be readable")
			local label = labels[COUNT_LABEL_KEY]
			helpers.assert_true(type(label) == "string" and label ~= "",
				COUNT_LABEL_KEY .. " must exist in " .. code .. ".json")
			helpers.assert_true(label:find("{n}", 1, true) ~= nil,
				"batch_advanced label (" .. code .. ") must contain {n}: " .. label)
			helpers.assert_true(label:find("{s}", 1, true) ~= nil,
				"batch_advanced label (" .. code .. ") must contain {s}: " .. label)
		end)
	end
end)
