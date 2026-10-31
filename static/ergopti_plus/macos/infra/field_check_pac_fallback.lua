--- infra/field_check_pac_fallback.lua

--- ==============================================================================
--- MODULE: Field Check, PAC Direct Fallback
--- DESCRIPTION:
--- What the Mac must confirm for the « PAC unusable: direct fallback » item,
--- read from the day log once the field run's AI downloads ran: each download
--- whose automatic proxy configuration (PAC, WPAD) could not be used announced
--- the stage with one WARNING, then said whether the direct connection worked
--- or named both causes. The shell admission, the Swift spool, the Python
--- receiver and the Ollama pull all write the same three line shapes.
---
--- FEATURES & RATIONALE:
--- 1. Read-only: one awk pass over the day log prints counts only, so no log
---    line (and nothing a line may carry) reaches the task's pipe.
--- 2. A network whose PAC works never falls back: that is information, never a
---    failure. A fallback with no outcome line, or a stage outside the shared
---    proxy_policy.json list, fails by name.
--- 3. A direct try that failed every time fails: the maintainer's terminal
---    reaches the registry direct on the same network, so the fallback that
---    still fails there is the defect the item exists for.
--- ==============================================================================

local Report = require("field_check_report")

local M = {}

local PASS, FAIL, INFO = Report.STATE_PASS, Report.STATE_FAIL, Report.STATE_INFO

local AWK = "/usr/bin/awk"
local TOOL_SECONDS = 10

-- Counts the three line shapes per stage; prints a summary only.
M.PAC_FALLBACK_AWK = [=[
function stage_of(text, lead,    rest) {
	rest = substr(text, index(text, lead) + length(lead))
	return substr(rest, 1, index(rest, ")") - 1)
}
/The automatic network configuration could not be used \(/ {
	w[stage_of($0, "could not be used (")]++; wc++
}
/The direct connection worked after the automatic network configuration failed \(/ {
	ok[stage_of($0, "configuration failed (")]++; okc++
}
/The automatic network configuration was unreachable \(.*\) and the direct connection failed/ {
	bad[stage_of($0, "was unreachable (")]++; badc++
}
END {
	for (k in w) printf "warning %s %d\n", k, w[k]
	for (k in ok) printf "worked %s %d\n", k, ok[k]
	for (k in bad) printf "failed %s %d\n", k, bad[k]
	printf "totals %d %d %d\n", wc, okc, badc
}
]=]

--- Reads the awk summary.
--- @param text any Awk output.
--- @return table|nil summary { warnings, worked, failed = count, stages = { name = true } }, nil when the
---   totals line is missing.
function M.parse_summary(text)
	local summary = { stages = {} }
	for line in tostring(text or ""):gmatch("[^\n]+") do
		local kind, stage = line:match("^(%a+) (%S+) %d+$")
		if kind == "warning" or kind == "worked" or kind == "failed" then summary.stages[stage] = true end
		local warnings, worked, failed = line:match("^totals (%d+) (%d+) (%d+)$")
		if warnings then
			summary.warnings, summary.worked, summary.failed = tonumber(warnings), tonumber(worked), tonumber(failed)
		end
	end
	if summary.warnings == nil then return nil end
	return summary
end

--- The verdict of one summary.
--- @param summary table From parse_summary.
--- @param is_fallback_stage function(stage) -> boolean, the shared policy.
--- @return string state
--- @return string value
function M.verdict(summary, is_fallback_stage)
	local unlisted = {}
	for stage in pairs(summary.stages) do
		if not is_fallback_stage(stage) then unlisted[#unlisted + 1] = stage end
	end
	table.sort(unlisted)
	if #unlisted > 0 then return FAIL, "unlisted_stage:" .. table.concat(unlisted, ",") end
	if summary.warnings == 0 and summary.worked == 0 and summary.failed == 0 then return INFO, "no_pac_failure" end
	if summary.worked + summary.failed == 0 then return FAIL, "no_outcome" end
	if summary.worked == 0 then return FAIL, "direct_failed" end
	return PASS, "direct_worked"
end

--- The PAC fallback step: counts, stages and verdict.
--- ports.today_log_path(), exec; ports.is_pac_fallback_stage(stage) defaults to the shared policy.
function M.pac_fallback(ports, report, finish)
	local path = ports.today_log_path()
	if type(path) ~= "string" or path == "" then
		report.step("pac_fallback_log", FAIL, "no_log")
		return finish()
	end
	local is_fallback_stage = ports.is_pac_fallback_stage
		or require("modules.llm.opaque_network_admission").is_pac_fallback_stage
	ports.exec(AWK, { M.PAC_FALLBACK_AWK, path }, TOOL_SECONDS, function(code, output)
		local summary = code == 0 and M.parse_summary(output) or nil
		if summary == nil then
			report.step("pac_fallback_log", FAIL, code == nil and "timeout" or "unreadable")
			return finish()
		end
		report.step("pac_fallback_log", PASS)
		local stages = {}
		for stage in pairs(summary.stages) do stages[#stages + 1] = stage end
		table.sort(stages)
		report.step("pac_fallback_stages", INFO, #stages > 0 and table.concat(stages, ",") or "none")
		report.step("pac_fallback_counts", INFO, summary.warnings .. ":" .. summary.worked .. ":" .. summary.failed)
		local state, value = M.verdict(summary, is_fallback_stage)
		report.step("pac_fallback_outcome", state, value)
		finish()
	end)
end

return M
