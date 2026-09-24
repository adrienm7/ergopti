--- platform/remap/legacy_kanata.lua

--- ==============================================================================
--- MODULE: Legacy Kanata Retirement (Linux)
--- DESCRIPTION:
--- Earlier installs ran the tap-holds in kanata, from a user unit install.sh
--- wrote and enabled (kanata.service, "Kanata key remapping daemon (Ergopti)").
--- The daemon now runs them itself. Left running, that kanata would grab the
--- keyboard first and remap it before the daemon sees it: CapsLock would reach
--- the engine as Ctrl, and every tap-hold would be applied twice.
---
--- The updater replaces the driver's files and does not run install.sh, so the
--- daemon retires that unit itself at boot, before it looks for a keyboard. Only
--- the unit Ergopti wrote is touched: a kanata the user set up is theirs, and is
--- reported instead.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local ShellRunner = require("adapters.shell_runner")

local LOG = "platform.remap.legacy_kanata"

-- The Description line install.sh wrote: what tells our unit from the user's.
M.ERGOPTI_UNIT_DESCRIPTION = "Description=Kanata key remapping daemon (Ergopti)"
M.UNIT_NAME = "kanata.service"

local function read_file(path)
	local fh = io.open(path, "r")
	if not fh then return nil end
	local text = fh:read("*a")
	fh:close()
	return text
end

local function exists(path)
	local fh = io.open(path, "r")
	if fh then fh:close() end
	return fh ~= nil
end

--- Stops, disables and removes the kanata unit an earlier install wrote.
--- @param opts table { unit_path, kbd_path, run = function(cmd) -> boolean }
--- @return string "absent", "foreign", "retired" or "failed"
function M.retire(opts)
	if type(opts) ~= "table" or type(opts.unit_path) ~= "string" or type(opts.kbd_path) ~= "string" then
		error("legacy kanata retirement requires unit_path and kbd_path", 2)
	end
	local run = opts.run or ShellRunner.run
	local unit = read_file(opts.unit_path)
	if not unit then return "absent" end
	if not unit:find(M.ERGOPTI_UNIT_DESCRIPTION, 1, true) then
		Logger.warn(LOG, "A %s not written by Ergopti exists (%s): if it remaps the keyboard, "
			.. "the tap-holds are applied twice. Stop it to use the tray's tap-holds.",
			M.UNIT_NAME, opts.unit_path)
		return "foreign"
	end

	Logger.start(LOG, "Retiring the kanata unit of an earlier install…")
	-- A session without a user bus cannot stop it, but removing the unit still
	-- keeps it from starting at the next login, which is what matters most.
	if not run("systemctl --user disable --now " .. M.UNIT_NAME .. " >/dev/null 2>&1") then
		Logger.warn(LOG, "systemctl could not stop %s — it stays up until the next login.", M.UNIT_NAME)
	end
	local removed, err = os.remove(opts.unit_path)
	if not removed and exists(opts.unit_path) then
		Logger.error(LOG, "Cannot remove %s (%s) — kanata will start again at login.",
			opts.unit_path, tostring(err))
		return "failed"
	end
	run("systemctl --user daemon-reload >/dev/null 2>&1")
	os.remove(opts.kbd_path)
	Logger.success(LOG, "The kanata unit of an earlier install is retired; the daemon runs the tap-holds.")
	return "retired"
end

return M
