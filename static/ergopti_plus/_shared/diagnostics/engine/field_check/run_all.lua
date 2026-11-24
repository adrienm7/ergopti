--- _shared/diagnostics/engine/field_check/run_all.lua

--- ==============================================================================
--- MODULE: Test Everything (Shared)
--- DESCRIPTION:
--- The Debug menu's « Test everything » on macOS and Linux: it runs, one after
--- the other, every check of the driver's plan that needs no person
--- (_shared/diagnostics/data/field_check_all.json) and turns their reports into
--- one combined report: each check's verdict, its field run step and the
--- TODO-tests field points that step decides, then the Tests rows a person must
--- run separately. Windows follows the same plan and report in AutoHotkey
--- (windows/diagnostics/ui/field_check/run_all.ahk).
---
--- FEATURES & RATIONALE:
--- 1. Fail fast without stopping: a check that cannot start, raises or misses
---    its deadline is recorded as failed with a closed code, and the sequence
---    goes on with the next check; the deadline is the field run step's own.
--- 2. Settle once: a check settles by its report or by its deadline, whichever
---    comes first; a late report is dropped. The run settles exactly once.
--- 3. One check at a time, each started from a fresh timer turn, never from the
---    previous check's callback, so no check runs inside another's stack.
--- 4. PURE Lua: the driver supplies the declarations and the ports (start a
---    check, timers); the evidence grammar is the shared report's.
--- ==============================================================================

local Report = require("diagnostics.engine.field_check.report")
local LabelValue = require("core.i18n.engine.label_value")

local M = {}

--- Identity of the combined record.
M.CHECK_ID = "all"

--- Closed codes of a check that gave no usable report.
M.CODE_TIMEOUT = "timeout"
M.CODE_REFUSED = "refused"
M.CODE_RAISED = "raised"

--- Entry verdicts.
M.VERDICT_PASS = "pass"
M.VERDICT_FAIL = "fail"
M.VERDICT_SKIP = "skip"

-- Locale key of the code a check that gave no report carries
local CODE_KEYS = {
	[M.CODE_TIMEOUT] = "field_check.all.timeout",
	[M.CODE_REFUSED] = "field_check.all.refused",
	[M.CODE_RAISED] = "field_check.all.raised",
}

local MARKS = {
	[M.VERDICT_PASS] = "✅", [M.VERDICT_FAIL] = "❌", [M.VERDICT_SKIP] = "➖",
}

-- Marks of a step state, as the one-check report draws them
local STEP_MARKS = {
	[Report.STATE_PASS] = "✅", [Report.STATE_FAIL] = "❌",
	[Report.STATE_INFO] = "ℹ️", [Report.STATE_SKIP] = "➖",
}

-- Indent of a check's own steps under its line
local STEP_INDENT = "    "





-- ===============================
-- ===============================
-- ======= 1/ The run plan =======
-- ===============================
-- ===============================

--- Lists, for each field run step, the TODO-tests field points one of whose
--- checks names it, in the coverage file's order.
--- @param coverage table|nil Decoded field_todo_coverage.json, or nil.
--- @return table step id → array of point ids.
function M.points_by_step(coverage)
	local by_step = {}
	if coverage == nil then return by_step end
	assert(type(coverage.points) == "table", "test everything: the coverage file has no points")
	for _, point in ipairs(coverage.points) do
		assert(type(point.id) == "string" and point.id ~= "", "test everything: a coverage point has no id")
		local seen = {}
		for _, check in ipairs(point.checks or {}) do
			local step = check.step
			if type(step) == "string" and not seen[step] then
				seen[step] = true
				by_step[step] = by_step[step] or {}
				table.insert(by_step[step], point.id)
			end
		end
	end
	return by_step
end

