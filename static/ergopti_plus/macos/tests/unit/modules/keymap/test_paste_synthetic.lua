--- tests/unit/modules/keymap/test_paste_synthetic.lua

--- ==============================================================================
--- MODULE: keymap.utils Paste Path Unit Tests
--- DESCRIPTION:
--- Regression tests for the A5 audit finding: emit_text() and emit_tokens()
--- must return the real character count and text string on the clipboard-paste
--- path so that callers can populate expected_synthetic_chars. Previously both
--- functions returned (1, "") on paste, causing the Cmd+V echo to reach the
--- handler with an empty synthetic queue and wipe the buffer unconditionally.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

-- Stub hs.pasteboard and keyStroke so no OS interaction occurs during tests
local hs_stub = package.loaded["hs"] or {}
hs_stub.pasteboard = hs_stub.pasteboard or {}
hs_stub.pasteboard.getContents = function() return "" end
hs_stub.pasteboard.setContents = function() end
hs_stub.eventtap = hs_stub.eventtap or {}
hs_stub.eventtap.keyStroke = function() end
hs_stub.eventtap.keyStrokes = function() end
hs_stub.timer = hs_stub.timer or {}
hs_stub.timer.doAfter = function(_, _) end
package.loaded["hs"] = hs_stub

local KU = helpers.load_with_stubs("modules.keymap.utils")




-- =========================================================
--- =========================================================
-- ======= 1/ emit_text: paste path returns real len =======
--- =========================================================
-- =========================================================

helpers.describe("KU.emit_text: paste path populates expected_synthetic_chars", function()
	helpers.it("returns non-empty string for text longer than PASTE_THRESHOLD", function()
		-- 60-char ASCII string exceeds the 50-char paste threshold
		local long_text = ("a"):rep(60)
		local count, emitted = KU.emit_text(long_text)
		-- Must return the real length (60) so the caller can arm expected_synthetic_chars
		helpers.assert_eq(count, 60)
		-- Must return the actual text so expected_synthetic_chars is populated
		helpers.assert_eq(emitted, long_text)
	end)

	helpers.it("returns non-empty string for emoji (high-unicode) text", function()
		-- Even a short emoji string triggers the paste path via contains_high_unicode;
		-- U+1F600 grinning face encoded as 4 UTF-8 bytes, 1 codepoint
		local emoji_text = "\xF0\x9F\x98\x80"
		local count, emitted = KU.emit_text(emoji_text)
		helpers.assert_eq(count >= 1, true)
		helpers.assert_eq(emitted, emoji_text)
	end)

	helpers.it("still returns 0, '' for non-string input", function()
		local count, emitted = KU.emit_text(nil)
		helpers.assert_eq(count, 0)
		helpers.assert_eq(emitted, "")
	end)
end)




-- =======================================================================
--- =======================================================================
-- ======= 2/ emit_tokens: paste path populates expected_synthetic =======
--- =======================================================================
-- =======================================================================

helpers.describe("KU.emit_tokens: paste path populates expected_synthetic_chars", function()
	helpers.it("returns real count and text for a long text token", function()
		local long_text = ("b"):rep(60)
		local tokens = { { kind = "text", value = long_text } }
		local count, emitted = KU.emit_tokens(tokens)
		helpers.assert_eq(count, 60)
		helpers.assert_eq(emitted, long_text)
	end)
end)
