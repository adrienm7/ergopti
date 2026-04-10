--- lib/logger.lua

--- ==============================================================================
--- MODULE: Logger
--- DESCRIPTION:
--- Centralized, level-aware logging system for the entire Hammerspoon runtime.
--- Provides consistent formatting and filtering so only relevant messages are
--- printed to the console.
---
--- FEATURES & RATIONALE:
--- 1. Level Filtering: Avoids console noise in production while keeping detail.
--- 2. Module Tagging: Every call receives a module name tag for quick triage.
--- 3. Lazy Formatting: Avoids unnecessary string allocations at runtime.
--- ==============================================================================

local M = {}
local hs = hs





-- ====================================
-- ====================================
-- ======= 1/ Level Definitions =======
-- ====================================
-- ====================================

--- Log level constants, ordered by severity.
M.LEVELS = {
	DEBUG   = 1,
	INFO    = 2,
	WARNING = 3,
	ERROR   = 4,
}

local LEVEL_LABELS = {
	[1] = "DEBUG",
	[2] = "INFO",
	[3] = "WARNING",
	[4] = "ERROR",
}

--- Current active level — only messages at or above this level are printed
M.current_level = M.LEVELS.WARNING





-- =======================================
-- =======================================
-- ======= 2/ Public Configuration =======
-- =======================================
-- =======================================

--- Sets the active log level.
--- @param level number|string Level constant or name string.
function M.set_level(level)
	if type(level) == "number" then
		M.current_level = level
	elseif type(level) == "string" then
		M.current_level = M.LEVELS[level:upper()] or M.LEVELS.WARNING
	end
end

--- Returns true when messages at the given level would be printed.
--- @param level number Level constant to test.
--- @return boolean
function M.is_enabled(level)
	return level >= M.current_level
end





-- ===================================
-- ===================================
-- ======= 3/ Core Logging API =======
-- ===================================
-- ===================================

--- Internal dispatcher — formats and prints a log entry.
--- @param level number Numeric severity level.
--- @param module_name string Short identifier of the calling module.
--- @param msg string Message or format string.
--- @param ... any Optional arguments for string formatting.
local function _log(level, module_name, msg, ...)
	if level < M.current_level then return end

	local text
	local ok, fmt = pcall(tostring, msg)
	text = ok and fmt or "???"

	if select("#", ...) > 0 then
		local ok_f, formatted = pcall(string.format, text, ...)
		text = ok_f and formatted or (text .. " [format error]")
	end

	local label = LEVEL_LABELS[level] or "???"
	print(string.format("[%s] [%s] %s", label, tostring(module_name), text))
end

--- Logs a DEBUG message.
--- @param module_name string Short module identifier.
--- @param msg string Message or format string.
--- @param ... any Optional format arguments.
function M.debug(module_name, msg, ...)   _log(M.LEVELS.DEBUG,   module_name, msg, ...) end

--- Logs an INFO message.
--- @param module_name string Short module identifier.
--- @param msg string Message or format string.
--- @param ... any Optional format arguments.
function M.info(module_name, msg, ...)    _log(M.LEVELS.INFO,    module_name, msg, ...) end

--- Logs a WARNING message.
--- @param module_name string Short module identifier.
--- @param msg string Message or format string.
--- @param ... any Optional format arguments.
function M.warn(module_name, msg, ...)    _log(M.LEVELS.WARNING, module_name, msg, ...) end

--- Logs an ERROR message.
--- @param module_name string Short module identifier.
--- @param msg string Message or format string.
--- @param ... any Optional format arguments.
function M.error(module_name, msg, ...)   _log(M.LEVELS.ERROR,   module_name, msg, ...) end





-- ==================================
-- ==================================
-- ======= 4/ Utility Helpers =======
-- ==================================
-- ==================================

--- Wraps pcall and logs any error at the ERROR level.
--- @param module_name string Short module identifier used in the error log.
--- @param fn function Function to call.
--- @param ... any Arguments forwarded to the function.
--- @return boolean ok
--- @return any result_or_error
function M.pcall(module_name, fn, ...)
	local results = table.pack(pcall(fn, ...))
	if not results[1] then
		_log(M.LEVELS.ERROR, module_name, "Exception: %s", tostring(results[2]))
	end
	return table.unpack(results, 1, results.n)
end

--- Wraps a builder pcall pattern.
--- @param module_name string Short module identifier.
--- @param label string Human-readable label of the component being built.
--- @param fn function Builder function to call.
--- @param ctx table Context argument forwarded to the function.
--- @return any|nil
function M.build(module_name, label, fn, ctx)
	local ok, result = pcall(fn, ctx)
	if not ok then
		_log(M.LEVELS.ERROR, module_name, "Erreur de construction de \"%s\" : %s", label, tostring(result))
		return nil
	end
	return result
end

return M
