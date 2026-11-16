--- tests/unit/menu/ui/gestures_and_apps/test_apps_shell_quoting.lua

--- ==============================================================================
--- MODULE: Bundled App Native Discovery
--- DESCRIPTION:
--- Native directory names reach metadata and icon lookups verbatim without
--- executing a shell, even when the paths contain shell metacharacters.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("menu_apps: native discovery preserves pathnames", function()
	helpers.it("enumerates app and icon directories without shell execution", function()
		helpers.with_stub_scope({ "apps.ui.menu.apps", "core.fs.engine.dir" }, function()
			local base = "/tmp/Ergopti $HOME `injected` O'Brien"
			local app = base .. "/apps/Fixture.app"
			local directories, metadata = {}, {}
			package.loaded["core.fs.engine.dir"] = { try_entries_quiet = function(dir)
				directories[#directories + 1] = dir
				if dir == base .. "/apps" then return { "Fixture.app" }, true end
				return {}, true
			end }
			local apps = helpers.load_with_stubs("apps.ui.menu.apps", {
				fs = { attributes = function() return { mode = "directory" } end },
				execute = function() error("discovery must not start a shell") end,
				application = { infoForBundlePath = function(path) metadata[#metadata + 1] = path; return nil end },
				image = { imageFromPath = function() return nil end },
			})
			apps.prime({ base_dir = base })
			helpers.assert_eq(metadata, { app })
			helpers.assert_eq(directories, { base .. "/apps", app .. "/Contents/Resources" })
		end)
	end)
end)
