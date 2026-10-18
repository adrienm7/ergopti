--- infra/session_lock.lua

--- ==============================================================================
--- MODULE: Graphical Session Lock Ownership (Linux)
--- DESCRIPTION:
--- The launcher passes its singleton flock across exec. Mark that descriptor
--- close-on-exec before any daemon dependency can start an external process,
--- so a browser or application cannot retain the lock after the daemon exits.
--- ==============================================================================

local M = {}

local MARKER = "ERGOPTI_SESSION_LOCK_FD"
local LOCK_FD = 9
local F_GETFD, F_SETFD, FD_CLOEXEC = 1, 2, 1

--- Restricts the inherited launcher lock to the daemon's own process lifetime.
--- Direct CLI runs have no launcher marker and need no inherited lock.
--- @return boolean protected
--- @return string|nil error_message
function M.protect()
	local marker = os.getenv(MARKER)
	if marker == nil then return true end
	if marker ~= tostring(LOCK_FD) then return false, "Invalid session lock descriptor marker." end
	local ffi = require("ffi")
	local bit = require("bit")
	ffi.cdef([[
		int fcntl(int fd, int command, ...);
		int unsetenv(const char *name);
	]])
	local flags = ffi.C.fcntl(LOCK_FD, F_GETFD)
	if flags < 0 then return false, "The inherited session lock descriptor is unavailable." end
	if ffi.C.fcntl(LOCK_FD, F_SETFD, ffi.new("int", bit.bor(flags, FD_CLOEXEC))) < 0 then
		return false, "The inherited session lock could not be restricted to the daemon."
	end
	-- External children must not inherit a marker for the descriptor exec closes.
	if ffi.C.unsetenv(MARKER) ~= 0 then return false, "The session lock marker could not be cleared." end
	return true
end

return M
