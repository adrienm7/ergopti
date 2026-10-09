--- tests/unit/ui/menu/test_menu_apps_descriptions_follow_locale.lua

--- ==============================================================================
--- MODULE: Bundled App Descriptions Follow The Active Language
--- DESCRIPTION:
--- The Applications submenu writes a short description after each bundled app
--- (« App Cloner — Dupliquer une application »). The descriptions were resolved
--- once, when menu_apps.lua was loaded, and the discovered apps kept that text in
--- the session cache: after a language change every other row of the tray was
--- relabelled and these two stayed in the old language until a reload. The
--- descriptions are resolved when the submenu is built now, from their keys.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("menu_apps: descriptions are resolved when the submenu is built", function()
	helpers.it("relabels a cached app after a language change", function()
		local previous_hs = _G.hs
		local ok, err = xpcall(function()
			helpers.with_fresh_modules({ "ui.menu.menu_apps", "infra.logger", "infra.paths",
				"infra.i18n", "infra.manifest_menu", "adapters.task_lifecycle", "infra.text_utils" }, function()
				local locale = "fr"
				local texts = {
					fr = { ["menu.apps.clone_desc"] = "Dupliquer une application" },
					en = { ["menu.apps.clone_desc"] = "Duplicate an app" },
				}
				package.loaded["infra.logger"] = helpers.make_logger_stub()
				package.loaded["infra.paths"] = {}
				package.loaded["infra.manifest_menu"] = { build = function(_, _, _, _, _, providers)
					return providers.apps_installed()
				end }
				package.loaded["adapters.task_lifecycle"] = {}
				local scans = 0
				local module = helpers.load_with_stubs("ui.menu.menu_apps", {
					fs = { attributes = function() return { mode = "directory" } end },
					execute = function(command)
						if command:find("*.icns", 1, true) then return "", true, "exit", 0 end
						scans = scans + 1
						return "/virtual/App Cloner.app\n", true, "exit", 0
					end,
					application = { infoForBundlePath = function() return {} end },
					image = { imageFromPath = function() return nil end },
				})
				-- Keep this fixture's direct child view, while the parent uses the
				-- genuinely initialized shared source and completed-tree API.
				local provider_view = package.loaded["infra.manifest_menu"]
				package.loaded["infra.manifest_menu"] = nil
				local binding = require("infra.manifest_menu")
				package.loaded["infra.manifest_menu"] = provider_view
				provider_view.get_root = binding.get_root
				provider_view.group_row = binding.group_row
				-- load_with_stubs installs its own i18n table and the module keeps that
				-- reference, so the language switch is made on that very table.
				package.loaded["infra.i18n"].get = function(key)
					return texts[locale][key] or key
				end
				local ctx = { base_dir = "/virtual/apps-fixture" }

				local first = module.build(ctx).submenu
				helpers.assert_eq(first[1].label, "App Cloner — Dupliquer une application")

				locale = "en"
				local second = module.build(ctx).submenu
				helpers.assert_eq(scans, 1, "the discovered apps stay cached across builds")
				helpers.assert_eq(second[1].label, "App Cloner — Duplicate an app",
					"the description must follow the language active when the submenu is built")
			end)
		end, debug.traceback)
		_G.hs = previous_hs
		if not ok then error(err, 0) end
	end)
end)
