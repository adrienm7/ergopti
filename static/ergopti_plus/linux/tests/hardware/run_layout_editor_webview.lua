--- tests/hardware/run_layout_editor_webview.lua

--- ==============================================================================
--- MODULE: The Layout Editor Installs a Source From the Daemon's WebView
--- DESCRIPTION:
--- Opens the real layout manager window (ui/webview_manager, WebKit2GTK, under a
--- real X server) and drives the layout editor as a user would: « Editor » opens it in its own window,
--- a layout source opened in it (the Ergopti source), « Install and use », « Yes ».
--- The page compiles the source with the shared generator and posts composer_save
--- through WebKit's own script-message channel; the daemon's composer host stores
--- it and installs it as the `composed` layout. Then the layout manager loads it
--- into the server and xkbcomp reads it back: base, Shift and the Kana level on
--- AltGr, ê on the ISO key. Typing is the server's keymap, read key by key.
--- Before that, « Emulate without installing »: nothing is installed, the
--- composed layout becomes the emulated one, and the daemon's layout emulation
--- (modules/keymap/layout_emulation.lua, its production collaborators but the
--- text output) types the source's characters for physical key presses.
--- Exit 0 = every check held, 1 = a failure, 2 = the machine cannot host it (no
--- display, WebKit or lgi).
--- USAGE: xvfb-run -a luajit tests/hardware/run_layout_editor_webview.lua <source.toml>
--- ==============================================================================

local ffi = require("ffi")
ffi.cdef([[
	int setenv(const char *, const char *, int);
	int unsetenv(const char *);
]])

local WAIT_ATTEMPTS = 600
local WAIT_SECONDS = 0.1
local _checks, _failures = 0, 0
local _scratch = nil
local _bus_pid = nil

local function check(condition, what)
	_checks = _checks + 1
	if not condition then _failures = _failures + 1 end
	print((condition and "  ok   " or "  FAIL ") .. what)
	return condition
end

local function abort(message)
	io.stderr:write("ENVIRONMENT: " .. message .. "\n")
	os.exit(2)
end

local function quote(text) return "'" .. text:gsub("'", "'\\''") .. "'" end

local function read(path)
	local handle = io.open(path, "rb")
	if not handle then return nil end
	local text = handle:read("*a")
	handle:close()
	return text
end

local function capture(command)
	local handle = assert(io.popen(command, "r"))
	local output = handle:read("*a")
	handle:close()
	return output
end

local function setenv(name, value)
	if value == nil then assert(ffi.C.unsetenv(name) == 0, "unsetenv " .. name)
	else assert(ffi.C.setenv(name, value, 1) == 0, "setenv " .. name) end
end

print("=== the layout editor installs a source from the daemon's WebView ===")
local display = os.getenv("DISPLAY")
if not display then abort("no X display: run under xvfb-run") end
local source_path = arg[1]
local source_text = source_path and read(source_path)
if not source_text then abort("usage: run_layout_editor_webview.lua <source.toml>") end
for _, tool in ipairs({ "setxkbmap", "xkbcomp", "python3", "gsettings", "dbus-daemon" }) do
	if capture("command -v " .. tool .. " 2>/dev/null") == "" then abort(tool .. " is not installed") end
end
local ok_lgi, lgi = pcall(require, "lgi")
if not ok_lgi then abort("lgi is not installed") end
if not pcall(function() return lgi.require("WebKit2", "4.1") end)
	and not pcall(function() return lgi.require("WebKit2", "4.0") end) then
	abort("WebKit2GTK is not available to lgi")
end
local Gtk = lgi.require("Gtk", "3.0")

