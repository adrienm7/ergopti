--- tests/unit/modules/test_file_selection_vectors.lua

--- ==============================================================================
--- MODULE: File-manager selection parsers replay the shared vectors (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/file_selection/vectors.json, which the macOS
--- suite replays too, against _shared/lua/file_selection under the Linux
--- runtime (LuaJIT in CI): the text/uri-list a file manager publishes for a
--- copied selection, and the Finder report the same module parses.
---
--- ROOT CAUSE ENCODED:
--- make_executable_selection changes permissions: a uri-list reader that
--- skipped a line it could not read would act on part of the selection, and a
--- lenient decoder would chmod a path the file manager never named.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")
local FileSelection = require("file_selection")

local CORPUS = helpers.driver_root() .. "/../_shared/tests/corpus/file_selection/vectors.json"

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
				helpers.assert_eq(#paths, #vector.paths, vector.id .. ": path count")
				for index, expected in ipairs(vector.paths) do
					helpers.assert_eq(paths[index], expected, vector.id .. ": path " .. index)
				end
			end
		end)
	end
end

helpers.describe("file-selection parsers replay the shared corpus (Linux)", function()
	local corpus = read_corpus()

	helpers.it("the corpus holds both families", function()
		helpers.assert_true(#corpus.applescript >= 10, "the AppleScript family must hold its vectors")
		helpers.assert_true(#corpus.uri_list >= 10, "the uri-list family must hold its vectors")
	end)

	replay(corpus.uri_list, FileSelection.parse_uri_list, "uri-list")
	replay(corpus.applescript, FileSelection.parse_applescript_paths, "AppleScript")
end)
