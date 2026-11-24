--- _shared/diagnostics/engine/field_check/field_report.lua

--- ==============================================================================
--- MODULE: In-App Field Report (Shared)
--- DESCRIPTION:
--- The report of Débogage's « Lancer le field report (tous les tests) » on
--- macOS and Linux: the driver's own field run session runs its steps in-app
--- (macOS and Linux diagnostics/engine/field_run/field_run.lua), and this module
--- turns the results it recorded into one text for the window and the
--- clipboard, and into one evidence line: the verdict counts, each step's
--- verdict with the TODO-tests field points it decides, the steps not run here
--- with their reason, the Tests rows a person runs separately, and the folder
--- that holds the result files.
---
--- FEATURES & RATIONALE:
--- 1. One source of truth: the steps, verdicts and files are the field run's,
---    the field points the driver's field_todo_coverage.json; nothing here
---    lists a step.
--- 2. A step a Tests row also runs alone reads as that row's localized
---    sentences; a developer field run step has no localized label, so its
---    report steps read as their closed codes, as in its evidence line.
--- 3. PURE Lua: the drivers supply the results, the translator and the titles.
--- ==============================================================================

local Report = require("diagnostics.engine.field_check.report")
local LabelValue = require("core.i18n.engine.label_value")

local M = {}

--- Identity of the evidence line.
M.CHECK_ID = "field_report"

--- The verdicts of the shared protocol, in the order the counts read.
M.VERDICT_ORDER = { "pass", "fail", "timeout", "skip", "needs_person", "needs_typing" }

local MARKS = {
	pass = "✅", fail = "❌", timeout = "⏱️", skip = "➖", needs_person = "🙋", needs_typing = "⌨️",
}

local STEP_MARKS = {
	[Report.STATE_PASS] = "✅", [Report.STATE_FAIL] = "❌",
	[Report.STATE_INFO] = "ℹ️", [Report.STATE_SKIP] = "➖",
}

-- Indent of a step's own report lines under its line
local INDENT = "    "

--- The mark of a verdict; an undeclared one is a defect of the caller.
--- @param verdict string
--- @return string
local function mark(verdict)
	return assert(MARKS[verdict], "field report: undeclared verdict " .. tostring(verdict))
end

--- Lists, for each field run step, the TODO-tests field points one of whose
--- checks names it, in the coverage file's order.
--- @param coverage table|nil Decoded field_todo_coverage.json, or nil.
--- @return table step id → array of point ids.
function M.points_by_step(coverage)
	local by_step = {}
	if coverage == nil then return by_step end
	assert(type(coverage.points) == "table", "field report: the coverage file has no points")
	for _, point in ipairs(coverage.points) do
		assert(type(point.id) == "string" and point.id ~= "", "field report: a coverage point has no id")
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

--- Builds the summary of one in-app run.
--- @param opts table {
---   results = array of the result documents the session recorded, in order,
---   not_run = array of { step, reason } the session left out,
---   separate = array of { row } Tests rows a person runs alone,
---   coverage = decoded field_todo_coverage.json or nil,
---   done = the done document, dir = the results folder }
--- @return table summary
function M.summary(opts)
	local points = M.points_by_step(opts.coverage)
	local counts, entries, passed = {}, {}, not opts.done.interrupted
	for _, result in ipairs(opts.results) do
		counts[result.verdict] = (counts[result.verdict] or 0) + 1
		if result.verdict ~= "pass" and result.verdict ~= "skip" then passed = false end
		table.insert(entries, { step = result.step, verdict = result.verdict, codes = result.codes or {},
			report = result.report, points = points[result.step] or {} })
	end
	local not_run = {}
	for _, item in ipairs(opts.not_run) do
		table.insert(not_run, { step = item.step, reason = item.reason, points = points[item.step] or {} })
	end
	return { passed = passed, interrupted = opts.done.interrupted == true, counts = counts, entries = entries,
		not_run = not_run, separate = opts.separate or {}, dir = opts.dir, request_id = opts.done.request_id }
end

