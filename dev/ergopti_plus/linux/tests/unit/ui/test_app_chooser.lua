--- tests/unit/ui/test_app_chooser.lua

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

--- A shell double that answers exec_line with `answer` and records commands.
--- @param tools table binary -> boolean
--- @param answer string|nil What the dialog prints.
--- @return table shell, table commands
local function fake_shell(tools, answer)
	local commands = {}
	local shell = {
		has_command = function(binary) return tools[binary] == true end,
		quote = function(value) return "'" .. tostring(value):gsub("'", "'\\''") .. "'" end,
		exec_line = function(command)
			commands[#commands + 1] = command
			return answer
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
