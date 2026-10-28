--- _shared/lua/test/hotpath_nesting_replay.lua

--- ==============================================================================
--- MODULE: Hot-path Nesting Vectors Replay
--- DESCRIPTION:
--- Replays _shared/tests/corpus/diagnostics/hotpath_nesting_vectors.json
--- through the shared nesting tracker (hotpath_segments.new_nesting). The macOS
--- and Linux suites both register it, so the two drivers attribute a slow
--- segment to the same parent with the same own time.
--- ==============================================================================

local M = {}

--- Registers the replay on one driver's suite.
--- @param helpers table The driver's test helpers.
--- @param options table { driver = string, corpus = string (the vectors' JSON text) }
function M.register(helpers, options)
	assert(type(options) == "table" and type(options.driver) == "string" and type(options.corpus) == "string",
		"the nesting replay needs a driver name and the corpus text")
	local corpus = require("json").decode(options.corpus)
	local Segments = require("hotpath_segments")

	helpers.describe("hot-path nesting vectors: " .. options.driver, function()
		helpers.it("corpus is readable and has cases", function()
			helpers.assert_true(type(corpus.cases) == "table" and #corpus.cases > 0, "the corpus must hold cases")
		end)

		for _, case in ipairs(corpus.cases) do
			helpers.it("vector " .. case.id, function()
				local reports = {}
				local tracker = Segments.new_nesting(
					function(name) return corpus.thresholds[name] end,
					function(report) reports[#reports + 1] = report end)
				local verdicts = {}
				for _, step in ipairs(case.steps) do
					if step[1] == "open" then tracker.open(step[2])
					else
						local _, _, slow = tracker.close(step[2], step[3], step[4])
						verdicts[#verdicts + 1] = slow
					end
				end
				helpers.assert_eq(tracker.depth(), 0, "every frame is closed")
				helpers.assert_eq(#verdicts, #case.slow, "one verdict per close")
				for index, expected in ipairs(case.slow) do
					helpers.assert_eq(verdicts[index], expected, "verdict of close " .. index)
				end
				helpers.assert_eq(#reports, #case.reports, "number of reports")
				for index, expected in ipairs(case.reports) do
					for _, field in ipairs({ "segment", "parent", "total_ms", "own_ms" }) do
						helpers.assert_eq(reports[index][field], expected[field], "report " .. index .. " " .. field)
					end
				end
			end)
		end
	end)
end

return M
