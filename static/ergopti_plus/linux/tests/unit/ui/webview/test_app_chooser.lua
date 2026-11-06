--- tests/unit/ui/webview/test_app_chooser.lua

--- ==============================================================================
--- MODULE: Application chooser for open_app (Linux)
--- DESCRIPTION:
--- The dialog an open_app binding is configured with: Ergopti's own file dialog
--- over the system's desktop entries, answered with the desktop-file id gtk-launch
--- takes, and nothing when the user cancels or picks something else.
---
--- ROOT CAUSE ENCODED:
--- open_app needs an application parameter; a free-text prompt would leave the
--- user guessing what gtk-launch accepts, so the value is picked from the
--- desktop entries instead.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A shell double that acknowledges only a supplied answer and records commands.
--- @param answer string|nil What the dialog prints.
--- @return table shell, table commands
local function fake_shell(answer)
	local commands = {}
	local shell = {
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

	helpers.it("the owned dialog lists the desktop entries and the choice becomes its desktop id", function()
		local shell, commands = fake_shell("/usr/share/applications/org.gnome.Nautilus.desktop")
		local id, err = Chooser.pick(shell, "Open an application", { resolve = function()
			return "/usr/share/applications/org.gnome.Nautilus.desktop", "found"
		end })
		helpers.assert_eq(err, nil)
		helpers.assert_eq(id, "org.gnome.Nautilus")
		helpers.assert_eq(commands[1], require("ui.native_dialog").command()
			.. " --file-selection --title='ErgoptiPlus — Open an application'"
			.. " --filename='/usr/share/applications/' --file-filter='*.desktop' 2>/dev/null")
	end)

	helpers.it("refuses a selected desktop entry shadowed by the native XDG owner", function()
		local shell = fake_shell("/usr/share/applications/example.desktop")
		local notices = 0
		local selected = Chooser.pick(shell, "Applications", {
			resolve = function(id)
				helpers.assert_eq(id, "example")
				return "/home/example/.local/share/applications/example.desktop", "found"
			end,
			notify = function() notices = notices + 1; return true end,
		})
		helpers.assert_nil(selected)
		helpers.assert_eq(notices, 1)
	end)

	helpers.it("refuses unverifiable native desktop resolution and reports it", function()
		for _, resolver in ipairs({ function() return nil, "unavailable" end, function() return nil, "not_found" end,
			function() error("native resolver failed") end }) do
			local shell, notices = fake_shell("/usr/share/applications/example.desktop"), 0
			local selected = Chooser.pick(shell, "Applications", {
				resolve = resolver, notify = function() notices = notices + 1; return true end,
			})
			helpers.assert_nil(selected)
			helpers.assert_eq(notices, 1)
		end
	end)

	helpers.it("a shadowed choice shows the translated native error", function()
		local shell, commands = fake_shell("/usr/share/applications/example.desktop")
		local selected = Chooser.pick(shell, "Applications", {
			resolve = function() return "/other/example.desktop", "found" end,
		})
		helpers.assert_nil(selected)
		helpers.assert_eq(#commands, 2)
		helpers.assert_true(commands[2]:find(" --error --no-markup ", 1, true) ~= nil)
		helpers.assert_true(commands[2]:find(" --title='ErgoptiPlus — Applications'", 1, true) ~= nil)
		helpers.assert_true(commands[2]:find(require("infra.i18n").get("dialog.app_picker.selection_unverified"), 1, true) ~= nil)
	end)

	helpers.it("a cancelled dialog or another file chooses nothing", function()
		local shell = fake_shell(nil)
		helpers.assert_eq((Chooser.pick(shell, "T")), nil)
		shell = fake_shell("/home/ana/notes.txt")
		helpers.assert_eq((Chooser.pick(shell, "T")), nil)
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
				local shell = fake_shell(row[4] .. "\n")
				local selected, reason = Chooser.pick(shell, "Applications", { resolve = function() return row[4], "found" end })
				helpers.assert_eq(selected, expected)
				if expected == nil then helpers.assert_true(type(reason) == "string" and reason ~= "") end
			end)
		end)
	end
end)


