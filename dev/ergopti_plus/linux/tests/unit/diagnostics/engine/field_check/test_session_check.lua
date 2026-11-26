--- tests/unit/diagnostics/engine/field_check/test_session_check.lua

--- ==============================================================================
--- MODULE: Session Health Check (Linux)
--- DESCRIPTION:
--- The field run's « session » check (diagnostics/engine/field_check/session_check.lua)
--- over scripted facts, commands and notification server:
--- 1. a healthy KDE Wayland session passes every step, with its fixed argv;
--- 2. the defects of 2026-11-25 fail by name: the virtual keyboard read as a
---    mouse by udev and as a pointer by libinput, a grabbed touchpad, a hook
---    restart, an emergency stop, a lost clipboard, an unresolved layout, the
---    KWin script not loaded, lgi built for another Lua, no restart launcher,
---    a missing input group or udev rule;
--- 3. what does not apply is a skip: no virtual pointer, no libinput tool, no
---    keys typed yet, an X11 session;
--- 4. the parsers read udevadm and libinput list-devices output;
--- 5. the field run declares the step, its check and its title.
--- ==============================================================================

local helpers = require("tests.helpers")

local Check = require("diagnostics.engine.field_check.session_check")
local Report = require("diagnostics.engine.field_check.report")

local KEYBOARD_UDEV = "DEVNAME=/dev/input/event21\nID_INPUT=1\nID_INPUT_KEY=1\nID_INPUT_KEYBOARD=1\n"
local MOUSE_UDEV = "DEVNAME=/dev/input/event22\nID_INPUT=1\nID_INPUT_MOUSE=1\n"
local TOUCHPAD_UDEV = "ID_INPUT=1\nID_INPUT_TOUCHPAD=1\n"
local LIBINPUT = "Device:           Ergopti Virtual Keyboard\nKernel:           /dev/input/event21\n"
	.. "Capabilities:     keyboard \n\nDevice:           SynPS/2 Synaptics TouchPad\nCapabilities:     pointer gesture\n"

--- The facts of a healthy KDE Wayland session; `change` overrides some.
local function facts(change)
	local base = {
		install = { kind = "standalone", launcher = true },
		groups = { "adrien", "wheel", "input", "uinput" },
		uinput_rule = { present = true, group = "uinput" },
		focus = { desktop = "kde", script_state = "loaded" },
		text_automation = { state = "window", reason = "no_accessible_field", accessibility = "enabled" },
		layout = { name = "French (Ergopti)", kde_wayland = true, watch = "watching" },
		lgi = { found = true, target = "5.1", runtime = "5.1" },
		hook_lifetime = { outages = 0, restarts = 0, exhausted = 0 },
		hook_stop = nil,
		clipboard_restore_failures = 0,
		dispatch = { n = 400, sum_ms = 40, max_ms = 3.5, slow = 0 },
		grabbed = { "/dev/input/event3" },
		devices = { keyboard_name = "Ergopti Virtual Keyboard", keyboard = "/dev/input/event21", pointer = "/dev/input/event22" },
		notify_send = true,
	}
	for key, value in pairs(change or {}) do base[key] = value end
	return base
end

