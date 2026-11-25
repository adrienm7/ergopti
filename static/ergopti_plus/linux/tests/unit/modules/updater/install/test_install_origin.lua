--- tests/unit/modules/updater/install/test_install_origin.lua

--- ==============================================================================
--- MODULE: Installation Origin Tests
--- DESCRIPTION:
--- Each origin the Linux driver ships from is classified from the running
--- source path, with the environment only confirming it, and every origin that
--- has a launcher restarts: « package-owned » refuses the self-update, never a
--- Reload. The field report of 2026-11-25 (v1.0.9, Arch, KDE) had the AppImage
--- refuse every Reload with updater_package_owned, and an install.sh install
--- greyed as « installé par un paquet système ».
--- ==============================================================================

local helpers = require("tests.helpers")
local Installer = helpers.load_module("modules.updater.installer")
local InstallOrigin = helpers.load_module("modules.updater.install_origin")
local DaemonRestart = helpers.load_module("core.lifecycle.engine.reload.daemon_restart")
local Restarter = helpers.load_module("modules.updater.restarter")
local Errors = require("diagnostics.engine.adapter_errors")

local MOUNT = "/tmp/.mount_ErgoptMCHmGI"
local APPIMAGE = "/home/user/Applications/ErgoptiPlus-x86_64.AppImage"
local APPIMAGE_SOURCE = MOUNT .. "/usr/lib/ergopti/modules/updater/manager.lua"
local STANDALONE_SOURCE = "/home/user/.local/lib/ergopti/linux/modules/updater/manager.lua"
local STANDALONE_LAUNCHER = "/home/user/.local/bin/ergopti-hotstrings"
local PACKAGE_SOURCE = "/usr/lib/ergopti/modules/updater/manager.lua"
local FLATPAK_SOURCE = "/app/lib/ergopti/modules/updater/manager.lua"
local SESSION_CGROUP = "0::/user.slice/user-1000.slice/session-2.scope\n"

--- An environment reader over a fixed table.
local function env(values)
	return function(name) return values[name] end
end

--- A probe admitting every path except the listed ones.
local function probe_except(absent)
	local set = {}
	for _, path in ipairs(absent or {}) do set[path] = true end
	return function(path) return not set[path] end
end

