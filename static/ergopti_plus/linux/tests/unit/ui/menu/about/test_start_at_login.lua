--- tests/unit/ui/menu/about/test_start_at_login.lua

--- ==============================================================================
--- MODULE: Login Startup Menu Tests
--- DESCRIPTION:
--- Exercises state queries and explicit changes without altering real startup.
--- ==============================================================================

local helpers = require("tests.helpers")
local Startup = require("ui.menu.start_at_login")

helpers.describe("login startup", function()
	helpers.it("queries without changing startup and verifies both toggle directions (login-startup)", function()
		local enabled = false
		local changes = 0
		local function run(command)
			if command:match(" status$") then return true, enabled and "enabled\n" or "disabled\n" end
			changes = changes + 1
			enabled = command:match(" enable$") ~= nil
			return true, ""
		end
		helpers.assert_eq(Startup.enabled(run), false)
		helpers.assert_eq(changes, 0)
		helpers.assert_true(Startup.toggle(run))
		helpers.assert_true(enabled)
		helpers.assert_true(Startup.toggle(run))
		helpers.assert_eq(enabled, false)
		helpers.assert_eq(changes, 2)
	end)
	helpers.it("refuses failed queries, failed mutations and unconfirmed changes (login-startup)", function()
		helpers.assert_eq(Startup.toggle(function() return false, "" end), false)
		helpers.assert_eq(Startup.toggle(function(command)
			return command:match(" status$") ~= nil, "disabled\n"
		end), false)
		helpers.assert_eq(Startup.toggle(function() return true, "disabled\n" end), false)
	end)
	helpers.it("another startup command disables mutation without a false owned state (login-startup)", function()
		local commands = {}
		local function run(command)
			commands[#commands + 1] = command
			return true, "other\n"
		end
		helpers.assert_eq(Startup.command_available(run), false)
		helpers.assert_eq(Startup.enabled(run), nil)
		helpers.assert_eq(Startup.toggle(run), false)
		helpers.assert_eq(#commands, 3)
		for _, command in ipairs(commands) do
			helpers.assert_true(command:match(" status$") ~= nil, "no mutation crosses the existing helper")
		end
		helpers.assert_eq(Startup.command_available(function() return false, "" end), nil)
		helpers.assert_eq(Startup.command_available(function() return true, "enabled\n" end), true)
		helpers.assert_eq(Startup.command_available(function() return true, "disabled\n" end), true)
	end)
	helpers.it("logs a failed read once until a read succeeds, and every failed change (login-startup)", function()
		local previous_logger = package.loaded["logger.shim"]
		local previous_subject = package.loaded["ui.menu.start_at_login"]
		local logs = {}
		local logger = assert(dofile(require("infra.paths").shared("lua/logger/init.lua")))
		logger.set_level("trace"); logger.set_sink(function(line) logs[#logs + 1] = line end)
		package.loaded["logger.shim"] = logger
		local okay, detail = pcall(function()
			local subject = helpers.load_module("ui.menu.start_at_login")
			local function failing() return false, "", "command exited with status 78" end
			helpers.assert_eq(subject.enabled(failing), nil)
			helpers.assert_eq(subject.command_available(failing), nil)
			local function count(pattern)
				local found = 0
				for _, line in ipairs(logs) do if line:find(pattern, 1, true) then found = found + 1 end end
				return found
			end
			helpers.assert_eq(count("Startup state could not be read: command exited with status 78."), 1)
			helpers.assert_eq(subject.enabled(function() return true, "disabled\n" end), false)
			-- The logger folds consecutive identical lines; a line between keeps this one apart.
			logger.info("test", "separator")
			helpers.assert_eq(subject.enabled(failing), nil)
			helpers.assert_eq(count("Startup state could not be read"), 2, "a success re-arms the log")
			helpers.assert_eq(subject.toggle(function(command)
				if command:match(" status$") then return true, "disabled\n" end
				return false, "", "command exited with status 78"
			end), false)
			helpers.assert_eq(count("Startup enable failed: command exited with status 78."), 1)
			helpers.assert_eq(subject.toggle(function() return true, "disabled\n" end), false)
			helpers.assert_eq(count("Startup enable was not confirmed by the next read."), 1)
		end)
		package.loaded["logger.shim"], package.loaded["ui.menu.start_at_login"] = previous_logger, previous_subject
		assert(okay, detail)
	end)
end)


--- Runs the genuine menu and shell capture against an installed private helper.
--- @param mode string Native metadata/retirement outcome supplied by systemctl.
--- @param body function Receives the menu, desktop path and actual command ledger.
local function with_installed_startup(mode, body)
	local uv, Paths = require("luv"), require("infra.paths")
	local loaded = { "adapters.shell_runner", "ui.menu.start_at_login" }
	local previous = {}
	for _, name in ipairs(loaded) do previous[name] = package.loaded[name] end
	local Shell, menu
	local source_root, original_root = Paths.driver_root(), Paths.driver_root
	local root = assert(uv.fs_mkdtemp(uv.os_tmpdir() .. "/ergopti-login-menu-XXXXXX"))
	local prefix = root .. "/a space d'été Ω"
	local environment = { PATH = root .. "/commands:" .. assert(os.getenv("PATH")), XDG_CONFIG_HOME = root .. "/config",
		XDG_RUNTIME_DIR = root .. "/runtime", ERGOPTI_TEST_MODE = mode, ERGOPTI_TEST_CALLS = root .. "/calls",
		ERGOPTI_TEST_FRAGMENT = root .. "/owned.service" }
	local saved = {}
	for key in pairs(environment) do saved[key] = os.getenv(key) end
	local okay, detail = xpcall(function()
		Shell = helpers.load_module("adapters.shell_runner")
		menu = helpers.load_module("ui.menu.start_at_login")
		for _, relative in ipairs({ "/a space d'été Ω", "/a space d'été Ω/lib", "/a space d'été Ω/lib/ergopti",
			"/a space d'été Ω/lib/ergopti/linux", "/a space d'été Ω/lib/ergopti/linux/install", "/commands", "/runtime" }) do
			assert(uv.fs_mkdir(root .. relative, 448))
		end
		local function write(path, text)
			local file = assert(io.open(path, "wb")); assert(file:write(text)); assert(file:close())
		end
		for _, name in ipairs({ "start_at_login.sh", "desktop_entry.sh", "config_home.sh" }) do
			local file = assert(io.open(source_root .. "/install/" .. name, "rb"))
			local text = assert(file:read("*a")); assert(file:close())
			write(prefix .. "/lib/ergopti/linux/install/" .. name, text)
		end
		require("tests.support.shell_messages_fixture").provide(prefix .. "/lib/ergopti/linux/install")
		local calls = root .. "/calls"
		write(root .. "/owned.service", "[Service]\nExecStart=" .. prefix .. "/bin/ergopti-hotstrings --tray\n")
		write(root .. "/commands/systemctl", [[#!/bin/bash
printf '%s\n' "$*" >> "$ERGOPTI_TEST_CALLS"
if [ "$2" = is-enabled ]; then exit 1; fi
if [ "$4" = list-unit-files ]; then
 if [ "$ERGOPTI_TEST_MODE" = query-refusal ]; then exit 23; fi
 if [ "$ERGOPTI_TEST_MODE" = absent ] || [ "$ERGOPTI_TEST_MODE" = near-miss ]; then
  [ "$#" -eq 4 ] || exit 1
  if [ "$ERGOPTI_TEST_MODE" = near-miss ]; then
   printf '%s\n' 'fooergopti-hotstrings.service disabled enabled' 'ergopti-hotstrings.service.other disabled enabled'
  fi
 else printf '%s\n' 'ergopti-hotstrings.service disabled enabled'; fi
 exit 0
fi
if [ "$2" = show ]; then printf 'FragmentPath=%s\nDropInPaths=\n' "$ERGOPTI_TEST_FRAGMENT"; exit 0; fi
if [ "$2 $3" = '--no-reload disable' ] && [ "$ERGOPTI_TEST_MODE" = present ]; then exit 0; fi
exit 24
]])
		assert(uv.fs_chmod(root .. "/commands/systemctl", 493))
		for key, value in pairs(environment) do assert(uv.os_setenv(key, value)) end
		Paths.driver_root = function() return prefix .. "/lib/ergopti/linux" end
		body(menu, root .. "/config/autostart/ergopti-hotstrings.desktop", function()
			local file = assert(io.open(calls, "rb")); local text = assert(file:read("*a")); assert(file:close()); return text
		end)
	end, debug.traceback)
	Paths.driver_root = original_root
	for key in pairs(environment) do
		if saved[key] == nil then assert(uv.os_unsetenv(key)) else assert(uv.os_setenv(key, saved[key])) end
	end
	for _, name in ipairs(loaded) do package.loaded[name] = previous[name] end
	if Shell then assert(Shell.run("rm -rf -- " .. Shell.quote(root))) else assert(uv.fs_rmdir(root)) end
	if not okay then error(detail, 0) end
end

helpers.describe("installed login startup menu and native helper", function()
	for _, mode in ipairs({ "absent", "near-miss", "present" }) do
		helpers.it("(login-native-helper) confirms both toggles with " .. mode .. " unit metadata", function()
			with_installed_startup(mode, function(menu, desktop, ledger)
				helpers.assert_eq(menu.enabled(), false)
				helpers.assert_eq(menu.command_available(), true)
				helpers.assert_eq(menu.toggle(), true)
				helpers.assert_eq(menu.enabled(), true)
				helpers.assert_eq(menu.toggle(), true)
				helpers.assert_eq(menu.enabled(), false)
				local file = assert(io.open(desktop, "rb")); local bytes = assert(file:read("*a")); assert(file:close())
				helpers.assert_true(bytes:find("Hidden=true", 1, true) ~= nil)
				local calls = ledger()
				local _, disables = calls:gsub("%-%-no%-reload disable ergopti%-hotstrings%.service", "")
				helpers.assert_eq(disables, mode == "present" and 2 or 0)
				helpers.assert_true(calls:find("list-unit-files", 1, true) ~= nil)
			end)
		end)
	end
	for _, mode in ipairs({ "query-refusal", "mutation-refusal" }) do
		helpers.it("(login-native-helper) refuses " .. mode .. " without publishing startup", function()
			with_installed_startup(mode, function(menu, desktop, ledger)
				helpers.assert_eq(menu.command_available(), true)
				helpers.assert_eq(menu.enabled(), false)
				helpers.assert_eq(menu.toggle(), false)
				local file = io.open(desktop, "rb")
				if file then assert(file:close()) end
				helpers.assert_nil(file)
				helpers.assert_eq(menu.enabled(), false)
				local calls = ledger()
				helpers.assert_true(calls:find("list-unit-files", 1, true) ~= nil)
				helpers.assert_nil(calls:find("--now", 1, true))
			end)
		end)
	end
end)

--- Runs the genuine menu and helper against a private source checkout (SAD-1).
--- @param body function Receives the menu, the checkout's launcher, the entry path and a writer.
local function with_source_startup(body)
	local uv, Paths = require("luv"), require("infra.paths")
	local loaded = { "adapters.shell_runner", "ui.menu.start_at_login" }
	local previous = {}
	for _, name in ipairs(loaded) do previous[name] = package.loaded[name] end
	local Shell
	local source_root, original_root = Paths.driver_root(), Paths.driver_root
	local root = assert(uv.fs_mkdtemp(uv.os_tmpdir() .. "/ergopti-source-login-XXXXXX"))
	local driver = root .. "/clone d'été/static/ergopti_plus/linux"
	local environment = { PATH = root .. "/commands:" .. assert(os.getenv("PATH")), XDG_CONFIG_HOME = root .. "/config" }
	local saved = {}
	for key in pairs(environment) do saved[key] = os.getenv(key) end
	local function write(path, text)
		local file = assert(io.open(path, "wb")); assert(file:write(text)); assert(file:close())
	end
	local okay, detail = xpcall(function()
		Shell = helpers.load_module("adapters.shell_runner")
		local menu = helpers.load_module("ui.menu.start_at_login")
		assert(Shell.run("mkdir -p -- " .. Shell.quote(driver .. "/install") .. " " .. Shell.quote(driver .. "/bin")
			.. " " .. Shell.quote(driver .. "/../_shared/data/locales") .. " " .. Shell.quote(root .. "/commands")))
		for _, name in ipairs({ "start_at_login.sh", "desktop_entry.sh", "config_home.sh" }) do
			local file = assert(io.open(source_root .. "/install/" .. name, "rb"))
			local text = assert(file:read("*a")); assert(file:close())
			write(driver .. "/install/" .. name, text)
		end
		require("tests.support.shell_messages_fixture").provide(driver .. "/install")
		write(driver .. "/bin/ergopti-hotstrings", "#!/usr/bin/env bash\n")
		write(driver .. "/../_shared/data/locales/en.json", "{}\n")
		-- No user unit and no enabled service: the XDG entry alone is the startup.
		write(root .. "/commands/systemctl", "#!/bin/bash\nif [ \"$2\" = is-enabled ]; then exit 1; fi\nexit 0\n")
		assert(uv.fs_chmod(root .. "/commands/systemctl", 493))
		for key, value in pairs(environment) do assert(uv.os_setenv(key, value)) end
		Paths.driver_root = function() return driver end
		body(menu, driver .. "/bin/ergopti-hotstrings", root .. "/config/autostart/ergopti-source.desktop", write)
	end, debug.traceback)
	Paths.driver_root = original_root
	for key in pairs(environment) do
		if saved[key] == nil then assert(uv.os_unsetenv(key)) else assert(uv.os_setenv(key, saved[key])) end
	end
	for _, name in ipairs(loaded) do package.loaded[name] = previous[name] end
	if Shell then assert(Shell.run("rm -rf -- " .. Shell.quote(root))) end
	if not okay then error(detail, 0) end
end

--- Reads a whole file.
local function read_file(path)
	local file = assert(io.open(path, "rb")); local text = assert(file:read("*a")); assert(file:close()); return text
end

helpers.describe("login startup on a source run (SAD-1)", function()
	helpers.it("(login-source-run) starts the checkout's own launcher by absolute path", function()
		with_source_startup(function(menu, launcher, desktop)
			helpers.assert_eq(menu.command_available(), true)
			helpers.assert_eq(menu.enabled(), false)
			helpers.assert_eq(menu.toggle(), true)
			helpers.assert_eq(menu.enabled(), true)
			-- The standalone installer's entry name stays free (install.sh refuses an
			-- ergopti-hotstrings entry it does not own).
			helpers.assert_nil(io.open(desktop:gsub("ergopti%-source", "ergopti-hotstrings"), "rb"))
			local bytes = read_file(desktop)
			helpers.assert_true(bytes:find('Exec=/bin/bash "' .. launcher .. '" --tray\n', 1, true) ~= nil, bytes)
			helpers.assert_true(bytes:find("Hidden=false", 1, true) ~= nil)
			helpers.assert_eq(menu.toggle(), true)
			helpers.assert_eq(menu.enabled(), false)
			helpers.assert_true(read_file(desktop):find("Hidden=true", 1, true) ~= nil)
		end)
	end)
	helpers.it("(login-source-run) reports an entry whose launcher is gone and rewrites it on enable", function()
		with_source_startup(function(menu, launcher, desktop, write)
			assert(require("adapters.shell_runner").run("mkdir -p -- "
				.. require("adapters.shell_runner").quote(desktop:match("^(.*)/[^/]+$"))))
			write(desktop, '[Desktop Entry]\nType=Application\nName=Ergopti\n'
				.. 'Exec=/bin/bash "/moved/clone/static/ergopti_plus/linux/bin/ergopti-hotstrings" --tray\n'
				.. 'Terminal=false\nHidden=false\nX-Ergopti-Startup=true\n')
			local previous_logger = package.loaded["logger.shim"]
			local logs = {}
			local logger = assert(dofile(require("infra.paths").shared("lua/logger/init.lua")))
			logger.set_level("trace"); logger.set_sink(function(line) logs[#logs + 1] = line end)
			package.loaded["logger.shim"] = logger
			local ok, failure = pcall(function()
				local subject = helpers.load_module("ui.menu.start_at_login")
				helpers.assert_eq(subject.enabled(), false, "a gone launcher starts nothing")
				helpers.assert_eq(subject.command_available(), true, "the entry is ours to rewrite")
				local warned = 0
				for _, line in ipairs(logs) do
					if line:find("names a launcher that no longer exists", 1, true) then warned = warned + 1 end
				end
				helpers.assert_eq(warned, 1, "the stale entry is said once")
				helpers.assert_eq(subject.toggle(), true)
				helpers.assert_eq(subject.enabled(), true)
				helpers.assert_true(read_file(desktop):find('Exec=/bin/bash "' .. launcher .. '" --tray\n', 1, true) ~= nil)
			end)
			package.loaded["logger.shim"] = previous_logger
			assert(ok, failure)
		end)
	end)
	helpers.it("(login-source-run) keeps a live foreign entry as another command", function()
		with_source_startup(function(menu, _, desktop, write)
			assert(require("adapters.shell_runner").run("mkdir -p -- "
				.. require("adapters.shell_runner").quote(desktop:match("^(.*)/[^/]+$"))))
			write(desktop, '[Desktop Entry]\nType=Application\nExec=/bin/bash "/bin/sh" --tray\n'
				.. 'X-Ergopti-Startup=true\n')
			helpers.assert_eq(menu.command_available(), false)
			helpers.assert_eq(menu.toggle(), false)
			helpers.assert_true(read_file(desktop):find('Exec=/bin/bash "/bin/sh" --tray', 1, true) ~= nil)
		end)
	end)
end)
