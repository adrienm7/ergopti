--- tests/meta/regressions/test_system_tool_paths.lua

--- ==============================================================================
--- MODULE: Regression — absolute macOS tool paths the driver spawns
--- DESCRIPTION:
--- hs.task launches an absolute path and refuses one that does not exist
--- ("launch path not accessible"). Two callers spawned
--- /usr/sbin/systemextensionsctl, which no macOS release ships: the tool lives in
--- /usr/bin. The owned-runtime field check and the runtime owner therefore read
--- the Karabiner driver state as unreadable on every Mac (issue #104), while the
--- onboarding probe, which spelled it right, worked. Every spelling in the driver
--- must name the real location (system-tool-paths).
--- ==============================================================================

local helpers = require("tests.helpers")

-- Tool name → the one directory macOS installs it in.
local TOOL_DIRECTORIES = {
	systemextensionsctl = "/usr/bin/",
}

helpers.describe("macOS tool paths the driver spawns (system-tool-paths)", function()
	for tool, directory in pairs(TOOL_DIRECTORIES) do
		helpers.it("spells " .. tool .. " only under " .. directory, function()
			local src = helpers.read_driver_source(tool)
			helpers.assert_true(type(src) == "string" and src ~= "", "the driver must still reference " .. tool)
			local spellings = 0
			for path in src:gmatch("(/[%w/._-]*/)" .. tool) do
				spellings = spellings + 1
				helpers.assert_eq(path, directory, tool .. " must be spawned from " .. directory)
			end
			helpers.assert_true(spellings >= 2, "the guard must see the spawned paths")
		end)
	end
end)