--- Builds a driver's run plan; any inconsistency raises, so a broken
--- declaration is found at the first click and never runs half a plan.
--- @param declaration table Decoded _shared/diagnostics/data/field_check_all.json.
--- @param platform string Manifest platform token ("hs", "linux").
--- @param steps table Array of the driver's field run steps ({ id, kind, check, deadline_seconds }).
--- @param coverage table|nil Decoded field_todo_coverage.json of the driver, or nil.
--- @return table plan { run = { {step, check, row, deadline_seconds, points} }, separate = { {row, step, points} } }
function M.plan(declaration, platform, steps, coverage)
	assert(type(declaration) == "table" and type(declaration.platforms) == "table",
		"test everything: the declaration has no platforms")
	local own = declaration.platforms[platform]
	assert(type(own) == "table" and type(own.run) == "table" and type(own.separate) == "table",
		"test everything: no plan for platform " .. tostring(platform))
	local by_id = {}
	for _, step in ipairs(steps) do by_id[step.id] = step end
	local points = M.points_by_step(coverage)
	local plan = { run = {}, separate = {} }
	for _, entry in ipairs(own.run) do
		local step = by_id[entry.step]
		assert(step ~= nil, "test everything: unknown field run step " .. tostring(entry.step))
		assert(step.kind == "field_check" and type(step.check) == "string",
			"test everything: step " .. entry.step .. " is not a field check")
		assert(type(step.deadline_seconds) == "number" and step.deadline_seconds > 0,
			"test everything: step " .. entry.step .. " has no deadline")
		table.insert(plan.run, {
			step = entry.step, check = step.check, row = entry.row,
			deadline_seconds = step.deadline_seconds, points = points[entry.step] or {},
		})
	end
	for _, entry in ipairs(own.separate) do
		assert(type(entry.row) == "string" and entry.row ~= "", "test everything: a separate entry has no row")
		if entry.step ~= nil then
			assert(by_id[entry.step] ~= nil, "test everything: unknown field run step " .. tostring(entry.step))
		end
		table.insert(plan.separate, {
			row = entry.row, step = entry.step, points = entry.step and points[entry.step] or {},
		})
	end
	return plan
end





-- ==========================
-- ==========================
-- ======= 2/ The run =======
-- ==========================
-- ==========================

--- The verdict of a settled check report.
--- @param result table A report result ({ passed, not_run }).
--- @return string verdict, string|nil code
local function verdict_of(result)
	if result.not_run then return M.VERDICT_SKIP, result.not_run end
	return result.passed and M.VERDICT_PASS or M.VERDICT_FAIL, nil
end

--- Runs every check of the plan in order and delivers the summary once.
--- @param plan table From M.plan.
--- @param ports table {
---   start = function(entry, on_result) -> boolean  starts one check; on_result(result) once,
---   after = function(seconds, fn) -> handle           a timer,
---   cancel = function(handle)                         cancels a timer,
---   abandon = function(entry)|nil                     forgets a check that missed its deadline }
--- @param on_done function on_done(summary) once every check settled.
function M.run(plan, ports, on_done)
	assert(type(on_done) == "function", "test everything: on_done must be a function")
	for _, name in ipairs({ "start", "after", "cancel" }) do
		assert(type(ports[name]) == "function", "test everything: the ports lack " .. name)
	end
	local entries, index = {}, 0
	local next_check

	local function settle_all()
		local passed = true
		for _, entry in ipairs(entries) do
			if entry.verdict == M.VERDICT_FAIL then passed = false end
		end
		on_done({ check = M.CHECK_ID, passed = passed, entries = entries, separate = plan.separate })
	end

	local function run_one(planned)
		local entry = {
			step = planned.step, check = planned.check, row = planned.row, points = planned.points,
		}
		table.insert(entries, entry)
		local settled, timer = false, nil
		local function settle(verdict, code, result)
			if settled then return end
			settled = true
			if timer ~= nil then pcall(ports.cancel, timer); timer = nil end
			entry.verdict, entry.code, entry.result = verdict, code, result
			ports.after(0, next_check)
		end
		timer = ports.after(planned.deadline_seconds, function()
			timer = nil
			if settled then return end
			if type(ports.abandon) == "function" then pcall(ports.abandon, planned) end
			settle(M.VERDICT_FAIL, M.CODE_TIMEOUT, nil)
		end)
		local ran, started = pcall(ports.start, planned, function(result)
			if type(result) ~= "table" or type(result.steps) ~= "table" then
				settle(M.VERDICT_FAIL, M.CODE_RAISED, nil)
				return
			end
			local verdict, code = verdict_of(result)
			settle(verdict, code, result)
		end)
		if not ran then
			settle(M.VERDICT_FAIL, M.CODE_RAISED, nil)
		elseif started ~= true then
			settle(M.VERDICT_FAIL, M.CODE_REFUSED, nil)
		end
	end

	next_check = function()
		index = index + 1
		local planned = plan.run[index]
		if planned == nil then
			settle_all()
			return
		end
		run_one(planned)
	end

	ports.after(0, next_check)
