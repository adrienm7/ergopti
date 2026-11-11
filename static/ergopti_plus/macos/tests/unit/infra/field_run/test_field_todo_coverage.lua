--- tests/unit/infra/field_run/test_field_todo_coverage.lua

--- ==============================================================================
--- MODULE: Field Report TODO Coverage Contract
--- DESCRIPTION:
--- One macOS field report must answer every open line of TODO.md « To confirm
--- on the Mac ». These cases fail when a line is added without a field-point
--- tag, when a tag has no entry in data/field_todo_coverage.json, when an entry
--- names a field run step, a report step or a collector step that does not
--- exist, when a point no run can test gives no reason, and when a guided step
--- is declared that no point reads or observes a report step its check never
--- writes.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local DRIVER = helpers.driver_root()
local REPO = DRIVER .. "../../../"

local function read(path)
	local file = assert(io.open(path, "rb"), "cannot read " .. path)
	local text = assert(file:read("*a"))
	file:close()
	return text
end

local COVERAGE = Json.decode(read(DRIVER .. "data/field_todo_coverage.json"))
local SPEC = Json.decode(read(DRIVER .. "data/field_run.json"))
local STEPS = {}
for _, step in ipairs(SPEC.steps) do STEPS[step.id] = step end

--- The TODO section's lines, from its heading to the next one.
local function section_lines()
	local lines, inside = {}, false
	for line in (read(REPO .. COVERAGE.todo.file) .. "\n"):gmatch("([^\n]*)\n") do
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

--- Every source a check writes its report steps from.
local function check_sources()
	local parts = {}
	local pipe = assert(io.popen("ls '" .. DRIVER .. "infra/'field_check*.lua"))
	for path in pipe:lines() do parts[#parts + 1] = read(path) end
	pipe:close()
	parts[#parts + 1] = read(DRIVER .. "../_shared/lua/network/field_check_network.lua")
	return table.concat(parts, "\n")
end

--- The report steps a check can write that its source builds from a table.
local function generated_report_steps()
	local ids = {}
	for _, entry in ipairs(require("infra.field_check_raw_telemetry").TABLES) do
		for kind in pairs(entry.kinds) do ids[entry.prefix .. "_" .. kind] = true end
	end
	return ids
end

local SOURCES = check_sources()
local GENERATED = generated_report_steps()

local function report_step_exists(id)
	return GENERATED[id] or SOURCES:find('"' .. id .. '"', 1, true) ~= nil
end





helpers.describe("field report TODO coverage: TODO.md « To confirm on the Mac »", function()
	helpers.it("tags every open line with a point the coverage table declares, once", function()
		local declared, tagged = {}, {}
		for _, point in ipairs(COVERAGE.points) do
			helpers.assert_nil(declared[point.id], "point declared twice: " .. point.id)
			declared[point.id] = true
		end
		local open_lines = 0
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

	helpers.it("names only declared steps, written report steps and collector steps", function()
		local collector = read(REPO .. "tools/dev/collect-macos-field-report.sh")
		for _, point in ipairs(COVERAGE.points) do
			helpers.assert_true(type(point.title) == "string" and point.title ~= "", point.id .. " has no title")
			helpers.assert_type(point.checks, "table", point.id)
			for _, check in ipairs(point.checks) do
				if check.collector then
					helpers.assert_true(collector:find("\nstep " .. check.collector .. " ", 1, true) ~= nil,
						point.id .. " names the collector step " .. check.collector .. " the collector never runs")
				else
					local step = STEPS[check.step]
					helpers.assert_not_nil(step, point.id .. " names the undeclared field run step " .. tostring(check.step))
					for _, id in ipairs(check.report or {}) do
						helpers.assert_true(step.kind == "field_check", point.id .. ": " .. check.step
							.. " is no field check, so it has no report step " .. id)
						helpers.assert_true(report_step_exists(id), point.id .. ": no check writes the report step " .. id)
					end
					if check.field then
						helpers.assert_eq(step.kind, "reload", point.id .. ": a field bound reads a reload report")
					end
				end
			end
		end
	end)

	helpers.it("says why a point no run can test cannot be tested", function()
		for _, point in ipairs(COVERAGE.points) do
			if #point.checks == 0 then
				helpers.assert_true(type(point.not_testable) == "string" and #point.not_testable > 20,
					point.id .. " has no check and no reason it cannot be tested")
			end
		end
	end)

	helpers.it("reads every guided step from a point and observes only report steps its check writes", function()
		local read_by_point = {}
		for _, point in ipairs(COVERAGE.points) do
			for _, check in ipairs(point.checks) do
				if check.step then read_by_point[check.step] = true end
			end
		end
		local guided = 0
		for _, step in ipairs(SPEC.steps) do
			if step.kind == "guided" then
				guided = guided + 1
				helpers.assert_true(read_by_point[step.id], step.id .. " is declared but decides no TODO point")
				local condition = step["until"]
				if condition then
					local ids = {}
					for _, id in ipairs(condition.steps) do ids[#ids + 1] = id end
					for _, id in ipairs(condition.steady or {}) do ids[#ids + 1] = id end
					for _, id in ipairs(ids) do
						helpers.assert_true(report_step_exists(id), step.id .. " observes " .. id .. ", which no check writes")
					end
				end
			end
		end
		helpers.assert_true(guided > 0, "the field run declares guided steps")
	end)
end)
