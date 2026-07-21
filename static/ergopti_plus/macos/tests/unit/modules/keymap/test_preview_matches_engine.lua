--- tests/unit/modules/keymap/test_preview_matches_engine.lua

--- ==============================================================================
--- MODULE: Regression — the tooltip must show exactly what the engine will emit
--- DESCRIPTION:
--- The tooltip previewed a hotstring expansion and the engine produced something
--- else. The two sides answered "will this mapping fire, and with what?" through
--- two independent implementations, and those implementations disagreed.
---
--- ROOT CAUSE ENCODED:
--- llm_bridge had a local ends_with_trigger(); the expander had
--- word_boundary_blocks(). They diverged in four ways:
---   1. At the buffer start, ends_with_trigger returned "allowed" whenever nothing
---      preceded the trigger. word_boundary_blocks returns `not
---      start_is_word_boundary` — so with the buffer starting mid-word the engine
---      REFUSED a match the tooltip had already promised.
---   2. Triggers starting with a separator (" ", NBSP, NNBSP, ";") are exempt from
---      the boundary rule in the engine; the preview applied it anyway, hiding
---      rows for expansions that do fire (the comma-layer ";e" -> "Je").
---   3. case_conform resolution existed in the preview's autocorrect bucket but
---      not in its star bucket, so a cased ★ trigger previewed wrong or not at all.
---   4. The no-op guards were written against different operands: the preview
---      compared plain_repl to the trigger, the engine compared the effective
---      replacement to what was actually typed.
---
--- THE FIX:
--- expander.would_fire(m, buffer) is now the single source of truth. try_auto_expand
--- calls it to decide and to obtain the effective replacement; update_preview calls
--- the SAME function — for a ★ trigger, against `buf .. magic_key`, which is the
--- buffer the engine will actually see once ★ is pressed. Agreement is structural
--- rather than maintained by hand.
---
--- These tests drive would_fire directly across the cases where the two old
--- implementations disagreed, so a reintroduced second opinion fails here.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Byte-length of the magic key, used to build the post-★ buffer the engine sees.
local MAGIC_KEY = "★"





-- ============================================
-- ============================================
-- ======= 1/ Loading The Real Expander =======
-- ============================================
-- ============================================

--- Loads the expander with a controllable CoreState.
--- @param state_overrides table Fields merged into the injected core state.
--- @return table expander, table state
local function load_expander(state_overrides)
	package.loaded["modules.keymap.expander"] = nil
	local E = helpers.load_with_stubs("modules.keymap.expander")

	local state = {
		buffer                 = "",
		start_is_word_boundary = true,
		expected_synthetic_chars   = "",
		expected_synthetic_deletes = 0,
		suppress_rescan        = function() end,
		suppress_rescan_keep_buffer = function() end,
	}
	for k, v in pairs(state_overrides or {}) do state[k] = v end

	E.init(state, { is_terminator = function() return false end }, {
		get_llm_enabled = function() return false end,
		update_preview  = function() end,
		start_timer     = function() end,
	})
	return E, state
end

--- Builds a mapping entry with the fields would_fire reads.
--- @param t table Overrides.
--- @return table
local function mapping(t)
	local trigger = t.trigger
	return {
		trigger       = trigger,
		trigger_bytes = #trigger,
		repl          = t.repl,
		plain_repl    = t.plain_repl or t.repl,
		is_word       = t.is_word == true,
		case_conform  = t.case_conform == true,
		tlen          = t.tlen or #trigger,
	}
end





-- ==================================================
-- ==================================================
-- ======= 2/ The Four Historical Divergences =======
-- ==================================================
-- ==================================================

