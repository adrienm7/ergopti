--- tests/unit/ui/bundled_apps/test_bundled_apps_launcher.lua

--- ==============================================================================
--- MODULE: Linux Bundled Apps Launcher Tests
--- DESCRIPTION:
--- Pins how the tray starts App Cloner and Encryptor (ui/bundled_apps.lua):
--- the daemon's own interpreter runs the app with the active locale and the
--- shared locales folder, and opening Encryptor writes its drop-target desktop
--- entry, whose launcher runs a real program here and forwards dropped files.
--- ==============================================================================

local helpers = require("tests.helpers")
local Apps = require("ui.bundled_apps")
local quote = require("core.text.engine.utils_core").shell_quote

local function fake_deps(overrides)
	local state = { spawned = {}, files = {} }
	local deps = {
		exepath = function() return "/opt/runtime/bin/luajit" end,
		driver_root = function() return "/opt/ergopti/linux" end,
		locales_dir = function() return "/opt/ergopti/_shared/core/i18n/data/locales" end,
		locale = function() return "fr" end,
		text = function(key) return "[" .. key .. "]" end,
		getenv = function(name) return ({ ERGOPTI_RUNTIME_PREFIX = "/opt/runtime" })[name] end,
		data_home = function() return "/home/u/.local/share" end,
		spawn = function(executable, args, environment)
			state.spawned[#state.spawned + 1] = { executable, args, environment }
			return true
		end,
		write_file = function(path, text) state.files[path] = text; return true end,
	}
	for key, value in pairs(overrides or {}) do deps[key] = value end
	return deps, state
end

helpers.describe("Linux bundled apps launcher", function()
	helpers.it("bundled apps: lists App Cloner and Encryptor with their macOS descriptions", function()
		local rows = Apps.rows(fake_deps())
		helpers.assert_eq(#rows, 2)
		helpers.assert_eq(rows[1].label, "App Cloner — [menu.apps.clone_desc]")
		helpers.assert_eq(rows[2].label, "Encryptor — [menu.apps.encrypt_desc]")
	end)

	helpers.it("bundled apps: runs the app with the daemon interpreter, locale and locales folder", function()
		local deps, state = fake_deps()
		helpers.assert_true(Apps.launch(Apps.APPS[1], deps))
		local call = state.spawned[1]
		helpers.assert_eq(call[1], "/opt/runtime/bin/luajit")
		helpers.assert_eq(table.concat(call[2], " "),
			"/opt/ergopti/linux/apps/app_cloner.lua --locales-dir /opt/ergopti/_shared/core/i18n/data/locales --locale fr")
		helpers.assert_nil(next(state.files))
	end)

	-- The daemon keeps its module paths in package.path and exports no
	-- LUA_PATH: a tray-started app without them could not load a module
	-- (tests/hardware/desktop/run_encryptor.sh found Encryptor dead on a launch.sh run).
	helpers.it("bundled apps: the tray's child gets the daemon's module paths and runtime", function()
		local deps, state = fake_deps()
		helpers.assert_true(Apps.launch(Apps.APPS[2], deps))
		local environment = {}
		for _, pair in ipairs(state.spawned[#state.spawned][3]) do environment[pair[1]] = pair[2] end
		helpers.assert_eq(environment.LUA_PATH, package.path)
		helpers.assert_eq(environment.LUA_CPATH, package.cpath)
		helpers.assert_eq(environment.ERGOPTI_RUNTIME_PREFIX, "/opt/runtime")
		local launcher = state.files["/home/u/.local/share/ergopti/apps/ergopti-encryptor.sh"]
		helpers.assert_contains(launcher, "export LUA_PATH=" .. quote(package.path) .. "\n")
	end)

	-- Under a relative package.path this module's source path is relative, and
	-- the dialog command used to refuse every dialog for want of a driver root.
	helpers.it("bundled apps: an app dialog opens under a relative module path", function()
		local root = require("core.fs.engine.paths").driver_root()
		local code = 'package.path = "./?.lua;./?/init.lua;../_shared/?.lua;../_shared/?/init.lua;"'
			.. ' .. package.path; io.write(require("core.ui.ui.native_dialog").command())'
		local pipe = assert(io.popen("cd " .. quote(root) .. " && " .. quote(require("luv").exepath())
			.. " -e " .. quote(code) .. " 2>&1"))
		local command = pipe:read("*a")
		pipe:close()
		-- The host is named by its module, so a move of the file does not break this.
		local host = assert(package.searchpath("core.ui.ui.dialog_host", root .. "/?.lua"), "dialog host module")
		helpers.assert_contains(command, quote(host))
	end)

	helpers.it("(bap-008-encryptor-entries) opens .enc by default and keeps « Open with » for any file", function()
		local deps, state = fake_deps()
		helpers.assert_true(Apps.launch(Apps.APPS[2], deps))
		local visible = state.files["/home/u/.local/share/applications/ergopti-encryptor.desktop"]
		helpers.assert_contains(visible, "MimeType=application/x-ergopti-encrypted;\n")
		helpers.assert_true(not visible:find("octet%-stream"), "the visible entry is no opener of any file")
		helpers.assert_true(not visible:find("NoDisplay"), "the visible entry stays in the menus")
		local any = state.files["/home/u/.local/share/applications/ergopti-encryptor-any.desktop"]
		helpers.assert_contains(any, "MimeType=application/octet-stream;\n")
		helpers.assert_contains(any, "NoDisplay=true\n")
		local package = state.files["/home/u/.local/share/mime/packages/ergopti-encryptor.xml"]
		helpers.assert_contains(package, '<mime-type type="application/x-ergopti-encrypted">')
		helpers.assert_contains(package, '<glob pattern="*.enc"/>')
		-- Only the .enc type is given a default opener.
		local register = state.spawned[1]
		helpers.assert_eq(register[1], "/bin/sh")
		helpers.assert_contains(register[2][2], "xdg-mime default 'ergopti-encryptor.desktop' 'application/x-ergopti-encrypted'")
		helpers.assert_contains(register[2][2], "update-mime-database '/home/u/.local/share/mime'")
		helpers.assert_true(not register[2][2]:find("octet"), "no default for any file")
		helpers.assert_eq(state.spawned[2][1], "/opt/runtime/bin/luajit", "then the app starts")
	end)

	helpers.it("bundled apps: writes the Encryptor drop target with its file field code", function()
		local deps, state = fake_deps()
		helpers.assert_true(Apps.launch(Apps.APPS[2], deps))
		local entry = state.files["/home/u/.local/share/applications/ergopti-encryptor.desktop"]
		helpers.assert_contains(entry, 'Exec="/bin/sh" "/home/u/.local/share/ergopti/apps/ergopti-encryptor.sh" %F\n')
		helpers.assert_contains(entry, "Comment=[menu.apps.encrypt_desc]\n")
		local launcher = state.files["/home/u/.local/share/ergopti/apps/ergopti-encryptor.sh"]
		helpers.assert_contains(launcher, "export ERGOPTI_RUNTIME_PREFIX='/opt/runtime'\n")
		helpers.assert_contains(launcher, "exec '/opt/runtime/bin/luajit' '/opt/ergopti/linux/apps/encryptor.lua'"
			.. " '--locales-dir' '/opt/ergopti/_shared/core/i18n/data/locales' '--locale' 'fr' -- \"$@\"\n")
	end)

	helpers.it("bundled apps: the generated launcher forwards dropped files after --", function()
		local pipe = assert(io.popen("mktemp -d"))
		local dir = pipe:read("*l")
		pipe:close()
		local recorder = dir .. "/interpreter"
		local f = assert(io.open(recorder, "wb"))
		f:write("#!/bin/sh\nprintf '%s\\n' \"$@\" > " .. quote(dir .. "/seen") .. "\n")
		f:close()
		os.execute("chmod 755 " .. quote(recorder))
		local script = dir .. "/launch.sh"
		f = assert(io.open(script, "wb"))
		f:write(Apps.launcher_text(recorder, { "/x/encryptor.lua", "--locales-dir", "/l" }, fake_deps()))
		f:close()
		os.execute("/bin/sh " .. quote(script) .. " " .. quote("/tmp/a b.pdf") .. " /tmp/c.enc")
		f = assert(io.open(dir .. "/seen", "rb"))
		local seen = f:read("*a")
		f:close()
		os.execute("rm -rf " .. quote(dir))
		helpers.assert_eq(seen, "/x/encryptor.lua\n--locales-dir\n/l\n--\n/tmp/a b.pdf\n/tmp/c.enc\n")
	end)

	helpers.it("bundled apps: every app dialog brands its caption once and tells cancel from no display", function()
		local commands, status = {}, 0
		local dialogs = require("apps.dialogs").new({
			command = function() return "DIALOG" end,
			run = function(command) commands[#commands + 1] = command; return "answer\n", status end,
		})
		helpers.assert_eq(dialogs.entry("Encrypt File", "Password:", { hidden = true }), "answer")
		helpers.assert_true(dialogs.question("Q", "text", "Yes", "No"))
		helpers.assert_true(dialogs.message("info", "M", "text"))
		helpers.assert_eq(dialogs.file("Pick", { filter = "*.desktop" }), "answer")
		for _, command in ipairs(commands) do
			local _, brands = command:gsub("ErgoptiPlus", "")
			helpers.assert_eq(brands, 1, command)
			helpers.assert_contains(command, " 2>/dev/null")
		end
		helpers.assert_contains(commands[1], "'--title=ErgoptiPlus — Encrypt File'")
		helpers.assert_contains(commands[1], "'--hide-text'")
		status = 1
		helpers.assert_nil(dialogs.entry("T", "x"))
		helpers.assert_true(not dialogs.question("T", "x"))
		status = 69
		helpers.assert_throws(function() dialogs.entry("T", "x") end)
	end)

	helpers.it("bundled apps: the Encryptor command line keeps files after -- as files", function()
		local options = require("apps.encryptor").parse_arguments({ "--locales-dir", "/l", "--", "--locale" })
		helpers.assert_eq(options.files[1], "--locale")
		helpers.assert_nil(options.locale)
		helpers.assert_nil((require("apps.encryptor").parse_arguments({ "a" })))
	end)
end)
