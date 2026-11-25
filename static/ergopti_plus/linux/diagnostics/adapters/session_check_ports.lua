--- diagnostics/adapters/session_check_ports.lua

--- ==============================================================================
--- MODULE: Session Health Check Ports (Linux)
--- DESCRIPTION:
--- The native side of the field run's « session » check
--- (diagnostics/engine/field_check/session_check.lua): the in-process readings
--- of the modules that own each fact, the read-only commands through the
--- daemon's asynchronous runner and the notification server's questions
--- through diagnostics/adapters/bus_query.lua.
---
--- FEATURES & RATIONALE:
--- 1. Each fact is asked of its owner (the installer's resolution, the hook,
---    its supervisor, the clipboard, the layout, the focus source, the perf
---    counters), never re-derived here.
--- 2. Groups are the daemon's own process groups (/proc/self/status), the ones
---    its open of /dev/uinput and /dev/input runs with, not the login's.
--- 3. A command is bounded by a share of the step's deadline; the commands run
---    one after the other, so together they never outlast it.
--- ==============================================================================

local M = {}

-- The udev rule install/setup_permissions.sh installs into the system rules
-- folder (the packages ship the same path, tools/test/test-linux-arch-package.cjs).
local UDEV_RULES_DIR = "/etc/udev/rules.d/"
M.UINPUT_RULE = UDEV_RULES_DIR .. require("core.text.engine.identifiers").linux_desktop.uinput_udev_rule_file
M.UINPUT_PATH = "/dev/uinput"
M.INPUT_CLASS_DIR = "/sys/class/input"

-- The check runs at most about eight commands and bus requests in turn
-- (constants.toml [adapters]).
M.COMMAND_SHARE = require("core.timing.engine.timings").count("adapters", "field_session_command_share")

--- Reads a small file, nil when it cannot be read.
local function read_file(path)
	return require("core.fs.engine.regular_file_reader").read_source(path)
end

