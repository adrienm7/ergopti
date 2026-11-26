--- diagnostics/engine/field_check/session_check.lua

--- ==============================================================================
--- MODULE: Session Health Check Steps (Linux)
--- DESCRIPTION:
--- The steps of the field run's « session » check: what the daemon found in
--- the user's real session and how it held up since it started, read from
--- inside it. The installation and the restart path a Reload takes, the input
--- groups and the udev rule, how udev and libinput classify the two virtual
--- devices, that no touchpad is grabbed, the compositor focus script, the
--- text automation mode, the active keyboard layout and its KDE watch, lgi,
--- the keyboard hook's outages and emergency stop, the clipboard restores, a
--- dispatch latency sample and the notification server.
---
--- FEATURES & RATIONALE:
--- 1. The fixes of 2026-11-25 each had a symptom only a real desktop showed
---    (the touchpad disabled because udev read the keyboard as a mouse, the
---    layout resolved on KDE's first group, a silent hook restart, a lost
---    clipboard). Each one's own state is read here, so one in-app field
---    report says whether it holds on the tester's machine.
--- 2. Nothing is changed and nothing is typed: in-process readings, three
---    read-only commands (udevadm, libinput list-devices) and two session-bus
---    questions to the notification server.
--- 3. A step that does not apply (no virtual pointer while no wheel binding is
---    held, no KWin off KDE, no libinput tool) is a skip with its code.
--- 4. Pure: every fact and command is a port, so the steps run in the unit suite.
--- ==============================================================================

local Report = require("diagnostics.engine.field_check.report")

local M = {}

-- The udev properties a device's class is read from (60-input-id.rules).
M.KEYBOARD_PROPERTY = "ID_INPUT_KEYBOARD"
M.POINTER_PROPERTIES = { "ID_INPUT_MOUSE", "ID_INPUT_TOUCHPAD", "ID_INPUT_POINTINGSTICK", "ID_INPUT_TABLET" }
M.TOUCHPAD_PROPERTY = "ID_INPUT_TOUCHPAD"

-- The groups install.sh adds the user to (install/setup_permissions.sh).
M.INPUT_GROUPS = { "input", "uinput" }

-- The notification server's capability for a notice that stays until closed.
M.PERSISTENCE_CAPABILITY = require("core.text.engine.identifiers").linux_desktop.notification_persistence

M.NOTIFICATIONS_NAME = "org.freedesktop.Notifications"
M.NOTIFICATIONS_PATH = "/org/freedesktop/Notifications"

--- The properties of `udevadm info --query=property`, by name.
--- @param text string|nil
--- @return table properties
function M.parse_udev(text)
	local properties = {}
	for line in tostring(text or ""):gmatch("[^\n]+") do
		local key, value = line:match("^([%w_]+)=(.*)$")
		if key then properties[key] = value end
	end
	return properties
end

--- The capabilities `libinput list-devices` names for a device, nil when the
--- device is not listed.
--- @param text string|nil
--- @param name string The device name.
--- @return table|nil capabilities Capability name -> true.
function M.parse_libinput(text, name)
	for block in (tostring(text or "") .. "\n\n"):gmatch("(.-)\n%s*\n") do
		local device = block:match("Device:%s*([^\n]-)%s*\n")
		if device == name then
			local list = block:match("Capabilities:%s*([^\n]*)") or ""
			local capabilities = {}
			for word in list:gmatch("[%w%-]+") do capabilities[word] = true end
			return capabilities
		end
	end
	return nil
end

--- A free text (a layout or server name) as a closed value token.
--- @param text string|nil
--- @return string|nil
function M.token(text)
	if type(text) ~= "string" or text == "" then return nil end
	local token = text:gsub("[^%w%.%+%-]+", "_"):gsub("^_+", ""):gsub("_+$", "")
	if token == "" then return nil end
	return token:sub(1, Report.MAX_VALUE_LENGTH)
end





-- ======================================
-- ======================================
-- ======= 1/ In-process steps ==========
-- ======================================
-- ======================================