--- Exercises a real dialog child and shell status without requiring a desktop prompt.
--- @param status number Actual child exit status.
--- @param output string Actual child stdout.
--- @return string receipt
local function native_dialog_receipt(status, output)
	local Shell = require("adapters.shell_runner")
	local made, directory = Shell.exec_checked("mktemp -d")
	assert(made)
	directory = directory:gsub("[\r\n]+$", "")
	local executable, worker = directory .. "/dialog", directory .. "/worker.lua"
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
			.. "local shell={quote=S.quote,exec_line=S.exec_line,exec_checked=S.exec_checked}\n"
			-- The private executable stands in for the owned dialog host.
			.. "package.loaded['ui.native_dialog']={command=function()return S.quote(" .. string.format("%q", executable) .. ")end}\n"
			.. "local id=require('ui.app_chooser').pick(shell,'Applications',{resolve=function() return "
			.. string.format("%q", output:gsub("\n$", "")) .. ", 'found' end})\n"
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

helpers.describe("application chooser follows the actual XDG resolution owner", function()
	helpers.it("keeps the higher-priority file and refuses the shadowed selection", function()
		if not rawget(_G, "jit") then print("SKIP: native Gio worker requires LuaJIT FFI"); return end
		local Shell = require("adapters.shell_runner")
		local ok, root = Shell.exec_checked("mktemp -d")
		assert(ok); root = root:gsub("[\r\n]+$", "")
		local user, system, worker = root .. "/user", root .. "/system", root .. "/worker.lua"
		assert(Shell.run("mkdir -p " .. Shell.quote(user .. "/applications") .. " " .. Shell.quote(system .. "/applications")))
		local function write(path, text)
			local f = assert(io.open(path, "wb")); assert(f:write(text)); assert(f:close())
		end
		local name = "ergopti-choice-witness.desktop"
		write(system .. "/applications/" .. name, "[Desktop Entry]\nType=Application\nName=Witness\nExec=/bin/true\n")
		write(worker, "package.path=" .. string.format("%q", package.path) .. "\n"
			.. "package.loaded['ui.modal']={run=function(fn)return fn()end}\n"
			.. "package.loaded['ui.native_dialog']={command=function()return 'dialog' end}\n"
			.. "local chooser=require('ui.app_chooser'); local resolver=require('ui.desktop_application_resolution'); local notices=0\n"
			.. "local function pick(path) local shell={quote=function(s)return s end,exec_checked=function()return true,path..'\\n' end}; "
			.. "return chooser.pick(shell,'T',{notify=function()notices=notices+1;return true end}) end\n"
			.. "local before=resolver.resolve('ergopti-choice-witness')\n"
			.. "local f=assert(io.open(" .. string.format("%q", user .. "/applications/" .. name) .. ", 'wb')); "
			.. "assert(f:write('[Desktop Entry]\\nType=Application\\nName=Override\\nExec=/bin/true\\n')); assert(f:close())\n"
			.. "local after=resolver.resolve('ergopti-choice-witness')\n"
			.. "io.write(tostring(before==" .. string.format("%q", system .. "/applications/" .. name) .. "), '|', "
			.. "tostring(after==" .. string.format("%q", user .. "/applications/" .. name) .. "), '|', "
			.. "tostring(pick(" .. string.format("%q", system .. "/applications/" .. name) .. ")), '|', "
			.. "tostring(pick(" .. string.format("%q", user .. "/applications/" .. name) .. ")), '|')\n"
			.. "assert(os.execute(" .. string.format("%q", "mkdir -p " .. Shell.quote(user .. "/applications/vendor")) .. ")==0)\n"
			.. "local f=assert(io.open(" .. string.format("%q", user .. "/applications/vendor/editor.desktop") .. ", 'wb')); "
			.. "assert(f:write('[Desktop Entry]\\nType=Application\\nName=Nested\\nExec=/bin/true\\n')); assert(f:close())\n"
			.. "local f=assert(io.open(" .. string.format("%q", user .. "/applications/" .. name .. ".desktop") .. ", 'wb')); "
			.. "assert(f:write('[Desktop Entry]\\nType=Application\\nName=Double\\nExec=/bin/true\\n')); assert(f:close())\n"
			.. "io.write(tostring(pick(" .. string.format("%q", user .. "/applications/" .. name .. ".desktop") .. ")), '|', "
			.. "tostring(pick(" .. string.format("%q", user .. "/applications/vendor/editor.desktop") .. ")), '|', notices)\n")
		local command = "env XDG_DATA_HOME=" .. Shell.quote(user) .. " XDG_DATA_DIRS=" .. Shell.quote(system)
			.. " " .. Shell.quote(arg[-1] or "luajit") .. " " .. Shell.quote(worker)
		local ran, output = Shell.exec_checked(command)
		os.remove(worker); os.remove(user .. "/applications/vendor/editor.desktop")
		Shell.run("rmdir " .. Shell.quote(user .. "/applications/vendor"))
		os.remove(user .. "/applications/" .. name .. ".desktop")
		os.remove(user .. "/applications/" .. name); os.remove(system .. "/applications/" .. name)
		Shell.run("rmdir " .. Shell.quote(user .. "/applications") .. " " .. Shell.quote(system .. "/applications")
			.. " " .. Shell.quote(user) .. " " .. Shell.quote(system) .. " " .. Shell.quote(root))
		helpers.assert_true(ran)
		helpers.assert_eq(output, "true|true|nil|ergopti-choice-witness|nil|vendor-editor|2")
	end)
end)

