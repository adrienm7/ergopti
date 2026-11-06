--- infra/updater_boot_ready.lua

--- ==============================================================================
--- MODULE: Updater Boot Ready
--- DESCRIPTION:
--- Tells the release swap that opened this build that it started: the swap
--- keeps the chosen app only once its boot reports ready, and otherwise puts
--- the previous app back, as the Windows swap does with its boot-ready event.
---
--- FEATURES & RATIONALE:
--- 1. One-shot token: the swap opens the app with ERGOPTI_UPDATER_BOOT_READY
---    naming a file in its own fresh folder. The boot writes the launcher's
---    pid there once, atomically (temporary file, then rename), so a partial
---    write can never read as ready.
--- 2. Ready means the boot runs: boot complete, or the boot handing over to
---    the user (the Accessibility wait a new signature needs, onboarding).
---    Waiting for the user is healthy; a crash or a hang before it is not.
--- 3. Stale tokens are harmless: the launcher restarts its runtime with the
---    same environment, and by then the swap has removed its folder; the write
---    then fails and is logged at info level, never as an error.
--- 4. Only a token of the swap's shape is written, so an inherited variable
---    cannot make the boot create a file anywhere else.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")

local LOG = "updater_boot_ready"

M.ENVIRONMENT = "ERGOPTI_UPDATER_BOOT_READY"

-- The swap's token: <tmp>/ergopti-boot-ready.<random>/ready (release_installer.lua).
local TOKEN_PATTERN = "^/.+/ergopti%-boot%-ready%.[%w]+/ready$"

local _reported = false




-- =====================================
-- ======= 1/ Internal helpers =========
-- =====================================

--- Writes the launcher pid to the token through a temporary file.
--- @param path string Admitted token path.
--- @param pid string Launcher pid.
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




-- ==============================
-- ======= 2/ Public API ========
-- ==============================

--- Reports this boot as ready to the swap that opened it, at most once.
--- @param reason string What made the boot ready, for the log.
--- @param deps table|nil { getenv, io_open, rename } test doubles.
--- @return boolean reported True when the token was written by this call.
function M.report(reason, deps)
	if _reported then return false end
	local getenv = deps and deps.getenv or os.getenv
	local path = getenv(M.ENVIRONMENT)
	if type(path) ~= "string" or path == "" then return false end
	_reported = true
	if not path:match(TOKEN_PATTERN) or path:find("/../", 1, true) or path:find("/./", 1, true) then
		Logger.warn(LOG, "Ignoring a boot-ready token outside the release swap's folder.")
		return false
	end
	local pid = getenv("ERGOPTI_LAUNCHER_PID")
	if type(pid) ~= "string" or not pid:match("^[1-9]%d*$") then
		Logger.error(LOG, "The boot cannot report ready: the launcher exported no pid.")
		return false
	end
	local written, detail = publish(path, pid, deps and deps.io_open or io.open, deps and deps.rename or os.rename)
	if not written then
		-- The swap removes its folder once it decided; a later runtime restart
		-- inherits the same variable and lands here.
		Logger.info(LOG, "No release swap is waiting for this boot (%s).", tostring(detail))
		return false
	end
	Logger.success(LOG, "Boot reported ready to the release swap (%s).", tostring(reason))
	return true
end

--- Forgets the one report (tests only).
function M.reset_for_tests()
	_reported = false
end

return M
