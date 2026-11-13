-- static/ergopti_plus/macos/tests/unit/ui/menu/wrap/test_wrap_unused_key_projection.lua

--- Actual cleanup readers preserve admitted Wrap records and classify unowned source.
local helpers = require("tests.helpers")
local function scan(source)
	return helpers.with_stub_scope({ "core.fs.adapters.storage", "core.fs.adapters.file_system", "settings.engine.overrides",
		"settings.engine.preferences.preferences", "ui.onboarding", "settings.ui.menu.unused_keys_cleanup", "ui.menu.builder",
		"menu.engine.wrap_preferences", "core.lifecycle.engine.compat.utf8" }, function()
		local stored = {}
		package.loaded["core.fs.adapters.storage"] = { set = function(key, value) stored[key] = value; return true end,
			get = function(key) return stored[key] end, delete = function(key) stored[key] = nil; return true end,
			keys = function() return {} end }
		helpers.load_with_stubs("settings.engine.preferences.preferences")
		helpers.load_with_stubs("settings.engine.overrides")
		helpers.load_with_stubs("ui.onboarding")
		local cleanup = helpers.load_with_stubs("settings.ui.menu.unused_keys_cleanup")
		local result = require("settings.engine.migration.unused_keys").find_in_source(source, cleanup.collect)
		helpers.assert_eq(result.status, "ok")
		local offered = {}
		for _, key in ipairs(result.keys) do offered[table.concat(key.path, ".")] = true end
		return offered
	end)
end
helpers.describe("actual cleanup Wrap projection ownership", function()
	helpers.it("marks each admitted Boolean and the valid custom array while offering only unowned fields", function()
		local source = '[shortcuts]\nwrap_symbols={states={"("=false,"."=true,old="obsolete"},custom=[{left="🙂",right="é",future=[]}],future=[]}\n'
		helpers.assert_eq(scan(source), { ["shortcuts.wrap_symbols.states.old"] = true, ["shortcuts.wrap_symbols.future"] = true })
	end)
	helpers.it("offers actual invalid empty kinds without consuming them as model-equivalent values", function()
		helpers.assert_eq(scan('[shortcuts.wrap_symbols]\nstates=[]\ncustom={}\n'),
			{ ["shortcuts.wrap_symbols.states"] = true, ["shortcuts.wrap_symbols.custom"] = true })
	end)
	helpers.it("retains source-bound admitted empty map and ordered array without cleanup offers", function()
		helpers.assert_eq(scan('[shortcuts.wrap_symbols]\nstates={}\ncustom=[]\n'), {})
	end)
end)