helpers.describe("would_fire is the single answer both sides get", function()
	helpers.it("refuses a word trigger at a non-boundary buffer start", function()
		-- DIVERGENCE 1. The preview's old ends_with_trigger saw an empty prefix and
		-- allowed the match; the engine consults start_is_word_boundary.
		local E = load_expander({ start_is_word_boundary = false })
		local m = mapping({ trigger = "abc", repl = "expanded", is_word = true })

		helpers.assert_nil(E.would_fire(m, "abc"),
			"with the rolling buffer starting mid-word, an is_word trigger occupying the "
			.. "whole buffer must NOT fire — the text to its left is simply not in the "
			.. "buffer, so the boundary is unknown and start_is_word_boundary says no. The "
			.. "preview used to show this expansion and the engine then declined it")
	end)

	helpers.it("fires the same trigger when the buffer start IS a boundary", function()
		local E = load_expander({ start_is_word_boundary = true })
		local m = mapping({ trigger = "abc", repl = "expanded", is_word = true })

		helpers.assert_eq(E.would_fire(m, "abc"), "expanded",
			"the mirror case must still fire — the fix must not make the engine stricter, "
			.. "only make the preview agree with it")
	end)

	helpers.it("exempts a separator-prefixed trigger from the boundary rule", function()
		-- DIVERGENCE 2. The comma-layer ";e" -> "Je" must fire in every context.
		local E = load_expander({ start_is_word_boundary = false })
		local m = mapping({ trigger = ";e", repl = "Je", is_word = true })

		helpers.assert_eq(E.would_fire(m, "mot;e"), "Je",
			"a trigger starting with a separator carries its own boundary and must fire "
			.. "even directly after a letter. The preview applied the boundary rule anyway "
			.. "and hid a row for an expansion that does happen")
	end)

	helpers.it("blocks a word trigger glued to a preceding letter", function()
		local E = load_expander({ start_is_word_boundary = true })
		local m = mapping({ trigger = "abc", repl = "expanded", is_word = true })

		helpers.assert_nil(E.would_fire(m, "xabc"),
			"an is_word trigger preceded by a letter must not fire — this is the case both "
			.. "old implementations already agreed on, and it must stay blocked")
	end)

	helpers.it("resolves case_conform identically for ★ triggers", function()
		-- DIVERGENCE 3. The preview's star bucket had no case_conform branch at all.
		local E = load_expander({})
		local m = mapping({
			trigger = "abc" .. MAGIC_KEY, repl = "expanded", case_conform = true,
		})

		local eff = E.would_fire(m, "ABC" .. MAGIC_KEY)
		helpers.assert_eq(eff, "EXPANDED",
			"an UPPER-typed case_conform ★ trigger must resolve to the UPPER replacement. "
			.. "The preview's star bucket never ran conform_replacement, so it showed the "
			.. "stored lowercase text while the engine emitted the conformed one")
	end)

	helpers.it("declines a no-op expansion rather than offering it", function()
		-- DIVERGENCE 4. Compared against what was TYPED, not against the trigger.
		local E = load_expander({})
		local m = mapping({ trigger = "abc", repl = "abc" })

		helpers.assert_nil(E.would_fire(m, "abc"),
			"a replacement equal to what was typed changes nothing: the engine passes the "
			.. "keystroke through, so the tooltip must not advertise an expansion")
	end)
end)





-- ======================================================
-- ======================================================
-- ======= 3/ The Preview Asks About The ★ Buffer =======
-- ======================================================
-- ======================================================

helpers.describe("the ★ preview evaluates the buffer the engine will see", function()
	helpers.it("matches a ★ trigger only once the magic key is appended", function()
		local E = load_expander({})
		local m = mapping({ trigger = "abc" .. MAGIC_KEY, repl = "expanded" })

		helpers.assert_nil(E.would_fire(m, "abc"),
			"the trigger includes ★, so the pre-★ buffer must not match it")
		helpers.assert_eq(E.would_fire(m, "abc" .. MAGIC_KEY), "expanded",
			"appending the magic key is what makes it match — this is why update_preview "
			.. "must ask about `buf .. magic_key` rather than about `buf`. Asking about the "
			.. "current buffer answers a different question than the engine will be asked")
	end)
end)





-- =================================================
-- =================================================
-- ======= 4/ No Second Opinion May Reappear =======
-- =================================================
-- =================================================

