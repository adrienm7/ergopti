--- tests/unit/meta/test_corpus_llm_parser.lua

--- ==============================================================================
--- MODULE: LLM Parser Corpus Consumer (Hammerspoon)
--- DESCRIPTION:
--- Loads the shared cross-driver corpus from
--- _shared/tests/corpus/llm/parser_test_vectors.json and validates the
--- Hammerspoon LLM response parsers against every vector scoped to this driver.
---
--- COVERAGE:
--- 1. ollama_nonstream  — Ollama /api/chat format: resp.message.content.
---    (driver=macos vectors only; driver=ahk vectors use /api/generate format.)
--- 2. remote/openai     — choices[1].message.content extraction.
--- 3. remote/anthropic  — content[1].text extraction.
--- 4. remote/gemini     — candidates[1].content.parts[1].text extraction.
--- 5. all               — all parsers tested on adversarial / malformed input.
---
--- SKIPPED:
--- - ollama_stream_line  — async streaming callback; tested in api_ollama unit.
--- - driver=ahk vectors  — /api/generate format not used on macOS.
---
--- INLINE PARSERS:
--- The remote parse logic mirrors api_remote.lua's private parse_response().
--- The ollama chat parser mirrors api_ollama.lua's non-streaming extraction.
--- Both are replicated inline (not imported) because they are private to their
--- respective modules, and the corpus test must not change the module API.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ========================================
-- ========================================
-- ======= 1/ Corpus file loading =========
-- ========================================
-- ========================================

local corpus_path = helpers.shared("tests/corpus/llm/parser_test_vectors.json")

local function read_corpus()
	local fh = io.open(corpus_path, "r")
	if not fh then
		return nil, "cannot open corpus at " .. corpus_path
	end
	local raw = fh:read("*a")
	fh:close()
	package.loaded["infra.logger"] = nil
	helpers.load_with_stubs("infra.logger")
	local ok, result = pcall(require("hs").json.decode, raw)
	if not ok then return nil, "JSON parse error: " .. tostring(result) end
	return result, nil
end

local corpus_root, corpus_err = read_corpus()





-- ============================================
-- ============================================
-- ======= 2/ Inline parser definitions =======
-- ============================================
-- ============================================

--- Parses an Ollama /api/chat non-streaming response body.
--- Mirrors the extraction in api_ollama.lua (resp.message.content).
--- @param body string Raw JSON response body.
--- @return string Extracted assistant content, or "" on failure.
local function parse_ollama_chat(body)
	if type(body) ~= "string" or body == "" then return "" end
	local ok_j, resp = pcall(require("hs").json.decode, body)
	if not ok_j or type(resp) ~= "table" then return "" end
	if type(resp.message) ~= "table" then return "" end
	local content = resp.message.content
	if type(content) ~= "string" then return "" end
	return content
end

--- Parses a remote provider response body given its format name.
--- Mirrors api_remote.lua's private parse_response(format, body).
--- @param format string "openai", "anthropic", or "gemini".
--- @param body string Raw JSON response body.
--- @return string Extracted assistant text, or "" on failure.
local function parse_remote(format, body)
	if type(body) ~= "string" or body == "" then return "" end
	local ok_j, resp = pcall(require("hs").json.decode, body)
	if not ok_j or type(resp) ~= "table" then return "" end

	if format == "anthropic" then
		local content = resp.content
		if type(content) == "table" and type(content[1]) == "table" then
			return tostring(content[1].text or "")
		end
		return ""
	end

	if format == "gemini" then
		local cand = resp.candidates
		if type(cand) == "table" and type(cand[1]) == "table" then
			local cnt = cand[1].content
			if type(cnt) == "table"
			and type(cnt.parts) == "table"
			and type(cnt.parts[1]) == "table" then
				return tostring(cnt.parts[1].text or "")
			end
		end
		return ""
	end

	-- OpenAI (default)
	local choices = resp.choices
	if type(choices) == "table" and type(choices[1]) == "table" then
		local msg = choices[1].message
		if type(msg) == "table" then return tostring(msg.content or "") end
	end
	return ""
end

