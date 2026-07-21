--- tests/unit/modules/keymap/test_star_validation_beats_repeat_key.lua

--- ==============================================================================
--- MODULE: Regression — pressing ★ must expand what the tooltip showed
--- DESCRIPTION:
--- The tooltip displayed a hotstring expansion for a ★ trigger, the user pressed
--- ★ to accept it, and got the last letter doubled instead. Intermittently — it
--- depended on how long the pause before ★ was.
---
--- ROOT CAUSE ENCODED:
--- run_trigger_checks has three branches, tried in order:
---   1. auto candidates      — gated by mapping_fires() (typing-speed delay)
---   2. terminator candidates — gated by mapping_fires() UNLESS ★ was typed
---   3. try_repeat_feature   — the "double the last letter" fallback
--- Branch 2 already bypassed the delay when the typed character is the magic key,
--- with the rationale spelled out in its own comment: pressing ★ is an explicit
--- validation of the displayed tooltip, so a slow typist must not get a repeat-key
--- instead of the intended expansion. Branch 1 — which is the branch that owns
--- has_magic triggers, since their tail codepoint IS ★ — never got that bypass.
---
--- So a ★ trigger typed after a pause failed mapping_fires (DELAYS.STAR_TRIGGER,
--- 2 s by default, scaled by the complex-keystroke multiplier), fell through
--- branch 2 (which buckets on the character BEFORE the terminator and therefore
--- cannot contain a has_magic mapping), and landed in branch 3, which doubled the
--- last letter.
---
--- WHY THE TOOLTIP DISAGREED:
--- llm_bridge.update_preview collects star matches with NO delay gate at all — it
--- checks group membership, the star_base suffix and the repetition guard, but
--- never consults typing speed. The preview therefore promised an expansion the
--- engine had already decided not to perform. The tooltip was not wrong about the
--- mapping; the two sides simply disagreed about whether it would fire.
---
--- WHY A SOURCE GUARD:
--- The branch chain lives in run_trigger_checks, a local function inside the
--- eventtap callback: reaching it behaviourally means driving a real CGEventTap
--- with real timing. What is decidable, and what was actually wrong, is that the
--- star bypass is applied to BOTH branches from a single shared decision — so the
--- two can never again be updated apart.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =====================================================
-- =====================================================
-- ======= 1/ ★ Bypasses The Delay On Both Paths =======
-- =====================================================
-- =====================================================

--- Reads the engine's trigger-dispatch source.
--- @return string
local function dispatch_source()
	-- Selected by a declaration unique to modules/keymap/init.lua rather than by
	-- path, so moving or splitting the module cannot turn this invariant into a
	-- path error.
	local src = helpers.read_driver_source("local function run_trigger_checks")
	helpers.assert_true(src ~= nil, "modules/keymap/init.lua source must be locatable")
	return src or ""
end

helpers.describe("pressing ★ validates the tooltip on every expansion branch", function()
	helpers.it("decides 'the magic key was typed' exactly once", function()
		local src = dispatch_source()
		local _, count = src:gsub("chars%s*==%s*CoreState%.magic_key", "")
		helpers.assert_eq(count, 1,
			"the 'is this the magic key' test must be made ONCE and shared by both branches. "
			.. "Two independent copies is how the auto branch ended up without the bypass the "
			.. "terminator branch had, which is what let a ★ trigger fall through to the "
			.. "repeat-key fallback")
	end)

	helpers.it("bypasses the typing-speed delay for has_magic triggers", function()
		local src = dispatch_source()
		helpers.assert_true(src:find("star_validated and m%.has_magic") ~= nil,
			"the auto branch must let a has_magic mapping through when ★ was just typed. "
			.. "Gated on mapping_fires alone, a ★ trigger typed after a pause longer than "
			.. "DELAYS.STAR_TRIGGER silently becomes a doubled letter — the user asked for an "
			.. "expansion and got 'aa'")
	end)

	helpers.it("still gates ordinary auto triggers on typing speed", function()
		local src = dispatch_source()
		helpers.assert_true(src:find("or mapping_fires%(m%)") ~= nil,
			"the bypass must apply ONLY to has_magic mappings — an ordinary auto trigger has "
			.. "no explicit validation keystroke, so its typing-speed gate must stay. Dropping "
			.. "mapping_fires entirely would fire every autocorrection regardless of delay")
	end)
end)





-- ==============================================================
-- ==============================================================
-- ======= 2/ The Repeat Key Stays A Last-Resort Fallback =======
-- ==============================================================
-- ==============================================================

helpers.describe("the repeat-key fallback runs only after every expansion attempt", function()
	helpers.it("calls try_repeat_feature after both expansion branches", function()
		local src = dispatch_source()

		-- Anchor on the CALL, not the bare name: the branch chain is documented in
		-- prose above it, and matching the name alone finds the comment first.
		local auto_at   = src:find("Expander%.try_auto_expand")
		local term_at   = src:find("Expander%.try_terminator_expand")
		local repeat_at = src:find("Expander%.try_repeat_feature")

		helpers.assert_true(auto_at ~= nil,   "the auto-expand branch must be locatable")
		helpers.assert_true(term_at ~= nil,   "the terminator branch must be locatable")
		helpers.assert_true(repeat_at ~= nil, "the repeat-key fallback must be locatable")

		helpers.assert_true(auto_at < repeat_at,
			"the repeat-key fallback must come AFTER the auto-expand branch — it is what the "
			.. "engine does when no hotstring matched, never a competitor to one that did")
		helpers.assert_true(term_at < repeat_at,
			"the repeat-key fallback must come AFTER the terminator branch, for the same reason")
	end)
end)





-- ==========================================================
-- ==========================================================
-- ======= 3/ The Preview Applies No Delay Of Its Own =======
-- ==========================================================
-- ==========================================================

helpers.describe("the tooltip's star preview does not second-guess the engine's timing", function()
	helpers.it("collects star matches without consulting the typing-speed delay", function()
		-- Selected by a declaration unique to modules/keymap/llm_bridge.lua rather
		-- than by path, so moving the module cannot turn this into a path error.
		local src = helpers.read_driver_source("function M.update_preview")
		helpers.assert_true(src ~= nil, "modules/keymap/llm_bridge.lua source must be locatable")
		if not src then return end

		local star_at = src:find("mappings_for_star_tail")
		helpers.assert_true(star_at ~= nil, "the star-preview bucket walk must be locatable")

		-- Bound the window to the star bucket's own loop so the autocorrect bucket
		-- below it cannot be miscredited.
		local tail_at = src:find("mappings_for_tail", star_at, true) or (star_at + 2000)
		local window  = src:sub(star_at, tail_at)

		helpers.assert_true(window:find("mapping_fires") == nil,
			"the preview must NOT re-implement the engine's delay gate — a second copy of that "
			.. "decision is exactly what diverged. The engine now honours ★ as an explicit "
			.. "validation, so what the preview shows is what pressing ★ produces; adding a "
			.. "delay check here would resurrect the divergence from the other side")
		helpers.assert_true(window:find("_tc_dt") == nil,
			"the preview must not read the engine's per-keystroke timing state either")
	end)
end)