--- Runs the check over a world; returns its steps by id, its result and the commands.
local function run(change, world)
	world = world or {}
	local calls = {}
	local ports = {
		facts = function() return facts(change) end,
		run = function(argv, done)
			calls[#calls + 1] = table.concat(argv, " ")
			if argv[1] == "libinput" and world.no_libinput then return nil, "not_found" end
			local output = argv[1] == "libinput" and (world.libinput or LIBINPUT)
				or (world.udev or {})[argv[4]:sub(8)] or (argv[4]:find("event22") and MOUSE_UDEV)
				or (argv[4]:find("event3") and "ID_INPUT_KEYBOARD=1\n") or KEYBOARD_UDEV
			done(0, output)
			return {}
		end,
		bus = function(args, done)
			calls[#calls + 1] = table.concat(args, " ")
			if world.no_server then done(nil, "exit"); return {} end
			if args[5] == "GetServerInformation" then done({ data = { "Plasma", "KDE", "6.8", "1.2" } })
			else done({ data = { { "body", world.no_persistence and "actions" or "persistence" } } }) end
			return {}
		end,
	}
	local report = Report.new_report("session")
	local finished = 0
	Check.run(ports, report, function() finished = finished + 1 end)
	helpers.assert_eq(finished, 1, "the check finishes once")
	local result, by_id = report.result(), {}
	for _, step in ipairs(result.steps) do by_id[step.id] = step end
	return by_id, result, calls
end

helpers.describe("field run session check (linux)", function()
	helpers.it("passes a healthy KDE Wayland session with its fixed commands (session-check)", function()
		local steps, result, calls = run()
		helpers.assert_true(result.passed, Report.format_log_line(result))
		for _, id in ipairs({ "reload_path", "input_groups", "uinput_rule", "focus_script", "active_layout",
			"kde_layout_watch", "lgi_module", "hook_restarts", "emergency_stop", "clipboard_restore",
			"virtual_keyboard_class", "virtual_pointer_class", "libinput_keyboard", "touchpad_not_grabbed",
			"notify_server", "notify_persistence" }) do
			helpers.assert_eq(steps[id].state, Report.STATE_PASS, id)
		end
		helpers.assert_eq(steps.install_origin.value, "standalone")
		helpers.assert_eq(steps.active_layout.value, "French_Ergopti")
		helpers.assert_eq(steps.dispatch_latency.value, "average:0.10+maximum:3.50")
		helpers.assert_eq(steps.notify_server.value, "Plasma")
		helpers.assert_eq(calls, {
			"udevadm info --query=property --name=/dev/input/event21",
			"udevadm info --query=property --name=/dev/input/event22",
			"libinput list-devices",
			"udevadm info --query=property --name=/dev/input/event3",
			"call org.freedesktop.Notifications /org/freedesktop/Notifications org.freedesktop.Notifications GetServerInformation",
			"call org.freedesktop.Notifications /org/freedesktop/Notifications org.freedesktop.Notifications GetCapabilities",
		})
	end)

	helpers.it("fails the defects of 2026-11-25 by name (session-check)", function()
		local steps = run({ hook_lifetime = { outages = 1 }, hook_stop = { deliberate = false, reason = "output failure" },
			clipboard_restore_failures = 2, layout = { kde_wayland = true, watch = "stopped" },
			focus = { desktop = "kde", script_state = "not_loaded" }, lgi = { found = true, target = "5.4", runtime = "5.1" },
			install = { kind = "appimage", launcher = false }, groups = { "wheel" }, uinput_rule = { present = false } },
			{ udev = { ["/dev/input/event21"] = KEYBOARD_UDEV .. "ID_INPUT_MOUSE=1\n", ["/dev/input/event3"] = TOUCHPAD_UDEV },
				libinput = "Device: Ergopti Virtual Keyboard\nCapabilities: keyboard pointer\n" })
		local expected = {
			hook_restarts = "1", emergency_stop = "output_failure", clipboard_restore = "2", active_layout = "unresolved",
			kde_layout_watch = "stopped", focus_script = "not_loaded", lgi_module = "wrong_lua:5.4", reload_path = "no_launcher",
			input_groups = "no_input+no_uinput", uinput_rule = "missing", virtual_keyboard_class = "mouse",
			libinput_keyboard = "pointer", touchpad_not_grabbed = "touchpad_grabbed",
		}
		for id, value in pairs(expected) do
			helpers.assert_eq({ steps[id].state, steps[id].value }, { Report.STATE_FAIL, value }, id)
		end
		steps = run({ uinput_rule = { present = true, group = "root" } })
		helpers.assert_eq(steps.uinput_rule.value, "wrong_group:root")
		steps = run({ focus = { desktop = "gnome", extension_problem = "out_of_date" } })
		helpers.assert_eq({ steps.focus_script.state, steps.focus_script.value }, { Report.STATE_FAIL, "out_of_date" })
	end)

	helpers.it("skips what the session does not have (session-check)", function()
		local steps, result = run({ devices = { keyboard_name = "Ergopti Virtual Keyboard", keyboard = "/dev/input/event21" },
			focus = {}, layout = { name = "us", kde_wayland = false }, dispatch = {} }, { no_libinput = true, no_persistence = true })
		helpers.assert_true(result.passed, Report.format_log_line(result))
		helpers.assert_eq(steps.virtual_pointer_class.value, "not_created")
		helpers.assert_eq(steps.libinput_keyboard.value, "no_libinput")
		helpers.assert_eq(steps.focus_script.value, "no_compositor_source")
		helpers.assert_eq(steps.kde_layout_watch.value, "not_kde_wayland")
		helpers.assert_eq(steps.dispatch_latency.value, "no_keys")
		helpers.assert_eq({ steps.notify_persistence.state, steps.notify_persistence.value }, { Report.STATE_INFO, "no_persistence" })
		steps = run(nil, { no_server = true })
		helpers.assert_eq({ steps.notify_server.state, steps.notify_server.value }, { Report.STATE_FAIL, "no_server" })
	end)

	helpers.it("reads udevadm and libinput output (session-check)", function()
		helpers.assert_eq(Check.parse_udev(KEYBOARD_UDEV).ID_INPUT_KEYBOARD, "1")
		helpers.assert_eq(Check.parse_libinput(LIBINPUT, "Ergopti Virtual Keyboard"), { keyboard = true })
		helpers.assert_nil(Check.parse_libinput(LIBINPUT, "Ergopti Virtual Pointer"))
		helpers.assert_eq(Check.token("French (Ergopti)"), "French_Ergopti")
	end)

	helpers.it("is a field run step with its runner and title (session-check)", function()
		local FieldRun = require("diagnostics.engine.field_run.field_run")
		helpers.assert_eq(FieldRun.CHECK_RUNNERS.session, "diagnostics.ui.field_check.session_check")
		helpers.assert_eq(require(FieldRun.CHECK_RUNNERS.session).title_key, "field_check.session.title")
		local spec = FieldRun.load(helpers.driver_root() .. "/../_shared", helpers.driver_root())
		helpers.assert_eq(spec.step_by_id.field_session.check, "session")
		-- The steps run before the timed reload, which ends the daemon that shows an in-app run.
		helpers.assert_eq(spec.steps[#spec.steps].id, "driver_reload")
	end)
end)