--- Dispatches a corpus vector to the correct inline parser.
--- Returns text (string) and ok (bool).
--- @param vec table A single corpus vector object.
--- @return string, boolean Extracted text, whether text is non-empty.
local function dispatch(vec)
	local parser = vec.parser or ""
	local input  = vec.input  or ""
	local fmt    = vec.format or ""

	if parser == "ollama_nonstream" then
		local text = parse_ollama_chat(input)
		return text, text ~= ""
	end

	if parser == "remote" then
		local text = parse_remote(fmt, input)
		return text, text ~= ""
	end

	if parser == "all" then
		-- All parsers must return "" on adversarial inputs.
		local r1 = parse_ollama_chat(input)
		local r2 = parse_remote("openai",    input)
		local r3 = parse_remote("anthropic", input)
		local r4 = parse_remote("gemini",    input)
		local all_empty = r1 == "" and r2 == "" and r3 == "" and r4 == ""
		local best = r1 ~= "" and r1 or r2 ~= "" and r2 or r3 ~= "" and r3 or r4
		return tostring(best), not all_empty
	end

	-- Unrecognised parser — return empty so the test skips gracefully.
	return "", false
end

--- Returns true if a corpus vector is in scope for the macOS driver.
--- A vector is in scope when it has no "driver" field (universal), or when
--- its "driver" array contains "macos".
--- @param vec table A single corpus vector object.
--- @return boolean
local function in_scope(vec)
	if type(vec.driver) ~= "table" then return true end
	for _, d in ipairs(vec.driver) do
		if d == "macos" then return true end
	end
	return false
end




-- ======================================
-- ======================================
-- ======= 3/ Corpus integrity ==========
-- ======================================
-- ======================================

helpers.describe("llm_parser corpus — integrity", function()
	helpers.it("corpus file is readable and parseable", function()
		helpers.assert_true(corpus_root ~= nil,
			"corpus load error: " .. tostring(corpus_err))
		helpers.assert_true(type(corpus_root) == "table",
			"corpus root must be a table")
		helpers.assert_true(type(corpus_root.vectors) == "table",
			"corpus.vectors must be a table")
		helpers.assert_true(#corpus_root.vectors > 0,
			"corpus must have at least one vector")
	end)

	helpers.it("every vector has required fields: id, parser, input, expected", function()
		if not corpus_root then return end
		for _, v in ipairs(corpus_root.vectors) do
			helpers.assert_true(type(v.id) == "string" and v.id ~= "",
				"vector missing id field")
			helpers.assert_true(type(v.parser) == "string" and v.parser ~= "",
				"vector '" .. tostring(v.id) .. "' missing parser")
			helpers.assert_true(type(v.input) == "string",
				"vector '" .. tostring(v.id) .. "' missing input (must be string)")
			helpers.assert_true(type(v.expected) == "table",
				"vector '" .. tostring(v.id) .. "' missing expected table")
		end
	end)

	helpers.it("at least one macos-scoped ollama_nonstream vector is present", function()
		if not corpus_root then return end
		local found = false
		for _, v in ipairs(corpus_root.vectors) do
			if v.parser == "ollama_nonstream" and in_scope(v) then
				found = true
				break
			end
		end
		helpers.assert_true(found,
			"corpus has no macos-scoped ollama_nonstream vectors")
	end)
end)




-- ===========================================
-- ===========================================
-- ======= 4/ Parser vector execution =========
-- ===========================================
-- ===========================================

helpers.describe("llm_parser corpus — parser vectors", function()
	helpers.it("every in-scope vector passes the parser contract", function()
		if not corpus_root then return end
		for _, v in ipairs(corpus_root.vectors) do
			-- Skip streaming vectors (async callback loop, not testable here).
			if v.parser == "ollama_stream_line" then goto continue end
			-- Skip vectors not scoped to this driver.
			if not in_scope(v) then goto continue end

			local exp_text = type(v.expected) == "table" and v.expected.text or ""
			local exp_ok   = type(v.expected) == "table" and v.expected.ok   or false

			local act_text, act_ok = dispatch(v)

			helpers.assert_eq(act_text, tostring(exp_text),
				"[corpus:" .. v.id .. "] text mismatch")
			helpers.assert_eq(act_ok, exp_ok,
				"[corpus:" .. v.id .. "] ok mismatch (expected "
				.. tostring(exp_ok) .. ", got " .. tostring(act_ok) .. ")")

			::continue::
		end
	end)
end)