--- The names of a list of group ids, from /etc/group.
local function group_names(gids)
	local names, wanted = {}, {}
	for _, gid in ipairs(gids) do wanted[gid] = true end
	for line in tostring(read_file("/etc/group") or ""):gmatch("[^\n]+") do
		local name, gid = line:match("^([^:]+):[^:]*:(%d+):")
		if name and wanted[tonumber(gid)] then names[#names + 1] = name end
	end
	return names
end

--- This process's supplementary and primary groups, by name.
local function process_groups()
	local status = read_file("/proc/self/status") or ""
	local gids = {}
	for gid in (status:match("\nGroups:([^\n]*)") or ""):gmatch("%d+") do gids[#gids + 1] = tonumber(gid) end
	local primary = status:match("\nGid:%s*(%d+)")
	if primary then gids[#gids + 1] = tonumber(primary) end
	return group_names(gids)
end

--- The udev rule's presence and the group /dev/uinput carries.
local function uinput_rule()
	local uv = require("luv")
	local present = uv.fs_stat(M.UINPUT_RULE) ~= nil
	local stat = uv.fs_stat(M.UINPUT_PATH)
	local group = stat and group_names({ stat.gid })[1] or nil
	return { present = present, group = group or (stat and tostring(stat.gid)) or "absent" }
end

--- The /dev/input node of each named virtual device, from sysfs.
local function virtual_devices()
	local uv = require("luv")
	local Names = require("platform.input.device_names")
	local devices = { keyboard_name = Names.VIRTUAL_KEYBOARD }
	local handle = uv.fs_scandir(M.INPUT_CLASS_DIR)
	while handle do
		local entry = uv.fs_scandir_next(handle)
		if not entry then break end
		if entry:match("^event%d+$") then
			local name = (read_file(M.INPUT_CLASS_DIR .. "/" .. entry .. "/device/name") or ""):gsub("%s+$", "")
			if name == Names.VIRTUAL_KEYBOARD then devices.keyboard = "/dev/input/" .. entry end
			if name == Names.VIRTUAL_POINTER then devices.pointer = "/dev/input/" .. entry end
		end
	end
	return devices
end

--- Where lgi is found, and the Lua version its native module is built for.
local function lgi_facts()
	local runtime = _VERSION:match("(%d+%.%d+)")
	local loaded = package.loaded["lgi"] ~= nil
	local core = package.searchpath("lgi.corelgi", package.cpath)
	local module = package.searchpath("lgi", package.path)
	local target = core and core:match("/lua/(%d+%.%d+)/") or nil
	return { found = loaded or (core ~= nil and module ~= nil), target = target, runtime = runtime }
end

--- The focus source's state on KDE and GNOME.
local function focus_facts()
	local DisplayServer = require("core.ui.engine.display_server")
	local WindowInfo = require("platform.focus.window_info")
	local desktop = DisplayServer.desktop_is("kde") and "kde" or (DisplayServer.desktop_is("gnome") and "gnome") or nil
	if not DisplayServer.is_wayland() or WindowInfo.compositor_focus_status() == nil then desktop = nil end
	return { desktop = desktop, script_state = WindowInfo.compositor_script_state(),
		extension_problem = WindowInfo.compositor_extension_problem() }
end

--- Every in-process reading of the check.
--- @return table facts
local function facts()
	local DisplayServer = require("core.ui.engine.display_server")
	local Paths = require("core.fs.engine.paths")
	local install = require("modules.updater.installer").resolve(Paths.driver_root() .. "/modules/updater/manager.lua")
	local TextStatus = require("platform.focus.text_automation_status")
	local state, reason = TextStatus.mode()
	local Layout = require("adapters.keyboard_layout")
	local spans = require("core.logger.engine.perf_counters").snapshot().spans
	local dispatch = spans["input.dispatch"] or {}
	local Shell = require("core.process.adapters.shell_runner")
	return {
		install = { kind = install.kind, launcher = install.launcher ~= nil },
		groups = process_groups(),
		uinput_rule = uinput_rule(),
		focus = focus_facts(),
		text_automation = { state = state, reason = reason, accessibility = TextStatus.accessibility() },
		layout = { name = Layout.layout_name(), kde_wayland = DisplayServer.is_wayland() and DisplayServer.desktop_is("kde"),
			watch = require("modules.keymap.kde_layout_watch").status() },
		lgi = lgi_facts(),
		hook_lifetime = require("platform.input.hook_supervisor").lifetime(),
		hook_stop = require("platform.input.keyboard_hook").last_stop(),
		clipboard_restore_failures = require("clipboard.adapters.clipboard").restore_failures(),
		dispatch = { n = dispatch.n, sum_ms = dispatch.sum_ms, max_ms = dispatch.max_ms, slow = dispatch.slow },
		grabbed = require("platform.input.evdev_reader").grabbed_paths(),
		devices = virtual_devices(),
		notify_send = Shell.has_command("notify-send", true),
	}
end

--- Builds the ports.
--- @param check string The check's id in the field run declaration.
--- @return table ports
function M.new(check)
	local Shell = require("core.process.adapters.shell_runner")
	local timeout_ms = require("diagnostics.adapters.setup_check_ports").step_deadline_ms(check) / M.COMMAND_SHARE
	return {
		facts = facts,
		run = function(argv, done)
			if not Shell.has_command(argv[1], true) then return nil, "not_found" end
			local args = {}
			for index = 2, #argv do args[#args + 1] = argv[index] end
			return Shell.run_async(argv[1], args, { timeout_ms = timeout_ms,
				max_output_bytes = require("diagnostics.adapters.bus_query").MAX_OUTPUT_BYTES }, function(result)
				if result.timed_out then done(nil, nil, "timeout")
				elseif type(result.code) == "number" then done(result.code, result.stdout)
				else done(nil, nil, "error") end
			end)
		end,
		bus = require("diagnostics.adapters.bus_query").new(timeout_ms),
	}
end

return M