helpers.describe("application lookup owns its bounded native worker", function()
	helpers.it("refuses failed or malformed bounded lookup receipts", function()
		local names = { "ui.desktop_application_resolution", "adapters.shell_runner", "ui.modal" }
		local previous = {}; for _, name in ipairs(names) do previous[name] = package.loaded[name] end
		local command, modal_calls, answer, output = nil, 0, false, ""
		local real_shell = require("adapters.shell_runner")
		package.loaded["adapters.shell_runner"] = { quote = real_shell.quote, exec_checked = function(value)
			command = value
			return answer, output
		end }
		package.loaded["ui.modal"] = { run = function(fn) modal_calls = modal_calls + 1; return fn() end }
		package.loaded["ui.desktop_application_resolution"] = nil
		local ok, detail = pcall(function()
			local resolver = require("ui.desktop_application_resolution")
			local path, status = resolver.resolve("example")
			helpers.assert_nil(path); helpers.assert_eq(status, "unavailable")
			helpers.assert_true(command:find("timeout --foreground --kill-after=1s 2s ", 1, true) == 1)
			answer, output = true, "/first\n/forged\n"
			path, status = resolver.resolve("example")
			helpers.assert_nil(path); helpers.assert_eq(status, "unavailable")
			answer, output = true, "/valid/example.desktop\n"
			path, status = resolver.resolve("example")
			helpers.assert_eq(path, "/valid/example.desktop"); helpers.assert_eq(status, "found")
			helpers.assert_eq(modal_calls, 3)
		end)
		for _, name in ipairs(names) do package.loaded[name] = previous[name] end
		if not ok then error(detail, 0) end
	end)

	helpers.it("resolves through a literal driver root containing semicolon and question mark", function()
		if not rawget(_G, "jit") then print("SKIP: native Gio worker requires LuaJIT FFI"); return end
		local Shell = require("adapters.shell_runner")
		local made, root = Shell.exec_checked("mktemp -d"); assert(made); root = root:gsub("[\r\n]+$", "")
		local driver, user = root .. "/driver;?literal", root .. "/user"
		assert(Shell.run("mkdir -p " .. Shell.quote(driver .. "/ui") .. " " .. Shell.quote(driver .. "/_generated")
			.. " " .. Shell.quote(user .. "/applications")))
		local function copy(source, target)
			local input = assert(io.open(source, "rb")); local bytes = input:read("*a"); assert(input:close())
			local output = assert(io.open(target, "wb")); assert(output:write(bytes)); assert(output:close())
		end
		local original = helpers.driver_root()
		for _, file in ipairs({ "ui/desktop_application_resolution.lua", "ui/desktop_application_resolution_worker.lua",
			"_generated/native_runtime.lua" }) do copy(original .. "/" .. file, driver .. "/" .. file) end
		local desktop = user .. "/applications/ergopti-literal-choice.desktop"
		local entry = assert(io.open(desktop, "wb")); assert(entry:write("[Desktop Entry]\nType=Application\nName=Literal\nExec=/bin/true\n")); assert(entry:close())
		local parent = root .. "/parent.lua"
		local file = assert(io.open(parent, "wb"))
		assert(file:write("package.path=" .. string.format("%q", package.path) .. "\n"
			.. "package.loaded['ui.modal']={run=function(fn)return fn()end}\n"
			.. "local resolver=assert(loadfile(" .. string.format("%q", driver .. "/ui/desktop_application_resolution.lua") .. "))()\n"
			.. "local path,status=resolver.resolve('ergopti-literal-choice'); io.write(tostring(path),'|',status)\n")); assert(file:close())
		local command = "env XDG_DATA_HOME=" .. Shell.quote(user) .. " XDG_DATA_DIRS=" .. Shell.quote(root .. "/empty")
			.. " " .. Shell.quote(arg[-1] or "luajit") .. " " .. Shell.quote(parent)
		local ran, output = Shell.exec_checked(command)
		for _, file_name in ipairs({ "ui/desktop_application_resolution.lua", "ui/desktop_application_resolution_worker.lua",
			"_generated/native_runtime.lua" }) do os.remove(driver .. "/" .. file_name) end
		os.remove(parent); os.remove(desktop)
		Shell.run("rmdir " .. Shell.quote(driver .. "/ui") .. " " .. Shell.quote(driver .. "/_generated")
			.. " " .. Shell.quote(user .. "/applications") .. " " .. Shell.quote(driver) .. " " .. Shell.quote(user) .. " " .. Shell.quote(root))
		helpers.assert_true(ran)
		helpers.assert_eq(output, desktop .. "|found")
	end)

	helpers.it("waits for a worker that ignores TERM and needs KILL", function()
		local Shell, uv = require("adapters.shell_runner"), require("luv")
		local made, root = Shell.exec_checked("mktemp -d"); assert(made); root = root:gsub("[\r\n]+$", "")
		local interpreter, marker, parent = root .. "/interpreter", root .. "/pid", root .. "/parent.lua"
		local function write(path, text)
			local file = assert(io.open(path, "wb")); assert(file:write(text)); assert(file:close())
		end
		-- No child commands: this interpreter remains the exact timeout child.
		write(interpreter, "#!/bin/sh\ntrap '' TERM\nprintf '%s' \"$$\" > " .. Shell.quote(marker)
			.. "\nwhile :; do :; done\n")
		assert(Shell.run("chmod u+x " .. Shell.quote(interpreter)))
		write(parent, "package.path=" .. string.format("%q", package.path) .. "\n"
			.. "require('adapters.shell_runner')\n"
			.. "package.loaded['ui.modal']={run=function(fn)return fn()end}\n"
			.. "package.loaded.luv={exepath=function()return " .. string.format("%q", interpreter) .. " end}\n"
			.. "local path,status=require('ui.desktop_application_resolution').resolve('witness'); io.write(tostring(path),'|',status)\n")
		local start = uv.hrtime()
		local ran, output = Shell.exec_checked("timeout --foreground --kill-after=1s 8s "
			.. Shell.quote(arg[-1] or "luajit") .. " " .. Shell.quote(parent))
		local elapsed = (uv.hrtime() - start) / 1e9
		local f = io.open(marker, "rb"); local pid = f and f:read("*a") or nil; if f then f:close() end
		local alive = type(pid) == "string" and pid:match("^%d+$") and Shell.run("kill -0 " .. pid .. " 2>/dev/null")
		os.remove(interpreter); os.remove(marker); os.remove(parent); Shell.run("rmdir " .. Shell.quote(root))
		helpers.assert_true(ran)
		helpers.assert_eq(output, "nil|unavailable")
		helpers.assert_true(type(pid) == "string" and pid:match("^%d+$") ~= nil, "the exact worker started")
		helpers.assert_true(elapsed >= 2.8 and elapsed < 10, "the kill grace elapsed and the worker retired")
		helpers.assert_eq(alive, false, "the exact worker no longer exists after timeout returns")
	end)

	helpers.it("retires a Gio worker blocked on a higher-priority FIFO", function()
		if not rawget(_G, "jit") then print("SKIP: native Gio worker requires LuaJIT FFI"); return end
		local Shell, uv = require("adapters.shell_runner"), require("luv")
		local made, root = Shell.exec_checked("mktemp -d"); assert(made); root = root:gsub("[\r\n]+$", "")
		local user, system = root .. "/user", root .. "/system"
		assert(Shell.run("mkdir -p " .. Shell.quote(user .. "/applications") .. " " .. Shell.quote(system .. "/applications")))
		local id = "ergopti-fifo-witness-" .. tostring(uv.os_getpid())
		local fifo, worker = user .. "/applications/" .. id .. ".desktop", root .. "/worker.lua"
		assert(Shell.run("mkfifo " .. Shell.quote(fifo)))
		local f = assert(io.open(worker, "wb"))
		assert(f:write("package.path=" .. string.format("%q", package.path) .. "\n"
			.. "package.loaded['ui.modal']={run=function(fn)return fn()end}\n"
			.. "local path,status=require('ui.desktop_application_resolution').resolve(" .. string.format("%q", id) .. ")\n"
			.. "io.write(tostring(path),'|',status)\n")); assert(f:close())
		local command = "timeout --foreground --kill-after=1s 8s env XDG_DATA_HOME=" .. Shell.quote(user) .. " XDG_DATA_DIRS=" .. Shell.quote(system)
			.. " " .. Shell.quote(arg[-1] or "luajit") .. " " .. Shell.quote(worker)
		local start = uv.hrtime()
		local ran, output = Shell.exec_checked(command)
		local elapsed = (uv.hrtime() - start) / 1e9
		-- The child has no descendants; timeout waits for its native exit before
		-- exec_checked returns. Check no matching worker survives the reply.
		local listed, processes = Shell.exec_checked("ps -eo comm=,args=")
		local survivor = false
		for line in processes:gmatch("[^\n]+") do
			if (line:match("^%s*luajit%s") or line:match("^%s*timeout%s"))
				and line:find("desktop_application_resolution_worker.lua", 1, true)
				and line:find(id, 1, true) then survivor = true end
		end
		os.remove(worker); os.remove(fifo)
		Shell.run("rmdir " .. Shell.quote(user .. "/applications") .. " " .. Shell.quote(system .. "/applications")
			.. " " .. Shell.quote(user) .. " " .. Shell.quote(system) .. " " .. Shell.quote(root))
		helpers.assert_true(ran)
		helpers.assert_eq(output, "nil|unavailable")
		helpers.assert_true(elapsed < 10, "a FIFO lookup must be bounded")
		helpers.assert_true(listed)
		helpers.assert_eq(survivor, false, "the lookup worker must have exited before the reply")
	end)
end)

helpers.describe("application chooser requires native confirmation", function()
	do local tool = "owned dialog"
		for _, status in ipairs({ 1, 7 }) do
			helpers.it("(linux-app-chooser-status) " .. tool .. " exit " .. status .. " rejects partial selection", function()
				helpers.assert_eq(native_dialog_receipt(status, "/usr/share/applications/firefox.desktop\n"),
					"refused|modal:1")
			end)
		end
		helpers.it("(linux-app-chooser-status) " .. tool .. " successful choice preserves the exact native id", function()
			helpers.assert_eq(native_dialog_receipt(0, "/usr/share/applications/org.gnome.Nautilus.desktop\n"),
				"accepted|org.gnome.Nautilus|modal:1")
		end)
		helpers.it("(linux-app-chooser-status) " .. tool .. " refuses a line break inside the full record", function()
			helpers.assert_eq(native_dialog_receipt(0, "/usr/share/applications/org.gnome.Nautilus.desktop\nignored\n"),
				"refused|modal:1")
		end)
		helpers.it("(linux-app-chooser-status) " .. tool .. " confirmed empty output is not an application", function()
			helpers.assert_eq(native_dialog_receipt(0, ""), "refused|modal:1")
		end)
	end
end)
