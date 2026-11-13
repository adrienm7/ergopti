--- tests/hardware/desktop/run_encryptor.lua

--- ==============================================================================
--- MODULE: Applications > Encryptor On A Real X11 Desktop
--- DESCRIPTION:
--- Clicks the tray row (ui/bundled_apps.lua rows(), the provider of
--- Applications in ui/menu/menu_apps.lua) and answers the real dialogs of the
--- spawned apps/encryptor.lua child through the session keyboard (xdotool):
--- 1. The row starts the child and writes the desktop entry and its launcher,
---    the Linux drop target.
--- 2. With no file given, the child opens Ergopti's own GTK file chooser; the
---    proof types the fixture's path, the password twice, and closes the
---    success question without revealing the folder.
--- 3. `<file>.enc` is written, is not the plain text, and openssl decrypts it
---    back to the exact bytes.
--- 4. The launcher the desktop entry runs, given the `.enc` file (a file
---    dropped on the entry), asks the password once and writes the plain
---    file back, byte for byte.
---
--- Exit 0 = every check held. 1 = a failure. 2 = no environment.
--- ==============================================================================

local WAIT_ATTEMPTS = 200
local WAIT_SECONDS  = 0.05
local PASSWORD      = "proof-pass-42"
local PLAIN         = "Ergopti encryptor proof\nsecond line, accents: é à ç\n"

local _failures, _checks = 0, 0

--- @param condition boolean
--- @param what string
local function check(condition, what)
	_checks = _checks + 1
	if not condition then _failures = _failures + 1 end
	print(string.format("  %s %s", condition and "ok  " or "FAIL", what))
end

--- @param message string
local function abort(message)
	io.stderr:write("ENVIRONMENT: " .. message .. "\n")
	os.exit(2)
end

if not os.getenv("DISPLAY") then abort("no X11 display.") end
-- As install/launch.sh starts the daemon: an absolute script, no LUA_PATH in
-- the environment, the module paths set in package.path by the entry point.
if os.getenv("LUA_PATH") then abort("run without LUA_PATH, as install/launch.sh starts the daemon.") end
local driver_root = assert(arg[0]:match("^(/.*)/tests/hardware/desktop/run_encryptor%.lua$"), "run with an absolute path")
package.path = driver_root .. "/?.lua;" .. driver_root .. "/?/init.lua;" .. driver_root .. "/../_shared/?.lua;"
	.. driver_root .. "/../_shared/?/init.lua;" .. package.path
for _, tool in ipairs({ "xdotool", "openssl" }) do
	if os.execute("command -v " .. tool .. " >/dev/null 2>&1") ~= 0 then abort(tool .. " is missing.") end
end
require("core.lifecycle.engine.compat.utf8").install()
local uv = require("luv")
local quote = require("core.text.engine.utils_core").shell_quote
local scratch = assert(arg[1], "usage: run_encryptor.lua <scratch folder>")

--- One line of a command's output.
--- @param command string
--- @return string|nil
local function line_of(command)
	local handle = assert(io.popen(command .. " 2>/dev/null"))
	local text = handle:read("*l")
	handle:close()
	return text
end

--- @param path string
--- @return string|nil
local function read_file(path)
	local file = io.open(path, "rb")
	if not file then return nil end
	local text = file:read("*a")
	file:close()
	return text
end

-- The launcher unrefs the child's handle; a loop with nothing referenced
-- returns at once and never reaps it. The daemon's own timers keep its loop
-- alive, and this one stands in for them.
local keepalive = uv.new_timer()
keepalive:start(1000, 1000, function() end)

--- Turns the loop while waiting, so the child's exit callback can run.
local function turn()
	uv.run("nowait")
	os.execute("sleep " .. WAIT_SECONDS)
end

--- Waits for an Ergopti dialog the window manager focused that was not
--- focused before (each dialog is its own host process and window).
--- Keyed by process: the X server hands a new client the window ids of one
--- that left, so the next dialog can reuse the last one's id.
--- @param seen table Dialog process ids already answered.
--- @return string|nil name The new window's title.
local function next_dialog(seen)
	for _ = 1, WAIT_ATTEMPTS do
		local id = line_of("xdotool getactivewindow")
		local pid = id and line_of("xdotool getwindowpid " .. id)
		local name = pid and not seen[pid] and line_of("xdotool getwindowname " .. id)
		if name and name:find("^ErgoptiPlus") then
			seen[pid] = true
			-- Let GTK settle the focus inside the dialog before typing.
			os.execute("sleep 0.5")
			return name
		end
		turn()
	end
	return nil
