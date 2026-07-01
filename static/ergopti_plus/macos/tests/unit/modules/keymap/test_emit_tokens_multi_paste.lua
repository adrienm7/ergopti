--- tests/unit/modules/keymap/test_emit_tokens_multi_paste.lua

--- ==============================================================================
--- MODULE: keymap.utils Multi-Segment Paste Serialisation Unit Tests
--- DESCRIPTION:
--- Regression tests for F-HIGH-1: a replacement containing two paste-worthy
--- text segments (e.g. a signature/address block split by a literal newline)
--- must not issue two hs.pasteboard.setContents + Cmd+V pairs back-to-back in
--- the same call stack. CGEventPost is asynchronous, so the second
--- setContents() call can overwrite the clipboard before the OS has delivered
--- the first Cmd+V, corrupting the first segment.
---
--- HISTORY:
--- F-HIGH-1 audit finding — emit_tokens() had zero synchronization between
--- "clipboard mutated, paste queued" and "target app actually consumed the
--- paste" for the second and later paste-worthy tokens in a single call.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

-- load_with_stubs installs a fresh hs stub (tests/stubs/hs.lua) that includes
-- pasteboard.readAllData/writeAllData and an introspectable __timers list, so
-- we can assert on call ORDER without depending on real OS timing.
local KU = helpers.load_with_stubs("modules.keymap.utils")

--- Builds two paste-worthy (>50 char) text tokens with a key token in between,
--- mirroring how tokens_from_repl() splits a replacement on a literal newline.
--- @return table Token list: [text(paste), key(return), text(paste)].
local function two_segment_tokens()
	return {
		{ kind = "text", value = ("A"):rep(60) },
		{ kind = "key",  value = "return" },
		{ kind = "text", value = ("B"):rep(60) },
	}
end





-- =========================================================================
-- =========================================================================
-- ======= 1/ emit_tokens: second paste is deferred, not synchronous =======
-- =========================================================================
-- =========================================================================

helpers.describe("KU.emit_tokens: multi-segment paste is serialised (F-HIGH-1 fix)", function()
	-- emit_tokens's deferred pastes are scheduled via hs.timer.doAfter, which
	-- appends to the SAME shared TIMERS list across every it() in this file
	-- (load_with_stubs runs once per file, not per test). Without this reset,
	-- a prior test's un-fired deferred-paste timer leaks into the next test's
	-- hs.timer.__fire_all() call and inflates its setContents count.
	helpers.before_each(function()
		hs.__reset()
	end)

	helpers.it("issues only ONE setContents call synchronously for two paste-worthy tokens", function()
		local set_contents_calls = {}
		hs.pasteboard.setContents = function(v)
			table.insert(set_contents_calls, v)
			return true
		end

		KU.take_paste_ops()
		KU.emit_tokens(two_segment_tokens())

		-- Only the FIRST segment's setContents must have fired synchronously;
		-- the second segment must still be waiting on a timer.
		helpers.assert_eq(#set_contents_calls, 1)
		helpers.assert_eq(set_contents_calls[1], ("A"):rep(60))
	end)

	helpers.it("issues the second setContents only after its scheduled timer fires", function()
		-- Track only the paste-worthy VALUES written to the clipboard; the
		-- restore-to-original timers also call setContents("") once their own
		-- delay elapses, which is unrelated bookkeeping this test must ignore.
		local pasted_values = {}
		hs.pasteboard.setContents = function(v)
			if v ~= "" then table.insert(pasted_values, v) end
			return true
		end

		KU.take_paste_ops()
		KU.emit_tokens(two_segment_tokens())
		helpers.assert_eq(#pasted_values, 1)
		helpers.assert_eq(pasted_values[1], ("A"):rep(60))

		-- Firing every pending timer delivers the deferred second paste (and
		-- also the restore timers, which are filtered out above).
		hs.timer.__fire_all()

		helpers.assert_eq(#pasted_values, 2)
		helpers.assert_eq(pasted_values[2], ("B"):rep(60))
	end)

	helpers.it("still counts both pastes in take_paste_ops even though the second is deferred", function()
		KU.take_paste_ops()
		KU.emit_tokens(two_segment_tokens())
		local ops = KU.take_paste_ops()
		-- The paste-ops counter must be incremented synchronously when the paste
		-- is QUEUED, not only once the deferred timer actually fires, so the
		-- expander's expected_synthetic_pastes bookkeeping stays accurate the
		-- moment emit_tokens() returns.
		helpers.assert_eq(ops, 2)
	end)

	helpers.it("returns the correct total character count synchronously despite the deferred paste", function()
		KU.take_paste_ops()
		local count = KU.emit_tokens(two_segment_tokens())
		-- 60 chars + 1 for the {Enter} key token + 60 chars.
		helpers.assert_eq(count, 121)
	end)

	helpers.it("single paste-worthy token still pastes synchronously (no unnecessary delay)", function()
		local set_contents_calls = {}
		hs.pasteboard.setContents = function(v)
			table.insert(set_contents_calls, v)
			return true
		end

		KU.take_paste_ops()
		KU.emit_tokens({ { kind = "text", value = ("C"):rep(60) } })

		helpers.assert_eq(#set_contents_calls, 1)
	end)
end)
