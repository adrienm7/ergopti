--- static/ergopti_plus/linux/tests/unit/meta/test_shared_hotstring_engine.lua

--- ==============================================================================
--- MODULE: Shared Hotstring Engine — Unit Tests (Linux)
--- DESCRIPTION:
--- Validates that the shared hotstring engine at _shared/lua/hotstring_engine/
--- is accessible from the Linux driver and that its core matching algorithm
--- behaves correctly — providing a smoke test that the path resolution in the
--- engine.lua thin re-export works end-to-end.
---
--- The full cross-driver corpus tests live in:
---   tests/unit/meta/test_port_adapter_presence.lua
--- This file focuses on functional correctness of the shared engine.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =========================================
-- =========================================
-- ======= 1/ Engine Bootstrap =============
-- =========================================
-- =========================================

--- Resolves the path to _shared/lua/ from this test file's location.
--- @return string|nil Absolute or relative path to _shared/lua/, or nil on failure.
local function shared_lua_path()
	local this = debug.getinfo(1, "S").source:gsub("^@", "")
	-- Navigate: tests/unit/meta/ → tests/ → linux/ → _shared/lua/
	local linux_root = this:match("^(.*[/\\])tests[/\\]")
	if not linux_root then return nil end
	return linux_root .. "../../_shared/lua"
end

-- Bootstrap: inject _shared/lua/ into package.path before requiring the engine.
local _shared = shared_lua_path()
if _shared then
	local entry = _shared .. "/?.lua"
	if not package.path:find(entry, 1, true) then
		package.path = entry .. ";" .. package.path
	end
end

local engine_mod = require("hotstring_engine")




-- =========================================
-- =========================================
-- ======= 2/ Suffix Matching ==============
-- =========================================
-- =========================================

helpers.describe("shared hotstring engine — suffix matching", function()
	helpers.it("basic trigger is matched at end of buffer", function()
		local e = engine_mod.new()
		e:load_mappings({ { auto_expand = true, trigger = "btw", replacement = "by the way" } })
		local result
		for _, ch in ipairs({"b", "t", "w"}) do
			result = e:on_char(ch)
		end
		helpers.assert_true(result ~= nil, "should match 'btw'")
		helpers.assert_eq("btw",        result.trigger,     "trigger")
		helpers.assert_eq("by the way", result.replacement, "replacement")
	end)

	helpers.it("no match when trigger is not at buffer tail", function()
		local e = engine_mod.new()
		e:load_mappings({ { auto_expand = true, trigger = "btw", replacement = "by the way" } })
		local result
		for _, ch in ipairs({"b", "t", "w", "x"}) do
			result = e:on_char(ch)
		end
		helpers.assert_true(result == nil, "should not match after extra char")
	end)

	helpers.it("longer trigger wins over shorter (longest-match-first)", function()
		local e = engine_mod.new()
		e:load_mappings({
			{ auto_expand = true, trigger = "btw",  replacement = "short" },
			{ auto_expand = true, trigger = "btww", replacement = "long"  },
		})
		local result
		for _, ch in ipairs({"b", "t", "w", "w"}) do
			result = e:on_char(ch)
		end
		helpers.assert_true(result ~= nil, "should match")
		helpers.assert_eq("btww", result.trigger, "longer trigger must win")
	end)
end)




-- =========================================
-- =========================================
-- ======= 3/ Word Boundary ================
-- =========================================
-- =========================================

helpers.describe("shared hotstring engine — word boundary", function()
	helpers.it("is_word trigger blocked mid-word", function()
		local e = engine_mod.new()
		e:load_mappings({ { auto_expand = true, trigger = "the", replacement = "X", is_word = true } })
		local result
		for _, ch in ipairs({"o", "t", "h", "e"}) do
			result = e:on_char(ch)
		end
		helpers.assert_true(result == nil, "should not match mid-word")
	end)

	helpers.it("is_word trigger matches after space", function()
		local e = engine_mod.new()
		e:load_mappings({ { auto_expand = true, trigger = "the", replacement = "X", is_word = true } })
		local result
		for _, ch in ipairs({" ", "t", "h", "e"}) do
			result = e:on_char(ch)
		end
		helpers.assert_true(result ~= nil, "should match after space")
	end)
end)




-- =========================================
-- =========================================
-- ======= 4/ Backspace Count ==============
-- =========================================
-- =========================================

