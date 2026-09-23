--- tests/unit/meta/test_corpus_diagnostics.lua

--- ==============================================================================
--- MODULE: Diagnostics Corpus Consumer (macOS)
--- DESCRIPTION:
--- Replays the shared diagnostics corpora against the shared Lua modules the
--- macOS driver runs, so this port and the AHK one are held to the same
--- golden vectors:
--- 1. _shared/tests/corpus/healthcheck/errors_tail_vectors.json through
---    healthcheck.snapshot.parse_errors_tail (the window's recent issues).
--- 2. _shared/tests/corpus/diagnostics/issue_link_vectors.json through
---    diagnostics.issue_link (the prefilled GitHub issue URL).
--- 3. _shared/tests/corpus/diagnostics/redaction_vectors.json through
---    diagnostics.redact with the rules of
---    _shared/modules/diagnostics/redaction.json (what leaves the machine).
--- Each corpus fails loudly when unreadable or empty: a replay over zero
--- vectors would report success while checking nothing.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

--- Reads and decodes one shared corpus.
--- @param rel string Path under _shared/.
--- @return table
local function read_corpus(rel)
	local path = helpers.shared(rel)
	local fh = io.open(path, "rb")
	if not fh then error("cannot open corpus at " .. path) end
	local raw = fh:read("*a")
	fh:close()
	local data = Json.decode(raw)
	if type(data) ~= "table" then error("corpus is not valid JSON: " .. path) end
	return data
end

--- Decodes a hex string into raw bytes.
--- @param hex string|nil
--- @return string
local function from_hex(hex)
	return ((hex or ""):gsub("%x%x", function(pair) return string.char(tonumber(pair, 16)) end))
end

helpers.describe("diagnostics corpus: errors-file tail (errors-tail-corpus)", function()
	local corpus = read_corpus("tests/corpus/healthcheck/errors_tail_vectors.json")
	local Snapshot = require("healthcheck.snapshot")

	helpers.it("has vectors (errors-tail-corpus)", function()
		helpers.assert_true(type(corpus.vectors) == "table" and #corpus.vectors >= 10,
			"the errors-tail corpus must hold its vectors")
	end)

	for _, vector in ipairs(corpus.vectors or {}) do
		helpers.it("parse_errors_tail: " .. vector.id .. " (errors-tail-corpus)", function()
			local input = vector.input
			local entries = Snapshot.parse_errors_tail(from_hex(input.prefix_hex) .. input.chunk,
				input.at_file_start, input.max_entries)
			helpers.assert_eq(entries, vector.expected, vector.id)
		end)
	end
end)

helpers.describe("diagnostics corpus: GitHub issue link (issue-link-corpus)", function()
	local corpus = read_corpus("tests/corpus/diagnostics/issue_link_vectors.json")
	local IssueLink = require("diagnostics.issue_link")

	helpers.it("has vectors (issue-link-corpus)", function()
		helpers.assert_true(type(corpus.encode_vectors) == "table" and #corpus.encode_vectors >= 5,
			"the issue-link corpus must hold its encoding vectors")
		helpers.assert_true(type(corpus.url_vectors) == "table" and #corpus.url_vectors >= 5,
			"the issue-link corpus must hold its URL vectors")
	end)

	for _, vector in ipairs(corpus.encode_vectors or {}) do
		helpers.it("percent_encode: " .. vector.id .. " (issue-link-corpus)", function()
			helpers.assert_eq(IssueLink.percent_encode(vector.input), vector.expected, vector.id)
		end)
	end

	for _, vector in ipairs(corpus.url_vectors or {}) do
		helpers.it("build_url: " .. vector.id .. " (issue-link-corpus)", function()
			local templates = {}
			for key, value in pairs(corpus.templates) do templates[key] = value end
			templates.max_url_bytes = vector.max_url_bytes
			local ok, url = pcall(IssueLink.build_url, templates, corpus.repository, vector.template, vector.values)
			if vector.expect_error then
				helpers.assert_eq(ok, false, vector.id .. ": an error was expected, got " .. tostring(url))
			else
				helpers.assert_true(ok, vector.id .. ": " .. tostring(url))
				helpers.assert_eq(url, vector.expected, vector.id)
			end
		end)
	end
end)

helpers.describe("diagnostics corpus: redaction (redaction-corpus)", function()
	local corpus = read_corpus("tests/corpus/diagnostics/redaction_vectors.json")
	local rules = read_corpus("modules/diagnostics/redaction.json")
	local Redact = require("diagnostics.redact")

	helpers.it("has vectors (redaction-corpus)", function()
		helpers.assert_true(type(corpus.vectors) == "table" and #corpus.vectors >= 10,
			"the redaction corpus must hold its vectors")
	end)

	for _, vector in ipairs(corpus.vectors or {}) do
		helpers.it("apply: " .. vector.id .. " (redaction-corpus)", function()
			helpers.assert_eq(Redact.apply(vector.input, rules, vector.context), vector.expected, vector.id)
		end)
	end
end)
