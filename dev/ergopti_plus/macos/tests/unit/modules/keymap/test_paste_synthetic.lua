--- tests/unit/modules/keymap/test_paste_synthetic.lua

--- ==============================================================================
--- MODULE: keymap.utils Paste Path Unit Tests
--- DESCRIPTION:
--- Regression tests for the paste-path emit contract in keymap.utils.
---
--- HISTORY:
--- A5 audit finding: emit_text/emit_tokens returned (1, "") on the paste path,
--- causing the Cmd+V echo to reach the handler with an empty synthetic queue
--- and wipe the buffer unconditionally.
---
--- A6 supersedes A5: returning the full text in emitted_str polluted
--- expected_synthetic_chars with text that Cmd+V never echoes back as individual
--- keystrokes, causing subsequent real keystrokes matching the expansion prefix to
--- be silently absorbed (paste-synthetic-chars-leak). The correct contract is:
---   - Return (count, "") — count is valid, emitted_str is empty on paste.
---   - Signal the pending Cmd+V echo via take_paste_ops() instead.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

-- load_with_stubs installs a fresh hs stub (tests/stubs/hs.lua) that includes
-- pasteboard.readAllData/writeAllData, so no extra setup is needed here.
local KU = helpers.load_with_stubs("modules.keymap.utils")





-- =============================================================
-- =============================================================
-- ======= 1/ emit_text: paste path returns empty string =======
-- =============================================================
-- =============================================================

helpers.describe("KU.emit_text: paste path returns empty emitted_str (A6 fix)", function()
	helpers.it("returns non-zero count and empty string for text longer than PASTE_THRESHOLD", function()
		-- 60-char ASCII string exceeds the 50-char paste threshold
		local long_text = ("a"):rep(60)
		local count, emitted = KU.emit_text(long_text)
		-- Must return the real length so callers can track emit size
		helpers.assert_eq(count, 60)
		-- Must return empty string so expected_synthetic_chars is NOT polluted
		helpers.assert_eq(emitted, "")
	end)

	helpers.it("returns non-zero count and empty string for emoji (high-unicode) text", function()
		-- U+1F600 grinning face encoded as 4 UTF-8 bytes, 1 codepoint
		local emoji_text = "\xF0\x9F\x98\x80"
		local count, emitted = KU.emit_text(emoji_text)
		helpers.assert_eq(count >= 1, true)
		helpers.assert_eq(emitted, "")
	end)

	helpers.it("still returns 0, '' for non-string input", function()
		local count, emitted = KU.emit_text(nil)
		helpers.assert_eq(count, 0)
		helpers.assert_eq(emitted, "")
	end)
end)





-- ==========================================================================
-- ==========================================================================
-- ======= 2/ emit_text: paste path increments take_paste_ops counter =======
-- ==========================================================================
-- ==========================================================================

helpers.describe("KU.emit_text: paste path signals via take_paste_ops (A6 fix)", function()
	helpers.it("take_paste_ops() returns 1 after a paste expansion", function()
		-- Reset by consuming any pending ops first
		KU.take_paste_ops()
		local long_text = ("c"):rep(60)
		KU.emit_text(long_text)
		local ops = KU.take_paste_ops()
		helpers.assert_eq(ops, 1)
	end)

	helpers.it("take_paste_ops() returns 0 for a short keystroke expansion", function()
		KU.take_paste_ops()
		local short_text = "hi"
		KU.emit_text(short_text)
		local ops = KU.take_paste_ops()
		helpers.assert_eq(ops, 0)
	end)

	helpers.it("take_paste_ops() resets to 0 after being read", function()
		KU.take_paste_ops()
		KU.emit_text(("d"):rep(60))
		KU.take_paste_ops()  -- consume
		local ops = KU.take_paste_ops()
		helpers.assert_eq(ops, 0)
	end)
end)





-- ===============================================================
-- ===============================================================
-- ======= 3/ emit_tokens: paste path returns empty string =======
-- ===============================================================
-- ===============================================================

helpers.describe("KU.emit_tokens: paste path returns empty emitted_str (A6 fix)", function()
	helpers.it("returns real count and empty string for a long text token", function()
		KU.take_paste_ops()
		local long_text = ("b"):rep(60)
		local tokens = { { kind = "text", value = long_text } }
		local count, emitted = KU.emit_tokens(tokens)
		helpers.assert_eq(count, 60)
		helpers.assert_eq(emitted, "")
	end)

	helpers.it("take_paste_ops() returns 1 after emit_tokens pastes a token", function()
		KU.take_paste_ops()
		local tokens = { { kind = "text", value = ("e"):rep(60) } }
		KU.emit_tokens(tokens)
		local ops = KU.take_paste_ops()
		helpers.assert_eq(ops, 1)
	end)
end)
