--- tests/support/ui/metrics/typing/read_completion_logs.lua

--- ==============================================================================
--- MODULE: Typing Read Completion Log Capture
--- DESCRIPTION:
--- Records the dashboard's incomplete-read warning and recovery lines, and
--- decodes the latest full publication a test delivered.
--- ==============================================================================

local M = {}

local LOG = "metrics_typing"

--- Captures the dashboard's incomplete-read and recovery lines on the shared
--- logger owner; other lifecycle lines are ignored.
--- The dashboard module holds this exact table, so the capture sees its calls.
--- @return table logs { warnings = string[], infos = string[] }
function M.capture()
	local logs = { warnings = {}, infos = {} }
	local logger = package.loaded["infra.logger"]
	logger.warn = function(tag, template, ...)
		local line = string.format(template, ...)
		if tag == LOG and line:find("read incomplete", 1, true) then logs.warnings[#logs.warnings + 1] = line end
	end
	logger.info = function(tag, template, ...)
		local line = string.format(template, ...)
		if tag == LOG and line:find("read complete again", 1, true) then logs.infos[#logs.infos + 1] = line end
	end
	return logs
end

--- Decodes the payload of the latest public data publication.
--- @param evaluations table JavaScript submissions recorded by the fixture.
--- @return table|nil payload First argument of window.publishTypingMetricsData.
function M.publication(evaluations)
	for index = #evaluations, 1, -1 do
		local arguments = evaluations[index].code:match("^window%.publishTypingMetricsData%((.*)%)%;$")
		if arguments then return require("json").decode("[" .. arguments .. "]")[1] end
	end
	return nil
end

return M
