--- tests/unit/meta/test_corpus_healthcheck_snapshot.lua

--- ==============================================================================
--- MODULE: Healthcheck Snapshot Corpus Consumer (macOS)
--- DESCRIPTION:
--- Loads the cross-driver snapshot corpus from
--- _shared/tests/corpus/healthcheck/snapshot_vectors.json and replays its Lua
--- categories through the shared healthcheck.snapshot module:
--- extract_recent_issues (the ring fallback of the recent warnings and
--- errors) and check_fields (the fields a driver produced that the schema does
--- not declare for it, and the declared synchronous ones it left out). The
--- AHK port replays check_fields too, and the page's model replays
--- format_uptime; the categories each consumer skips are counted, so a
--- category nobody replays cannot hide.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The categories this consumer replays, and those another consumer owns
local REPLAYED = { extract_recent_issues = true, check_fields = true }
local OWNED_ELSEWHERE = { format_uptime = "tools/test/test-healthcheck-model.cjs" }





-- ==================================
-- ==================================
-- ======= 1/ Corpus Loading ========
-- ==================================
-- ==================================

--- Reads and decodes the corpus.
--- @return table
local function read_corpus()
	local path = helpers.shared("tests/corpus/healthcheck/snapshot_vectors.json")
	local fh = io.open(path, "rb")
	if not fh then error("cannot open corpus at " .. path) end
	local raw = fh:read("*a")
	fh:close()
	local data = require("json").decode(raw)
	if type(data) ~= "table" then error("corpus is not valid JSON: " .. path) end
	return data
end

local corpus = read_corpus()





-- ====================================
-- ====================================
-- ======= 2/ Corpus Integrity ========
-- ====================================
-- ====================================

helpers.describe("healthcheck snapshot corpus — integrity", function()
	helpers.it("every vector belongs to a category someone replays", function()
		helpers.assert_true(type(corpus.vectors) == "table" and #corpus.vectors >= 10,
			"the snapshot corpus must hold its vectors")
		local counts = {}
		for _, vector in ipairs(corpus.vectors) do
			helpers.assert_true(type(vector.id) == "string" and vector.id ~= "", "a vector has no id")
			helpers.assert_true(REPLAYED[vector.category] or OWNED_ELSEWHERE[vector.category] ~= nil,
				vector.id .. " has the category " .. tostring(vector.category) .. ", which no consumer replays")
			counts[vector.category] = (counts[vector.category] or 0) + 1
		end
		for category in pairs(REPLAYED) do
			helpers.assert_true((counts[category] or 0) >= 4, category .. " holds fewer than 4 vectors")
		end
	end)
end)





-- ===================================
-- ===================================
-- ======= 3/ Vector Replay ==========
-- ===================================
-- ===================================

helpers.describe("healthcheck snapshot corpus — vector replay", function()
	package.loaded["healthcheck.snapshot"] = nil
	local Snapshot = require("healthcheck.snapshot")

	for _, vector in ipairs(corpus.vectors) do
		if vector.category == "extract_recent_issues" then
			helpers.it("extract_recent_issues: " .. vector.id, function()
				helpers.assert_eq(Snapshot.extract_recent_issues(vector.input.lines, vector.input.max_lines),
					vector.expected, vector.id)
			end)
		elseif vector.category == "check_fields" then
			helpers.it("check_fields: " .. vector.id, function()
				local undeclared, missing = Snapshot.check_fields(vector.snapshot, corpus.check_fields_schema)
				helpers.assert_eq(undeclared, vector.expected_undeclared, vector.id .. " undeclared")
				helpers.assert_eq(missing, vector.expected_missing, vector.id .. " missing")
			end)
		end
	end
end)
