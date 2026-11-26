--- tests/unit/gestures/engine/actions/test_take_note.lua

--- ==============================================================================
--- MODULE: Daily Note Action Regression (Linux)
--- DESCRIPTION:
--- Exercises the actual catalogue handler against private note files. Repeated
--- use preserves the note, and missing desktop associations or refused writes
--- never launch an editor or claim success.
--- ==============================================================================

local helpers = require("tests.helpers")
local Shell = require("core.process.adapters.shell_runner")
local Paths = require("settings.engine.paths")
local Files = require("core.fs.adapters.file_system")

--- Isolates only desktop association, notifications and application launch.
--- @param body function Receives note path, recorded launches and notices.
--- @param handler string|nil Registered desktop file, absent for no handler.
local function fixture(body, handler)
	local folder = os.tmpname()
	os.remove(folder)
	assert(Shell.run("mkdir -p -- " .. Shell.quote(folder)))
	local saved_data, saved_notifier = Paths.data, package.loaded["platform.focus.application_notifier"]
	local launches, notices = {}, {}
	Paths.data = function(rel) helpers.assert_eq(rel, "notes"); return folder end
	package.loaded["platform.focus.application_notifier"] = {
		send = function(text) notices[#notices + 1] = text; return true end,
	}
	Shell._set_runner(function(command)
		if command == "xdg-mime query default text/plain" then
			return { ok = true, output = handler or "" }
		end
		if command:match("^mkdir ") then return true end
		error("Unexpected shell command: " .. command)
	end)
	local path = folder .. "/Notes_" .. os.date("%d_%m_%Y") .. ".txt"
	local function launch(command) launches[#launches + 1] = command; return true end
	local ok, err = pcall(body, path, launches, notices, launch)
	Shell._reset_runner()
	Paths.data, package.loaded["platform.focus.application_notifier"] = saved_data, saved_notifier
	os.remove(path)
	assert(Shell.run("rmdir -- " .. Shell.quote(folder)))
	if not ok then error(err, 0) end
end

helpers.describe("Linux daily notes (linux-take-note)", function()
	helpers.it("linux-take-note: catalogue handler creates today's note and never truncates it", function()
		fixture(function(path, launches, _, launch)
			local handler = require("gestures.engine.system_actions").HANDLERS.take_note
			helpers.assert_true(type(handler) == "function")
			helpers.assert_true(require("_generated.action_catalogue").actions.take_note ~= nil)
			helpers.assert_true(handler({ run_background = launch }))
			helpers.assert_eq(Files.read(path), "")
			helpers.assert_true(Files.append(path, "Private note\n"))
			helpers.assert_true(handler({ run_background = launch }))
			helpers.assert_eq(Files.read(path), "Private note\n")
			local editor = "gtk-launch -- " .. Shell.quote("org.gnome.TextEditor.desktop") .. " " .. Shell.quote(path)
			helpers.assert_eq(launches, { editor, editor })
		end, "org.gnome.TextEditor.desktop\n")
	end)

	-- xdg-open and gio choose by content, and the day's first note is empty:
	-- inode/x-empty went to a browser on generic desktops, application/x-zerosize
	-- to nothing under gio. The registered editor is launched by its id instead.
	helpers.it("linux-take-note: an empty note opens in the registered editor, never a content-sniffing opener", function()
		fixture(function(path, launches, _, launch)
			helpers.assert_true(require("modules.take_note").open(launch))
			helpers.assert_eq(Files.read(path), "")
			helpers.assert_eq(#launches, 1)
			helpers.assert_eq(launches[1]:match("^xdg%-open ") or launches[1]:match("^gio open "), nil)
			helpers.assert_eq(launches[1], "gtk-launch -- " .. Shell.quote("mousepad.desktop") .. " " .. Shell.quote(path))
		end, "  mousepad.desktop  \n")
	end)

	helpers.it("linux-take-note: absent text handler reports the reason without creating a file", function()
		fixture(function(path, launches, notices, launch)
			helpers.assert_eq(require("modules.take_note").open(launch), false)
			helpers.assert_eq(#launches, 0)
			helpers.assert_eq(#notices, 1)
			helpers.assert_eq(Files.exists(path), false)
		end)
	end)

	-- SNU-09: the refused write and the failed launch told the user but left no
	-- log line, where Windows logs every refused note (TakeNote ReportError).
	helpers.it("linux-take-note: every refused note is logged (snu-09)", function()
		fixture(function(_, _, notices)
			local saved_shim, saved_module = package.loaded["core.logger.engine.shim"], package.loaded["modules.take_note"]
			local errors = {}
			local logger = helpers.make_logger_stub()
			logger.error = function(_, message) errors[#errors + 1] = message end
			package.loaded["core.logger.engine.shim"] = logger
			package.loaded["modules.take_note"] = nil
			local ok, failure = pcall(function()
				local TakeNote = require("modules.take_note")
				local saved_append = Files.append
				Files.append = function() return false end
				local refused = TakeNote.open(function() return true end)
				Files.append = saved_append
				helpers.assert_eq(refused, false)
				helpers.assert_eq(TakeNote.open(function() return false end), false)
				helpers.assert_eq(#notices, 2)
				helpers.assert_eq(#errors, 2, "each refused note leaves its log line")
				helpers.assert_true(errors[1]:find("could not be created", 1, true) ~= nil, errors[1])
				helpers.assert_true(errors[2]:find("could not be launched", 1, true) ~= nil, errors[2])
			end)
			package.loaded["core.logger.engine.shim"], package.loaded["modules.take_note"] = saved_shim, saved_module
			if not ok then error(failure, 0) end
		end, "editor.desktop")
	end)

	-- SNU-08: the folder and dated settings this driver ignores carried the
	-- shortcut chords' reason, which says nothing of where the Linux note goes.
	helpers.it("linux-take-note: the Windows-only note settings say where the Linux note goes (snu-08)", function()
		local found = 0
		for _, entry in ipairs(require("settings.engine.features.manifest_data").features) do
			if type(entry) == "table" and entry.section == "shortcuts.take_note" then
				helpers.assert_eq(entry.reason_key, "platform_reason.take_note_settings_are_windows", entry.path)
				found = found + 1
			end
		end
		helpers.assert_eq(found, 2, "dated_notes and destination_folder")
	end)

	helpers.it("linux-take-note: refused write does not launch an editor", function()
		fixture(function(path, launches, notices, launch)
			local saved = Files.append
			Files.append = function() return false end
			local ok, result = pcall(require("modules.take_note").open, launch)
			Files.append = saved
			helpers.assert_true(ok)
			helpers.assert_eq(result, false)
			helpers.assert_eq(#launches, 0)
			helpers.assert_eq(#notices, 1)
			helpers.assert_eq(Files.exists(path), false)
		end, "editor.desktop")
	end)
end)
