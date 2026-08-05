--- tests/unit/modules/hotstrings/test_repeat_key.lua

--- ==============================================================================
--- MODULE: Magic-Key Repeat
--- DESCRIPTION:
--- The rule that turns `po★` into `poo`, and the conditions under which it must
--- stay out of the way.
---
--- WHY THIS EXISTS AT ALL:
--- The manifest declared `hotstrings.repeat_key_enabled` and the `repeat_key`
--- menu row as `platforms = ["ahk"]`, so a parity ratchet reading the manifest
--- reported Linux as complete while the keystroke did nothing and no row offered
--- it. The restriction was false the day it was written — macOS ships both the
--- engine and the toggle — and the way to close a gap the manifest describes
--- wrongly is to write the feature and correct the declaration, not to widen the
--- declaration over an absence.
---
--- WHAT IS ASSERTED HERE IS THE RULE, NOT THE KEYSTROKE:
--- `M.resolve` is pure, so the decision can be checked without a keyboard, a
--- display or an injector. The daemon's part — running it only when nothing else
--- matched — is one line at the call site and is asserted by the shape of the
--- result it builds.
--- ==============================================================================

local helpers = require("tests.helpers")

local RepeatKey = helpers.load_module("modules.hotstrings.repeat_key")

local STAR = "★"




-- =================================================================
-- =================================================================
-- ======= 1/ When it fires ========================================
-- =================================================================
-- =================================================================

helpers.describe("magic-key repeat: the rule", function()

	helpers.it("doubles the character before the magic key", function()
		local out = RepeatKey.resolve("po" .. STAR, STAR)
		helpers.assert_true(out ~= nil, "typing the magic key after a letter must repeat it")
		helpers.assert_eq(out.replacement, "o", "the character immediately before the key")
		helpers.assert_eq(out.backspace_count, 1,
			"only the magic key is erased — the character before it stays and is joined "
				.. "by its copy, so the caret moves once rather than twice")
	end)

	helpers.it("repeats a multi-byte character whole", function()
		-- LuaJIT is 5.1-based and has no utf8 library, so a byte-wise
		-- implementation would repeat the last BYTE of "é" and emit mojibake.
		local out = RepeatKey.resolve("caf\195\169" .. STAR, STAR)
		helpers.assert_eq(out.replacement, "\195\169",
			"the whole codepoint, not its trailing byte")
	end)

	helpers.it("works with a magic key the user chose", function()
		local out = RepeatKey.resolve("ab@", "@")
		helpers.assert_eq(out.replacement, "b",
			"the key is read from the caller, not baked in — a user who changed it "
				.. "must get the same behaviour")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ When it must not =====================================
-- =================================================================
-- =================================================================

helpers.describe("magic-key repeat: when it stays out of the way", function()

	helpers.it("does nothing when the buffer does not end with the magic key", function()
		helpers.assert_nil(RepeatKey.resolve("po" .. STAR .. "x", STAR),
			"this fires on the keystroke that typed the key; a magic key further back "
				.. "is history the user has moved past")
	end)

	helpers.it("does nothing when the magic key is the whole buffer", function()
		helpers.assert_nil(RepeatKey.resolve(STAR, STAR),
			"there is nothing before it to repeat")
	end)

	helpers.it("does not double the magic key itself", function()
		helpers.assert_nil(RepeatKey.resolve(STAR .. STAR, STAR),
			"two magic keys are a second trigger, not a repeat — doubling here would "
				.. "let a held key emit an unbounded run of them")
	end)

	helpers.it("refuses a missing or empty magic key rather than guessing", function()
		helpers.assert_nil(RepeatKey.resolve("po", ""))
		helpers.assert_nil(RepeatKey.resolve("po", nil))
		helpers.assert_nil(RepeatKey.resolve(nil, STAR))
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 3/ The setting ==========================================
-- =================================================================
-- =================================================================

helpers.describe("magic-key repeat: the toggle", function()

	helpers.it("is on for a user who has never touched it", function()
		-- Opt-out, not opt-in: both other drivers default it on, so a user who has
		-- set nothing must get the same behaviour on all three.
		local Storage = helpers.load_module("adapters.storage")
		Storage.delete("hotstrings.repeat_key_enabled")
		local fresh = helpers.load_module("modules.hotstrings.repeat_key")
		helpers.assert_true(fresh.is_enabled(), "the shipped default is on")
	end)

	helpers.it("remembers being switched off", function()
		local fresh = helpers.load_module("modules.hotstrings.repeat_key")
		fresh.set_enabled(false)
		helpers.assert_true(not fresh.is_enabled(), "and a stored false must not read as unset")
		fresh.set_enabled(true)
	end)

end)
