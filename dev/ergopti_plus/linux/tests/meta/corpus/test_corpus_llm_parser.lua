--- tests/meta/corpus/test_corpus_llm_parser.lua

--- ==============================================================================
--- MODULE: LLM Reply Parser Corpus Consumer (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/llm/parser_test_vectors.json through the reply
--- extraction the Linux driver actually runs, api_remote.extract_text().
---
--- COVERAGE:
--- 1. remote/openai, remote/anthropic, remote/gemini: the completion text of a
---    provider reply, nothing on a malformed or error reply.
--- 2. all: every adversarial body yields no text in any of the three formats.
---
--- OUT OF SCOPE:
--- The Ollama vectors are scoped to the AutoHotkey and macOS drivers. Linux reads
--- Ollama as an NDJSON stream (api_ollama.lua), tested in its own unit file.
---
--- ROOT CAUSE ENCODED:
--- This corpus used to be skipped on Linux behind a guard that probed a module
--- named modules.llm.parser, which never existed, so the skip stayed green
--- while Linux parsed every remote reply with no shared vector behind it.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local CORPUS = helpers.driver_root() .. "/../_shared/tests/corpus/llm/parser_test_vectors.json"
local FORMATS = { "openai", "anthropic", "gemini" }

--- Reads and decodes the shared corpus.
--- @return table corpus
local function read_corpus()
	local fh = assert(io.open(CORPUS, "r"), "cannot open " .. CORPUS)
	local raw = fh:read("*a")
	fh:close()
	return assert(Json.decode(raw), "the parser corpus is not valid JSON")
end

--- A vector is in scope when it names no driver, or names linux.
--- @param vector table
--- @return boolean
local function in_scope(vector)
	if type(vector.driver) ~= "table" then return true end
	for _, driver in ipairs(vector.driver) do
		if driver == "linux" then return true end
	end
	return false
end

--- Loads api_remote over an HTTP client that refuses any traffic, then
--- unloads every module the load brought in, so no later test file inherits
--- a dependency bound to the refusing client.
--- @return table remote
local function load_remote()
	local before = {}
	for name in pairs(package.loaded) do before[name] = true end
	local saved_client = package.loaded["adapters.http_client"]
	package.loaded["adapters.http_client"] = {
		get = function() error("the parser corpus must not reach the network") end,
		post = function() error("the parser corpus must not reach the network") end,
		cancel = function() return true end,
	}
	local remote = helpers.load_module("modules.llm.api_remote")
	package.loaded["adapters.http_client"] = saved_client
	for name in pairs(package.loaded) do
		if not before[name] then package.loaded[name] = nil end
	end
	return remote
end

--- The text a format extracts, "" when it extracts none.
--- @param remote table
--- @param format string
--- @param body string
--- @return string
local function extract(remote, format, body)
	local text = remote.extract_text(format, body)
	if text == nil then return "" end
	return text
end

helpers.describe("llm parser corpus: Linux remote reply extraction", function()
	local corpus = read_corpus()
	local remote = load_remote()

	local replayed = 0
	for _, vector in ipairs(corpus.vectors) do
		if in_scope(vector) and (vector.parser == "remote" or vector.parser == "all") then
			replayed = replayed + 1
			helpers.it("vector '" .. vector.id .. "'", function()
				local expected_text = vector.expected.text or ""
				if vector.parser == "remote" then
					local text = extract(remote, vector.format, vector.input)
					helpers.assert_eq(text, expected_text, vector.id .. ": text")
					helpers.assert_eq(text ~= "", vector.expected.ok, vector.id .. ": ok")
				else
					for _, format in ipairs(FORMATS) do
						local text = extract(remote, format, vector.input)
						helpers.assert_eq(text ~= "", vector.expected.ok, vector.id .. ": ok in " .. format)
					end
				end
			end)
		end
	end

	helpers.it("replays every remote and adversarial vector of the corpus", function()
		local expected = 0
		for _, vector in ipairs(corpus.vectors) do
			if vector.parser == "remote" or vector.parser == "all" then expected = expected + 1 end
		end
		helpers.assert_true(expected >= 30, "the corpus lost its remote vectors")
		helpers.assert_eq(replayed, expected, "a remote vector was scoped away from Linux")
	end)
end)
