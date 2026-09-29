--- tests/unit/modules/gestures/test_file_selection_vectors.lua

--- ==============================================================================
--- MODULE: File-manager selection parsers replay the shared vectors (macOS)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/file_selection/vectors.json, which the Linux
--- suite replays too, against _shared/lua/file_selection: the Finder selection
--- as `osascript -ss` prints it, and a text/uri-list selection.
---
--- ROOT CAUSE ENCODED:
--- The file-selection actions change permissions and security attributes. A
--- parser that splits Finder's output on line breaks acts on a truncated path
--- when a name holds one, and a lenient uri-list reader acts on part of a
--- selection it could not fully read; both must refuse instead.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")
local FileSelection = require("file_selection")

local CORPUS = helpers.shared("tests/corpus/file_selection/vectors.json")

--- @return table The decoded corpus.
local function read_corpus()
	local fh = assert(io.open(CORPUS, "r"), "cannot open " .. CORPUS)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), "the file-selection corpus is not valid JSON")
end

--- Replays one family of vectors through one parser.
--- @param vectors table
--- @param parse function
--- @param family string
local function replay(vectors, parse, family)
	for _, vector in ipairs(vectors) do
		helpers.it(family .. " vector '" .. vector.id .. "'", function()
			local paths, reason = parse(vector.text)
			if vector.refused == true then
				helpers.assert_eq(paths, nil, vector.id .. ": the report must be refused")
				helpers.assert_true(type(reason) == "string" and reason ~= "",
					vector.id .. ": a refusal names its reason")
			else
				helpers.assert_eq(reason, nil, vector.id .. ": no refusal")
				helpers.assert_eq(paths, vector.paths, vector.id .. ": paths")
			end
		end)
	end
end

helpers.describe("file-selection parsers replay the shared corpus (macOS)", function()
	local corpus = read_corpus()

	helpers.it("the corpus holds both families", function()
		helpers.assert_true(#corpus.applescript >= 10, "the AppleScript family must hold its vectors")
		helpers.assert_true(#corpus.uri_list >= 10, "the uri-list family must hold its vectors")
	end)

	replay(corpus.applescript, FileSelection.parse_applescript_paths, "AppleScript")
	replay(corpus.uri_list, FileSelection.parse_uri_list, "uri-list")
end)
