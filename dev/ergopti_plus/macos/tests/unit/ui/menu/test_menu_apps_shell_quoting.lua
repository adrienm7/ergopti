--- tests/unit/ui/menu/test_menu_apps_shell_quoting.lua

--- ==============================================================================
--- MODULE: Regression — bundled-app discovery uses POSIX shell quoting
--- DESCRIPTION:
--- The app and icon scans pass bundle paths through /bin/sh. Lua's `%q` only
--- creates a Lua literal, so `$`, backticks and `!` remain expandable inside the
--- resulting double quotes. This test drives the real discovery path and pins the
--- exact canonical POSIX quoting for both shell commands.
--- ==============================================================================

local helpers = require("tests.helpers")

local function copy_with(base, overrides)
	local copy = {}
	for key, value in pairs(base) do copy[key] = value end
	for key, value in pairs(overrides) do copy[key] = value end
	return copy
end

helpers.describe("menu_apps: discovery quotes paths for POSIX sh", function()
	helpers.it("quotes both the app directory and icon resource directory", function()
		local base_hs = require("tests.stubs.hs")
		local base_dir = "/tmp/Ergopti $HOME `printf injected` O'Brien"
		local apps_dir = base_dir .. "/apps"
		local app_path = apps_dir .. "/Fixture.app"
		local commands = {}

		local fs = copy_with(base_hs.fs, {
			attributes = function(path)
				if path == apps_dir then return { mode = "directory" } end
				return base_hs.fs.attributes(path)
			end,
		})
		local application = copy_with(base_hs.application, {
			infoForBundlePath = function(path)
				helpers.assert_eq(path, app_path,
					"discovery must inspect the exact app returned by the shell scan")
				return nil
			end,
		})
		local image = copy_with(base_hs.image, {
			imageFromPath = function() return nil end,
		})
		local execute = function(command)
			commands[#commands + 1] = command
			if command:find("-name '*.app'", 1, true) then
				return app_path .. "\n", true, "exit", 0
			end
			return "", true, "exit", 0
		end

		local apps = helpers.load_with_stubs("ui.menu.menu_apps", {
			execute = execute,
			fs = fs,
			application = application,
			image = image,
		})
		apps.prime({ base_dir = base_dir })

		local text_utils = require("infra.text_utils")
		local expected_apps = "find " .. text_utils.shell_quote(apps_dir)
			.. " -maxdepth 1 -name '*.app' 2>/dev/null | sort"
		local expected_icons = "find " .. text_utils.shell_quote(
			app_path .. "/Contents/Resources")
			.. " -maxdepth 1 -name '*.icns' 2>/dev/null | head -1"
		helpers.assert_eq(#commands, 2,
			"one app scan and one icon fallback scan must reach the shell boundary")
		helpers.assert_eq(commands[1], expected_apps,
			"the app directory must be one POSIX-quoted argv word")
		helpers.assert_eq(commands[2], expected_icons,
			"the icon resource directory must be one POSIX-quoted argv word")
	end)
end)