--- The installation, the restart path, the groups and the udev rule.
local function install_steps(facts, report)
	local install = facts.install or {}
	report.step("install_origin", Report.STATE_INFO, install.kind or "unknown")
	report.step("reload_path", install.launcher and Report.STATE_PASS or Report.STATE_FAIL,
		install.launcher and install.kind or "no_launcher")
	local held, missing = {}, {}
	for _, name in ipairs(facts.groups or {}) do held[name] = true end
	for _, name in ipairs(M.INPUT_GROUPS) do
		if not held[name] then missing[#missing + 1] = "no_" .. name end
	end
	report.step("input_groups", #missing == 0 and Report.STATE_PASS or Report.STATE_FAIL,
		#missing > 0 and table.concat(missing, "+") or nil)
	local rule = facts.uinput_rule or {}
	if not rule.present then
		report.step("uinput_rule", Report.STATE_FAIL, "missing")
	elseif rule.group ~= "uinput" then
		report.step("uinput_rule", Report.STATE_FAIL, "wrong_group:" .. (M.token(rule.group) or "unknown"))
	else
		report.step("uinput_rule", Report.STATE_PASS)
	end
end

--- The compositor focus source, the text automation and the layout.
local function desktop_steps(facts, report)
	local focus = facts.focus or {}
	if focus.desktop == "kde" then
		local loaded = focus.script_state == "loaded"
		report.step("focus_script", loaded and Report.STATE_PASS or Report.STATE_FAIL,
			loaded and "loaded" or (focus.script_state or "unanswered"))
	elseif focus.desktop == "gnome" then
		report.step("focus_script", focus.extension_problem == nil and Report.STATE_PASS or Report.STATE_FAIL,
			focus.extension_problem or "reporting")
	else
		report.step("focus_script", Report.STATE_SKIP, "no_compositor_source")
	end
	local text = facts.text_automation or {}
	report.step("text_automation", Report.STATE_INFO,
		text.state and (text.state .. ":" .. tostring(text.reason or "none")) or "unbound")
	report.step("accessibility_bus", Report.STATE_INFO, text.accessibility or "unknown")
	local layout = facts.layout or {}
	local name = M.token(layout.name)
	report.step("active_layout", name and Report.STATE_PASS or Report.STATE_FAIL, name or "unresolved")
	if layout.kde_wayland then
		report.step("kde_layout_watch", layout.watch == "watching" and Report.STATE_PASS or Report.STATE_FAIL,
			layout.watch or "idle")
	else
		report.step("kde_layout_watch", Report.STATE_SKIP, "not_kde_wayland")
	end
	local lgi = facts.lgi or {}
	if not lgi.found then
		report.step("lgi_module", Report.STATE_FAIL, "missing")
	elseif lgi.target ~= nil and lgi.target ~= lgi.runtime then
		report.step("lgi_module", Report.STATE_FAIL, "wrong_lua:" .. lgi.target)
	else
		report.step("lgi_module", Report.STATE_PASS, lgi.target or lgi.runtime)
	end
end

--- How the typing path held up since the daemon started.
local function health_steps(facts, report)
	local lifetime = facts.hook_lifetime or {}
	local outages = tonumber(lifetime.outages) or 0
	report.step("hook_restarts", outages == 0 and Report.STATE_PASS or Report.STATE_FAIL, tostring(outages))
	local stop = facts.hook_stop
	if stop == nil or stop.deliberate then
		report.step("emergency_stop", Report.STATE_PASS)
	else
		report.step("emergency_stop", Report.STATE_FAIL, M.token(stop.reason) or "stopped")
	end
	local failures = tonumber(facts.clipboard_restore_failures) or 0
	report.step("clipboard_restore", failures == 0 and Report.STATE_PASS or Report.STATE_FAIL, tostring(failures))
	local dispatch = facts.dispatch or {}
	local count = tonumber(dispatch.n) or 0
	if count == 0 then
		report.step("dispatch_latency", Report.STATE_SKIP, "no_keys")
	else
		report.step("dispatch_latency", Report.STATE_INFO,
			"average:" .. string.format("%.2f", (tonumber(dispatch.sum_ms) or 0) / count) .. "+maximum:"
				.. string.format("%.2f", tonumber(dispatch.max_ms) or 0))
	end
	report.step("hotpath_slow", Report.STATE_INFO, tostring(tonumber(dispatch.slow) or 0))
end





-- ======================================
-- ======================================
-- ======= 2/ Commands and the bus ======
-- ======================================
-- ======================================

--- Runs a list of asynchronous tasks one after the other, then done().
local function sequence(tasks, done)
	local index = 0
	local function next_task()
		index = index + 1
		local task = tasks[index]
		if task == nil then return done() end
		task(next_task)
	end
	next_task()
end

--- One command's output; done(stdout|nil, why).
local function command(ports, argv, done)
	local settled = false
	local function finish(stdout, why)
		if settled then return end
		settled = true
		done(stdout, why)
	end
	local handle, refusal = ports.run(argv, function(exit_code, stdout, why)
		if exit_code == 0 then finish(stdout or "") else finish(nil, exit_code ~= nil and "exit" or (why or "error")) end
	end)
	if handle == nil then finish(nil, refusal == "not_found" and "not_found" or "error") end
end

--- The udev class of one virtual device.
local function device_class_step(ports, id, path, want_keyboard, next_task, report)
	if path == nil then
		report.step(id, Report.STATE_SKIP, want_keyboard and "no_device" or "not_created")
		return next_task()
	end
	command(ports, { "udevadm", "info", "--query=property", "--name=" .. path }, function(stdout, why)
		if stdout == nil then
			report.step(id, why == "not_found" and Report.STATE_SKIP or Report.STATE_FAIL,
				why == "not_found" and "no_udevadm" or why)
			return next_task()
		end
		local properties = M.parse_udev(stdout)
		local pointer = nil
		for _, name in ipairs(M.POINTER_PROPERTIES) do
			if properties[name] == "1" then pointer = pointer or name:gsub("^ID_INPUT_", ""):lower() end
		end
		local keyboard = properties[M.KEYBOARD_PROPERTY] == "1"
		if want_keyboard then
			report.step(id, (keyboard and not pointer) and Report.STATE_PASS or Report.STATE_FAIL,
				pointer or (not keyboard and "not_keyboard") or nil)
		else
			report.step(id, (pointer == "mouse" and not keyboard) and Report.STATE_PASS or Report.STATE_FAIL,
				(keyboard and "keyboard") or (pointer ~= "mouse" and (pointer or "not_pointer")) or nil)
		end
		next_task()
	end)
end

--- libinput's capabilities of the virtual keyboard: a keyboard, never a pointer.
local function libinput_step(ports, facts, next_task, report)
	command(ports, { "libinput", "list-devices" }, function(stdout, why)
		if stdout == nil then
			report.step("libinput_keyboard", Report.STATE_SKIP, why == "not_found" and "no_libinput" or "unreadable")
			return next_task()
		end
		local capabilities = M.parse_libinput(stdout, facts.devices.keyboard_name)
		if capabilities == nil then
			report.step("libinput_keyboard", Report.STATE_SKIP, "not_listed")
		elseif capabilities.pointer or capabilities.touch or not capabilities.keyboard then
			report.step("libinput_keyboard", Report.STATE_FAIL, capabilities.pointer and "pointer" or
				(capabilities.touch and "touch" or "not_keyboard"))
		else
			report.step("libinput_keyboard", Report.STATE_PASS)
		end
		next_task()
	end)
end

--- No grabbed device is a touchpad.
local function grab_step(ports, facts, next_task, report)
	local paths = facts.grabbed or {}
	local index, touchpad, unreadable = 0, false, false
	local function next_path()
		index = index + 1
		local path = paths[index]
		if path == nil then
			report.step("touchpad_not_grabbed", touchpad and Report.STATE_FAIL or Report.STATE_PASS,
				touchpad and "touchpad_grabbed" or (unreadable and "unclassified" or tostring(#paths)))
			return next_task()
		end
		command(ports, { "udevadm", "info", "--query=property", "--name=" .. path }, function(stdout)
			if stdout == nil then unreadable = true
			elseif M.parse_udev(stdout)[M.TOUCHPAD_PROPERTY] == "1" then touchpad = true end
			next_path()
		end)
	end
	next_path()
end

--- The notification server answers and keeps a notice until it is closed.
local function notification_steps(ports, facts, next_task, report)
	local function call(method, done)
		local handle, why = ports.bus({ "call", M.NOTIFICATIONS_NAME, M.NOTIFICATIONS_PATH, M.NOTIFICATIONS_NAME, method },
			function(reply, failure) done(type(reply) == "table" and reply.data or nil, failure) end)
		if handle == nil then done(nil, why) end
	end
	call("GetServerInformation", function(info, why)
		if type(info) ~= "table" then
			report.step("notify_server", why == "not_found" and Report.STATE_SKIP or Report.STATE_FAIL,
				why == "not_found" and "no_busctl" or "no_server")
			report.step("notify_persistence", Report.STATE_SKIP, "no_server")
			return next_task()
		end
		report.step("notify_server", facts.notify_send and Report.STATE_PASS or Report.STATE_FAIL,
			facts.notify_send and (M.token(info[1]) or "unnamed") or "no_notify_send")
		call("GetCapabilities", function(values)
			local capabilities = type(values) == "table" and values[1] or nil
			local persistent = false
			for _, name in ipairs(type(capabilities) == "table" and capabilities or {}) do
				if name == M.PERSISTENCE_CAPABILITY then persistent = true end
			end
			report.step("notify_persistence", persistent and Report.STATE_PASS or Report.STATE_INFO,
				not persistent and "no_persistence" or nil)
			next_task()
		end)
	end)
end





-- ======================================
-- ======================================
-- ======= 3/ Run =======================
-- ======================================
-- ======================================

--- Runs the steps, then calls finish once.
--- @param ports table {
---   facts = function() -> table   the in-process readings (see the steps above),
---   run = function(argv, done(exit code|nil, stdout|nil, why|nil)) -> handle|nil, why:
---     done once with the exit code and stdout, or nil and "not_found", "timeout" or "error",
---   bus = function(args, done(reply|nil, why)) -> handle|nil, why: one busctl request
---     (diagnostics/adapters/bus_query.lua) }
--- @param report table field check report.
--- @param finish function
function M.run(ports, report, finish)
	local facts = ports.facts()
	facts.devices = facts.devices or {}
	install_steps(facts, report)
	desktop_steps(facts, report)
	health_steps(facts, report)
	sequence({
		function(next_task)
			device_class_step(ports, "virtual_keyboard_class", facts.devices.keyboard, true, next_task, report)
		end,
		function(next_task)
			device_class_step(ports, "virtual_pointer_class", facts.devices.pointer, false, next_task, report)
		end,
		function(next_task) libinput_step(ports, facts, next_task, report) end,
		function(next_task) grab_step(ports, facts, next_task, report) end,
		function(next_task) notification_steps(ports, facts, next_task, report) end,
	}, finish)
end

return M
