--- tests/unit/infra/lifecycle/test_boot_profiler_summary.lua

--- ==============================================================================
--- MODULE: Boot Profiler Summary Tests
--- DESCRIPTION:
--- Startup cost is read from one never-collapsed evidence line written at
--- complete(): every closed stage with its milliseconds, the total and the heap.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads a fresh profiler with the real logger capturing delivered lines.
--- @return table profiler, table lines
local function fixture()
	package.loaded["logger"] = nil
	package.loaded["logger.shim"] = nil
	local logger = require("logger")
	local lines = {}
	logger.set_sink(function(line) lines[#lines + 1] = line end)
	logger.set_level(20)
	local profiler = helpers.load_module("infra.boot_profiler")
	profiler._reset_for_test()
	return profiler, lines
end

helpers.describe("boot profiler: one summary line at completion", function()
	helpers.it("lists every closed stage, the total and the heap", function()
		local profiler, lines = fixture()
		profiler.begin()
		profiler.stage("config"); profiler.stage_done("config", "3 mappings")
		profiler.stage("input hooks"); profiler.stage_done("input hooks")
		profiler.complete()
		local summary
		for _, line in ipairs(lines) do
			if line:find("Boot summary", 1, true) then summary = line end
		end
		helpers.assert_not_nil(summary, "no boot summary line")
		helpers.assert_contains(summary, "config=")
		helpers.assert_contains(summary, "input hooks=")
		helpers.assert_contains(summary, "total=")
		helpers.assert_contains(summary, "heap=")
		helpers.assert_true(not summary:find("3 mappings", 1, true), "stage detail text stays out of the summary")
	end)

	helpers.it("leaves a stage that never closed out of the summary", function()
		local profiler, lines = fixture()
		profiler.begin()
		profiler.stage("died"); profiler.stage("config"); profiler.stage_done("config")
		profiler.complete()
		for _, line in ipairs(lines) do
			if line:find("Boot summary", 1, true) then
				helpers.assert_true(not line:find("died=", 1, true))
				return
			end
		end
		error("no boot summary line")
	end)
end)
