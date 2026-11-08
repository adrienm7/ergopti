--- infra/updater_boot_ready.lua

--- ==============================================================================
--- MODULE: Updater Boot Ready (Linux)
--- DESCRIPTION:
--- Tells the update watcher that started this daemon that it is ready: the
--- watcher keeps the updated installation only once its boot reports ready,
--- and otherwise puts the previous one back, as the Windows swap does with
--- its boot-ready event (modules/updater/restarter.lua).
---
--- FEATURES & RATIONALE:
--- 1. One-shot token: the watcher names a file in its own fresh folder through
---    ERGOPTI_UPDATER_BOOT_READY. The boot writes its pid there once,
---    atomically (temporary file, then rename), so a partial write can never
---    read as ready.
--- 2. Stale tokens are harmless: once the watcher decided it removes its
---    folder; a later start that still inherits the variable fails the write,
---    which is logged at info level.
--- 3. Only a token of the watcher's shape is written, so an inherited
---    variable cannot make the daemon create a file anywhere else.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "infra.updater_boot_ready"

M.ENVIRONMENT = "ERGOPTI_UPDATER_BOOT_READY"

-- The watcher's token: <tmp>/ergopti-boot-ready.<random>/ready (restarter.lua).
local TOKEN_PATTERN = "^/.+/ergopti%-boot%-ready%.[%w]+/ready$"

local _reported = false

--- Writes the pid to the token through a temporary file.
--- @param path string Admitted token path.
--- @param pid string Daemon pid.
--- @param io_open function io.open or a test double.
--- @param rename function os.rename or a test double.
--- @return boolean written
--- @return string|nil detail Exact failure when written is false.
local function publish(path, pid, io_open, rename)
	local temporary = path .. ".tmp"
	local file, open_err = io_open(temporary, "wb")
	if not file then return false, tostring(open_err) end
	local wrote, write_err = file:write(pid, "\n")
	local closed, close_err = file:close()
	if not wrote or not closed then
		os.remove(temporary)
		return false, tostring(write_err or close_err)
	end
	local renamed, rename_err = rename(temporary, path)
	if not renamed then
		os.remove(temporary)
		return false, tostring(rename_err)
	end
	return true
end

--- Reports this daemon as ready to the watcher that started it, at most once.
--- @param reason string What made the daemon ready, for the log.
--- @param deps table|nil { getenv, pid, io_open, rename } test doubles.
--- @return boolean reported True when the token was written by this call.
function M.report(reason, deps)
	if _reported then return false end
	local getenv = deps and deps.getenv or os.getenv
	local path = getenv(M.ENVIRONMENT)
	if type(path) ~= "string" or path == "" then return false end
	_reported = true
	if not path:match(TOKEN_PATTERN) or path:find("/../", 1, true) or path:find("/./", 1, true) then
		Logger.warn(LOG, "Ignoring a boot-ready token outside the update watcher's folder.")
		return false
	end
	local pid = deps and deps.pid or require("luv").os_getpid()
	if type(pid) ~= "number" or pid <= 0 or pid % 1 ~= 0 then
		Logger.error(LOG, "The daemon cannot report ready: its pid is unreadable.")
		return false
	end
	local written, detail = publish(path, string.format("%.0f", pid), deps and deps.io_open or io.open,
		deps and deps.rename or os.rename)
	if not written then
		Logger.info(LOG, "No update watcher is waiting for this daemon (%s).", tostring(detail))
		return false
	end
	Logger.success(LOG, "Daemon reported ready to the update watcher (%s).", tostring(reason))
	return true
end

--- Forgets the one report (tests only).
function M.reset_for_tests()
	_reported = false
end

return M
