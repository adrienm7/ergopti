--- tests/unit/modules/gestures/actions/test_take_note.lua

--- ==============================================================================
--- MODULE: Daily Note Action Regression (Linux)
--- DESCRIPTION:
--- Exercises the actual catalogue handler against private note files. Repeated
--- use preserves the note, and missing desktop associations or refused writes
--- never launch an editor or claim success.
--- ==============================================================================

local helpers = require("tests.helpers")
local Shell = require("adapters.shell_runner")
local Paths = require("infra.config_paths")
local Files = require("adapters.file_system")

--- Isolates only desktop association, notifications and application launch.
--- @param body function Receives note path, recorded launches and notices.
--- @param handler string|nil Registered desktop file, absent for no handler.
local function fixture(body, handler)
	local folder = os.tmpname()
	os.remove(folder)
	assert(Shell.run("mkdir -p -- " .. Shell.quote(folder)))
	local saved_data, saved_notifier = Paths.data, package.loaded["adapters.application_notifier"]
	local launches, notices = {}, {}
	Paths.data = function(rel) helpers.assert_eq(rel, "notes"); return folder end
	package.loaded["adapters.application_notifier"] = {
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
	Paths.data, package.loaded["adapters.application_notifier"] = saved_data, saved_notifier
	os.remove(path)
	assert(Shell.run("rmdir -- " .. Shell.quote(folder)))
	if not ok then error(err, 0) end
end

helpers.describe("Linux daily notes (linux-take-note)", function()
	helpers.it("linux-take-note: catalogue handler creates today's note and never truncates it", function()
		fixture(function(path, launches, _, launch)
			local handler = require("modules.gestures.system_actions").HANDLERS.take_note
			helpers.assert_true(type(handler) == "function")
			helpers.assert_true(require("_generated.action_catalogue").actions.take_note ~= nil)
			helpers.assert_true(handler({ run_background = launch }))
			helpers.assert_eq(Files.read(path), "")
			helpers.assert_true(Files.append(path, "Private note\n"))
			helpers.assert_true(handler({ run_background = launch }))
			helpers.assert_eq(Files.read(path), "Private note\n")
			helpers.assert_eq(launches, { "xdg-open " .. Shell.quote(path), "xdg-open " .. Shell.quote(path) })
		end, "org.gnome.TextEditor.desktop\n")
	end)

	helpers.it("linux-take-note: absent text handler reports the reason without creating a file", function()
		fixture(function(path, launches, notices, launch)
			helpers.assert_eq(require("modules.take_note").open(launch), false)
			helpers.assert_eq(#launches, 0)
			helpers.assert_eq(#notices, 1)
			helpers.assert_eq(Files.exists(path), false)
		end)
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
