--- tests/unit/modules/keymap/expansion/test_case_conform.lua

--- ==============================================================================
--- MODULE: Case-conform optimisation regression tests
--- DESCRIPTION:
--- Locks in the case-conform fast path ported from the AHK driver: an auto,
--- case-insensitive, plain-text trigger WITHOUT a shift-symbol char is registered
--- as ONE lowercase entry (match_mode = "conform") instead of the lower/Title/UPPER
--- trio, and the expander conforms the replacement's case to the typed trigger at
--- fire time. Triggers that must keep the explicit-variant path (comma/shift-symbol,
--- non-auto, case-sensitive, token replacements) are guarded too.
---
--- ROOT CAUSE ENCODED: the old registry exploded ~3.3k TOML rows into ~10-30k
--- mappings (lower×Title×UPPER × space variants). A regression that drops the
--- conform flag, mis-buckets an accented uppercase tail, or fires on mixed case
--- would silently bloat startup or break casing — these tests fail fast on each.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["core.logger.engine.logger"] = nil
local _      = helpers.load_with_stubs("core.logger.engine.logger")
local State  = helpers.load_with_stubs("modules.keymap.state")
local txt    = helpers.load_with_stubs("infra.text_utils")

local REGISTRY_OWNERSHIP = {
	"modules.keymap.registry",
	"modules.keymap.registry_groups",
	"modules.keymap.registry_index",
	"modules.keymap.terminators",
	"modules.keymap.utils",
	"infra.text_utils",
	"core.text.engine.utils_core",
}

local ENGINE_OWNERSHIP = {
	"modules.keymap.registry",
	"modules.keymap.registry_groups",
	"modules.keymap.registry_index",
	"modules.keymap.terminators",
	"modules.keymap.expander",
	"modules.keymap.terminator_replay",
	"modules.keymap.utils",
	"infra.text_utils",
	"core.text.engine.utils_core",
	"ui.tooltip",
	"modules.keystats",
}




-- =========================================
-- =========================================
-- ======= 1/ conform_replacement ==========
-- =========================================
-- =========================================

helpers.describe("text_utils.conform_replacement", function()
	helpers.it("returns the lowercase replacement for a lowercase trigger", function()
		helpers.assert_eq(txt.conform_replacement("austria", "at", "at"), "austria")
	end)

	helpers.it("Title-cases the replacement for a Title-cased trigger", function()
		helpers.assert_eq(txt.conform_replacement("austria", "At", "at"), "Austria")
	end)

	helpers.it("UPPER-cases the replacement for an UPPER-cased trigger", function()
		helpers.assert_eq(txt.conform_replacement("austria", "AT", "at"), "AUSTRIA")
	end)

	helpers.it("handles accented triggers (Unicode case maps)", function()
		helpers.assert_eq(txt.conform_replacement("ccu", "ccê", "ccê"), "ccu")
		helpers.assert_eq(txt.conform_replacement("ccu", "Ccê", "ccê"), "Ccu")
		helpers.assert_eq(txt.conform_replacement("ccu", "CCÊ", "ccê"), "CCU")
	end)

	helpers.it("maps a one-character body's capital to Title (Title == UPPER)", function()
		-- For a single-char body Title and UPPER are identical; a typed capital must
		-- resolve to the Title replacement (matches the old lower+Title registration).
		helpers.assert_eq(txt.conform_replacement("été", "E", "e"), "Été")
	end)

	helpers.it("returns nil for a mixed-case trigger (must NOT fire)", function()
		helpers.assert_nil(txt.conform_replacement("austria", "aT", "at"))
		helpers.assert_nil(txt.conform_replacement("ccu", "cCê", "ccê"))
	end)
end)




-- =========================================
-- =========================================
-- ======= 2/ Registration shape ===========
-- =========================================
-- =========================================

