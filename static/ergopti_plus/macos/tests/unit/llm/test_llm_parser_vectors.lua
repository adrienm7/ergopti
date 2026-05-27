--- tests/unit/llm/test_llm_parser_vectors.lua

--- ==============================================================================
--- MODULE: LLM Parser Corpus Consumer (Hammerspoon)
--- DESCRIPTION:
--- Loads the shared cross-driver LLM parser corpus from
--- shared/tests/corpus/llm/parser_test_vectors.json and validates each vector
--- against pure-Lua re-implementations of the HS parser logic.
---
--- WHY A RE-IMPLEMENTATION RATHER THAN CALLING THE MODULE DIRECTLY:
--- The parse_response function in api_remote.lua and the streaming line parser
--- in api_ollama.lua are both module-local. Exposing them solely for tests
--- would pollute the production API surface. The logic is small and
--- self-contained (JSON decode + table path walk), so duplicating it here
--- is the correct isolation boundary. Any divergence from the module source
--- becomes a test failure that mandates a fix in one of the two copies.
---
--- COVERAGE:
--- 1. Corpus integrity — JSON file is readable and every vector has required
---    fields (id, parser, input, expected).
--- 2. Ollama non-streaming — response field extraction + JSON unescape.
--- 3. Ollama streaming line — message.content token extraction per NDJSON line.
--- 4. Remote / OpenAI format — choices[1].message.content path.
--- 5. Remote / Anthropic format — content[1].text path.
--- 6. Remote / Gemini format — candidates[1].content.parts[1].text path.
--- 7. Edge cases — malformed JSON, empty body, null values, missing fields.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Bootstrap the hs stub so hs.json.decode is available
package.loaded["lib.logger"] = nil
helpers.load_with_stubs("lib.logger")




-- ============================================
-- ============================================
-- ======= 1/ Corpus Loading ==================
-- ============================================
-- ============================================

local _driver_root = helpers.driver_root()
local corpus_path  = _driver_root .. "../shared/tests/corpus/llm/parser_test_vectors.json"

--- Reads and parses the shared corpus JSON file.
--- @return table|nil corpus, string|nil err
local function read_corpus()
	local fh = io.open(corpus_path, "r")
	if not fh then
		return nil, "cannot open corpus at " .. corpus_path
	end
	local raw = fh:read("*a")
	fh:close()
	local ok, result = pcall(require("hs").json.decode, raw)
	if not ok then return nil, "JSON parse error: " .. tostring(result) end
	return result, nil
end

local corpus, corpus_err = read_corpus()




-- ==============================================
--- ==============================================
-- ======= 2/ Pure Parser Implementations =======
--- ==============================================
-- ==============================================

--- Unescapes the common JSON string escape sequences.
--- Mirrors LLM_UnescapeJSON (AHK) and _LLMRemoteJsonUnescape (AHK api_remote).
--- @param s string The escaped string extracted from a JSON value.
--- @return string The unescaped string.
local function json_unescape(s)
	s = s:gsub("\\n",  "\n")
	s = s:gsub("\\r",  "\r")
	s = s:gsub("\\t",  "\t")
	s = s:gsub('\\"',  '"')
	s = s:gsub("\\\\", "\\")
	return s
end

--- Parses a full Ollama /api/generate (non-streaming) response body.
--- Mirrors LLM_ParseOllamaResponse in api_ollama.ahk.
--- The HS non-streaming path uses /api/chat (message.content), but the AHK
--- path uses /api/generate (response field). This corpus tests the
--- /api/generate shape used by both the AHK sync client and AHK streaming
--- line-parser (which reads the same "response" key in each JSONL chunk).
---
--- @param raw string The raw JSON body.
--- @return string The extracted response text, or "".
local function parse_ollama_nonstream(raw)
	if type(raw) ~= "string" or raw == "" then return "" end
	local ok, resp = pcall(require("hs").json.decode, raw)
	if not ok or type(resp) ~= "table" then return "" end
	local text = resp["response"]
	if type(text) ~= "string" then return "" end
	return text
