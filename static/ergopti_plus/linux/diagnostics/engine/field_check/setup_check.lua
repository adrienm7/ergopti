--- diagnostics/engine/field_check/setup_check.lua

--- ==============================================================================
--- MODULE: Session Setup Check Steps (Linux)
--- DESCRIPTION:
--- The steps of the field run's « setup » check: what install.sh and the
--- desktop session must have given the daemon, read from inside it. The
--- input path (/dev/uinput writable, one evdev node readable), the systemd
--- user unit enabled at login, a polkit authentication agent running, and on
--- a GNOME, KDE or COSMIC Wayland session the compositor focus reporter
--- listening.
---
--- FEATURES & RATIONALE:
--- 1. These were the collector's probe steps only (field_guided_steps.json),
---    so the menu's in-app field report could not decide the field points
---    physical_acceptance and wayland_focus. The daemon reads the same facts
---    here, and reads the focus source's own state instead of its log line.
--- 2. Every port is injected (diagnostics/adapters/setup_check_ports.lua), so
---    the steps run in the unit suite without a session.
--- 3. A step that does not apply to this session (no compositor focus source
---    under X11, no systemd user manager) is a skip with its closed code, never
---    a pass.
--- ==============================================================================

local Report = require("diagnostics.engine.field_check.report")

local M = {}

M.CHECK_ID = "setup"

-- The paths install.sh opens to the user's groups
M.UINPUT_PATH = "/dev/uinput"
M.INPUT_DIR = "/dev/input"

-- The systemd user unit the installer enables
M.UNIT = require("modules.updater.restarter").UNIT

-- The polkit agents of the common desktops, as pgrep -f reads them
M.POLKIT_PATTERN = "polkit.*agent|polkit-gnome|polkit-kde|lxpolkit|mate-polkit"

-- Each command's bound: both answer at once on a working session
M.COMMAND_TIMEOUT_MS = 5000

--- The closed code of a refused access.
--- @param code string|nil Native error name (EACCES, ENOENT, ...).
--- @return string
local function access_code(code)
	if code == "EACCES" or code == "EPERM" then return "denied" end
	if code == "ENOENT" then return "missing" end
	return "error"
end

--- Records the two input path steps.
--- @param ports table
--- @param report table
local function input_steps(ports, report)
	local writable, code = ports.access(M.UINPUT_PATH, "W")
	report.step("uinput_writable", writable and Report.STATE_PASS or Report.STATE_FAIL,
		not writable and access_code(code) or nil)
	local names = ports.list_dir(M.INPUT_DIR)
	local nodes, readable, last = 0, false, nil
	for _, name in ipairs(names or {}) do
		if name:match("^event%d+$") then
			nodes = nodes + 1
			local ok, why = ports.access(M.INPUT_DIR .. "/" .. name, "R")
			if ok then readable = true; break end
			last = why
		end
	end
	report.step("evdev_readable", readable and Report.STATE_PASS or Report.STATE_FAIL,
		not readable and (nodes == 0 and "no_device" or access_code(last)) or nil)
end

--- Records the focus reporter step.
--- @param ports table
--- @param report table
local function focus_step(ports, report)
	local status = ports.focus_status()
	if status == nil then
		report.step("focus_listening", Report.STATE_SKIP, "no_compositor_source")
	elseif status == "ready" then
		report.step("focus_listening", Report.STATE_PASS)
	else
		report.step("focus_listening", Report.STATE_FAIL, status)
	end
end

--- Runs the steps, then calls finish once.
--- @param ports table {
---   access = function(path, mode "R"|"W") -> boolean, error name|nil,
---   list_dir = function(dir) -> names|nil,
---   run = function(argv, timeout_ms, done(exit code|nil, why|nil)) -> handle|nil, why: done is
---     called once with the exit code, or nil and "not_found", "timeout" or "error",
---   focus_status = function() -> nil (no compositor focus source) or its status }
--- @param report table field check report.
--- @param finish function
function M.run(ports, report, finish)
	input_steps(ports, report)
	focus_step(ports, report)
	-- The two commands one after the other: each answer is recorded before the next starts
	local function command(id, argv, absent_state, absent_code, fail_code, next_step)
		local settled = false
		local function done(exit_code, why)
			if settled then return end
			settled = true
			if exit_code == 0 then
				report.step(id, Report.STATE_PASS)
			elseif exit_code ~= nil then
				report.step(id, Report.STATE_FAIL, fail_code)
			elseif why == "not_found" then
				report.step(id, absent_state, absent_code)
			else
				report.step(id, Report.STATE_FAIL, why == "timeout" and "timeout" or "error")
			end
			next_step()
		end
		local handle, refusal = ports.run(argv, M.COMMAND_TIMEOUT_MS, done)
		if handle == nil then done(nil, refusal == "not_found" and "not_found" or "error") end
	end
	command("unit_enabled", { "systemctl", "--user", "is-enabled", "--quiet", M.UNIT },
		Report.STATE_SKIP, "no_systemd", "not_enabled", function()
			command("polkit_agent", { "pgrep", "-f", M.POLKIT_PATTERN },
				Report.STATE_FAIL, "no_pgrep", "not_running", finish)
		end)
end

return M