local function fresh_registry()
	return helpers.with_fresh_modules(REGISTRY_OWNERSHIP, function()
		local R = require("modules.keymap.registry")
		local state = State.new({ trigger_char = "★", expansion_delay = 0.4 }, {})
		helpers.assert_eq(R.init(state), true)
		return state, R
	end)
end

helpers.describe("Registry — case-conform registration shape", function()
	helpers.it("preserves leading-space guards without creating space variants (unicode-space-prefix)", function()
		for _, space in ipairs({ " ", " ", " " }) do
			local state, R = fresh_registry()
			R.add(space .. "x y", "output", { auto_expand = true, is_case_sensitive = true })
			helpers.assert_eq(#state.mappings, 1, "leading space must keep the guarded trigger literal")
		end
	end)
	helpers.it("registers ONE lowercase entry for an auto/insensitive/plain/no-symbol trigger", function()
		local state, R = fresh_registry()
		R.add("ccê", "ccu", { auto_expand = true, is_case_sensitive = false })
		helpers.assert_eq(#state.mappings, 1, "one conform entry, not lower+Title+UPPER")
		helpers.assert_eq(state.mappings[1].trigger, "ccê")
		helpers.assert_eq(state.mappings[1].match_mode, "conform")
	end)

	helpers.it("buckets the entry under the Unicode-lowered tail (accented capital matches)", function()
		local state, R = fresh_registry()
		R.add("ccê", "ccu", { auto_expand = true, is_case_sensitive = false })
		R.sort_mappings()
		-- An UPPERCASE accented tail "Ê" must resolve to the lowercase "ê" bucket.
		local bucket = R.mappings_for_tail("Ê")
		helpers.assert_true(bucket ~= nil and #bucket == 1, "Ê resolves to the ê bucket")
		helpers.assert_eq(bucket[1].trigger, "ccê")
	end)

	helpers.it("finds uppercase non-French accented triggers in the folded tail index (hotstring-unicode-fold)", function()
		local state, R = fresh_registry()
		R.add("á", "output", { auto_expand = true, is_case_sensitive = true })
		R.sort_mappings()
		local bucket = R.mappings_for_tail("Á")
		helpers.assert_true(bucket ~= nil and #bucket == 1, "Spanish uppercase Á must use the á bucket")
		helpers.assert_eq(bucket[1].trigger, "á")
	end)

	helpers.it("keeps the explicit-variant path for a comma (shift-symbol) trigger", function()
		local state, R = fresh_registry()
		R.add(",e", "je", { auto_expand = true, is_case_sensitive = false })
		helpers.assert_true(#state.mappings > 1, "comma trigger keeps explicit variants + aliases")
		for _, m in ipairs(state.mappings) do
			helpers.assert_true(m.match_mode ~= "conform", "no comma entry may be in conform mode")
		end
	end)

	helpers.it("keeps the explicit-variant path for a non-auto trigger", function()
		local state, R = fresh_registry()
		R.add("teh", "the", { auto_expand = false, is_case_sensitive = false })
		helpers.assert_true(#state.mappings > 1, "non-auto trigger keeps lower/Title/UPPER")
		for _, m in ipairs(state.mappings) do
			helpers.assert_true(m.match_mode ~= "conform", "non-auto entries are never in conform mode")
		end
	end)

	helpers.it("does not conform a case-sensitive trigger", function()
		local state, R = fresh_registry()
		R.add("API", "api", { auto_expand = true, is_case_sensitive = true })
		helpers.assert_eq(#state.mappings, 1)
		helpers.assert_true(state.mappings[1].match_mode ~= "conform")
	end)

	helpers.it("does not conform a token (non-plain) replacement", function()
		local state, R = fresh_registry()
		R.add("sig", "Hi{Enter}Me", { auto_expand = true, is_case_sensitive = false })
		for _, m in ipairs(state.mappings) do
			helpers.assert_true(m.match_mode ~= "conform", "token replacements keep the explicit path")
		end
	end)
end)




-- =========================================
-- =========================================
-- ======= 3/ Fire-time conform ============
-- =========================================
-- =========================================

-- Build a registry + expander sharing ONE CoreState so a registered conform entry
-- can be driven through the real auto-expansion path. tooltip/keystats are stubbed
-- so perform_text_replacement's side-effects never touch real UI/OS code.
local function fresh_engine()
	return helpers.with_fresh_modules(ENGINE_OWNERSHIP, function()
		package.loaded["ui.tooltip"] = { hide = function() end, hide_forced = function() end }
		package.loaded["modules.keystats"] = {
			notify_synthetic = function() end,
			set_buffer       = function() end,
			log_hotstring    = function() end,
		}
		local R = require("modules.keymap.registry")
		local E = require("modules.keymap.expander")
		local state = State.new({ trigger_char = "★", expansion_delay = 0.4 }, {})
		helpers.assert_eq(R.init(state), true)
		local llm = {
			update_preview  = function() end,
			get_llm_enabled = function() return false end,
			start_timer     = function() end,
		}
		helpers.assert_eq(E.init(state, R, llm), true)
		return state, R, E
	end)
end

--- Registers one conform entry, sets the buffer to `typed`, and fires the
--- auto-expansion. Returns (fired, resulting_buffer).
local function fire(R, E, state, trigger, repl, typed, opts)
	state.mappings = {}
	state.mappings_lookup = {}
	R.add(trigger, repl, opts or { auto_expand = true, is_case_sensitive = false })
	R.sort_mappings()
	state.buffer = typed
	state.start_is_word_boundary = true
	local fired = E.try_auto_expand(state.mappings[1], 1, false)
	return fired, state.buffer
end

helpers.describe("Expander — fire-time case conform", function()
	helpers.it("expands space variants after non-space Unicode leading characters (unicode-space-prefix)", function()
		for _, first in ipairs({ "©", "€" }) do
			for _, space in ipairs({ " ", " " }) do
				local state, R, E = fresh_engine()
				R.add(first .. " x", "output", { auto_expand = true, is_case_sensitive = true })
				R.sort_mappings()
				state.buffer = first .. space .. "x"
				state.start_is_word_boundary = true
				local fired = false
				for _, mapping in ipairs(state.mappings) do
					if E.try_auto_expand(mapping, 1, false) then fired = true; break end
				end
				helpers.assert_true(fired, "non-space Unicode prefix must preserve space variants")
				helpers.assert_eq(state.buffer, "output")
			end
		end
	end)
	helpers.it("matches a folded trigger whose typed character has a different UTF-8 width (hotstring-width-fold)", function()
		local state, R, E = fresh_engine()
		local fired, buffer = fire(R, E, state, "k", "output", "xK",
			{ auto_expand = true, is_case_sensitive = true })
		helpers.assert_true(fired, "Kelvin sign must fold to k")
		helpers.assert_eq(buffer, "xoutput")
	end)

	helpers.it("retains the prefix on a width-changing folded terminator (hotstring-width-fold)", function()
		local state, R, E = fresh_engine()
		R.add("k", "output", { auto_expand = false, is_case_sensitive = true })
		R.sort_mappings()
		state.buffer = "xK "
		state.start_is_word_boundary = true
		helpers.assert_true(E.try_terminator_expand(state.mappings[1], " ", 1, false))
		helpers.assert_eq(state.buffer, "xoutput ")
	end)

	helpers.it("expands a folded non-French accented trigger (hotstring-unicode-fold)", function()
		local state, R, E = fresh_engine()
		local fired, buffer = fire(R, E, state, "á", "output", "Á",
			{ auto_expand = true, is_case_sensitive = true })
		helpers.assert_true(fired, "a folded trigger must match Unicode case pairs")
		helpers.assert_eq(buffer, "output")
	end)

	helpers.it("expands a folded magic trigger after the magic key changes", function()
		local state, R, E = fresh_engine()
		R.add("abc★", "output", { auto_expand = true, is_case_sensitive = true })
		R.sort_mappings()
		helpers.assert_true(R.update_trigger_char("!"))
		state.buffer = "ABC!"
		state.start_is_word_boundary = true
		local fired = E.try_auto_expand(state.mappings[1], 1, false)
		helpers.assert_true(fired, "the renamed trigger must still match")
		helpers.assert_eq(state.buffer, "output")
	end)

	helpers.it("matches every simple-folded Greek sigma and sharp S without changing case conformance", function()
		for _, pair in ipairs({ { "σ", "ς" }, { "ς", "Σ" }, { "ß", "ẞ" }, { "s", "ſ" } }) do
			local state, R, E = fresh_engine()
			local fired, buffer = fire(R, E, state, pair[1], "output", pair[2],
				{ auto_expand = true, is_case_sensitive = true })
			helpers.assert_true(fired, "simple-fold equivalence must reach the matching bucket")
			helpers.assert_eq(buffer, "output")
		end
	end)


	helpers.it("keeps strict matching and case conformance distinct from simple folding", function()
		for _, item in ipairs({
			{ "σ", "ς", { auto_expand = true, is_case_sensitive = true, is_case_sensitive_strict = true } },
			{ "σ", "ς", { auto_expand = true } },
			{ "ß", "ss", { auto_expand = true, is_case_sensitive = true } },
		}) do
			local state, R, E = fresh_engine()
			local fired = fire(R, E, state, item[1], "output", item[2], item[3])
			helpers.assert_true(not fired)
		end
	end)

	helpers.it("conforms default non-French accented and Greek triggers (hotstring-unicode-fold)", function()
		for _, pair in ipairs({ { "á", "Á" }, { "σ", "Σ" } }) do
			local state, R, E = fresh_engine()
			local fired, buffer = fire(R, E, state, pair[1], "resultado", pair[2])
			helpers.assert_true(fired, "default conform matching must recognize the Unicode uppercase")
			helpers.assert_eq(buffer, "Resultado")
		end
	end)

	helpers.it("expands a lowercase trigger to the lowercase replacement", function()
		local state, R, E = fresh_engine()
		local fired, buf = fire(R, E, state, "ccê", "ccu", "ccê")
		helpers.assert_true(fired)
		helpers.assert_eq(buf, "ccu")
	end)

	helpers.it("conforms a Title-cased trigger to a Title-cased replacement", function()
		local state, R, E = fresh_engine()
		local fired, buf = fire(R, E, state, "ccê", "ccu", "Ccê")
		helpers.assert_true(fired)
		helpers.assert_eq(buf, "Ccu")
	end)

	helpers.it("conforms an UPPER-cased (accented) trigger to an UPPER replacement", function()
		local state, R, E = fresh_engine()
		local fired, buf = fire(R, E, state, "ccê", "ccu", "CCÊ")
		helpers.assert_true(fired)
		helpers.assert_eq(buf, "CCU")
	end)

	helpers.it("does NOT fire on a mixed-case trigger (parity with no-variant-registered)", function()
		local state, R, E = fresh_engine()
		local fired, buf = fire(R, E, state, "ccê", "ccu", "cCê")
		helpers.assert_true(not fired)
		helpers.assert_eq(buf, "cCê", "buffer untouched when the case is mixed")
	end)

	helpers.it("respects the word boundary for an is_word conform entry", function()
		local state, R, E = fresh_engine()
		-- Letter immediately before the trigger → blocked.
		local blocked = fire(R, E, state, "abim", "abîm", "xabim",
			{ auto_expand = true, is_case_sensitive = false, is_word = true })
		helpers.assert_true(not blocked, "is_word match blocked when preceded by a letter")

		-- At a word boundary (buffer starts with the trigger) → fires + conforms.
		local fired, buf = fire(R, E, state, "abim", "abîm", "ABIM",
			{ auto_expand = true, is_case_sensitive = false, is_word = true })
		helpers.assert_true(fired)
		helpers.assert_eq(buf, "ABÎM")
	end)
end)