end

--- Types into the focused dialog, then presses the given keys.
--- @param text string|nil
--- @param keys string
local function answer(text, keys)
	if text then os.execute("xdotool type --delay 15 " .. quote(text)) end
	os.execute("xdotool key --delay 80 " .. keys)
end

local function run()
	local plain_path = scratch .. "/proof.txt"
	local file = assert(io.open(plain_path, "wb"))
	file:write(PLAIN)
	file:close()
	-- The chooser starts in the session's home: the proof gives the full path.
	local BundledApps = require("ui.bundled_apps")
	local row
	for _, candidate in ipairs(BundledApps.rows()) do
		if candidate.label:find("^Encryptor") then row = candidate end
	end
	check(row ~= nil, "Applications lists Encryptor")
	if not row then return 1 end

	local seen = {}
	check(row.action() == true, "the row starts the Encryptor child")
	local data_home = require("settings.engine.paths").data_home()
	local entry = read_file(data_home .. "/applications/ergopti-encryptor.desktop") or ""
	local launcher = data_home .. "/ergopti/apps/ergopti-encryptor.sh"
	check(entry:find("MimeType=application/octet-stream;", 1, true) ~= nil
		and entry:find(launcher, 1, true) ~= nil, "the desktop entry is written and runs the launcher")

	local chooser = next_dialog(seen)
	check(chooser ~= nil, "a file chooser opens: " .. tostring(chooser))
	-- Opened on « Recent », the chooser loses a typed path one time in three:
	-- Ctrl+L opens its location field first, and the path's completion
	-- settles before Return.
	os.execute("sleep 1 && xdotool key ctrl+l && sleep 1")
	os.execute("xdotool type --delay 30 " .. quote(plain_path) .. " && sleep 1")
	answer(nil, "Return")
	local first = next_dialog(seen)
	check(first ~= nil, "the password is asked: " .. tostring(first))
	answer(PASSWORD, "Return")
	local second = next_dialog(seen)
	check(second ~= nil, "the password is confirmed: " .. tostring(second))
	answer(PASSWORD, "Return")
	local done = next_dialog(seen)
	check(done ~= nil, "the success question opens: " .. tostring(done))
	answer(nil, "Escape")

	local encrypted_path = plain_path .. ".enc"
	local exited = false
	for _ = 1, WAIT_ATTEMPTS do
		if read_file(encrypted_path) and next(BundledApps._children) == nil then exited = true break end
		turn()
	end
	local encrypted = read_file(encrypted_path)
	check(exited, "the child exits and the launcher retires its handle")
	check(encrypted ~= nil and #encrypted > 0 and not encrypted:find("Ergopti encryptor proof", 1, true),
		"<file>.enc is written and does not hold the plain text")
	local Core = require("apps.encryptor_core")
	local checked = scratch .. "/checked.txt"
	check(Core.convert(Core.load_format(), "decrypt", encrypted_path, checked, PASSWORD, "openssl") == true
		and read_file(checked) == PLAIN, "openssl decrypts <file>.enc back to the exact bytes")

	-- The drop target: the launcher the desktop entry runs, with the .enc file.
	assert(os.remove(plain_path))
	os.execute("/bin/sh " .. quote(launcher) .. " " .. quote(encrypted_path) .. " >/dev/null 2>&1 &")
	local drop_password = next_dialog(seen)
	check(drop_password ~= nil, "a dropped .enc asks its password once: " .. tostring(drop_password))
	answer(PASSWORD, "Return")
	local drop_done = next_dialog(seen)
	check(drop_done ~= nil, "the decryption reports success: " .. tostring(drop_done))
	answer(nil, "Escape")
	local restored
	for _ = 1, WAIT_ATTEMPTS do
		restored = read_file(plain_path)
		if restored then break end
		turn()
	end
	check(restored == PLAIN, "the dropped file is decrypted back, byte for byte")
	print(string.format("=== %d check(s), %d failure(s) ===", _checks, _failures))
	return _failures == 0 and 0 or 1
end

local ran, result = pcall(run)
keepalive:close()
if not ran then error(result, 0) end
os.exit(result)
