--- tests/unit/modules/keylogger/test_notify_synthetic_malformed_utf8.lua

--- ==============================================================================
--- MODULE: Regression — notify_synthetic tolerates malformed UTF-8 (F-HIGH-16)
--- DESCRIPTION:
--- notify_synthetic's `for _, code in utf8.codes(text) do` loop raised
--- immediately on malformed UTF-8 (e.g. a truncated LLM completion cut
--- mid-codepoint — French accents, curly quotes, and em-dashes are all
--- multi-byte). Every other utf8.* call in this file is pcall-guarded; this
--- one was not, so a bad completion aborted the expansion mid-flight and left
--- the synthetic-injection trackers (synth_queue / recent_typing_eff) desynced.
---
--- Fix: validate with pcall(utf8.len, text) BEFORE iterating with utf8.codes
--- (utf8.len fails closed with nil instead of throwing), and on a validation
--- failure queue one opaque, non-decoded fallback entry instead of raising.
---
--- CoreState is a private module-local in keylogger/init.lua (not exposed for
--- test injection, and M.notify_synthetic gates on CoreState.is_enabled which
--- only M.start() sets — M.start() itself needs hs.caffeinate/filesystem
--- access unavailable under the headless stub). So this test exercises the
--- REAL Lua utf8 stdlib behavior against the exact validate-then-branch logic
--- that now lives in notify_synthetic (a faithful extracted mirror, in the
--- same spirit as test_synth_queue_drain.lua's simulate_drain), and separately
--- pins the fix at the source level to guarantee the mirror matches production.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Mirrors notify_synthetic's post-fix text-processing branch verbatim: validates
--- with pcall(utf8.len, text) and falls back to one opaque queue entry instead of
--- raising when the text contains malformed UTF-8. Uses the REAL utf8 stdlib (no
--- stubbing) so the raise/no-raise behavior is genuinely exercised.
--- @param text string The candidate synthetic text.
--- @param source_type string Origin label stored on each queue entry.
--- @return table synth_queue The resulting queue entries.
--- @return number char_count The char count used for WPM-window timestamps.
local function simulate_notify_synthetic_text_branch(text, source_type)
	local synth_queue = {}
	local ok_len, char_count = pcall(utf8.len, text)
	if ok_len and char_count then
		for _, code in utf8.codes(text) do
			table.insert(synth_queue, { char = utf8.char(code), type = source_type })
		end
	else
		table.insert(synth_queue, { char = text, type = source_type })
		char_count = 1
	end
	return synth_queue, char_count
end





-- =============================================================================
-- =============================================================================
-- ======= 1/ Malformed UTF-8 does not raise and queues a fallback entry =======
-- =============================================================================
-- =============================================================================

helpers.describe("keylogger: notify_synthetic tolerates malformed UTF-8 (F-HIGH-16)", function()

	helpers.it("a lone high byte does not raise and queues exactly one fallback entry", function()
		local lone_high_byte = "\xF0\x28"  -- invalid UTF-8: truncated 4-byte sequence

		local ok, queue, char_count = pcall(simulate_notify_synthetic_text_branch, lone_high_byte, "llm")
		helpers.assert_true(ok, "the validate-then-iterate branch must not raise on malformed UTF-8")
		helpers.assert_eq(#queue, 1, "exactly one opaque fallback entry must be queued")
		helpers.assert_eq(queue[1].char, lone_high_byte, "the fallback entry must carry the raw text verbatim")
		helpers.assert_eq(queue[1].type, "llm")
		helpers.assert_eq(char_count, 1)
	end)

	helpers.it("valid multi-byte UTF-8 (French accents) still decodes per-codepoint (non-regression)", function()
		local text = "café"  -- 4 codepoints, 5 bytes (é is 2 bytes)
		local queue, char_count = simulate_notify_synthetic_text_branch(text, "hotstring")
		helpers.assert_eq(#queue, 4, "valid UTF-8 must still be split into one entry per codepoint")
		helpers.assert_eq(char_count, 4)
	end)

	helpers.it("raw utf8.codes() (unguarded) DOES raise on the same malformed input — proves the guard is load-bearing", function()
		local lone_high_byte = "\xF0\x28"
		local ok = pcall(function()
			for _, code in utf8.codes(lone_high_byte) do end
		end)
		helpers.assert_true(not ok, "utf8.codes must raise on malformed UTF-8 without the pcall(utf8.len, …) guard in front of it")
	end)
end)





-- ============================================================================
-- ============================================================================
-- ======= 2/ Source pin: guard precedes utf8.codes in notify_synthetic =======
-- ============================================================================
-- ============================================================================

helpers.describe("keylogger: notify_synthetic source guards utf8.codes with pcall(utf8.len, …) (F-HIGH-16)", function()

	helpers.it("the validation call precedes the utf8.codes loop inside notify_synthetic", function()
		-- Selected by a declaration unique to modules/keylogger/init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function ensure_browser_window_filter")
		helpers.assert_true(src ~= nil, "modules/keylogger/init.lua source must be locatable")

		local body = src:match("function M%.notify_synthetic.-\nend")
		helpers.assert_true(body ~= nil, "notify_synthetic body must be locatable")

		local guard_pos = body:find("pcall(utf8.len, text)", 1, true)
		local codes_pos = body:find("utf8.codes(text)", 1, true)
		helpers.assert_true(guard_pos ~= nil, "notify_synthetic must validate with pcall(utf8.len, text)")
		helpers.assert_true(codes_pos ~= nil, "notify_synthetic must still iterate with utf8.codes(text)")
		helpers.assert_true(guard_pos < codes_pos, "the pcall(utf8.len, …) guard must precede the utf8.codes(text) loop")
	end)

	helpers.it("expander.lua wraps its notify_synthetic call site in a pcall", function()
		-- Selected by a declaration unique to modules/keymap/expander.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("function M.perform_text_replacement")
		helpers.assert_true(src ~= nil, "modules/keymap/expander.lua source must be locatable")

		helpers.assert_true(
			src:find("pcall(keylogger.notify_synthetic", 1, true) ~= nil,
			"expander.lua must call keylogger.notify_synthetic via pcall"
		)
	end)
end)
