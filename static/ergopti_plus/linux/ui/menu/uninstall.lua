--- ui/menu/uninstall.lua

--- ==============================================================================
--- MODULE: Linux Menu Uninstallation
--- DESCRIPTION:
--- Hands a confirmed removal to an independent worker, then asks the daemon to
--- finish its normal shutdown. The worker waits for that exact process before
--- invoking the package manager or removing installer-owned standalone files.
--- A local version run from source has nothing to remove: the About row is
--- greyed there, and a click that still arrives does nothing.
--- ==============================================================================

local M = {}
local WindowTitles = require("window_titles")

local ShellRunner = require("adapters.shell_runner")
local Paths = require("infra.paths")
local Installation = require("infra.installation")
local Logger = require("logger.shim")

local LOG = "ui.menu.uninstall"

--- Reads one complete file without treating a missing file as empty content.
--- @param path string
--- @return string|nil
local function read_file(path)
	local file = io.open(path, "rb")
	if not file then return nil end
	local value = file:read("*a")
	file:close()
	return value
end

--- Requests removal after the menu's own localized confirmation.
--- @param opts table { confirm, fail, quit, title, confirmation, failure }; tests
---   also pass root, version_source, run, read and getenv.
--- @return boolean launched
function M.run(opts)
	local root = opts.root or Paths.driver_root()
	local run = opts.run or ShellRunner.run
	local read = opts.read or read_file
	local getenv = opts.getenv or os.getenv
	local quote = ShellRunner.quote
	if Installation.is_source_run(root, opts.version_source) then
		-- No failure dialog: the row already says there is nothing to remove.
		Logger.info(LOG, "Uninstall ignored: this is a local version run from source, with nothing to remove.")
		return false
	end
	local layout = Installation.layout(root)
	local prefix = layout.prefix
	if not layout.system and not prefix then
		opts.fail(opts.failure)
		return false
	end
	local command = "/bin/bash " .. quote(root .. "/uninstall.sh")
	if prefix then command = command .. " --prefix " .. quote(prefix) end
	if not run(command .. " --check") then
		opts.fail(opts.failure)
		return false
	end
	if not opts.confirm(opts.title, opts.confirmation) then return false end
	local stat = read("/proc/self/stat") or ""
	local pid, fields = stat:match("^(%d+) %(.+%) (.+)$")
	local values = {}
	for value in (fields or ""):gmatch("%S+") do values[#values + 1] = value end
	local started = values[20]
	if not pid or not started or not started:match("^%d+$") then
		opts.fail(opts.failure)
		return false
	end
	command = command .. " --yes --wait-owner " .. quote(pid .. ":" .. started)
		.. " --gui " .. quote(WindowTitles.compose(opts.title)) .. " " .. quote(opts.failure)
	if run("systemctl --user show-environment >/dev/null 2>&1") then
		local launcher = "systemd-run --user --collect --quiet --service-type=exec --unit="
			.. quote("ergopti-uninstall-" .. pid .. "-" .. started)
		for _, key in ipairs({ "DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS" }) do
			local value = getenv(key)
			if value and value ~= "" then launcher = launcher .. " --setenv=" .. quote(key .. "=" .. value) end
		end
		command = launcher .. " " .. command
	else
		if not run("command -v setsid >/dev/null 2>&1") then
			opts.fail(opts.failure)
			return false
		end
		-- There is no service control group to escape on this desktop. setsid
		-- keeps removal alive when the tray's session leader exits.
		command = "setsid " .. command .. " </dev/null >/dev/null 2>&1 &"
	end
	if not run(command) then
		opts.fail(opts.failure)
		return false
	end
	opts.quit()
	return true
end

return M