end





-- =============================
-- =============================
-- ======= 3/ The report =======
-- =============================
-- =============================

--- Renders the summary as the one log line the maintainer pastes back:
--- check=all verdict=fail checks=3 field_network=pass field_composer=fail:timeout separate=1
--- @param summary table From M.run.
--- @return string
function M.format_log_line(summary)
	local parts = {}
	for _, entry in ipairs(summary.entries) do
		local part = entry.step .. "=" .. entry.verdict
		if entry.code then part = part .. ":" .. (Report.sanitize_value(entry.code) or Report.REDACTED) end
		table.insert(parts, part)
	end
	return string.format("check=%s verdict=%s checks=%d %s separate=%d", M.CHECK_ID,
		summary.passed and M.VERDICT_PASS or M.VERDICT_FAIL, #summary.entries,
		table.concat(parts, " "), #summary.separate)
end

--- The heading of one check or row: its menu label, or its field run step id
--- when no Tests row starts it alone, then the step id and the field points.
--- @param translate function key → localized text.
--- @param row string|nil Tests row id.
--- @param step string|nil Field run step id.
--- @param points table Array of field point ids.
--- @return string
local function heading(translate, row, step, points)
	local name = row and translate("menu.debug." .. row) or step
	local tags = {}
	if step and row then table.insert(tags, step) end
	for _, point in ipairs(points) do table.insert(tags, point) end
	if #tags == 0 then return name end
	return name .. " — " .. table.concat(tags, ", ")
end

--- The lines of one check's own steps. A check a Tests row starts alone has a
--- localized sentence per step (its report's own text, without its verdict
--- line, which the entry's mark already gives); a developer field run check has
--- none, so its steps read as their closed codes, as in its evidence line.
--- @param entry table A summary entry with a result.
--- @param translate function key → localized text.
--- @return table lines
local function step_lines(entry, translate)
	local lines = {}
	if entry.row then
		local first = true
		for line in (Report.format_text(entry.result, translate) .. "\n"):gmatch("(.-)\n") do
			if first then first = false elseif line ~= "" then table.insert(lines, line) end
		end
		return lines
	end
	for _, step in ipairs(entry.result.steps) do
		local line = STEP_MARKS[step.state] .. " " .. step.id
		if step.value then line = LabelValue.compose(translate, line, step.value) end
		table.insert(lines, line)
	end
	return lines
end

--- Renders the summary for the window and the clipboard: the verdict, then one
--- line per check with its own steps beneath it, then the rows to run separately.
--- @param summary table From M.run.
--- @param translate function key → localized text.
--- @return string
function M.format_text(summary, translate)
	local lines = {
		translate(summary.passed and "field_check.all.verdict_pass" or "field_check.all.verdict_fail"),
	}
	for _, entry in ipairs(summary.entries) do
		table.insert(lines, "")
		table.insert(lines, MARKS[entry.verdict] .. " " .. heading(translate, entry.row, entry.step, entry.points))
		if entry.result == nil then
			local key = CODE_KEYS[entry.code]
			if key then table.insert(lines, STEP_INDENT .. translate(key)) end
		else
			if entry.result.not_run then
				table.insert(lines, STEP_INDENT .. LabelValue.compose(translate,
					translate("field_check.all.not_run"), Report.sanitize_value(entry.result.not_run) or Report.REDACTED))
			end
			for _, line in ipairs(step_lines(entry, translate)) do table.insert(lines, STEP_INDENT .. line) end
		end
	end
	if #summary.separate > 0 then
		table.insert(lines, "")
		table.insert(lines, translate("field_check.all.separate_header"))
		for _, entry in ipairs(summary.separate) do
			table.insert(lines, MARKS[M.VERDICT_SKIP] .. " " .. heading(translate, entry.row, entry.step, entry.points))
		end
	end
	return table.concat(lines, "\n")
end

return M
