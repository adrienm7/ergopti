--- tests/unit/meta/test_llm_thinking_filter.lua

--- ==============================================================================
--- MODULE: Streaming Thinking-Filter Regression Test (Linux driver)
--- DESCRIPTION:
--- Regression guard for the blocker where a reasoning model's <think>…</think>
--- block was typed into the user's document on Linux.
---
--- The Linux driver never loaded the shared parser, so nothing stripped thinking
--- tags. Worse, the streaming path injects each delta immediately
--- (`sender.send(delta)` inside on_chunk), so applying strip_thinking to the
--- completed response would have been too late — the block was already on screen,
--- character by character.
---
--- The fix is Parser.new_thinking_filter(), an incremental filter that withholds
--- any tail which could still be the start of a tag, so a tag split across two
--- chunks is recognised. These tests exercise that filter directly and assert the
--- engine is wired to it.
---
--- FEATURES & RATIONALE:
--- 1. Chunk-boundary coverage: the interesting case is "<thi" + "nk>hidden</think>",
---    which a naive per-chunk gsub cannot handle. Split at every offset so no
---    boundary is untested.
--- 2. Unterminated block: a truncated thinking block must emit nothing rather than
---    leak its prefix.
--- 3. Wiring assertion strips comments first — otherwise commenting the filter out
---    would leave the searched text intact and the guard would pass.
--- ==============================================================================

local helpers = require("tests.helpers")

local DRIVER_ROOT = helpers.driver_root()

--- Feeds a whole response through a fresh filter in the given chunk sizes.
--- @param text string Full model response.
--- @param chunks table Array of strings whose concatenation is `text`.
--- @return string Everything the filter allowed through.
local function run_stream(Parser, chunks)
	local f = Parser.new_thinking_filter()
	local out = {}
	for _, c in ipairs(chunks) do out[#out + 1] = f:feed(c) end
	out[#out + 1] = f:flush()
	return table.concat(out)
end

--- Splits a string into chunks of at most n characters.
local function split_every(s, n)
	local parts = {}
	for i = 1, #s, n do parts[#parts + 1] = s:sub(i, i + n - 1) end
	return parts
end

--- Reads a file or returns nil.
local function read_file(path)
	local fh = io.open(path, "r")
	if not fh then return nil end
	local c = fh:read("*a")
	fh:close()
	return c
end

--- Drops fully-commented Lua lines so a commented-out call cannot satisfy a scan.
local function strip_comment_lines(src)
	local kept = {}
	for line in (src .. "\n"):gmatch("([^\n]*)\n") do
		if not line:match("^%s*%-%-") then kept[#kept + 1] = line end
	end
	return table.concat(kept, "\n")
end




-- ==================================================
-- ==================================================
-- ======= 1/ The filter removes thinking ===========
-- ==================================================
-- ==================================================

helpers.describe("llm thinking filter — whole-chunk cases", function()
	local Parser = helpers.load_module("llm.parser")

	helpers.it("passes text through untouched when there is no tag", function()
		helpers.assert_eq(run_stream(Parser, { "hello ", "world" }), "hello world")
	end)

	helpers.it("removes a complete thinking block", function()
		helpers.assert_eq(
			run_stream(Parser, { "<think>secret reasoning</think>answer" }),
			"answer")
	end)

	helpers.it("keeps text before and after the block", function()
		helpers.assert_eq(
			run_stream(Parser, { "before<think>hidden</think>after" }),
			"beforeafter")
	end)

	helpers.it("emits nothing for an unterminated block", function()
		-- A truncated stream must not leak the prefix of the reasoning.
		helpers.assert_eq(run_stream(Parser, { "<think>still thinking" }), "")
	end)

	helpers.it("handles two blocks in one response", function()
		helpers.assert_eq(
			run_stream(Parser, { "a<think>x</think>b<think>y</think>c" }),
			"abc")
	end)
end)




-- ======================================================
-- ======================================================
-- ======= 2/ Tags split across chunk boundaries ========
-- ======================================================
-- ======================================================

helpers.describe("llm thinking filter — chunk boundaries", function()
	local Parser = helpers.load_module("llm.parser")

	helpers.it("catches a tag split at every possible offset", function()
		local full = "before<think>hidden reasoning</think>the answer"
		for cut = 1, #full - 1 do
			local chunks = { full:sub(1, cut), full:sub(cut + 1) }
			helpers.assert_eq(run_stream(Parser, chunks), "beforethe answer",
				"split after " .. cut .. " char(s) must still strip the block")
		end
	end)

	helpers.it("survives one-character-at-a-time streaming", function()
		local full = "x<think>y</think>z"
		helpers.assert_eq(run_stream(Parser, split_every(full, 1)), "xz")
	end)

	helpers.it("does not withhold text that only looks like a tag start", function()
		-- "<thi" that never becomes "<think>" must eventually be emitted.
		helpers.assert_eq(run_stream(Parser, { "a<thi", "ng b" }), "a<thing b")
	end)

	helpers.it("emits a lone < that never opens a tag", function()
		helpers.assert_eq(run_stream(Parser, { "1 <", " 2" }), "1 < 2")
	end)
end)




-- =========================================================
-- =========================================================
-- ======= 3/ The engine is wired to the filter ============
-- =========================================================
-- =========================================================

helpers.describe("llm thinking filter — engine wiring", function()
	local raw = read_file(DRIVER_ROOT .. "/modules/llm/prediction_engine.lua")
	local src = raw and strip_comment_lines(raw) or nil

	helpers.it("the engine source is readable", function()
		helpers.assert_not_nil(src, "prediction_engine.lua must be readable")
	end)

	helpers.it("the engine requires the shared parser", function()
		helpers.assert_contains(src, 'require("llm.parser")',
			"Linux must load the shared parser — not loading it is the root cause")
	end)

	helpers.it("the engine builds a filter per request", function()
		helpers.assert_contains(src, "Parser.new_thinking_filter()",
			"a per-request filter is required to carry state across chunks")
	end)

	helpers.it("the streaming callback filters before injecting", function()
		-- The injection must consume the filter's output, never the raw delta.
		helpers.assert_contains(src, "think_filter:feed(delta)",
			"on_chunk must pass the delta through the filter")
		helpers.assert_true(not src:find("sender.send(delta", 1, true),
			"on_chunk must never inject the raw delta — that is what typed the " ..
			"thinking block into the document")
	end)

	helpers.it("the completed text is stripped as well", function()
		helpers.assert_contains(src, "Parser.strip_thinking(full_text)",
			"non-streaming consumers must receive a stripped response too")
	end)
end)