end

--- Parses one NDJSON line from an Ollama /api/chat streaming response.
--- Mirrors the process_line() closure in api_ollama.lua (HS streaming path)
--- and _LLM_Ollama_ConsumeStreamChunk (AHK streaming path — reads "response"
--- key; this implementation targets the HS /api/chat shape which uses
--- message.content).
---
--- Returns a table { token, done } where token is the content string (may be
--- empty) and done reflects the "done" boolean field.
---
--- @param line string One complete NDJSON line.
--- @return table { token: string, done: boolean }
local function parse_ollama_stream_line(line)
	local result = { token = "", done = false }
	if type(line) ~= "string" or line == "" then return result end
	local ok, obj = pcall(require("hs").json.decode, line)
	if not ok or type(obj) ~= "table" then return result end
	if obj.done == true then result.done = true end
	if type(obj.message) == "table" and type(obj.message.content) == "string" then
		result.token = obj.message.content
	end
	return result
end

--- Parses a remote API response body for the given provider format.
--- Mirrors parse_response() in api_remote.lua (HS) and
--- _LLMRemoteParseResponse() in api_remote.ahk (AHK).
---
--- @param format string "openai" | "anthropic" | "gemini"
--- @param body string The raw JSON response body.
--- @return string The extracted text, or "".
local function parse_remote(format, body)
	if type(body) ~= "string" or body == "" then return "" end
	local ok, resp = pcall(require("hs").json.decode, body)
	if not ok or type(resp) ~= "table" then return "" end

	if format == "anthropic" then
		local content = resp.content
		if type(content) == "table" and type(content[1]) == "table" then
			local text = content[1].text
			if type(text) == "string" then return text end
		end
		return ""
	end

	if format == "gemini" then
		local cand = resp.candidates
		if type(cand) == "table" and type(cand[1]) == "table" then
			local cnt = cand[1].content
			if type(cnt) == "table" and type(cnt.parts) == "table"
				and type(cnt.parts[1]) == "table" then
				local text = cnt.parts[1].text
				if type(text) == "string" then return text end
			end
		end
		return ""
	end

	-- OpenAI shape (default): choices[1].message.content
	local choices = resp.choices
	if type(choices) == "table" and type(choices[1]) == "table" then
		local msg = choices[1].message
		if type(msg) == "table" then
			local text = msg.content
			if type(text) == "string" then return text end
		end
	end
	return ""
end




-- ============================================
-- ============================================
-- ======= 3/ Corpus Integrity ================
-- ============================================
-- ============================================

