--- tests/unit/modules/shortcuts/test_wrap_symbols.lua

--- ==============================================================================
--- MODULE: shortcuts wrap-symbols Unit Tests
--- DESCRIPTION:
--- Guards the per-symbol enable/disable contract for the wrap-selection feature.
---
--- ROOT CAUSE ENCODED:
--- The wrap-selection eventtap (modules/shortcuts/actions/system.bind_wrap_text_if_selected)
--- decides whether to wrap a selection by looking the typed character up in the
--- table returned by build_active_wrap_pairs(symbol_states, custom_symbols). If a
--- symbol the user disabled from the menu still appears in that table, the eventtap
--- wraps it anyway — the exact bug seen on Windows where a disabled "@" kept
--- wrapping. These tests pin down build_active_wrap_pairs so a disabled symbol can
--- never leak back into the active table:
---   1. A disabled symbol is absent from the active table.
---   2. Disabling an asymmetric pair by its opening char removes BOTH its opening
---      and closing keys (e.g. disabling "<" also drops ">").
---   3. A symbol with no state entry defaults to enabled (opt-out, not opt-in).
---   4. Custom user pairs are registered under both their opening and closing keys.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Load text_acts under the standard stub environment. We deliberately do NOT
-- stub lib.logger: text.lua uses the real logger fine under the hs stub, and
-- leaving a partial logger stub in package.loaded would leak into later suites
-- (e.g. the log-level menu test that calls Logger.set_level).
local text_acts = helpers.load_with_stubs("modules.shortcuts.actions.text")




-- =====================================
-- =====================================
-- ======= 1/ Disabled symbols =========
-- =====================================
-- =====================================

helpers.describe("build_active_wrap_pairs: disabled symbols", function()
	helpers.it("excludes a symbol disabled by its opening char ('@')", function()
		local active = text_acts.build_active_wrap_pairs({ ["@"] = false }, {})
		helpers.assert_nil(active["@"], "disabled '@' must not appear in the active wrap table")
	end)

	helpers.it("keeps other symbols active when one is disabled", function()
		local active = text_acts.build_active_wrap_pairs({ ["@"] = false }, {})
		helpers.assert_true(active["#"] ~= nil, "'#' must stay active when only '@' is disabled")
		helpers.assert_eq(active["#"].left,  "#")
		helpers.assert_eq(active["#"].right, "#")
	end)

	helpers.it("removes BOTH keys of an asymmetric pair when its opener is disabled", function()
		-- The disabled set is keyed by the opening char, so disabling "<" must also
		-- silence ">" — otherwise typing ">" on a selection would still wrap.
		local active = text_acts.build_active_wrap_pairs({ ["<"] = false }, {})
		helpers.assert_nil(active["<"], "disabled opener '<' must be absent")
		helpers.assert_nil(active[">"], "closing '>' of a disabled pair must also be absent")
	end)
end)




-- =====================================
-- =====================================
-- ======= 2/ Default + custom =========
-- =====================================
-- =====================================

helpers.describe("build_active_wrap_pairs: defaults and custom pairs", function()
	helpers.it("treats a symbol with no state entry as enabled (opt-out semantics)", function()
		local active = text_acts.build_active_wrap_pairs({}, {})
		helpers.assert_true(active["@"] ~= nil, "'@' must be active by default when no state is stored")
	end)

	helpers.it("registers a symmetric custom pair under its single key", function()
		-- '^' is intentionally absent from the built-in catalogue, so it only
		-- appears when added as a custom pair.
		local active = text_acts.build_active_wrap_pairs({}, { { left = "^", right = "^" } })
		helpers.assert_true(active["^"] ~= nil, "custom symmetric symbol must be registered")
		helpers.assert_eq(active["^"].left,  "^")
		helpers.assert_eq(active["^"].right, "^")
	end)

	helpers.it("registers an asymmetric custom pair under both keys", function()
		local active = text_acts.build_active_wrap_pairs({}, { { left = "<<", right = ">>" } })
		helpers.assert_true(active["<<"] ~= nil, "custom opener must be registered")
		helpers.assert_true(active[">>"] ~= nil, "custom closer must be registered")
		helpers.assert_eq(active["<<"].left,  "<<")
		helpers.assert_eq(active[">>"].right, ">>")
	end)
end)




-- =====================================
-- =====================================
-- ======= 3/ Shared catalogue =========
-- =====================================
-- =====================================

-- These pin the shared single source of truth (_shared/wrap_symbols.json) so that
-- the catalogue is loaded from there (not hardcoded) and the newly-added Unicode
-- bracket families are present. Glyphs are built via utf8.char(codepoint) so this
-- source file stays ASCII-only and immune to encoding regressions.
helpers.describe("wrap-symbols shared catalogue", function()
	helpers.it("exposes ordered WRAP_GROUPS with labelled groups", function()
		helpers.assert_eq(type(text_acts.WRAP_GROUPS), "table", "WRAP_GROUPS must be exposed")
		helpers.assert_true(#text_acts.WRAP_GROUPS >= 5,
			"the shared catalogue must load several groups (got " .. tostring(#text_acts.WRAP_GROUPS) .. ")")
		-- Each group carries an i18n label key and a non-empty array of {left,right} pairs.
		for _, group in ipairs(text_acts.WRAP_GROUPS) do
			helpers.assert_eq(type(group.i18n), "string", "every group must carry an i18n label key")
			helpers.assert_true(group.i18n:find("^menu%.shortcuts%.wrap_group_") ~= nil,
				"group i18n key must be a wrap_group_* key, got " .. tostring(group.i18n))
			helpers.assert_eq(type(group.pairs), "table", "every group must carry a pairs array")
			helpers.assert_true(#group.pairs > 0, "every group must hold at least one pair")
			helpers.assert_eq(type(group.pairs[1].left),  "string")
			helpers.assert_eq(type(group.pairs[1].right), "string")
		end
	end)

	helpers.it("includes the newly-added Unicode bracket families", function()
		local active = text_acts.build_active_wrap_pairs({}, {})
		local angle_open   = utf8.char(0x3008)  -- 〈
		local angle_close  = utf8.char(0x3009)  -- 〉
		local corner_open  = utf8.char(0x300C)  -- 「
		local white_open   = utf8.char(0x27E6)  -- ⟦
		helpers.assert_true(active[angle_open] ~= nil, "U+3008 angle bracket must be active")
		helpers.assert_eq(active[angle_open].right, angle_close, "angle bracket must map to its closer")
		helpers.assert_true(active[corner_open] ~= nil, "U+300C CJK corner bracket must be active")
		helpers.assert_true(active[white_open] ~= nil, "U+27E6 white square bracket must be active")
	end)

	helpers.it("registers the asymmetric German low-high quotes from the catalogue", function()
		-- „ (U+201E) opens, “ (U+201C) closes — keyed by the opener.
		local active = text_acts.build_active_wrap_pairs({}, {})
		local low_quote  = utf8.char(0x201E)  -- „
		helpers.assert_true(active[low_quote] ~= nil, "U+201E German opening quote must be active")
		helpers.assert_eq(active[low_quote].left, low_quote)
	end)

	helpers.it("still honours a disabled Unicode bracket", function()
		local angle_open = utf8.char(0x3008)
		local active = text_acts.build_active_wrap_pairs({ [angle_open] = false }, {})
		helpers.assert_nil(active[angle_open], "a disabled Unicode opener must not appear in the active table")
		helpers.assert_nil(active[utf8.char(0x3009)], "its closer must also be absent")
	end)
end)