--- The preview's word-boundary rule exactly as it was before the unification,
--- kept here as an executable record of the defect. Deleted from production; a
--- test that only asserts the new behaviour cannot show that the old one differed.
--- @param buffer string Buffer to test.
--- @param trigger string Trigger to match at its end.
--- @param is_word boolean Whether the trigger is word-anchored.
--- @return boolean
local function old_preview_ends_with_trigger(buffer, trigger, is_word)
	if type(buffer) ~= "string" or type(trigger) ~= "string" or trigger == "" then return false end
	if #buffer < #trigger or buffer:sub(-#trigger) ~= trigger then return false end
	if is_word ~= true then return true end
	local before = buffer:sub(1, #buffer - #trigger)
	if #before == 0 then return true end   -- <- the divergence
	local ok_utf8, prev_offset = pcall(utf8.offset, before, -1)
	if not ok_utf8 then prev_offset = nil end
	local prev_char = prev_offset and before:sub(prev_offset) or ""
	if prev_char == "@" or prev_char:match("%a") then return false end
	return true
end

helpers.describe("the old preview rule really did disagree with the engine", function()
	helpers.it("promised a match the engine refuses at a non-boundary start", function()
		local E = load_expander({ start_is_word_boundary = false })
		local m = mapping({ trigger = "abc", repl = "expanded", is_word = true })

		local old_says = old_preview_ends_with_trigger("abc", "abc", true)
		local engine_says = E.would_fire(m, "abc") ~= nil

		helpers.assert_true(old_says,
			"the old preview rule allowed this match (empty prefix -> allowed)")
		helpers.assert_true(not engine_says,
			"the engine refuses it (start_is_word_boundary is false)")
		helpers.assert_true(old_says ~= engine_says,
			"this is the divergence the user saw: the tooltip promised an expansion and the "
			.. "engine declined it. If this assertion ever fails, the two rules have been "
			.. "made to agree by accident rather than by construction — which is precisely "
			.. "the state that decays back into a bug")
	end)

	helpers.it("hid a separator-prefixed match the engine performs", function()
		local E = load_expander({ start_is_word_boundary = false })
		local m = mapping({ trigger = ";e", repl = "Je", is_word = true })

		local old_says    = old_preview_ends_with_trigger("mot;e", ";e", true)
		local engine_says = E.would_fire(m, "mot;e") ~= nil

		helpers.assert_true(not old_says,
			"the old preview rule blocked ';e' after a letter")
		helpers.assert_true(engine_says,
			"the engine exempts separator-prefixed triggers and fires it")
		helpers.assert_true(old_says ~= engine_says,
			"the divergence in the other direction: the engine expanded something the "
			.. "tooltip never offered, so the text changed with no preview at all")
	end)
end)

helpers.describe("neither side reimplements the match decision", function()
	helpers.it("the preview owns no word-boundary rule of its own", function()
		-- Selected by a declaration unique to modules/keymap/llm_bridge.lua rather
		-- than by path, so moving the module cannot turn this into a path error.
		local src = helpers.read_driver_source("function M.update_preview")
		helpers.assert_true(src ~= nil, "llm_bridge source must be locatable")
		if not src then return end

		helpers.assert_true(src:find("local function ends_with_trigger") == nil,
			"the preview must not carry its own trigger/boundary matcher. That helper is "
			.. "exactly what diverged from the engine's word_boundary_blocks — reintroducing "
			.. "it recreates the bug even if the two agree on the day it is written")
	end)

	helpers.it("the preview resolves matches through the expander", function()
		local src = helpers.read_driver_source("function M.update_preview")
		if not src then return end

		helpers.assert_true(src:find("expander%.would_fire") ~= nil,
			"update_preview must obtain its matches from expander.would_fire, the same "
			.. "function try_auto_expand uses, so the row shown is the replacement that "
			.. "keystroke will actually produce")
	end)

	helpers.it("the engine decides through the same function", function()
		local src = helpers.read_driver_source("function M.try_auto_expand")
		helpers.assert_true(src ~= nil, "expander source must be locatable")
		if not src then return end

		local fn_at = src:find("function M%.try_auto_expand")
		local body  = src:sub(fn_at, fn_at + 1200)
		helpers.assert_true(body:find("M%.would_fire") ~= nil,
			"try_auto_expand must delegate its decision to would_fire rather than inlining "
			.. "a copy — an inlined copy is free to drift from the one the preview calls")
	end)
end)