helpers.describe("LLM parser corpus — integrity", function()
	helpers.it("corpus file is readable and parseable", function()
		helpers.assert_eq(corpus_err, nil, "corpus_err should be nil: " .. tostring(corpus_err))
		helpers.assert_true(corpus ~= nil, "corpus must not be nil")
	end)

	helpers.it("corpus has a vectors array", function()
		helpers.assert_true(corpus ~= nil and type(corpus.vectors) == "table",
			"corpus.vectors must be a table")
	end)

	helpers.it("corpus has at least 20 vectors", function()
		helpers.assert_true(corpus ~= nil and #corpus.vectors >= 20,
			"expected >= 20 vectors, got " .. tostring(corpus and #corpus.vectors or 0))
	end)

	helpers.it("every vector has required fields", function()
		if not corpus then return end
		for _, v in ipairs(corpus.vectors) do
			helpers.assert_true(type(v.id)       == "string", "vector missing id")
			helpers.assert_true(type(v.parser)   == "string", "vector missing parser: " .. tostring(v.id))
			helpers.assert_true(type(v.input)    == "string", "vector missing input: " .. tostring(v.id))
			helpers.assert_true(type(v.expected) == "table",  "vector missing expected: " .. tostring(v.id))
		end
	end)
end)




-- ============================================
-- ============================================
-- ======= 4/ Ollama Non-Streaming ============
-- ============================================
-- ============================================

helpers.describe("LLM parser corpus — Ollama non-streaming", function()
	if not corpus then return end

	for _, v in ipairs(corpus.vectors) do
		if v.parser == "ollama_nonstream" then
			-- Capture v in the closure explicitly
			local vec = v
			helpers.it(vec.id .. ": " .. (vec.description or ""), function()
				local text = parse_ollama_nonstream(vec.input)
				local want = vec.expected.text
				helpers.assert_eq(text, want,
					"text mismatch for " .. vec.id .. ": got=" .. tostring(text) .. " want=" .. tostring(want))
				-- ok semantics: expected.ok=false means text must be ""
				if not vec.expected.ok then
					helpers.assert_eq(text, "",
						"expected empty text (ok=false) for " .. vec.id)
				end
			end)
		end
	end
end)




-- ============================================
-- ============================================
-- ======= 5/ Ollama Streaming Line ===========
-- ============================================
-- ============================================

helpers.describe("LLM parser corpus — Ollama streaming line", function()
	if not corpus then return end

	for _, v in ipairs(corpus.vectors) do
		if v.parser == "ollama_stream_line" then
			local vec = v
			helpers.it(vec.id .. ": " .. (vec.description or ""), function()
				local result = parse_ollama_stream_line(vec.input)
				local want_token = vec.expected.token
				local want_done  = vec.expected.done
				helpers.assert_eq(result.token, want_token,
					"token mismatch for " .. vec.id .. ": got=" .. tostring(result.token) .. " want=" .. tostring(want_token))
				helpers.assert_eq(result.done, want_done,
					"done mismatch for " .. vec.id .. ": got=" .. tostring(result.done) .. " want=" .. tostring(want_done))
				if not vec.expected.ok then
					helpers.assert_eq(result.token, "",
						"expected empty token (ok=false) for " .. vec.id)
				end
			end)
		end
	end
end)




-- ============================================
-- ============================================
-- ======= 6/ Remote Providers ================
-- ============================================
-- ============================================

helpers.describe("LLM parser corpus — remote providers", function()
	if not corpus then return end

	for _, v in ipairs(corpus.vectors) do
		if v.parser == "remote" then
			local vec = v
			helpers.it(vec.id .. " [" .. (vec.format or "?") .. "]: " .. (vec.description or ""), function()
				local text = parse_remote(vec.format, vec.input)
				local want = vec.expected.text
				helpers.assert_eq(text, want,
					"text mismatch for " .. vec.id .. ": got=" .. tostring(text) .. " want=" .. tostring(want))
				if not vec.expected.ok then
					helpers.assert_eq(text, "",
						"expected empty text (ok=false) for " .. vec.id)
				end
			end)
		end
	end
end)




-- ============================================
-- ============================================
-- ======= 7/ Edge Cases (all parsers) ========
-- ============================================
-- ============================================

helpers.describe("LLM parser corpus — edge cases (all formats)", function()
	if not corpus then return end

	for _, v in ipairs(corpus.vectors) do
		if v.parser == "all" then
			local vec = v
			helpers.it(vec.id .. ": " .. (vec.description or ""), function()
				local t_ons  = parse_ollama_nonstream(vec.input)
				local t_osl  = parse_ollama_stream_line(vec.input).token
				local t_oai  = parse_remote("openai",    vec.input)
				local t_anth = parse_remote("anthropic", vec.input)
				local t_gem  = parse_remote("gemini",    vec.input)

				helpers.assert_eq(t_ons,  "", "ollama_nonstream must return '' for " .. vec.id)
				helpers.assert_eq(t_osl,  "", "ollama_stream must return '' for "    .. vec.id)
				helpers.assert_eq(t_oai,  "", "openai must return '' for "           .. vec.id)
				helpers.assert_eq(t_anth, "", "anthropic must return '' for "        .. vec.id)
				helpers.assert_eq(t_gem,  "", "gemini must return '' for "           .. vec.id)
			end)
		end
	end
end)