helpers.describe("shared hotstring engine — backspace count", function()
	helpers.it("backspace_count = tlen without terminator", function()
		local e = engine_mod.new()
		e:load_mappings({ { auto_expand = true, trigger = "btw", replacement = "by the way" } })
		local result
		for _, ch in ipairs({"b", "t", "w"}) do
			result = e:on_char(ch, { terminator_consumed = false })
		end
		helpers.assert_true(result ~= nil, "match required")
		helpers.assert_eq(3, result.backspace_count, "tlen = 3")
	end)

	helpers.it("backspace_count = tlen + 1 with terminator consumed", function()
		local e = engine_mod.new()
		e:load_mappings({ { auto_expand = true, trigger = "btw", replacement = "by the way" } })
		-- Simulate trigger typed, then terminator typed but consumed.
		e:on_char("b")
		e:on_char("t")
		local result = e:on_char("w", { terminator_consumed = true })
		helpers.assert_true(result ~= nil, "match required")
		helpers.assert_eq(4, result.backspace_count, "tlen + 1 = 4")
	end)
end)




-- =========================================
-- =========================================
-- ======= 5/ Case Sensitivity =============
-- =========================================
-- =========================================

helpers.describe("shared hotstring engine — case sensitivity", function()
	helpers.it("default is case-insensitive", function()
		local e = engine_mod.new()
		e:load_mappings({ { auto_expand = true, trigger = "btw", replacement = "by the way" } })
		local result
		for _, ch in ipairs({"B", "T", "W"}) do
			result = e:on_char(ch)
		end
		helpers.assert_true(result ~= nil, "uppercase input should match lowercase trigger")
	end)

	helpers.it("is_case_sensitive rejects wrong case", function()
		local e = engine_mod.new()
		e:load_mappings({ { auto_expand = true, trigger = "BTW", replacement = "by the way", is_case_sensitive = true } })
		local result
		for _, ch in ipairs({"b", "t", "w"}) do
			result = e:on_char(ch)
		end
		helpers.assert_true(result == nil, "lowercase should not match case-sensitive uppercase trigger")
	end)

	helpers.it("is_case_sensitive accepts correct case", function()
		local e = engine_mod.new()
		e:load_mappings({ { auto_expand = true, trigger = "BTW", replacement = "by the way", is_case_sensitive = true } })
		local result
		for _, ch in ipairs({"B", "T", "W"}) do
			result = e:on_char(ch)
		end
		helpers.assert_true(result ~= nil, "exact case should match")
	end)
end)




-- =========================================
-- =========================================
-- ======= 6/ Reset ========================
-- =========================================
-- =========================================

helpers.describe("shared hotstring engine — buffer reset", function()
	helpers.it("reset clears buffer so trigger no longer matches", function()
		local e = engine_mod.new()
		e:load_mappings({ { auto_expand = true, trigger = "btw", replacement = "by the way" } })
		e:on_char("b")
		e:on_char("t")
		e:reset()
		local result = e:on_char("w")
		helpers.assert_true(result == nil, "after reset, partial buffer is cleared — no match")
	end)
end)





-- ==================================================
-- ==================================================
-- ======= 9/ final_result and chaining =============
-- ==================================================
-- ==================================================

-- Linux reset the buffer after every expansion, so nothing could ever chain and
-- final_result was unobservable — while Windows and macOS both keep the expanded
-- text and let a later keystroke complete a further trigger. apply_expansion is
-- what closes that; reset() stays for the final case.

--- Feeds a string, applying each expansion the way the driver does.
--- @return table|nil last result, table engine
local function _fr_drive(mappings, text)
	local e = engine_mod.new()
	e:load_mappings(mappings)
	local last
	for ch in text:gmatch(".") do
		local r = e:on_char(ch, {})
		if r then
			last = r
			if r.final_result then e:reset() else e:apply_expansion(r) end
		end
	end
	return last, e
end