-- A private configuration and XKB tree, as the layout manager uses from any session.
_scratch = capture("mktemp -d /tmp/ergopti-editor-webview-XXXXXX"):gsub("%s+$", "")
assert(_scratch ~= "", "a scratch directory")
os.execute("mkdir -p " .. quote(_scratch .. "/config") .. " " .. quote(_scratch .. "/home"))
setenv("XDG_CONFIG_HOME", _scratch .. "/config")
setenv("HOME", _scratch .. "/home")
setenv("ERGOPTI_XKB_USER_HOME", _scratch .. "/home")
setenv("ERGOPTI_XKB_USER_ROOT", nil)
setenv("WAYLAND_DISPLAY", nil)
setenv("XDG_CURRENT_DESKTOP", nil)
setenv("XDG_SESSION_TYPE", "x11")
-- A private session bus started after the configuration folder moved: the dconf
-- service it activates writes where gsettings, the installer and this probe
-- read (a bus started before would write under the runner's own folder).
local bus = capture("dbus-daemon --session --fork --print-address=1 --print-pid=1 2>/dev/null")
local bus_address, bus_pid = bus:match("^(%S+)\n(%d+)")
if not bus_address then abort("dbus-daemon did not start a session bus: " .. bus) end
_bus_pid = bus_pid
setenv("DBUS_SESSION_BUS_ADDRESS", bus_address)
-- The installer runs on the runner's interpreter; Ergopti's own Python download
-- on consent has its own live probe (run_managed_python_live.lua).
local runner_python = (capture("command -v python3 2>/dev/null"):gsub("%s+$", ""))
package.loaded["modules.keymap.managed_python"] = { ensure = function(_, done) done(true, runner_python) end }





-- ========================================
-- ========================================
-- ======= 1/ Driving the real page =======
-- ========================================
-- ========================================

local function pump_once() while Gtk.events_pending() do Gtk.main_iteration_do(false) end end

--- Evaluates JavaScript in the live page; its own loop, never nested in another wait.
local function eval_sync(webview, source)
	local answer, done = nil, false
	webview:run_javascript(source, nil, function(_object, result)
		local ok, value = pcall(function()
			return webview:run_javascript_finish(result):get_js_value():to_string()
		end)
		answer = ok and value or nil
		done = true
	end, nil)
	for _ = 1, WAIT_ATTEMPTS do
		pump_once()
		if done then return answer end
		os.execute("sleep " .. WAIT_SECONDS)
	end
	return answer
end

--- Pumps the GTK and libuv loops until the page answers the probe with "true".
local function wait_for(webview, probe)
	local uv = require("luv")
	for _ = 1, WAIT_ATTEMPTS do
		pump_once()
		uv.run("nowait")
		if eval_sync(webview, "String(Boolean(" .. probe .. "))") == "true" then return true end
		os.execute("sleep " .. WAIT_SECONDS)
	end
	return false
end

local Manager

local function run()
	Manager = require("ui.webview_manager")
	Manager.set_daemon_state({})
	check(Manager.show("layout_manager") == true, "the layout manager window opens")
	local webview = Manager.webview_for("layout_manager")
	if not check(webview ~= nil, "a WebKit view hosts it") then return 1 end
	if not check(wait_for(webview, "!document.getElementById('btn-editor').hidden"),
		"the host offers the unified editor (source_editor)") then return 1 end
	eval_sync(webview, "document.getElementById('btn-editor').click(); 'clicked'")
	-- « Editor » opens the editor in its own window (layout_editor_window); the
	-- manager's page never mounts it, so the rest drives the editor's own view.
	local editor_view
	local uv = require("luv")
	for _ = 1, WAIT_ATTEMPTS do
		pump_once()
		uv.run("nowait")
		editor_view = Manager.webview_for("layout_editor_window")
		if editor_view then break end
		os.execute("sleep " .. WAIT_SECONDS)
	end
	if not check(editor_view ~= nil, "« Editor » opens the layout editor in its own window") then return 1 end
	check(eval_sync(webview, "String(Boolean(document.getElementById('le-install')))") == "false",
		"the manager's page does not mount the editor")
	webview = editor_view
	if not check(wait_for(webview, "document.getElementById('le-install')"),
		"the editor window mounts the editor with « Install and use »") then return 1 end

	-- The source as the host hands a saved one to the page (window.sourceData).
	local Json = require("core.text.engine.json")
	eval_sync(webview, "window.sourceData(" .. Json.encode({ filename = "ergopti.toml", text = source_text })
		.. "); 'opened'")
	check(wait_for(webview, "document.getElementById('le-name') && document.getElementById('le-name').value.length"),
		"the source opens in the editor")
	local Registry = require("modules.keymap.layout_registry")
	local function message_text() return eval_sync(webview, "(document.getElementById('le-message') || {}).textContent") end
	local function settled_after(previous)
		return wait_for(webview, "(document.getElementById('le-message') || {}).className === 'le-message ok'"
			.. " && document.getElementById('le-message').textContent !== " .. Json.encode(previous))
	end

	-- « Emulate without installing »: stored for the emulation alone, nothing installed.
	if not check(wait_for(webview, "document.getElementById('le-emulate')"), "the host offers « Emulate without installing »") then
		return 1
	end
	local before_emulate = message_text()
	eval_sync(webview, "document.getElementById('le-emulate').click(); 'emulate'")
	check(wait_for(webview, "document.getElementById('le-confirm-yes')"), "the page asks to confirm the emulation")
	eval_sync(webview, "document.getElementById('le-confirm-yes').click(); 'yes'")
	check(settled_after(before_emulate), "the host emulates it and the page says so: " .. tostring(message_text()))
	local composer = assert(Registry.composer_settings())
	local composer_folder = require("infra.config_paths").get_config_dir() .. "/" .. composer.folder .. "/"
	check(read(composer_folder .. composer.keylayout_file) ~= nil, "the compiled layout is kept in the composer folder")
	check((Registry.snapshot().installed or {})[composer.id] == nil, "nothing is installed in the system")
	local emulated = require("infra.layout_emulation_preferences").settings()
	check(emulated.id == composer.id and emulated.base == true, "the composed layout is the emulated one: "
		.. tostring(emulated.id))
	-- The daemon's emulation with its production collaborators, the typed text recorded.
	local LayoutEmulation = require("modules.keymap.layout_emulation")
	local typed = {}
	local deps = LayoutEmulation.production_deps({ injector = {}, is_paused = function() return false end,
		dispatch_char = function() end, magic_evdev = function() return nil end, dry_run = false })
	deps.type_text = function(text) typed[#typed + 1] = text return true end
	deps.caps_locked = function() return false end
	LayoutEmulation.init(deps)
	check(LayoutEmulation.reload() == true and LayoutEmulation.status().active == true,
		"the layout emulation loads the composed layout from the composer folder: "
		.. tostring(LayoutEmulation.status().error))
	local keys = deps.registry().keys
	for _, case in ipairs({ { "KeyA", "a" }, { "IntlBackslash", "ê" }, { "Backquote", "$" } }) do
		typed = {}
		LayoutEmulation.on_key({ code = keys[case[1]].evdev, mods = {} })
		check(table.concat(typed) == case[2], case[1] .. " types " .. case[2] .. " through the emulation: "
			.. table.concat(typed))
	end
	LayoutEmulation._reset_for_test()

	eval_sync(webview, "document.getElementById('le-install').click(); 'install'")
	if not check(wait_for(webview, "document.getElementById('le-confirm-yes')"), "the page asks to confirm") then
		return 1
	end
	local opened_text = message_text()
	-- No session type while installing: the layout manager installs into the user
	-- tree from a Wayland or unknown session, as the number-row live probe does.
	-- The desktop names itself GNOME, whose input-source setting (dconf on this
	-- run's private session bus) the installer writes and reads back; an unnamed
	-- desktop has no owner to confirm the switch.
	setenv("XDG_SESSION_TYPE", nil)
	setenv("XDG_CURRENT_DESKTOP", "GNOME")
	eval_sync(webview, "document.getElementById('le-confirm-yes').click(); 'yes'")
	local installed = wait_for(webview, "(document.getElementById('le-message') || {}).className === "
		.. "'le-message ok' && document.getElementById('le-message').textContent !== " .. Json.encode(opened_text))
	local said = tostring(eval_sync(webview, "(document.getElementById('le-message') || {}).textContent"))
	if capture("id -u"):gsub("%s+$", "") == "0" then
		-- The installer never writes a desktop setting as root (dconf and D-Bus belong
		-- to the user's session), so « use » is refused there and only the
		-- installation itself is checked below; a user session checks both.
		check(said:find("use_failed", 1, true) ~= nil,
			"as root the installer installs it but refuses to select it: " .. said)
	else
		check(installed, "the composer host installed and selected it and the page says so: " .. said)
		local sources = capture("gsettings get org.gnome.desktop.input-sources sources 2>&1")
		check(sources:match("^%[%('xkb', 'composed[^']*'%)") ~= nil,
			"the GNOME input sources start with the composed layout: " .. sources:gsub("%s+$", ""))
	end
	setenv("XDG_CURRENT_DESKTOP", nil)

	-- What the daemon stored from the page's own message.
	local settings = assert(Registry.composer_settings())
	local folder = require("infra.config_paths").get_config_dir() .. "/" .. settings.folder .. "/"
	local stored = read(folder .. settings.source_file)
	check(stored ~= nil and stored:find('id = "ergopti"', 1, true) ~= nil, "the source is stored by the host")
	local table_ = Registry.composer_emulation()
	check(type(table_) == "table" and table_.platform == "linux", "the page sent the Linux emulation table")

	-- Loaded into the server and read back.
	setenv("XDG_SESSION_TYPE", "x11")
	local loaded
	Registry.apply_rows("composed", { order = "native", edges = false }, function(...) loaded = { ... } end)
	local uv = require("luv")
	for _ = 1, WAIT_ATTEMPTS do
		pump_once()
		uv.run("nowait")
		if loaded then break end
		os.execute("sleep " .. WAIT_SECONDS)
	end
	check(loaded and loaded[1] == true, "the layout manager loads the composed layout into the server: "
		.. (loaded and (tostring(loaded[2]) .. " " .. tostring(loaded[3])) or "no answer"))
	local keymap = capture("xkbcomp -xkb " .. quote(display) .. " - 2>/dev/null")
	local function level(key, index)
		local block = keymap:match("key <" .. key .. ">%s*(%b{})") or ""
		local list = block:match("symbols%[Group1%]%s*=%s*(%b[])") or block:match("(%b[])") or ""
		local names = {}
		for name in list:gmatch("[^%[%],%s]+") do names[#names + 1] = name end
		return names[index]
	end
	-- ERGOPTI_SEVEN_LEVEL: 1 base, 3 Shift, 6 AltGr (the source's Kana level).
	for _, case in ipairs({
		{ "AC01", 1, "a" }, { "AC01", 3, "A" }, { "AC01", 6, "less" }, { "AD03", 6, "oe" },
		{ "LSGT", 1, "ecircumflex" }, { "TLDE", 1, "dollar" },
	}) do
		check(level(case[1], case[2]) == case[3],
			case[1] .. " level " .. case[2] .. " types " .. case[3] .. ": " .. tostring(level(case[1], case[2])))
	end
	print(string.format("=== %d check(s), %d failure(s) ===", _checks, _failures))
	return _failures == 0 and 0 or 1
end

local ran, result = pcall(run)
if Manager then pcall(Manager.shutdown) end
pcall(function() require("modules.keymap.layout_registry").shutdown() end)
if _bus_pid then os.execute("kill " .. _bus_pid .. " 2>/dev/null") end
if _scratch then os.execute("rm -rf " .. quote(_scratch)) end
if not ran then
	io.stderr:write(tostring(result) .. "\n")
	os.exit(1)
end
os.exit(result)
