--- infra/session_lock.lua

--- ==============================================================================
--- MODULE: Graphical Session Lock Ownership (Linux)
--- DESCRIPTION:
--- The launcher passes its singleton flock across exec. Mark that descriptor
--- close-on-exec before any daemon dependency can start an external process,
--- so a browser or application cannot retain the lock after the daemon exits.
--- A start that did not come through the launcher (AppImage AppRun, Nix wrapper,
--- a manual luajit run) has no inherited lock: acquire() takes the same lock
--- file, so two daemons never grab the keyboard together.
--- ==============================================================================

local M = {}

local MARKER = "ERGOPTI_SESSION_LOCK_FD"
local LOCK_FD = 9
local F_GETFD, F_SETFD, FD_CLOEXEC = 1, 2, 1

-- Same file as install/launch.sh: $XDG_RUNTIME_DIR (else $HOME/.cache)/ergopti.
local LOCK_FOLDER, LOCK_NAME = "ergopti", "ergopti.lock"
local FALLBACK_ROOT = "/.cache"
local FOLDER_MODE, FILE_MODE = 448, 384 -- 0700, 0600
local O_WRONLY, O_CREAT, O_CLOEXEC = 1, 64, 524288
local LOCK_EX, LOCK_NB = 2, 4
local ERRNO_EXISTS, ERRNO_WOULD_BLOCK = 17, 11

-- True once this process owns the lock, through the launcher or acquire().
-- A process loads the entry once in production; tests load it repeatedly, and
-- a second acquire() by the same owner must not contend with itself.
local _inherited = false
local _held_fd = nil

local ffi_ready = false
local function ffi_c()
	local ffi = require("ffi")
	if not ffi_ready then
		ffi.cdef([[
			int fcntl(int fd, int command, ...);
			int unsetenv(const char *name);
			int open(const char *path, int flags, ...);
			int close(int fd);
			int flock(int fd, int operation);
			int mkdir(const char *path, unsigned int mode);
		]])
		ffi_ready = true
	end
	return ffi
end

--- Restricts the inherited launcher lock to the daemon's own process lifetime.
--- Direct CLI runs have no launcher marker and need no inherited lock.
--- @return boolean protected
--- @return string|nil error_message
function M.protect()
	local marker = os.getenv(MARKER)
	if marker == nil then return true end
	if marker ~= tostring(LOCK_FD) then return false, "Invalid session lock descriptor marker." end
	local ffi = ffi_c()
	local bit = require("bit")
	local flags = ffi.C.fcntl(LOCK_FD, F_GETFD)
	if flags < 0 then return false, "The inherited session lock descriptor is unavailable." end
	if ffi.C.fcntl(LOCK_FD, F_SETFD, ffi.new("int", bit.bor(flags, FD_CLOEXEC))) < 0 then
		return false, "The inherited session lock could not be restricted to the daemon."
	end
	-- External children must not inherit a marker for the descriptor exec closes.
	if ffi.C.unsetenv(MARKER) ~= 0 then return false, "The session lock marker could not be cleared." end
	_inherited = true
	return true
end

--- Takes the single-instance lock when the launcher did not.
--- Idempotent for the process that already owns it, however it got it.
--- @return boolean acquired
--- @return string|nil error_message
--- @return boolean|nil contended True when another instance holds the lock.
function M.acquire()
	if _inherited or _held_fd then return true end
	local root = os.getenv("XDG_RUNTIME_DIR")
	if root == nil or root == "" then
		local home = os.getenv("HOME")
		if home == nil or home == "" then return false, "Neither XDG_RUNTIME_DIR nor HOME is set; no session lock folder." end
		root = home .. FALLBACK_ROOT
	end
	local ffi = ffi_c()
	local folder = root .. "/" .. LOCK_FOLDER
	-- The runtime or cache root may not exist yet on a fresh account.
	for _, path in ipairs({ root, folder }) do
		if ffi.C.mkdir(path, FOLDER_MODE) ~= 0 and ffi.errno() ~= ERRNO_EXISTS then
			return false, "The session lock folder could not be created: " .. path
		end
	end
	local path = folder .. "/" .. LOCK_NAME
	local bit = require("bit")
	local fd = ffi.C.open(path, bit.bor(O_WRONLY, O_CREAT, O_CLOEXEC), ffi.new("int", FILE_MODE))
	if fd < 0 then return false, "The session lock file could not be opened: " .. path end
	if ffi.C.flock(fd, bit.bor(LOCK_EX, LOCK_NB)) ~= 0 then
		local contended = ffi.errno() == ERRNO_WOULD_BLOCK
		ffi.C.close(fd)
		if contended then
			return false, "Ergopti+ is already running in this session (" .. path .. " is held).", true
		end
		return false, "The session lock could not be taken: " .. path
	end
	_held_fd = fd
	return true
end

--- Releases a lock taken by acquire(). The launcher's lock is never released here.
function M.release()
	if _held_fd == nil then return end
	ffi_c().C.close(_held_fd)
	_held_fd = nil
end

return M
