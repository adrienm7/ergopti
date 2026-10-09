--- tests/unit/ui/menu/test_menu_watcher_builtin_path_boundaries.lua

--- ==============================================================================
--- MODULE: Menu Watcher Built-In Path Boundaries
--- DESCRIPTION:
--- Distinguishes excluded path components from unrelated names containing them.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.menu_config_watcher_fixture")

helpers.describe("Menu watcher built-in exclusions (menu-built-in-path-boundary)", function()
	for _, case in ipairs({
		{ "/fake/project", "/modules/source.lua", true },
		{ "/fake/catalogs/project", "/modules/source.lua", true },
		{ "/fake/project", "/catalogs/source.lua", true },
		{ "/fake/project", "/keypaths.toml", true },
		{ "/fake/project", "/logs/source.lua", false },
		{ "/fake/project", "/nested/logs/source.lua", false },
		{ "/fake/project", "/paths.toml", false },
		{ "/fake/project", "/nested/paths.toml", false },
	}) do
		local path = case[1] .. case[2]
		helpers.it("classifies " .. path, function()
			Fixture.with_watcher(function(w)
				w.fire({ path })
				helpers.assert_eq(type(w.scheduled()) == "function", case[3],
					"exclusions must match a complete path component")
				if case[3] then
					w.set_clock(1001)
					w.poll()
					helpers.assert_eq(w.reloads(), 1, "admitted source changes must actually reload")
					helpers.assert_nil(w.scheduled(), "accepted changes must settle")
				else
					helpers.assert_eq(w.reloads(), 0, "excluded runtime writes must stay inert")
				end
			end, { base_dir = case[1] })
		end)
	end
end)
