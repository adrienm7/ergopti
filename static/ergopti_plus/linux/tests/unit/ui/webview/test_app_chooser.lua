--- tests/unit/ui/webview/test_app_chooser.lua

--- ==============================================================================
--- MODULE: Application chooser for open_app (Linux)
--- DESCRIPTION:
--- The dialog an open_app binding is configured with: zenity (or kdialog) over
--- the system's desktop entries, answered with the desktop-file id gtk-launch
--- takes, and nothing when the user cancels or picks something else.
---
--- ROOT CAUSE ENCODED:
--- open_app needs an application parameter; a free-text prompt would leave the
--- user guessing what gtk-launch accepts, so the value is picked from the
--- desktop entries instead.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A shell double that acknowledges only a supplied answer and records commands.
--- @param tools table binary -> boolean
--- @param answer string|nil What the dialog prints.
--- @return table shell, table commands
local function fake_shell(tools, answer)
	local commands = {}
	local shell = {
		has_command = function(binary) return tools[binary] == true end,
		quote = function(value) return "'" .. tostring(value):gsub("'", "'\\''") .. "'" end,
		exec_checked = function(command)
			commands[#commands + 1] = command
			return answer ~= nil, answer or ""
		end,
	}
	return shell, commands
end

helpers.describe("open_app application chooser (Linux)", function()
	local Chooser = helpers.load_module("ui.app_chooser")

	helpers.it("zenity lists the desktop entries and the choice becomes its desktop id", function()
		local shell, commands = fake_shell({ zenity = true }, "/usr/share/applications/org.gnome.Nautilus.desktop")
		local id, err = Chooser.pick(shell, "Open an application")
		helpers.assert_eq(err, nil)
		helpers.assert_eq(id, "org.gnome.Nautilus")
		helpers.assert_eq(commands[1], "zenity --file-selection --title='ErgoptiPlus — Open an application'"
			.. " --filename='/usr/share/applications/' --file-filter='*.desktop' 2>/dev/null")
	end)

	helpers.it("kdialog is the fallback", function()
		local shell, commands = fake_shell({ kdialog = true }, "/usr/share/applications/firefox.desktop")
		helpers.assert_eq((Chooser.pick(shell, "T")), "firefox")
		helpers.assert_eq(commands[1], "kdialog --getopenfilename '/usr/share/applications/' '*.desktop'"
			.. " --title 'ErgoptiPlus — T' 2>/dev/null")
	end)

	helpers.it("a cancelled dialog, another file or no dialog tool chooses nothing", function()
		local shell = fake_shell({ zenity = true }, nil)
		helpers.assert_eq((Chooser.pick(shell, "T")), nil)
		shell = fake_shell({ zenity = true }, "/home/ana/notes.txt")
		helpers.assert_eq((Chooser.pick(shell, "T")), nil)
		local none, commands = fake_shell({}, "/usr/share/applications/firefox.desktop")
		local id, err = Chooser.pick(none, "T")
		helpers.assert_eq(id, nil)
		helpers.assert_true(type(err) == "string" and err ~= "", "no dialog tool is named as the reason")
		helpers.assert_eq(#commands, 0)
	end)

	helpers.it("desktop_id strips only a real .desktop suffix", function()
		helpers.assert_eq(Chooser.desktop_id("/usr/share/applications/code.desktop"), "code")
		helpers.assert_eq(Chooser.desktop_id("/x/.desktop"), nil)
		helpers.assert_eq(Chooser.desktop_id("/x/app.desktop.bak"), nil)
	end)
end)


--- Runs one mapping under explicit XDG directories without leaking process state.
--- @param environment table XDG values; false means unset.
--- @param body function Test body.
local function with_desktop_environment(environment, body)
	local real = os.getenv
	os.getenv = function(name)
		if environment[name] ~= nil then return environment[name] or nil end
		return real(name)
	end
	local called, detail = pcall(body)
	os.getenv = real
	if not called then error(detail, 0) end
end

helpers.describe("application chooser preserves installed desktop ids", function()
	local cases = {
		{ "nested system entry", false, false, "/usr/share/applications/vendor/editor.desktop", "vendor-editor" },
		{ "nested user entry", "/data/user", false, "/data/user/applications/vendor/editor.desktop", "vendor-editor" },
		{ "custom system entry", false, "/custom/share", "/custom/share/applications/tools/editor.desktop", "tools-editor" },
		{ "multiple roots", false, "/first:/second", "/second/applications/tools/editor.desktop", "tools-editor" },
		{ "default system roots", false, false, "/usr/local/share/applications/editor.desktop", "editor" },
		{ "empty system roots use defaults", false, "", "/usr/share/applications/editor.desktop", "editor" },
		{ "relative user root uses canonical default", "relative", false, "/account/.local/share/applications/tools/editor.desktop", "tools-editor" },
		{ "relative system root is ignored", false, "relative:/custom/share", "/custom/share/applications/editor.desktop", "editor" },
		{ "relative roots do not become the CWD", false, "relative", "/usr/share/applications/editor.desktop", false },
		{ "filesystem root data directory", "/", false, "/applications/vendor/editor.desktop", "vendor-editor" },
		{ "root boundary", "/data", false, "/database/applications/editor.desktop", false },
		{ "applications boundary", "/data", false, "/data/applications-copy/editor.desktop", false },
		{ "overlapping roots retain ordered relative path", "/data", "/data/applications/vendor", "/data/applications/vendor/applications/editor.desktop", "vendor-applications-editor" },
		{ "standalone file has no installed id", false, false, "/downloads/editor.desktop", false },
		{ "relative desktop path", false, false, "editor.desktop", false },
		{ "parent traversal", false, false, "/usr/share/applications/vendor/../editor.desktop", false },
		{ "dot traversal", false, false, "/usr/share/applications/./editor.desktop", false },
		{ "empty basename", false, false, "/usr/share/applications/vendor/.desktop", false },
		{ "desktop suffix remains exact", false, false, "/usr/share/applications/vendor/editor.desktop.bak", false },
		{ "repeated separators", false, false, "/usr//share/applications/vendor//editor.desktop", "vendor-editor" },
	}
	for _, row in ipairs(cases) do
		helpers.it("(linux-desktop-id) " .. row[1], function()
			with_desktop_environment({ HOME = "/account", XDG_DATA_HOME = row[2], XDG_DATA_DIRS = row[3] }, function()
				local expected = row[5] ~= false and row[5] or nil
				local Chooser = require("ui.app_chooser")
				helpers.assert_eq(Chooser.desktop_id(row[4]), expected)
				local shell = fake_shell({ zenity = true }, row[4] .. "\n")
				local selected, reason = Chooser.pick(shell, "Applications")
				helpers.assert_eq(selected, expected)
				if expected == nil then helpers.assert_true(type(reason) == "string" and reason ~= "") end
			end)
		end)
	end
end)


--- Exercises a real dialog child and shell status without requiring a desktop prompt.
--- @param tool string Selected native dialog tool.
--- @param status number Actual child exit status.
--- @param output string Actual child stdout.
--- @return string receipt
local function native_dialog_receipt(tool, status, output)
	local Shell = require("adapters.shell_runner")
	local made, directory = Shell.exec_checked("mktemp -d")
	assert(made)
	directory = directory:gsub("[\r\n]+$", "")
	local executable, worker = directory .. "/" .. tool, directory .. "/worker.lua"
	local function write(path, content)
		local file = assert(io.open(path, "wb"))
		assert(file:write(content) and file:close())
	end
	local ok, receipt = xpcall(function()
		write(executable, "#!/bin/sh\nprintf '%s' " .. Shell.quote(output) .. "\nexit " .. status .. "\n")
		assert(Shell.run("chmod u+x " .. Shell.quote(executable)))
		write(worker, "package.path = " .. string.format("%q", package.path) .. "\n"
			.. "package.loaded['logger.shim']={error=function()end,warn=function()end,debug=function()end}\n"
			.. "local calls=0;package.loaded['ui.modal']={run=function(fn)calls=calls+1;return fn()end}\n"
			.. "local S=require('adapters.shell_runner')\n"
			.. "local shell={quote=S.quote,exec_line=S.exec_line,exec_checked=S.exec_checked,"
			.. "has_command=function(name)return name==" .. string.format("%q", tool) .. "end}\n"
			.. "local id=require('ui.app_chooser').pick(shell,'Applications')\n"
			.. "io.write(id==nil and 'refused' or 'accepted|'..id);io.write('|modal:'..calls)\n")
		local executed, result, reason = Shell.exec_checked("env PATH="
			.. Shell.quote(directory .. ":" .. (os.getenv("PATH") or ""))
			.. " " .. Shell.quote(arg[-1] or "luajit") .. " " .. Shell.quote(worker))
		assert(executed, tostring(reason))
		return result
	end, debug.traceback)
	os.remove(executable)
	os.remove(worker)
	assert(Shell.run("rmdir " .. Shell.quote(directory)), "Private dialog files must retire")
	assert(ok, receipt)
	return receipt
end

helpers.describe("application chooser requires native confirmation", function()
	for _, tool in ipairs({ "zenity", "kdialog" }) do
		for _, status in ipairs({ 1, 7 }) do
			helpers.it("(linux-app-chooser-status) " .. tool .. " exit " .. status .. " rejects partial selection", function()
				helpers.assert_eq(native_dialog_receipt(tool, status, "/usr/share/applications/firefox.desktop\n"),
					"refused|modal:1")
			end)
		end
		helpers.it("(linux-app-chooser-status) " .. tool .. " successful choice preserves the first-line id", function()
			helpers.assert_eq(native_dialog_receipt(tool, 0, "/usr/share/applications/org.gnome.Nautilus.desktop\nignored\n"),
				"accepted|org.gnome.Nautilus|modal:1")
		end)
		helpers.it("(linux-app-chooser-status) " .. tool .. " confirmed empty output is not an application", function()
			helpers.assert_eq(native_dialog_receipt(tool, 0, ""), "refused|modal:1")
		end)
	end
end)
