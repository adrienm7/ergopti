--- tests/hardware/run_file_manager_actions_live.lua

--- ==============================================================================
--- MODULE: File-Manager Actions Against a Real Terminal and a Real File Manager
--- DESCRIPTION:
--- Run by run_file_manager_actions_live.sh on Xvfb with openbox, a private
--- session bus and a throwaway HOME. The action goes through the gesture
--- manager's public executor (modules/gestures/manager.lua execute_action) with
--- its production dependencies: the real X11 focus query, the real clipboard
--- adapter over xclip, and the combo emitter on the production uinput writer,
--- whose last hop is XTest (tests/hardware/lib/xtest_uinput_backend.lua) since
--- Xvfb reads no evdev device.
---
--- WHAT IT ASSERTS (flow review LCP-004 and the make-executable caller):
--- 1. A focused xterm running a job that traps SIGINT: make_executable_selection
---    sends no key at all, the job receives no interrupt and no file mode
---    changes. Control: a Ctrl+C pressed on the same wire does interrupt that
---    job, so the first verdict is not the wire's silence.
--- 2. A focused PCManFM window with a file selected: the same action copies the
---    selection, makes exactly that file executable, and puts the clipboard's
---    previous text back.
--- Exit 0 = every check held; 1 = a failure; 2 = no environment.
--- ==============================================================================

local uv = require("luv")
local Shell = require("core.process.adapters.shell_runner")

local EXPECTED_CHECKS = 9
if os.getenv("ERGOPTI_LIVE_DEBUG") then
	require("core.logger.engine").set_sink(function(line) io.stderr:write(line, "\n") end)
end

for _, program in ipairs({ "xterm", "pcmanfm", "xdotool", "xclip" }) do
	if not Shell.exec_checked("command -v " .. program) then
		io.stderr:write("ENVIRONMENT: " .. program .. " is missing\n")
		os.exit(2)
	end
end

local checks, failures = 0, 0
local function check(condition, text)
	checks = checks + 1
	if not condition then failures = failures + 1 end
	print((condition and "  ok   " or "  FAIL ") .. text)
	return condition
end

--- Polls until the predicate holds or the deadline passes.
local function settle(predicate, seconds)
	local deadline = uv.hrtime() + seconds * 1e9
	repeat
		uv.run("nowait")
		if predicate() then return true end
		uv.sleep(50)
	until uv.hrtime() > deadline
	return predicate()
end

local function read_file(path)
	local file = io.open(path, "rb")
	if not file then return nil end
	local content = file:read("*a")
	file:close()
	return content
end

local function write_file(path, content)
	local file = assert(io.open(path, "wb"))
	assert(file:write(content))
	assert(file:close())
end

local function mode_of(path)
	local stat = uv.fs_stat(path)
	return stat and stat.mode % 512 or nil
end

local function executable(path)
	local mode = mode_of(path)
	return mode ~= nil and math.floor(mode / 64) % 2 == 1
end

--- Starts a detached program; returns its pid.
local function spawn(file, args)
	local handle, pid = uv.spawn(file, { args = args, stdio = { nil, nil, nil } }, function() end)
	assert(handle, "could not start " .. file .. ": " .. tostring(pid))
	return pid, handle
end

--- Activates the first window xdotool finds and waits for focus to report it.
local function focus(search, expected_app)
	local Window = require("platform.focus.window_info")
	local found = settle(function()
		return Shell.exec_checked("xdotool search --sync --limit 1 " .. search .. " windowactivate --sync") == true
	end, 15)
	if not found then return false end
	return settle(function()
		local info = Window.getFocused()
		return type(info.appId) == "string" and info.appId:lower():find(expected_app, 1, true) ~= nil
	end, 10)
end

require("core.i18n.engine.i18n").init()
local Window = require("platform.focus.window_info")
Window.use_native_x11()

-- The production writer, its last hop moved from /dev/uinput to XTest.
local work = assert(uv.fs_mkdtemp(os.getenv("HOME") .. "/actions-XXXXXX"))
local Backend = require("tests.hardware.lib.xtest_uinput_backend")
local Writer = require("platform.input.uinput_writer")
local wire = Backend.new()
Writer._set_backend(wire)
write_file(work .. "/uinput", "")
Writer._set_path_for_test(work .. "/uinput")
assert(require("modules.hotstrings.injector").open_fast_channel(), "the output channel must open on the XTest wire")