--- The one evidence line:
--- check=field_report verdict=fail request=app-… pass=2 fail=1 not_run=1 field_network=pass …
--- @param summary table From M.summary.
--- @return string
function M.format_log_line(summary)
	local parts = {}
	for _, verdict in ipairs(M.VERDICT_ORDER) do
		if summary.counts[verdict] then table.insert(parts, verdict .. "=" .. summary.counts[verdict]) end
	end
	table.insert(parts, "not_run=" .. #summary.not_run)
	for _, entry in ipairs(summary.entries) do table.insert(parts, entry.step .. "=" .. entry.verdict) end
	return string.format("check=%s verdict=%s request=%s %s", M.CHECK_ID,
		summary.interrupted and "interrupted" or summary.passed and "pass" or "fail",
		Report.sanitize_value(summary.request_id) or Report.REDACTED, table.concat(parts, " "))
end

--- A step's heading: its Tests row title when it has one, else its step id,
--- then the step id and the field points it decides.
local function heading(title, step, points)
	local tags = {}
	if title then table.insert(tags, step) end
	for _, point in ipairs(points) do table.insert(tags, point) end
	local name = title or step
	if #tags == 0 then return name end
	return name .. " — " .. table.concat(tags, ", ")
end

--- The lines of one step's own report, under its heading.
local function report_lines(entry, titled, translate)
	local lines, report = {}, entry.report
	if type(report) ~= "table" or type(report.steps) ~= "table" or #report.steps == 0 then
		if #entry.codes > 0 then table.insert(lines, table.concat(entry.codes, ", ")) end
		return lines
	end
	if titled and report.passed ~= nil then
		local first = true
		for line in (Report.format_text(report, translate) .. "\n"):gmatch("(.-)\n") do
			if first then first = false elseif line ~= "" then table.insert(lines, line) end
		end
		return lines
	end
	for _, step in ipairs(report.steps) do
		local line = (STEP_MARKS[step.state] or "➖") .. " " .. tostring(step.id)
		if step.value then line = LabelValue.compose(translate, line, step.value) end
		table.insert(lines, line)
	end
	return lines
end

--- Renders the summary for the window and the clipboard.
--- @param summary table From M.summary.
--- @param translate function key → localized text.
--- @param title_of function step id → localized Tests row title, or nil.
--- @return string
function M.format_text(summary, translate, title_of)
	local verdict_key = summary.interrupted and "field_check.all.interrupted"
		or summary.passed and "field_check.all.verdict_pass" or "field_check.all.verdict_fail"
	local counts = {}
	for _, verdict in ipairs(M.VERDICT_ORDER) do
		if summary.counts[verdict] then table.insert(counts, mark(verdict) .. " " .. summary.counts[verdict]) end
	end
	if #summary.not_run > 0 then table.insert(counts, "➖ " .. #summary.not_run) end
	local lines = { translate(verdict_key), table.concat(counts, " · ") }
	for _, entry in ipairs(summary.entries) do
		local title = title_of(entry.step)
		table.insert(lines, "")
		table.insert(lines, mark(entry.verdict) .. " " .. heading(title, entry.step, entry.points))
		for _, line in ipairs(report_lines(entry, title ~= nil, translate)) do table.insert(lines, INDENT .. line) end
	end
	if #summary.not_run > 0 then
		table.insert(lines, "")
		table.insert(lines, translate("field_check.all.not_run_header"))
		for _, item in ipairs(summary.not_run) do
			table.insert(lines, LabelValue.compose(translate, "➖ " .. heading(nil, item.step, item.points),
				translate("field_check.all.reason." .. item.reason)))
		end
	end
	if #summary.separate > 0 then
		table.insert(lines, "")
		table.insert(lines, translate("field_check.all.separate_header"))
		for _, item in ipairs(summary.separate) do
			table.insert(lines, "➖ " .. translate("menu.debug." .. item.row))
		end
	end
	table.insert(lines, "")
	table.insert(lines, (translate("field_check.all.saved_in"):gsub("{1}", function() return summary.dir end)))
	table.insert(lines, translate("field_check.all.attach"))
	return table.concat(lines, "\n")
end

return M
