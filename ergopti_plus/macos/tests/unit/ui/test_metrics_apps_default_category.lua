--- tests/unit/ui/test_metrics_apps_default_category.lua

--- ==============================================================================
--- MODULE: Regression — the default app category has ONE source, and it is i18n
--- DESCRIPTION:
--- The original bug (ui-windows-b-1) was two hardcoded "Général" literals, one in
--- the chooser callback and one in the bridge message handler. The fix introduced
--- a named constant — and stopped there, keeping the constant itself a French
--- literal while a sibling function three lines away already read
--- `i18n.get("metrics_apps.general_category")`. So de-duplicating two literals
--- created two SOURCES: the constant and the key. On any non-French locale the
--- key returns "General"/"Allgemein"/… while the constant still returns
--- "Général", so the category picker's "current" tick matches nothing and every
--- unclassified app is written under a category name no locale displays.
---
--- ROOT CAUSE ENCODED:
--- A single-source fix that consolidated the DUPLICATES without pointing the
--- result at the source that already existed. The assertions below are on the
--- invariant — no bare French literal, and the default derived from i18n — not on
--- the name of whatever holds it. The previous version of this test pinned
--- `DEFAULT_APP_CATEGORY` and the exact spelling of both call sites, which is why
--- it stayed green over the second half of the bug: a constant satisfying it was
--- the very thing that was wrong.
---
--- The same file also passed a hardcoded French chooser placeholder while its two
--- sibling placeholders went through i18n, so that is pinned here too.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Anchored on an i18n key rather than on a file path: the shared reader locates
-- whichever file carries it, so moving the window does not silently empty the
-- corpus (a pinned path is also rejected by the pre-commit ratchet).
--
-- Deliberately NOT metrics_apps.general_category: modules/keylogger/export.lua
-- reads that one twice, so it would pull three files into the corpus and the
-- "is the default read from the key" count below would already be satisfied by
-- the exporter alone. This key belongs to this window only.
local ANCHOR = "metrics_apps.chooser_placeholder"

-- The shared key the default category must come from.
local DEFAULT_KEY = "metrics_apps.general_category"

-- The French default, assembled byte by byte so this test file does not itself
-- contain the literal it forbids. The accented character is UTF-8 (two bytes,
-- 0xC3 0xA9) and NOT Latin-1 char(233): the sources are UTF-8, so a single-byte
-- spelling matches nothing and the absence assertion below passes vacuously.
-- That is exactly what the first version of this test did.
local E_ACUTE = string.char(0xC3, 0xA9)
local FRENCH_DEFAULT = "G" .. E_ACUTE .. "n" .. E_ACUTE .. "ral"




-- ==================================================================
-- ==================================================================
-- ======= 1/ One source, and it comes from i18n ====================
-- ==================================================================
-- ==================================================================

helpers.describe("metrics_apps: the default app category is i18n-derived", function()

	helpers.it("carries no bare French default anywhere", function()
		local src = helpers.read_driver_source(ANCHOR)
		helpers.assert_true(src ~= nil and src ~= "",
			"metrics_apps must be locatable by '" .. ANCHOR .. "'; an empty corpus would make "
			.. "every assertion below vacuous")

		-- Comments stripped: prose explaining the old literal is not the literal.
		local code = src:gsub("%-%-[^\n]*", "")

		helpers.assert_true(code:find('"' .. FRENCH_DEFAULT .. '"', 1, true) == nil,
			"a hardcoded French default is a SECOND source for a value the file already reads "
			.. "from i18n.get('" .. ANCHOR .. "'). On any non-French locale the two disagree, so "
			.. "the category picker's current-selection tick matches nothing and unclassified "
			.. "apps are stored under a name no locale ever displays")
	end)

	helpers.it("still resolves a default, from the shared key", function()
		local src  = helpers.read_driver_source(ANCHOR)
		local code = src:gsub("%-%-[^\n]*", "")

		-- Without this case the assertion above would pass against a file that
		-- simply deleted the default and now writes nil as the category.
		local _, uses = code:gsub(DEFAULT_KEY, "")
		helpers.assert_true(uses >= 1,
			"the file must read the shared key at all; zero reads means the default was deleted "
			.. "rather than localised, and unclassified apps get stored with no category")

		-- And the two fallback sites must go through a CALL, not a constant. This is
		-- the part that cannot be expressed by counting key reads: repeating the key
		-- at each site would satisfy a naive count while being the opposite of single
		-- source, and a module-level constant cannot work here at all because this
		-- file is required before the locale is settled — the value has to resolve at
		-- call time or it freezes whatever locale happened to be active at boot.
		local fallbacks = 0
		for expr in code:gmatch("or%s+([%w_]+%(%))") do
			if expr:find("categor", 1, true) or expr:find("default", 1, true) then
				fallbacks = fallbacks + 1
			end
		end
		for expr in code:gmatch("type%s*=%s*([%w_]+%(%))") do
			if expr:find("categor", 1, true) or expr:find("default", 1, true) then
				fallbacks = fallbacks + 1
			end
		end
		helpers.assert_true(fallbacks >= 2,
			"both the chooser fallback and the bridge handler must resolve the default through "
			.. "a call; found " .. fallbacks .. ". A constant assigned once at load time is what "
			.. "froze the French spelling in place")
	end)

end)




-- ==================================================================
-- ==================================================================
-- ======= 2/ Every chooser placeholder goes through i18n ===========
-- ==================================================================
-- ==================================================================

helpers.describe("metrics_apps: no user-facing string is hardcoded", function()

	helpers.it("every placeholderText argument is an i18n lookup", function()
		local src  = helpers.read_driver_source(ANCHOR)
		local code = src:gsub("%-%-[^\n]*", "")

		local offenders = {}
		for call in code:gmatch("placeholderText%(([^\n]*)") do
			-- A literal opening quote immediately after the paren is a hardcoded
			-- string; an i18n lookup or a string.format over one is not.
			if call:sub(1, 1) == '"' or call:sub(1, 1) == "'" then
				table.insert(offenders, call:sub(1, 46))
			end
		end

		helpers.assert_eq(#offenders, 0,
			"two of the three placeholders in this file already go through i18n; the third "
			.. "predates i18n adoption here and was never migrated, so it shows French to every "
			.. "user of the other twenty locales: " .. table.concat(offenders, " | "))
	end)

	helpers.it("the scan sees the placeholder calls at all", function()
		local src  = helpers.read_driver_source(ANCHOR)
		local code = src:gsub("%-%-[^\n]*", "")
		local _, n = code:gsub("placeholderText%(", "")
		helpers.assert_true(n >= 3,
			"the file must still set the placeholders this test claims to check; a rename would "
			.. "otherwise make the absence assertion above vacuous, found " .. n)
	end)

end)
