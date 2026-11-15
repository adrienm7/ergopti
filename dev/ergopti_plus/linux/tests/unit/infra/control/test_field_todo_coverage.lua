--- tests/unit/infra/control/test_field_todo_coverage.lua

--- ==============================================================================
--- MODULE: Linux Field Report TODO Coverage Contract
--- DESCRIPTION:
--- One Linux field report must answer every open line of TODO.md « To confirm
--- on Linux ». These cases fail when a line is added without a field-point
--- tag, when a tag has no entry in data/field_todo_coverage.json, when an entry
--- names a step neither the daemon's field run (data/field_run_steps.json) nor
--- the collector (data/field_guided_steps.json) declares, or a report step that
--- step does not write, when a point no run can test gives no reason, and when
--- a collector step is declared that no point reads.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")

local DRIVER = helpers.driver_root()
local REPO = DRIVER .. "/../../.."

local function read(path)
	local file = assert(io.open(path, "rb"), "cannot read " .. path)
	local text = assert(file:read("*a"))
	file:close()
	return text
end

local COVERAGE = Json.decode(read(DRIVER .. "/data/field_todo_coverage.json"))
local RUN = Json.decode(read(DRIVER .. "/data/field_run_steps.json"))
local GUIDED = Json.decode(read(DRIVER .. "/data/field_guided_steps.json"))

-- Every declared step, with the report steps it can write: a collector step
-- writes one report step per probe, a daemon check its own (not read here).
local STEPS = {}
for _, step in ipairs(RUN.steps) do STEPS[step.id] = { kind = step.kind } end
for _, step in ipairs(GUIDED.steps) do
	local writes = {}
	for _, probe in ipairs(step.probes or {}) do writes[probe.id] = true end
	for _, probe in ipairs(step.steady or {}) do writes[probe.id] = true end
	STEPS[step.id] = { kind = "collector", writes = writes }
end

--- The TODO section's lines, from its heading to the next one.
local function section_lines()
	local lines, inside = {}, false
	for line in (read(REPO .. "/" .. COVERAGE.todo.file) .. "\n"):gmatch("([^\n]*)\n") do
		if line == COVERAGE.todo.section then
			inside = true
		elseif inside and line:match("^## ") then
			break
		elseif inside then
			lines[#lines + 1] = line
		end
	end
	return lines
end





helpers.describe("Linux field report TODO coverage: TODO-tests-linux.md « To confirm on Linux »", function()
	helpers.it("tags every open line with a point the coverage table declares, once", function()
		local declared, tagged, open_lines = {}, {}, 0
		for _, point in ipairs(COVERAGE.points) do
			helpers.assert_nil(declared[point.id], "point declared twice: " .. point.id)
			declared[point.id] = true
		end
		local pattern = "<!%-%- " .. COVERAGE.todo.tag:gsub("%-", "%%-") .. ": ([a-z0-9_]+) %-%->"
		for _, line in ipairs(section_lines()) do
			local id = line:match(pattern)
			if line:match("^%- %[ %]") then
				open_lines = open_lines + 1
				helpers.assert_not_nil(id, "an open TODO line has no field-point tag: " .. line:sub(1, 80))
			end
			if id then
				helpers.assert_true(declared[id], "the TODO tag " .. id .. " has no coverage entry")
				helpers.assert_nil(tagged[id], "two TODO lines carry the tag " .. id)
				tagged[id] = true
			end
		end
		helpers.assert_true(open_lines > 0, "the section was found and has open lines")
		for id in pairs(declared) do
			helpers.assert_true(tagged[id], "the coverage entry " .. id .. " tags no TODO line (stale entry)")
		end
	end)

	helpers.it("names only declared steps and the report steps they write", function()
		for _, point in ipairs(COVERAGE.points) do
			helpers.assert_true(type(point.title) == "string" and point.title ~= "", point.id .. " has no title")
			for _, check in ipairs(point.checks) do
				local step = STEPS[check.step]
				helpers.assert_not_nil(step, point.id .. " names the undeclared step " .. tostring(check.step))
				for _, id in ipairs(check.report or {}) do
					helpers.assert_true(step.kind == "collector" and step.writes[id] == true,
						point.id .. ": " .. check.step .. " writes no report step " .. id)
				end
			end
			if #point.checks == 0 then
				helpers.assert_true(type(point.not_testable) == "string" and #point.not_testable > 20,
					point.id .. " has no check and no reason it cannot be tested")
			end
		end
	end)

	helpers.it("reads every collector step from a point", function()
		local read_by_point = {}
		for _, point in ipairs(COVERAGE.points) do
			for _, check in ipairs(point.checks) do read_by_point[check.step] = true end
		end
		for _, step in ipairs(GUIDED.steps) do
			helpers.assert_true(read_by_point[step.id], step.id .. " is declared but decides no TODO point")
		end
	end)
end)
