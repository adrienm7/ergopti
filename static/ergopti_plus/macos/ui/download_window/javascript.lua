--- ui/download_window/javascript.lua

--- ==============================================================================
--- MODULE: Download Window JavaScript Execution Boundary
--- DESCRIPTION:
--- Makes native submission and asynchronous script failures visible without
--- exposing payloads. Each operation owns its bounded diagnostic context.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local LOG = "download_window.javascript"

--- Creates diagnostic ownership for one progress-window operation.
--- @param session integer Positive operation identifier.
--- @param kind string Stable kind identifier, never user-provided content.
--- @return table context Explicit operation-owned diagnostic state.
function M.new_context(session, kind)
	assert(type(session) == "number" and session > 0 and session < math.huge
		and session % 1 == 0, "JavaScript diagnostics require a positive integer session")
	assert(type(kind) == "string" and kind:match("^[a-z][a-z0-9_]*$"),
		"JavaScript diagnostics require a stable kind identifier")
	return { session = session, kind = kind, reported = {} }
end

--- Reports each failure category once per operation, before returning control.
--- @param context table Operation-owned diagnostic state.
--- @param category string Fixed internal failure category.
local function report(context, category)
	if context.reported[category] then return end
	context.reported[category] = true
	-- Native errors may echo script literals; neither their messages nor the
	-- submitted JavaScript belong in diagnostic logs
	Logger.error(LOG, "JavaScript %s (session=%d, kind=%s); repeats suppressed for this operation.",
		category, context.session, context.kind)
end

--- Submits one script and observes its independently delivered execution result.
--- @param view table|userdata Exact native WebView receiving the script.
--- @param code string JavaScript payload, never logged.
--- @param context table State returned by new_context for the owning operation.
--- @return boolean submitted True only when native submission returned the exact view.
function M.execute(view, code, context)
	assert(type(code) == "string", "JavaScript execution requires a string payload")
	assert(type(context) == "table" and type(context.reported) == "table",
		"JavaScript execution requires an operation diagnostic context")
	local ok, result = pcall(function()
		return view:evaluateJavaScript(code, function(_, script_error)
			if script_error ~= nil then report(context, "execution failed") end
		end)
	end)
	if not ok then
		report(context, "submission raised")
		return false
	end
	if result == nil or result ~= view then
		report(context, "submission refused")
		return false
	end
	return true
end

return M
