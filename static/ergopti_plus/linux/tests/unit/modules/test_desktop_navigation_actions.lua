--- tests/unit/modules/test_desktop_navigation_actions.lua

--- ==============================================================================
--- MODULE: Downloads, file manager and system settings actions (Linux)
--- DESCRIPTION:
--- The three navigation actions the macOS shortcut layer and the Windows
--- driver offer, run through the real dispatcher with a recording shell: the
--- XDG Downloads directory, the home directory in the default file manager, and
--- the first settings application the desktop has.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs `body` with os.execute recording instead of running.
--- @param body function Receives the recorded command table.
--- @param answer function|nil Result of each command, true by default.
local function with_recorded_shell(body, answer)
	local commands = {}
	local real = os.execute
	os.execute = function(cmd)
		commands[#commands + 1] = tostring(cmd)
		if answer then return answer(tostring(cmd)) end
		return true
	end
	local ok, err = pcall(body, commands)
	os.execute = real
	if not ok then error(err, 0) end
end

helpers.describe("Linux desktop navigation actions", function()
	local Gestures = helpers.load_module("modules.gestures.manager")

	helpers.it("open_downloads opens the XDG Downloads directory", function()
		with_recorded_shell(function(commands)
			Gestures.execute_action("open_downloads", "tap_3")
			local text = table.concat(commands, "\n")
			helpers.assert_true(text:find("xdg-user-dir DOWNLOAD", 1, true) ~= nil,
				"the directory must come from the user's XDG configuration, not a guessed name")
			helpers.assert_true(text:find("xdg-open", 1, true) ~= nil, "and be opened")
		end)
	end)

	helpers.it("open_file_manager opens the home directory", function()
		with_recorded_shell(function(commands)
			Gestures.execute_action("open_file_manager", "tap_3")
			helpers.assert_true(table.concat(commands, "\n"):find('xdg-open "$HOME"', 1, true) ~= nil)
		end)
	end)

	helpers.it("open_system_settings launches the first settings application present", function()
		with_recorded_shell(function(commands)
			Gestures.execute_action("open_system_settings", "tap_3")
			local launched = nil
			for _, command in ipairs(commands) do
				if not command:find("command -v", 1, true) then launched = command end
			end
			helpers.assert_true(launched ~= nil and launched:find("systemsettings", 1, true) ~= nil,
				"the first installed candidate must be launched, got " .. tostring(launched))
		end, function(command)
			-- Only KDE's settings application is installed on this desktop.
			if command:find("command -v", 1, true) then
				return command:find("systemsettings", 1, true) ~= nil
			end
			return true
		end)
	end)
end)
