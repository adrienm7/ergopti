--- _shared/lua/diagnostics/error_report.lua

--- ==============================================================================
--- MODULE: Error Report Text (Shared Lua)
--- DESCRIPTION:
--- What the error window (_shared/ui/error_dialog/) shows, copies and sends to
--- GitHub for one logged error, for the macOS and Linux drivers: the Markdown
--- report, the saved file's name and the prefilled fields of the bug form. The
--- AHK port (windows/infra/error_report.ahk) replays the same vectors
--- (_shared/tests/corpus/diagnostics/error_report_vectors.json).
---
--- FEATURES & RATIONALE:
--- 1. Built from diagnostics.issue_report, the bug report of the diagnostics
---    window: the same identity table, the same file name and the same form
---    summary, so a report opened from an error reads like any other.
--- 2. The issue's title is the error's module and the first line of its
---    message: what a maintainer triages by.
--- 3. The recent warnings and errors of today's errors file travel with the
---    error: a failure is rarely the first thing that went wrong.
--- 4. Nothing here redacts: the host redacts the finished texts with
---    diagnostics.redact before showing them, and again before anything leaves
---    the machine.
--- ==============================================================================

local M = {}

local IssueReport = require("diagnostics.issue_report")

-- The kinds of error the window reports: an ERROR logged by a running driver,
-- and the notice of a crash found at the next launch
M.KINDS = { error = true, crash = true }





-- ===============================
-- ===============================
-- ======= 1/ The Composer =======
-- ===============================
-- ===============================

--- The first line of a text.
--- @param text string
--- @return string
local function first_line(text)
	return (text:match("^([^\r\n]*)"))
end

--- Checks the error record and returns it.
--- @param err table { kind, module, message, time, recent }
--- @return table
local function checked(err)
	if type(err) ~= "table" then error("error_report: the error must be a table", 3) end
	if not M.KINDS[err.kind] then error("error_report: unknown kind " .. tostring(err.kind), 3) end
	for _, field in ipairs({ "module", "message", "time" }) do
		if type(err[field]) ~= "string" then error("error_report: " .. field .. " must be a string", 3) end
	end
	if type(err.recent) ~= "table" then error("error_report: recent must be a list", 3) end
	return err
end

--- Builds the report of one error.
--- @param err table { kind = "error"|"crash", module, message, time, recent = { line, … } }
--- @param identity table { version, commit, os, driver, generated_utc, file_stamp, warn_count, err_count }
--- @return table { name, text, fields = { title, version, os, driver, diagnostics } }
function M.compose(err, identity)
	checked(err)
	if type(identity) ~= "table" then error("error_report: the identity must be a table", 2) end
	local body = {
		error = { kind = err.kind, module = err.module, message = err.message, time = err.time },
	}
	if #err.recent > 0 then body.recent_issues = err.recent end

	local name = IssueReport.file_name(identity)
	local summary_info = {}
	for key, value in pairs(identity) do summary_info[key] = value end
	summary_info.last_error = "[" .. err.module .. "] " .. err.message

	return {
		name = name,
		text = IssueReport.markdown(identity, IssueReport.dump(body)),
		fields = {
			title       = err.module .. ": " .. first_line(err.message),
			version     = identity.version,
			os          = identity.os,
			driver      = identity.driver,
			diagnostics = IssueReport.summary(summary_info, name),
		},
	}
end

return M
