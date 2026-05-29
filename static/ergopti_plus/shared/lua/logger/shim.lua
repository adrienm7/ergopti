--- shared/lua/logger/shim.lua

--- ==============================================================================
--- MODULE: Logger Shim (Shared)
--- DESCRIPTION:
--- Canonical print-fallback logger for shared Lua modules that must work in
--- environments where neither lib.logger (macOS) nor the shared logger core is
--- on the module search path (e.g. the Linux standalone daemon, LuaJIT test
--- runners, build scripts).
---
--- FEATURES & RATIONALE:
--- 1. Platform-neutral: no hs.*, no file I/O — pure print() only.
--- 2. Canonical interface: exposes all 8 logger variants (debug, trace, done,
---    info, start, success, warn, error) so callers can switch to the real logger
---    without changing call sites.
--- 3. Try-real-first: attempts to load the shared logger core (logger/init.lua)
---    and the macOS driver logger (lib.logger) before falling back to print,
---    so the shim degrades gracefully across all environments.
--- 4. Single definition: every shared module that needs a logger shim should
---    require("logger.shim") rather than copy-pasting the fallback closure.
--- ==============================================================================

local M = {}




-- ===========================================
-- ===========================================
-- ======= 1/ Attempt real logger load =======
-- ===========================================
-- ===========================================

-- Try the shared logger core first (works when shared/lua/ is on package.path).
local ok, real = pcall(require, "logger")
if not ok or not real then
	-- Try the macOS driver logger as a secondary fallback.
	ok, real = pcall(require, "lib.logger")
end

if ok and real then
	return real
end




-- ======================================
-- ======================================
-- ======= 2/ Print-fallback logger =====
-- ======================================
-- ======================================

local function _log(level, tag, fmt, ...)
	local msg = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
	print(string.format("[%s] [%s] %s", level, tag, msg))
end

M.debug   = function(t, f, ...) _log("DEBUG",   t, f, ...) end
M.trace   = function(t, f, ...) _log("TRACE",   t, f, ...) end
M.done    = function(t, f, ...) _log("DONE",    t, f, ...) end
M.info    = function(t, f, ...) _log("INFO",    t, f, ...) end
M.start   = function(t, f, ...) _log("START",   t, f, ...) end
M.success = function(t, f, ...) _log("SUCCESS", t, f, ...) end
M.warn    = function(t, f, ...) _log("WARN",    t, f, ...) end
M.error   = function(t, f, ...) _log("ERROR",   t, f, ...) end

return M
