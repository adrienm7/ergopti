--- _shared/lua/diagnostics/runtime_log.lua

--- ==============================================================================
--- MODULE: Runtime Log Helpers (shared)
--- DESCRIPTION:
--- Small formatting and throttling helpers for the runtime events both Lua
--- drivers log after boot: which files triggered a reload, and how an external
--- process ended. Kept pure (the logger and the clock are injected) so the
--- macOS and Linux drivers produce identical lines and the tests drive the real
--- code.
---
--- FEATURES & RATIONALE:
--- 1. Privacy by construction. A shell command line can carry user text (a
---    heredoc payload, a clipboard value, a path under the user's home), so only
---    the program's base name is ever logged, never the command. Changed files
---    are logged by base name for the same reason.
--- 2. Bounded volume. Some programs run every few hundred milliseconds (focus
---    polling, clipboard probes). The first exit of each program is logged, then
---    at most one line per program per window, carrying the number of runs it
---    summarises, so the debug log stays readable and the hot path pays one table
---    lookup.
--- ==============================================================================

local M = {}

-- How many file names a reload line lists before summarising the rest.
M.MAX_LISTED_PATHS = 5

-- Minimum interval between two exit lines for the same program.
M.PROCESS_LOG_WINDOW_MS = 60000

-- A run at least this long is always logged: a slow child process is exactly
-- what a user-visible stall needs to be traced to.
M.SLOW_PROCESS_MS = 1000




-- ===================================
-- ===================================
-- ======= 1/ Changed files ==========
-- ===================================
-- ===================================

--- Returns the last component of a path.
--- @param path string
--- @return string
local function basename(path)
	return (tostring(path):match("([^/\\]+)[/\\]*$")) or tostring(path)
end

--- Describes the files behind a reload as "N file(s): a, b, +K more".
--- @param paths table Either an array of paths or a set keyed by path.
--- @return string
function M.describe_paths(paths)
	local names = {}
	if type(paths) == "table" then
		if #paths > 0 then
			for _, path in ipairs(paths) do names[#names + 1] = basename(path) end
		else
			for path, present in pairs(paths) do
				if present then names[#names + 1] = basename(path) end
			end
		end
	end
	if #names == 0 then return "no file recorded" end
	table.sort(names)
	local listed = {}
	for index = 1, math.min(#names, M.MAX_LISTED_PATHS) do listed[index] = names[index] end
	local text = string.format("%d file(s): %s", #names, table.concat(listed, ", "))
	if #names > M.MAX_LISTED_PATHS then
		text = text .. string.format(", +%d more", #names - M.MAX_LISTED_PATHS)
	end
	return text
end





-- =====================================
-- =====================================
-- ======= 2/ External processes =======
-- =====================================
-- =====================================

--- Extracts the program name from a composed shell command. Environment
--- assignments and a leading `exec`/`env` are skipped; only the base name of
--- the first real word is returned, never an argument.
--- @param cmd string|nil
--- @return string
function M.program_name(cmd)
	if type(cmd) ~= "string" then return "unknown" end
	for word in cmd:gmatch("%S+") do
		local bare = word:match("^[\"']?(.-)[\"']?$")
		if not bare:match("^[%w_]+=") and bare ~= "exec" and bare ~= "env"
				and bare ~= "sh" and bare ~= "-c" and bare ~= "nohup" then
			local name = basename(bare)
			if name:match("^[%w%._%-+]+$") then return name end
			return "unknown"
		end
	end
	return "unknown"
end

--- Creates a throttled recorder for process exits.
--- @param logger table Logger with a debug(tag, fmt, ...) method.
--- @param tag string Log tag.
--- @param clock_ms function Returns monotonic milliseconds.
--- @return function record(program, status, duration_ms)
function M.new_process_log(logger, tag, clock_ms)
	local last_logged = {}
	local suppressed = {}
	return function(program, status, duration_ms)
		local name = type(program) == "string" and program ~= "" and program or "unknown"
		local now = clock_ms()
		local elapsed = tonumber(duration_ms) or 0
		local previous = last_logged[name]
		if previous and now - previous < M.PROCESS_LOG_WINDOW_MS and elapsed < M.SLOW_PROCESS_MS then
			suppressed[name] = (suppressed[name] or 0) + 1
			return false
		end
		local skipped = suppressed[name] or 0
		last_logged[name] = now
		suppressed[name] = 0
		logger.debug(tag, "Process '%s' exited (status=%s, %.0f ms, %d similar run(s) since the last line).",
			name, tostring(status), elapsed, skipped)
		return true
	end
end

return M