helpers.describe("shared hotstring engine — final_result governs chaining", function()
	helpers.it("a non-final expansion stays in the buffer and can chain", function()
		local _, e = _fr_drive({
			{ trigger = "sig", replacement = "JD", auto_expand = true, final_result = false },
		}, "sig")
		helpers.assert_eq("JD", e:current_buffer(),
			"the replacement must remain in the buffer — resetting here is what stopped Linux chaining")
	end)

	helpers.it("the chained trigger fires on the next keystroke", function()
		local last = _fr_drive({
			{ trigger = "sig", replacement = "JD",       auto_expand = true, final_result = false },
			{ trigger = "JDx", replacement = "John Doe", auto_expand = true, final_result = false },
		}, "sigx")
		helpers.assert_true(last ~= nil and last.replacement == "John Doe",
			"the second trigger must complete off the first expansion's output")
	end)

	helpers.it("final_result clears the buffer so nothing chains", function()
		local last, e = _fr_drive({
			{ trigger = "sig", replacement = "JD",       auto_expand = true, final_result = true },
			{ trigger = "JDx", replacement = "John Doe", auto_expand = true },
		}, "sigx")
		helpers.assert_eq("x", e:current_buffer(), "only the post-expansion keystroke may remain")
		helpers.assert_true(last ~= nil and last.replacement == "JD",
			"the chained trigger must NOT fire when the first expansion is final")
	end)

	helpers.it("apply_expansion never re-enters matching", function()
		-- A replacement containing its own trigger would loop if apply_expansion
		-- re-ran the matcher. Chaining is deferred to the next real keystroke
		-- precisely so this cannot happen.
		local _, e = _fr_drive({
			{ trigger = "ab", replacement = "xaby", auto_expand = true, final_result = false },
		}, "ab")
		helpers.assert_eq("xaby", e:current_buffer(),
			"one expansion only — a self-containing replacement must not recurse")
	end)
end)





-- ======================================================
-- ======================================================
-- ======= 10/ French typographic ":" and ";" ===========
-- ======================================================
-- ======================================================

-- The Ergopti layer emits ":" and ";" as NNBSP+":" / NNBSP+";", so the no-break
-- space lands between the trigger and the terminator. Windows strips it in
-- hotstring_match.ahk and macOS in expander.lua; Linux did neither, so a trigger
-- followed by a typographic colon never fired there.

local _NNBSP = string.char(0xE2, 0x80, 0xAF)  -- U+202F narrow no-break space
local _NBSP  = string.char(0xC2, 0xA0)        -- U+00A0 no-break space

--- Feeds an explicit list of characters, marking " ", ":" and ";" as terminators.
--- @param chars table Array of single-character strings.
local function _typo_play(mappings, chars)
	local e = engine_mod.new()
	e:load_mappings(mappings)
	for _, ch in ipairs(chars) do
		local r = e:on_char(ch, { is_terminator = (ch == " " or ch == ":" or ch == ";") })
		if r then return r end
	end
	return nil
end

--- Splits an ASCII word into single characters, then appends the given tail.
local function _chars(word, ...)
	local out = {}
	for i = 1, #word do out[#out + 1] = word:sub(i, i) end
	for _, extra in ipairs({ ... }) do out[#out + 1] = extra end
	return out
end

helpers.describe("shared hotstring engine — typographic ':' and ';'", function()
	local AFAIK = { trigger = "afaik", replacement = "as far as I know", auto_expand = false }

	helpers.it("a trigger followed by NNBSP + ':' fires", function()
		helpers.assert_true(_typo_play({ AFAIK }, _chars("afaik", _NNBSP, ":")) ~= nil,
			"the narrow no-break space must be looked past, not treated as text")
	end)

	helpers.it("the stripped space is counted as replaced", function()
		local r = _typo_play({ AFAIK }, _chars("afaik", _NNBSP, ":"))
		-- 5 trigger + 1 terminator + 1 nbsp: all three sit between the trigger's
		-- start and the caret, so all three are replaced.
		helpers.assert_eq(7, r and r.backspace_count,
			"backspace_count must cover the trigger, the terminator AND the stripped space")
	end)

	helpers.it("the full no-break space works too", function()
		helpers.assert_true(_typo_play({ AFAIK }, _chars("afaik", _NBSP, ";")) ~= nil,
			"U+00A0 must behave like U+202F")
	end)

	helpers.it("a BARE ':' does not end a hotstring", function()
		-- The ":" of ":D" is mid-sequence text. Requiring the space is what keeps
		-- an emoticon from triggering an expansion.
		helpers.assert_true(_typo_play({ AFAIK }, _chars("afaik", ":")) == nil,
			"a colon with no no-break space before it must not fire the end-char path")
	end)

	helpers.it("an auto trigger ending in ':' is untouched by the rule", function()
		-- The rule belongs to the end-char path only; Windows leaves its star path
		-- alone, and a trigger whose own last codepoint is ":" must still fire.
		local r = _typo_play({ { trigger = "todo:", replacement = "TODO:", auto_expand = true } },
			_chars("todo", ":"))
		helpers.assert_true(r ~= nil and r.replacement == "TODO:",
			"a star trigger ending in ':' must fire on its own last character")
	end)
end)
