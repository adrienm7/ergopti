--- tests/unit/ui/bundled_apps/test_app_cloner_core.lua

--- ==============================================================================
--- MODULE: Linux App Cloner Tests
--- DESCRIPTION:
--- Pins the Linux App Cloner: desktop-entry parsing and Exec quoting, family
--- detection from the shared catalogue, the generated launcher (run for real
--- against a recording program, so the isolation it promises is observed) and
--- the dialog flow with scripted answers.
--- ==============================================================================

local helpers = require("tests.helpers")
local Core = require("apps.app_cloner_core")
local Flow = require("apps.app_cloner")
local quote = require("text_utils").shell_quote

local CATALOGUE = Core.load_families()

local function work_dir()
	local pipe = assert(io.popen("mktemp -d"))
	local dir = pipe:read("*l")
	pipe:close()
	return dir
end
local function write(path, text) local f = assert(io.open(path, "wb")); f:write(text); f:close() end
local function read(path) local f = io.open(path, "rb"); if not f then return nil end local b = f:read("*a"); f:close(); return b end
local function cleanup(dir) os.execute("rm -rf " .. quote(dir)) end

local function plan_for(exec, overrides)
	local request = {
		source = { Exec = exec, Name = "Source", Icon = "source-icon" }, source_path = "/usr/share/applications/s.desktop",
		name = "Work Browser", open_item = "", catalogue = CATALOGUE, data_home = "/home/u/.local/share",
		home = "/home/u", taken = function() return false end,
	}
	for key, value in pairs(overrides or {}) do request[key] = value end
	return Core.plan(request)
end

