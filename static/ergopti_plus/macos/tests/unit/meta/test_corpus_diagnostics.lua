--- tests/unit/meta/test_corpus_diagnostics.lua

--- ==============================================================================
--- MODULE: Diagnostics Corpus Consumer (macOS)
--- DESCRIPTION:
--- Replays the shared diagnostics corpora against the shared Lua modules the
--- macOS driver runs, so this port and the AHK one are held to the same
--- golden vectors:
--- 1. _shared/tests/corpus/healthcheck/errors_tail_vectors.json through
---    healthcheck.snapshot.parse_errors_tail (the window's recent issues).
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