--- Requests a Reload of a session daemon resolved by `context`, recording the
--- shell commands the restart dispatched instead of running them.
local function reload(context, extra)
	local commands = {}
	local opts = {
		reason = "reload", args = { "--tray" }, cgroup = SESSION_CGROUP, restarter = Restarter,
		installation = function() return context end,
		run = function(command) commands[#commands + 1] = command; return true end,
	}
	for key, value in pairs(extra or {}) do opts[key] = value end
	local how, detail = DaemonRestart.restart(opts)
	return how, detail, commands
end

helpers.describe("installation origin", function()
	helpers.it("(install-origin-appimage) names the AppImage and restarts the .AppImage file, never the mount", function()
		local context = Installer.resolve(APPIMAGE_SOURCE, probe_except(),
			env({ APPDIR = MOUNT, APPIMAGE = APPIMAGE }))
		helpers.assert_eq(context.kind, "appimage")
		helpers.assert_eq(context.reason, Errors.UPDATER_APPIMAGE_OWNED)
		helpers.assert_eq(context.launcher, APPIMAGE)
		helpers.assert_eq(InstallOrigin.update_blocked_key(context.kind), "changelog_window.install_blocked_appimage")
		local how, detail, commands = reload(context)
		helpers.assert_eq(how, "relay", tostring(detail))
		helpers.assert_eq(#commands, 1)
		helpers.assert_contains(commands[1], APPIMAGE)
		helpers.assert_nil(commands[1]:find(MOUNT, 1, true), "the squashfs mount vanishes with this process")
		helpers.assert_contains(commands[1], "setsid sh -c", "the relay is spawned before this daemon exits")
	end)

	helpers.it("(install-origin-appimage) refuses a restart when APPIMAGE names no usable file", function()
		for _, case in ipairs({
			{ values = { APPDIR = MOUNT }, absent = {} },
			{ values = { APPDIR = MOUNT, APPIMAGE = MOUNT .. "/AppRun" }, absent = {} },
			{ values = { APPDIR = MOUNT, APPIMAGE = "relative.AppImage" }, absent = {} },
			{ values = { APPDIR = MOUNT, APPIMAGE = APPIMAGE }, absent = { APPIMAGE } },
		}) do
			local context = Installer.resolve(APPIMAGE_SOURCE, probe_except(case.absent), env(case.values))
			helpers.assert_eq(context.kind, "appimage")
			helpers.assert_nil(context.launcher)
			helpers.assert_type(context.launcher_refusal, "string")
			local how, detail, commands = reload(context)
			helpers.assert_nil(how)
			helpers.assert_contains(detail, context.launcher_refusal)
			helpers.assert_eq(#commands, 0, "nothing runs: exiting would leave no daemon")
		end
	end)

	helpers.it("(install-origin-standalone) keeps an install.sh install standalone under inherited AppImage or Flatpak variables", function()
		-- A terminal or a process started from a running AppImage inherits its
		-- APPDIR and APPIMAGE: they do not make this tree package-owned.
		for _, values in ipairs({
			{ APPDIR = MOUNT, APPIMAGE = APPIMAGE },
			{ APPIMAGE = APPIMAGE },
			{ FLATPAK_ID = "org.ergopti.Ergopti" },
			{},
		}) do
			local context = Installer.resolve(STANDALONE_SOURCE, probe_except(), env(values))
			helpers.assert_eq(context.kind, "standalone")
			helpers.assert_eq(context.launcher, STANDALONE_LAUNCHER)
			helpers.assert_nil(InstallOrigin.update_blocked_key(context.kind), "the standalone updater stays allowed")
			local how, _, commands = reload(context)
			helpers.assert_eq(how, "relay")
			helpers.assert_contains(commands[1], STANDALONE_LAUNCHER)
		end
	end)

	helpers.it("(install-origin-standalone) reads the process environment by default", function()
		local uv = require("luv")
		local saved = { APPDIR = os.getenv("APPDIR"), APPIMAGE = os.getenv("APPIMAGE") }
		assert(uv.os_setenv("APPDIR", MOUNT)); assert(uv.os_setenv("APPIMAGE", APPIMAGE))
		local ok, context = pcall(Installer.resolve, STANDALONE_SOURCE, probe_except())
		for key, value in pairs(saved) do
			if value == nil then assert(uv.os_unsetenv(key)) else assert(uv.os_setenv(key, value)) end
		end
		helpers.assert_true(ok, tostring(context))
		helpers.assert_eq(context.kind, "standalone", "an inherited APPDIR must not grey an install.sh install")
	end)

	helpers.it("(install-origin-package) blocks only the self-update of a system package, and restarts its wrapper", function()
		local context = Installer.resolve(PACKAGE_SOURCE, probe_except(), env({}))
		helpers.assert_eq(context.kind, "package")
		helpers.assert_eq(context.reason, Errors.UPDATER_PACKAGE_OWNED)
		helpers.assert_eq(context.launcher, Installer.PACKAGE_LAUNCHER)
		helpers.assert_eq(InstallOrigin.update_blocked_key(context.kind), "changelog_window.install_blocked_package")
		local how, detail, commands = reload(context)
		helpers.assert_eq(how, "relay", tostring(detail))
		helpers.assert_contains(commands[1], Installer.PACKAGE_LAUNCHER)
		local missing = Installer.resolve(PACKAGE_SOURCE, probe_except({ Installer.PACKAGE_LAUNCHER }), env({}))
		helpers.assert_eq(missing.kind, "package")
		helpers.assert_nil(missing.launcher)
		helpers.assert_nil((reload(missing)), "a package without its wrapper reports instead of exiting")
	end)

	helpers.it("(install-origin-package) restarts a package under its user unit through systemd", function()
		local context = Installer.resolve(PACKAGE_SOURCE, probe_except(), env({}))
		local how, _, commands = reload(context, {
			cgroup = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/" .. Restarter.UNIT .. "\n" })
		helpers.assert_eq(how, "systemd")
		helpers.assert_eq(commands, { Restarter.OWN_UNIT_JOB_PREFIX .. "systemctl --user --no-block restart " .. Restarter.UNIT })
	end)

	helpers.it("(install-origin-flatpak) restarts a Flatpak through a new portal instance gated on this process", function()
		local context = Installer.resolve(FLATPAK_SOURCE, probe_except(), env({ FLATPAK_ID = "org.ergopti.Ergopti" }))
		helpers.assert_eq(context.kind, "flatpak")
		helpers.assert_eq(context.reason, Errors.UPDATER_FLATPAK_OWNED)
		helpers.assert_eq(context.launcher, Installer.FLATPAK_LAUNCHER)
		helpers.assert_eq(InstallOrigin.update_blocked_key(context.kind), "changelog_window.install_blocked_flatpak")
		local gates = {}
		local how, detail, commands = reload(context, { hold_gate = function(path) gates[#gates + 1] = path; return true end })
		helpers.assert_eq(how, "relay", tostring(detail))
		helpers.assert_eq(#gates, 1, "the gate is held before the new instance starts")
		helpers.assert_eq(#commands, 1)
		helpers.assert_contains(commands[1], "flatpak-spawn --latest-version /bin/sh -c")
		helpers.assert_nil(commands[1]:find("--host", 1, true), "the restart stays inside the Flatpak sandbox")
		helpers.assert_contains(commands[1], "flock -x")
		helpers.assert_contains(commands[1], Installer.FLATPAK_LAUNCHER)
		helpers.assert_contains(commands[1], gates[1])
		local refused, why, none = reload(context, { hold_gate = function() return false, "denied" end })
		helpers.assert_nil(refused)
		helpers.assert_type(why, "string")
		helpers.assert_eq(#none, 0, "no instance starts without the gate")
	end)

	helpers.it("(install-origin-flatpak) a /app tree outside Flatpak names no launcher", function()
		local context = Installer.resolve(FLATPAK_SOURCE, probe_except({ "/.flatpak-info" }), env({}))
		helpers.assert_eq(context.kind, "package")
		helpers.assert_nil(context.launcher)
	end)
end)

helpers.describe("installation origin launchers", function()
	helpers.it("(install-origin-launchers) names the launchers the packagers install", function()
		-- A packager that moved its launcher would leave every Reload of that
		-- origin refused: the restart runs exactly the identifiers' path.
		local repository = require("core.fs.engine.paths").driver_root() .. "/../../.."
		local function read(relative)
			local file = assert(io.open(repository .. "/" .. relative, "rb"), relative)
			local text = assert(file:read("*a")); assert(file:close())
			return text
		end
		for packager, root in pairs({ ["tools/build/build-linux-deb.sh"] = "$DEB_ROOT",
			["tools/build/build-linux-rpm.sh"] = "$INSTALL_ROOT", ["tools/build/PKGBUILD"] = "$pkgdir" }) do
			helpers.assert_contains(read(packager), 'cat > "' .. root .. Installer.PACKAGE_LAUNCHER .. '"', packager)
		end
		helpers.assert_contains(read("tools/build/build-linux-flatpak.sh"),
			"install -Dm755 bin/ergopti " .. Installer.FLATPAK_LAUNCHER .. "\n")
	end)
end)

helpers.describe("Flatpak relay command", function()
	helpers.it("(install-origin-flatpak) waits for the new instance, then gives up by cancelling it", function()
		local command = Restarter.flatpak_relay_command("/home/user/.var/app/x/gate", "/app/bin/ergopti",
			{ "--tray", "it's" }, "/home/user/.var/app/x/cancel")
		helpers.assert_contains(command, ".spawned")
		helpers.assert_contains(command, tostring(Restarter.FLATPAK_SPAWN_TICKS))
		helpers.assert_true(command:find("cancel", 1, true) ~= nil, "a timed-out dispatch cancels the instance")
		helpers.assert_contains(command, "--tray")
	end)
end)
