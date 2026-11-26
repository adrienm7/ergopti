--- tests/unit/core/lifecycle/test_input_access.lua

--- ==============================================================================
--- MODULE: Input Access Failure — the first launch after install
--- DESCRIPTION:
--- install.sh grants the input and uinput groups, and they only apply from the
--- next session. The first launch therefore always met an unreadable keyboard:
--- it printed to a console nobody sees, exited 1, and systemd restarted it every
--- three seconds with no tray icon and nothing on screen. These cases pin the
--- replacement: a translated notification, and an exit status the unit does not
--- retry.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Reads a file from the driver tree.
--- @param rel string
--- @return string
local function read(rel)
	local fh = assert(io.open(helpers.driver_root() .. "/" .. rel, "r"))
	local text = fh:read("*a")
	fh:close()
	return text
end

helpers.describe("input_access: telling the user", function()

	helpers.it("prints an absolute quoted repair command (input-access-repair-path)", function()
		local Access = helpers.load_module("platform.input.access")
		local lines = {}
		Access.report({
			i18n = { init = function() end, get = function(key)
				return key == Access.BODY_KEY and "Repair: {1}" or "Title"
			end },
			script_dir = "/opt/Ergopti user's % directory",
			getenv = function() return nil end,
			print = function(line) lines[#lines + 1] = line end,
		}, "denied")
		helpers.assert_eq(lines[2], "Repair: bash '/opt/Ergopti user'\\''s % directory/install.sh' --setup-perms")
	end)

	helpers.it("names the AppImage itself, not its vanishing mount, as the repair (field report, Arch)", function()
		-- The AppImage's driver root is a temporary mount: the install.sh it
		-- named was gone once the image exited. Relaunching the image runs the
		-- launcher, which asks once for the authorization.
		local Access = helpers.load_module("platform.input.access")
		local lines = {}
		Access.report({
			i18n = { init = function() end, get = function(key)
				return key == Access.BODY_KEY and "Repair: {1}" or "Title"
			end },
			script_dir = "/tmp/.mount_ErgoptXYZ/usr/lib/ergopti",
			getenv = function(name) return name == "APPIMAGE" and "/home/u/Apps/Ergopti Plus.AppImage" or nil end,
			print = function(line) lines[#lines + 1] = line end,
		}, "denied")
		helpers.assert_eq(lines[2], "Repair: '/home/u/Apps/Ergopti Plus.AppImage'")
	end)

	helpers.it("names the host's copy of the Flatpak's setup script, never the sandbox's /app", function()
		-- /app exists only inside the sandbox, and nothing run there can add a
		-- host group: the repair named bash '/app/lib/ergopti/install.sh'.
		local Access = helpers.load_module("platform.input.access")
		local deployment = "/var/lib/flatpak/app/fr.ergopti.Plus/x86_64/stable/0a1b2c/files"
		local command = Access.setup_command({
			script_dir = "/app/lib/ergopti",
			getenv = function(name) return name == "FLATPAK_ID" and "fr.ergopti.Plus" or nil end,
			read_file = function(path)
				helpers.assert_eq(path, "/.flatpak-info")
				return "[Application]\nname=fr.ergopti.Plus\n\n[Instance]\ninstance-id=42\napp-path="
					.. deployment .. "\nbranch=stable\n"
			end,
		})
		helpers.assert_eq(command,
			"sudo bash '" .. deployment .. "/lib/ergopti/install/setup_permissions.sh' --user \"$(id -u)\"")
		helpers.assert_true(command:find("'/app/", 1, true) == nil, "no sandbox path")
		local ok = pcall(Access.setup_command, {
			getenv = function(name) return name == "FLATPAK_ID" and "fr.ergopti.Plus" or nil end,
			read_file = function() return "[Application]\nname=fr.ergopti.Plus\n" end,
		})
		helpers.assert_eq(ok, false, "a Flatpak whose deployment is unknown is refused, not sent to /app")
	end)

	helpers.it("the AppImage's tray launch goes through the permission launcher", function()
		local fh = assert(io.open(helpers.driver_root() .. "/../../../tools/build/build-linux-appimage.sh", "r"))
		local builder = fh:read("*a")
		fh:close()
		local apprun = builder:match("cat > \"%$APPDIR/AppRun\" << 'APPRUN_EOF'\n(.-)\nAPPRUN_EOF")
		helpers.assert_true(apprun ~= nil, "the AppRun heredoc")
		local launcher = apprun:find('exec bash "$DRIVER_ROOT/install/launch.sh" "$@"', 1, true)
		local direct = apprun:find('exec "$LUAJIT_BIN" "$DRIVER_ROOT/ergopti_hotstrings.lua" "$@"', 1, true)
		helpers.assert_true(launcher ~= nil and direct ~= nil and launcher < direct,
			"a --tray launch reaches launch.sh before the direct daemon start")
		helpers.assert_true(apprun:find("export ERGOPTI_PORTABLE_LAUNCH=1", 1, true) ~= nil)
	end)

	helpers.it("notifies with the translated title and body", function()
		local Access = helpers.load_module("platform.input.access")
		local sent = {}
		local fake_i18n = {
			init = function() end,
			get = function(key) return "<" .. key .. ">" end,
		}
		local fake_notifier = { send = function(body, opts) sent[#sent + 1] = { body = body, opts = opts } end }
		local status = Access.report({ i18n = fake_i18n, notifier = fake_notifier, print = function() end },
			"/dev/input/event3")
		helpers.assert_eq(#sent, 1, "exactly one on-screen notification")
		helpers.assert_eq(sent[1].body, "<startup.linux_input_access_body>")
		helpers.assert_eq(sent[1].opts.title, "<startup.linux_input_access_label>")
		helpers.assert_eq(sent[1].opts.level, "error")
		helpers.assert_eq(status, 78, "EX_CONFIG, the status the unit refuses to retry")
	end)

	helpers.it("(input-access-no-device) names no input group when no keyboard exists", function()
		local Access = helpers.load_module("platform.input.access")
		local sent = {}
		local status = Access.report({
			i18n = { init = function() end, get = function(key) return "<" .. key .. ">" end },
			notifier = { send = function(body) sent[#sent + 1] = body end },
			print = function() end,
			body_key = Access.NO_DEVICE_BODY_KEY,
		}, "no keyboard device detected")
		helpers.assert_eq(sent, { "<startup.linux_input_access_no_device_body>" })
		helpers.assert_eq(status, 78)
	end)

	helpers.it("(input-access-no-device) the daemon passes the no-device body and the English text names no group", function()
		local src = read("ergopti_hotstrings.lua")
		helpers.assert_true(src:find("body_key = InputAccess.NO_DEVICE_BODY_KEY", 1, true) ~= nil,
			"the absent-keyboard report must use the no-device body")
		local Paths = helpers.load_module("core.fs.engine.paths")
		local fh = assert(io.open(Paths.shared("core/i18n/data/locales/en.json"), "r"))
		local text = fh:read("*a")
		fh:close()
		local body = text:match("\"startup.linux_input_access_no_device_body\": \"([^\"]*)\"")
		helpers.assert_true(body ~= nil and not body:find("group", 1, true) and not body:find("uinput", 1, true),
			"the no-device notice must not blame the input groups")
	end)

	helpers.it("ships the message in every locale", function()
		-- A missing key renders as the raw key on screen, in the one message a
		-- new user reads first.
		local locales = { "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja",
			"ko", "nl", "no", "pl", "pt", "ru", "sv", "tr", "uk", "zh" }
		local Paths = helpers.load_module("core.fs.engine.paths")
		for _, code in ipairs(locales) do
			local fh = assert(io.open(Paths.shared("core/i18n/data/locales/" .. code .. ".json"), "r"))
			local text = fh:read("*a")
			fh:close()
			for _, key in ipairs({ "startup.linux_input_access_title", "startup.linux_input_access_body", "startup.linux_input_access_label", "startup.linux_input_access_no_device_body" }) do
				helpers.assert_true(text:find('"' .. key .. '": "', 1, true) ~= nil,
					code .. ".json lacks " .. key)
			end
		end
	end)

	helpers.it("still explains itself on the console when there is no notifier", function()
		local Access = helpers.load_module("platform.input.access")
		local lines = {}
		Access.report({ print = function(line) lines[#lines + 1] = line end }, "detail")
		helpers.assert_true(#lines >= 2, "the console gets both the cause and the fix")
		helpers.assert_contains(lines[1], "detail")
	end)

end)

helpers.describe("input_access: a tray launch stays visible", function()

	--- A tray adapter double that records what the user would see.
	local function fake_tray(backend)
		local tray = { calls = {}, menu = nil, pumps = 0, destroyed = false, windows = {} }
		-- The degraded tray creates its icon as the daemon does (TRAY-04): a
		-- setIcon without an image file is refused and would show nothing.
		function tray.start()
			tray.calls[#tray.calls + 1] = "start"
			return backend ~= nil
		end
		function tray.setIcon() error("the degraded tray must create its icon with start()") end
		function tray.getBackend() return backend end
		-- Flattens the fallback builder's arguments into the rows a click reaches;
		-- the adapter's own suite pins the separators it adds.
		function tray.setFallbackMenu(title, quit_label, on_quit, groups)
			tray.menu = { { title = title, disabled = true } }
			for _, group in ipairs(groups or {}) do
				for _, action in ipairs(group) do tray.menu[#tray.menu + 1] = { title = action.label, fn = action.fn } end
			end
			tray.menu[#tray.menu + 1] = { title = quit_label, fn = on_quit }
		end
		function tray.showStatusWindow(title, text)
			tray.windows[#tray.windows + 1] = { title = title, text = text }
			return true
		end
		function tray.pump() tray.pumps = tray.pumps + 1 end
		function tray.destroy() tray.destroyed = true end
		return tray
	end

	--- The degraded state's side effects, recorded instead of performed.
	local function fake_actions()
		local actions = { opened = {}, drains = 0 }
		function actions.open_logs() actions.opened[#actions.opened + 1] = "logs" end
		function actions.report_bug() actions.opened[#actions.opened + 1] = "bug" end
		function actions.run_once() actions.drains = actions.drains + 1 end
		return actions
	end

	local fake_i18n = { init = function() end, get = function(key)
		return key == "menu.global.quit" and "🚪 Leave" or "<" .. key .. ">"
	end }

	--- Finds the row with a title.
	local function row(menu, title)
		for _, item in ipairs(menu) do
			if item.title == title then return item end
		end
		return nil
	end

	helpers.it("keeps the icon, names the failure and exits only on Quit", function()
		-- The AppImage catalogue launches the app without the input group and
		-- fails it when no window or tray icon appears; exiting after the
		-- notification left nothing on screen.
		local Access = helpers.load_module("platform.input.access")
		local tray = fake_tray("appindicator")
		local actions = fake_actions()
		local naps = 0
		local status = Access.report({
			i18n = fake_i18n, tray = tray, actions = actions, print = function() end,
			sleep_ms = function()
				naps = naps + 1
				if naps == 3 then row(tray.menu, "Leave").fn() end
			end,
		}, "denied")
		helpers.assert_eq(status, 78)
		helpers.assert_eq(#tray.calls, 1, "the icon is shown")
		helpers.assert_eq(tray.menu[1].title, "<startup.linux_input_access_label>")
		helpers.assert_eq(tray.menu[1].disabled, true)
		helpers.assert_true(row(tray.menu, "Leave") ~= nil, "the Quit row drops the menu emoji")
		helpers.assert_eq(tray.pumps, 3, "the menu is served until Quit is clicked")
		helpers.assert_eq(actions.drains, 3, "desktop helpers progress while the tray is held")
		helpers.assert_true(tray.destroyed, "the icon is removed before the exit")
	end)

	helpers.it("opens a status window at once (appimage-catalogue-tray-screenshot)", function()
		-- The catalogue screenshots the first named window. With only an icon it
		-- left-clicked it (the menu popped), then right-clicked the same spot,
		-- which closed the grabbed menu: its screenshot showed the bare icon.
		local Access = helpers.load_module("platform.input.access")
		local tray = fake_tray("appindicator")
		Access.report({
			i18n = fake_i18n, tray = tray, actions = fake_actions(), print = function() end,
			sleep_ms = function() row(tray.menu, "Leave").fn() end,
		}, "no keyboard device detected")
		helpers.assert_eq(#tray.windows, 1, "the window opens before any click")
		helpers.assert_eq(tray.windows[1].title, "Ergopti+")
		helpers.assert_contains(tray.windows[1].text, "<startup.linux_input_access_title>")
		helpers.assert_contains(tray.windows[1].text, "<startup.linux_input_access_body>")
	end)

	helpers.it("publishes a real menu, not a name and a way out", function()
		local Access = helpers.load_module("platform.input.access")
		local tray = fake_tray("appindicator")
		local actions = fake_actions()
		local clicked = false
		Access.report({
			i18n = fake_i18n, tray = tray, actions = actions, print = function() end,
			sleep_ms = function()
				if not clicked then
					clicked = true
					row(tray.menu, "<startup.linux_input_access_title>").fn()
					row(tray.menu, "<menu.debug.open_logs>").fn()
					row(tray.menu, "<menu.debug.report_bug>").fn()
				else
					row(tray.menu, "Leave").fn()
				end
			end,
		}, "denied")
		helpers.assert_eq(#tray.windows, 2, "the details row shows the window again")
		helpers.assert_eq(table.concat(actions.opened, ","), "logs,bug")
		local actionable = 0
		for _, item in ipairs(tray.menu) do
			if type(item.fn) == "function" then actionable = actionable + 1 end
		end
		helpers.assert_eq(actionable, 4, "details, logs, bug report and quit")
	end)

	helpers.it("returns at once when no tray backend can show an icon", function()
		local Access = helpers.load_module("platform.input.access")
		local tray = fake_tray(nil)
		local status = Access.report({ tray = tray, print = function() end,
			sleep_ms = function() error("must not wait without an icon") end }, "denied")
		helpers.assert_eq(status, 78)
		helpers.assert_eq(tray.menu, nil)
		helpers.assert_eq(#tray.windows, 0, "no window without a GTK backend")
	end)

end)

helpers.describe("input_access: only a denied node means re-login", function()

	helpers.it("recognises EACCES and nothing else", function()
		local Access = helpers.load_module("platform.input.access")
		local denied = function() return false, "EACCES" end
		local absent = function() return false, "ENOENT" end
		helpers.assert_eq(Access.is_denied("/dev/input/event3", denied), true)
		helpers.assert_eq(Access.is_denied("/dev/input/event99", absent), false,
			"a mistyped --device must not be told to log out and back in")
		local readable = function() return true end
		helpers.assert_eq(Access.is_denied("/tmp/x", readable), false)
	end)

end)

helpers.describe("input_access: the service does not loop on it", function()

	helpers.it("declares the exit status in RestartPreventExitStatus", function()
		local Access = helpers.load_module("platform.input.access")
		local unit = read("ergopti-hotstrings.service")
		local declared = unit:match("\nRestartPreventExitStatus=(%d+)")
		helpers.assert_eq(tonumber(declared), Access.EXIT_ACCESS,
			"systemd would restart the daemon every 3 s and repeat the notification")
	end)

	helpers.it("bounds the restarts of a failure that repeats at every start", function()
		-- The default burst (5 in 10 s) never trips with RestartSec=3s, so an exit
		-- status other than 78 (no device, unopenable /dev/uinput, unreadable
		-- keymap) restarted the daemon every three seconds for the whole session.
		local unit = read("ergopti-hotstrings.service")
		local unit_section = unit:match("\n%[Unit%]\n(.-)\n%[Service%]")
		local interval = tonumber(unit_section:match("\nStartLimitIntervalSec=(%d+)"))
		local burst = tonumber(unit_section:match("\nStartLimitBurst=(%d+)"))
		local delay = tonumber(unit:match("\nRestartSec=(%d+)s"))
		helpers.assert_true(interval ~= nil and burst ~= nil, "the [Unit] section declares the start limit")
		helpers.assert_true((burst - 1) * delay < interval,
			"the burst must be reachable at the restart delay, or the limit never trips")
	end)

	helpers.it("an unwritable /dev/uinput exits with the access status, not the restarted 1", function()
		-- The report's status was dropped and the error unwound to os.exit(1),
		-- which the unit restarts: a missing uinput group or module looped all session.
		local src = read("ergopti_hotstrings.lua")
		local refusal = src:find("Cannot open /dev/uinput", 1, true)
		helpers.assert_true(refusal ~= nil, "the uinput refusal is where this test reads it")
		local branch = src:sub(refusal, (src:find("\n\tend\n", refusal, true)))
		helpers.assert_contains(branch, 'startup_refusal_status = require("platform.input.access").report(')
		helpers.assert_contains(src, "os.exit(startup_refusal_status or 1)")
		local declared = src:find("\nlocal startup_refusal_status = nil\n", 1, true)
		helpers.assert_true(declared ~= nil and declared < refusal,
			"declared above its writer, or the write lands in a nil global")
	end)

	helpers.it("is what the daemon reports at every access check", function()
		local src = read("ergopti_hotstrings.lua")
		-- The whole module name, quoted, so a move that renames it renames it here.
		local access = ("platform.input.access"):gsub("%p", "%%%0")
		local _, sites = src:gsub('require%("' .. access .. '"%)%.report%(', "")
		local _, named = src:gsub("InputAccess%.report%(", "")
		helpers.assert_eq(sites + named, 4,
			"the absent keyboard, the unreadable keyboard, the unwritable /dev/uinput and the missing setup program must all report through input_access")
		local _, held = src:gsub("tray = opts%.tray and tray_menu or nil", "")
		helpers.assert_eq(held, 3, "every access exit must keep the tray icon up when --tray is set")
		helpers.assert_true(src:find("InputAccess.is_denied(device)", 1, true) ~= nil,
			"the keyboard check must distinguish a denied node from an absent one")
	end)

end)

helpers.describe("input_access: a program the permission setup needs is missing", function()

	helpers.it("reads the program the launcher reported, and nothing else", function()
		local Access = helpers.load_module("platform.input.access")
		local function with(value) return function(name) return name == Access.MISSING_PROGRAM_ENV and value or nil end end
		helpers.assert_eq(Access.missing_program(with("getent")), "getent")
		helpers.assert_eq(Access.missing_program(with(nil)), nil)
		helpers.assert_eq(Access.missing_program(with("")), nil)
		helpers.assert_eq(pcall(Access.missing_program, with("a b; rm")), false, "a name is never trusted as a command")
	end)

	helpers.it("tells the user which program is missing, in their language (missing-program-localized)", function()
		local Access = helpers.load_module("platform.input.access")
		local sent, lines = {}, {}
		local status = Access.report({
			i18n = { init = function() end, get = function(key)
				return key == Access.MISSING_PROGRAM_BODY_KEY and "Install “{1}”." or "T"
			end },
			notifier = { send = function(body) sent[#sent + 1] = body end },
			print = function(line) lines[#lines + 1] = line end,
			program = "getent",
			body_key = Access.MISSING_PROGRAM_BODY_KEY,
		}, "missing program getent")
		helpers.assert_eq(sent[1], "Install “getent”.", "the notification names the program")
		helpers.assert_eq(status, Access.EXIT_ACCESS)
	end)

	helpers.it("has a message naming the program in every locale (missing-program-locales)", function()
		for _, locale in ipairs({ "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja", "ko", "nl",
			"no", "pl", "pt", "ru", "sv", "tr", "uk", "zh" }) do
			local json = read("../_shared/core/i18n/data/locales/" .. locale .. ".json")
			for _, key in ipairs({ "startup.linux_input_access_missing_program_body", "dialog.uninstall.missing_program" }) do
				local text = json:match('"' .. key:gsub("%.", "%%.") .. '": "([^\n]-)",?\n')
				helpers.assert_true(text ~= nil and text:find("{1}", 1, true) ~= nil, locale .. " " .. key .. " names {1}")
			end
		end
	end)

	helpers.it("is wired from the launcher token to the daemon (missing-program-wiring)", function()
		local launcher = read("install/launch.sh")
		helpers.assert_true(launcher:find("missing-program", 1, true) ~= nil and launcher:find("ERGOPTI_MISSING_PROGRAM", 1, true) ~= nil,
			"the launcher must hand the token to the daemon")
		local daemon = read("ergopti_hotstrings.lua")
		helpers.assert_true(daemon:find("InputAccess.missing_program()", 1, true) ~= nil,
			"the daemon must report it before the device error")
	end)

end)

helpers.describe("input-access-fifo-probe", function()
	local native_ok, native = pcall(require, "luv")
	local ffi_ok, ffi = pcall(require, "ffi")
	if not native_ok or not ffi_ok then return end
	ffi.cdef("int mkfifo(const char *pathname, unsigned int mode);")
	local probes = {
		{ name = "startup denial", body = 'require("platform.input.access").is_denied(path)' },
		{ name = "keyboard availability", body = 'local reader = require("platform.input.evdev_reader"); reader._set_backend({}); reader.is_available(path)' },
		{ name = "uinput availability", body = 'local writer = require("platform.input.uinput_writer"); writer._set_backend({}); writer._set_path_for_test(path); writer.is_available()' },
	}
	for _, probe in ipairs(probes) do
		helpers.it("(input-access-fifo-probe) " .. probe.name .. " never waits for a FIFO writer", function()
			local path = os.tmpname()
			os.remove(path)
			helpers.assert_eq(ffi.C.mkfifo(path, 384), 0, "the fixture must be a real FIFO with no writer")
			local code = string.format("package.path = %q; local path = %q; %s", package.path, path, probe.body)
			local expired, exited, exit_code, exit_signal = false, false, nil, nil
			local timer = assert(native.new_timer())
			local child
			child = assert(native.spawn(assert(arg[-1]), { args = { "-e", code } }, function(status, signal)
				exited, exit_code, exit_signal = true, status, signal
				native.timer_stop(timer)
				native.close(timer)
				native.close(child)
			end))
			assert(require("core.timing.engine.native_timer").start(native, timer, 2000, 0, function()
				expired = true
				child:kill("sigkill")
			end))
			while not exited do native.run("once") end
			native.run("nowait")
			os.remove(path)
			helpers.assert_eq(expired, false, "a permission probe must never open a FIFO in blocking mode")
			helpers.assert_eq(exit_code, 0, "the native probe must finish without an exception")
			helpers.assert_eq(exit_signal, 0, "a killed or crashed probe must never count as success")
		end)
	end
end)

helpers.describe("input-access-probe-receipts", function()
	helpers.it("(input-access-probe-receipts) rejects invalid paths before any native operation", function()
		local probe = require("platform.input.device_access")
		local calls = 0
		local native = { fs_open = function() calls = calls + 1 end }
		for _, path in ipairs({ "", "/dev/null\0/other", false, {} }) do
			local readable, code = probe.readable(path, native)
			helpers.assert_eq(readable, false)
			helpers.assert_eq(code, "EINVAL")
		end
		helpers.assert_eq(calls, 0, "NUL must never reach the native path boundary")
	end)

	helpers.it("(input-access-probe-receipts) preserves native refusal and requires the exact close receipt", function()
		local probe = require("platform.input.device_access")
		local descriptor, closed = {}, nil
		local native = {
			constants = { O_RDONLY = 0, O_NONBLOCK = 2048 },
			fs_open = function(path, flags, mode)
				helpers.assert_eq(path, "/dev/input/example")
				helpers.assert_eq(flags, 2048, "every read probe must be nonblocking")
				helpers.assert_eq(mode, 0, "the probe must never create a device node")
				return descriptor
			end,
			fs_close = function(fd)
				helpers.assert_true(fd == descriptor, "only the exact temporary descriptor may close")
				return closed, "controlled close refusal", "EIO"
			end,
		}
		local readable, code = probe.readable("/dev/input/example", native)
		helpers.assert_eq(readable, false, "a refused close cannot certify a successful probe")
		helpers.assert_eq(code, "EIO")
		closed = true
		helpers.assert_eq(probe.readable("/dev/input/example", native), true)
		native.fs_open = function() return nil, "permission denied", "EACCES" end
		readable, code = probe.readable("/dev/input/example", native)
		helpers.assert_eq(readable, false)
		helpers.assert_eq(code, "EACCES", "permission denial must remain distinct from an absent node")
	end)

	helpers.it("(input-access-probe-receipts) real native admission distinguishes denied and absent files", function()
		local native = require("luv")
		local path = os.tmpname()
		assert(native.fs_chmod(path, 0))
		local Access = require("platform.input.access")
		local denied = Access.is_denied(path)
		assert(native.fs_chmod(path, 384))
		local readable = Access.is_denied(path)
		os.remove(path)
		local absent = Access.is_denied(path)
		helpers.assert_eq(denied, true, "the native EACCES must retain the repair notice")
		helpers.assert_eq(readable, false)
		helpers.assert_eq(absent, false, "an absent node must not suggest re-login")
	end)
end)