local Manager = require("modules.gestures.manager")
local BackgroundCommands = require("modules.gestures.background_commands")
local ComboEmitter = require("modules.gestures.combo_emitter")
local Clipboard = require("adapters.clipboard")
local function idle()
	BackgroundCommands._collect_now()
	return BackgroundCommands.pending_count() == 0
end

print("=== file-manager actions, a real terminal and a real file manager ===")

local target = work .. "/files/run.sh"
assert(uv.fs_mkdir(work .. "/files", 448))
write_file(target, "#!/bin/sh\necho ran\n")
assert(uv.fs_chmod(target, 420))
local marker, ready = work .. "/interrupts", work .. "/ready"
local pids = {}

local function run()
	-- 1) A focused terminal running a job.
	local job = string.format("trap 'echo INT >> %s' INT; echo ready > %s; while :; do sleep 0.1; done",
		Shell.quote(marker), Shell.quote(ready))
	pids[#pids + 1] = spawn("xterm", { "-T", "ergopti-terminal", "-e", "sh", "-c", job })
	settle(function() return read_file(ready) ~= nil end, 15)
	check(focus("--name ergopti-terminal", "xterm"), "the xterm running a job has the X focus")
	local sent = #wire.events
	Manager.execute_action("make_executable_selection")
	settle(idle, 3)
	uv.sleep(500)
	check(#wire.events == sent, "make_executable_selection sends no key to a focused terminal")
	check(read_file(marker) == nil, "the terminal's job receives no interrupt")
	check(mode_of(target) == 420, "no file mode changes from a terminal")
	-- Control: the same wire does interrupt that job.
	local pressed = ComboEmitter.press("ctrl+c")
	check(pressed == true and settle(function() return (read_file(marker) or ""):find("INT", 1, true) ~= nil end, 5),
		"control: a Ctrl+C on the same wire interrupts the terminal's job")

	-- 2) A focused file manager with the file selected.
	local seed = "ERGOPTI-CLIPBOARD-BEFORE-" .. tostring(uv.hrtime())
	assert(Clipboard.write(seed), "the clipboard must be seeded")
	pids[#pids + 1] = spawn("pcmanfm", { "--new-win", work .. "/files" })
	check(focus("--class pcmanfm", "pcmanfm"), "the PCManFM window has the X focus")
	-- The folder view holds the focus: select its only file from the keyboard.
	uv.sleep(500)
	ComboEmitter.press("ctrl+a")
	uv.sleep(300)
	Manager.execute_action("make_executable_selection")
	local made = check(settle(function() idle(); return executable(target) end, 10),
		"make_executable_selection makes the selected file executable")
	check(mode_of(target) == 420 + 73, "exactly the execute bits are added")
	local restored_ok, restored = Clipboard.read_checked()
	check(restored_ok and restored == seed, "the clipboard's previous text is put back")
	if not made then
		-- What the file manager publishes on its own Ctrl+C, for the failure's reader.
		ComboEmitter.press("ctrl+c")
		uv.sleep(500)
		for _, kind in ipairs({ "TARGETS", "text/uri-list", "x-special/gnome-copied-files" }) do
			local _, text = Shell.exec_checked("xclip -selection clipboard -o -t " .. kind .. " 2>&1")
			print(string.format("       %s: %q", kind, tostring(text)))
		end
	end
end

local ran, err = xpcall(run, debug.traceback)
if not ran then
	failures = failures + 1
	print("  FAIL the flow raised: " .. tostring(err))
end
for _, pid in ipairs(pids) do uv.kill(pid, "sigterm") end
Shell.run("rm -rf " .. Shell.quote(work))
check(checks == EXPECTED_CHECKS, string.format("every check ran (%d of %d)", checks, EXPECTED_CHECKS))
print(string.format("=== %d check(s), %d failure(s) ===", checks, failures))
os.exit(failures == 0 and 0 or 1)