helpers.describe("Linux App Cloner", function()
	helpers.it("app cloner: reads the Desktop Entry group and splits Exec as the specification quotes it", function()
		local entry = Core.parse_desktop_entry("[Desktop Entry]\nName=Code\nName[fr]=Code FR\n"
			.. 'Exec="/opt/My Apps/code" --flag "a \\\\"b\\\\"" %F\nIcon=vscode\n[Desktop Action new]\nExec=other\n')
		helpers.assert_eq(entry.Name, "Code")
		helpers.assert_eq(entry.Icon, "vscode")
		local words = Core.exec_words(entry.Exec)
		helpers.assert_eq(#words, 3)
		helpers.assert_eq(words[1], "/opt/My Apps/code")
		helpers.assert_eq(words[3], 'a "b"')
		helpers.assert_nil(Core.exec_words('"unterminated'))
	end)

	helpers.it("app cloner: detects each shared family by executable name, Electron also by its marker", function()
		helpers.assert_eq(Core.family(CATALOGUE, "/usr/bin/google-chrome-stable"), "chromium")
		helpers.assert_eq(Core.family(CATALOGUE, "firefox"), "firefox")
		helpers.assert_eq(Core.family(CATALOGUE, "/usr/share/code/code"), "vscode")
		helpers.assert_eq(Core.family(CATALOGUE, "Slack"), "electron")
		helpers.assert_eq(Core.family(CATALOGUE, "/opt/obsidian/obsidian",
			function(_, marker) return marker == "resources/app.asar" end), "electron")
		helpers.assert_eq(Core.family(CATALOGUE, "gnome-calculator", function() return false end), "native")
	end)

	helpers.it("app cloner: gives a Chromium clone its own profile, window class and web-app window", function()
		local plan = plan_for("/usr/bin/chromium %U", { open_item = "https://mail.example.com/" })
		helpers.assert_eq(plan.family, "chromium")
		helpers.assert_contains(plan.launcher_text, "'--user-data-dir=/home/u/.local/share/ergopti/app_cloner/work-browser/profile'")
		helpers.assert_contains(plan.launcher_text, "'--class=ergopti-clone-work-browser'")
		helpers.assert_contains(plan.launcher_text, "'--app=https://mail.example.com/'")
		helpers.assert_contains(plan.desktop_text, "StartupWMClass=ergopti-clone-work-browser\n")
		helpers.assert_contains(plan.desktop_text, "Name=Work Browser\n")
		helpers.assert_contains(plan.desktop_text, "Icon=source-icon\n")
		helpers.assert_eq(plan.desktop_path, "/home/u/.local/share/applications/ergopti-clone-work-browser.desktop")
	end)

	helpers.it("(bap-006-duplicate-name) app cloner: suffixes a taken name on its profile and its menu name", function()
		local plan = plan_for("chromium", { taken = function(id) return id == "work-browser" end })
		helpers.assert_eq(plan.id, "work-browser-2")
		-- The menu tells the two clones apart.
		helpers.assert_contains(plan.desktop_text, "Name=Work Browser (2)\n")
	end)

	helpers.it("app cloner: runs a native clone with its own XDG folders and the source's own words", function()
		local dir = work_dir()
		local recorder = dir .. "/recorder"
		write(recorder, "#!/bin/sh\n{ printf '%s\\n' \"$XDG_CONFIG_HOME\" \"$XDG_DATA_HOME\" \"$XDG_CACHE_HOME\" "
			.. "\"$XDG_STATE_HOME\"; printf 'arg:%s\\n' \"$@\"; } > " .. quote(dir .. "/seen") .. "\n")
		os.execute("chmod 755 " .. quote(recorder))
		local plan = assert(plan_for(Core.desktop_exec_word(recorder):gsub("\\\\", "\\") .. " --x %f",
			{ data_home = dir .. "/data", home = dir, open_item = dir }))
		helpers.assert_eq(plan.family, "native")
		helpers.assert_true((Core.write(plan)))
		helpers.assert_true(read(plan.desktop_path) == plan.desktop_text)
		os.execute("/bin/sh " .. quote(plan.launcher_path) .. " dropped.txt")
		local seen = read(dir .. "/seen")
		helpers.assert_eq(seen, plan.profile .. "/config\n" .. plan.profile .. "/data\n" .. plan.profile .. "/cache\n"
			.. plan.profile .. "/state\narg:--x\narg:" .. dir .. "\narg:dropped.txt\n")
		helpers.assert_eq(require("ui.native_dialog").exit_code(os.execute("test -d " .. quote(plan.profile .. "/config"))), 0)
		cleanup(dir)
	end)

	helpers.it("app cloner: quotes a desktop Exec word through both decoding layers", function()
		helpers.assert_eq(Core.desktop_exec_word('/a b/$x"%'), '"/a b/\\\\$x\\\\"%%"')
		helpers.assert_throws(function() Core.desktop_exec_word("a\nb") end)
	end)

	helpers.it("(bap-005-open-item) app cloner: expands « ~ » and refuses a URL without « :// »", function()
		local answers = {
			file = { "/usr/share/applications/firefox.desktop" },
			entry = { "Firefox Work", "https:/typo", "localhost:3000", "~/Documents/notes.txt" },
			question = { true, true },
		}
		local messages, checked = {}, {}
		local outcome, plan = Flow.run({
			dialogs = {
				file = function() return table.remove(answers.file, 1) end,
				entry = function() return table.remove(answers.entry, 1) end,
				question = function() return table.remove(answers.question, 1) end,
				message = function(kind, _, text) messages[#messages + 1] = kind .. ":" .. text; return true end,
			},
			t = function(key, value) return value and (key .. "|" .. value) or key end,
			catalogue = CATALOGUE, home = "/home/u", data_home = "/home/u/.local/share",
			read = function() return "[Desktop Entry]\nName=Firefox\nExec=firefox %u\nIcon=firefox\n" end,
			exists = function(path) checked[#checked + 1] = path; return path == "/home/u/Documents/notes.txt" end,
			write = function() return true end,
		})
		helpers.assert_eq(outcome, "created")
		helpers.assert_eq(messages, { "warning:apps.cloner.err_url_format", "warning:apps.cloner.err_url_format",
			"info:apps.cloner.msg_created|Firefox Work" })
		helpers.assert_eq(checked[1], "/home/u/Documents/notes.txt", "the expanded path is the one checked")
		helpers.assert_contains(plan.launcher_text, "'/home/u/Documents/notes.txt' \"$@\"")
	end)

	helpers.it("app cloner: walks the dialogs and refuses a missing path before cloning", function()
		local answers = {
			file = { "/usr/share/applications/firefox.desktop" },
			entry = { "Firefox Work", "/does/not/exist", "https://example.com" },
			question = { true, true },
		}
		local messages, written = {}, nil
		local outcome, plan = Flow.run({
			dialogs = {
				file = function() return table.remove(answers.file, 1) end,
				entry = function() return table.remove(answers.entry, 1) end,
				question = function() return table.remove(answers.question, 1) end,
				message = function(kind, _, text) messages[#messages + 1] = kind .. ":" .. text; return true end,
			},
			t = function(key, value) return value and (key .. "|" .. value) or key end,
			catalogue = CATALOGUE, home = "/home/u", data_home = "/home/u/.local/share",
			read = function() return "[Desktop Entry]\nName=Firefox\nExec=firefox %u\nIcon=firefox\n" end,
			exists = function() return false end,
			write = function(p) written = p; return true end,
		})
		helpers.assert_eq(outcome, "created")
		helpers.assert_eq(messages[1], "warning:apps.cloner.err_path_missing|/does/not/exist")
		helpers.assert_eq(written, plan)
		helpers.assert_eq(plan.family, "firefox")
		helpers.assert_contains(plan.launcher_text, "'--no-remote' '--profile' '/home/u/.local/share/ergopti/app_cloner/firefox-work/profile'")
		helpers.assert_contains(plan.launcher_text, "'https://example.com' \"$@\"")
	end)
end)
