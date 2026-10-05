--- _shared/lua/diagnostics/operation_reporter.lua

--- ==============================================================================
--- MODULE: Operation Diagnostic Reporter
--- DESCRIPTION:
--- Keeps caller-owned private refusals limited to fixed categories while ordinary
--- operations retain their existing concrete native diagnostics.
--- ==============================================================================

local M = {}

--- Binds diagnostic ownership to one operation without changing the logger.
--- @param on_error function|nil Callback receiving a fixed category only.
--- @param logger table Existing central logger.
--- @param scope string Stable logger scope.
--- @return function report Category, severity, template and ordinary arguments.
function M.new(on_error, logger, scope)
	assert(on_error == nil or type(on_error) == "function", "operation diagnostic owner must be a function")
	return function(category, severity, template, ...)
		if on_error then
			local acknowledged = pcall(on_error, category)
			if not acknowledged then logger.error(scope, "Operation diagnostic callback failed.") end
		else
			logger[severity](scope, template, ...)
		end
	end
end

return M
