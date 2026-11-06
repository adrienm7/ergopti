--- tests/unit/modules/keymap/registry/test_section_projection_read_only.lua
--- A readable source must not activate a stale cache when backup creation fails.
local helpers = require("tests.helpers")
local Fixture = require("tests.support.modules.keymap.registry.registry_mutation_transactions_fixture")
local OutputFixture = require("tests.support.toml_output_fixture")

helpers.describe("section projection backup admission", function()
	helpers.it("refuses a read-only backup without changing the cache or the live group", function()
		local _, registry = Fixture.fresh_registry()
		registry.register_lua_group("rolls", "Rolls", { { name = "hc" } })
		local storage = require("adapters.storage")
		local key = registry.section_setting_key("rolls", "hc")
		helpers.assert_true(storage.set(key, false))
		local before_group = registry.is_group_enabled("rolls")
		local Preferences = helpers.load_with_stubs("infra.preferences")
		local files = require("adapters.file_system")
		local original_write, refuse, attempts = files.write_if_unchanged, true, 0
		files.write_if_unchanged = function(path, ...)
			if path:find(".section-settings-", 1, true) then
				attempts = attempts + 1
				if refuse then return false, "read-only directory" end
			end
			return original_write(path, ...)
		end
		local ok, err = xpcall(function()
			OutputFixture.with_output(function(path)
				local source = "[hotstrings]\nmodules = { rolls = { hc = true } }\n"
				local file = assert(io.open(path, "wb")); assert(file:write(source)); file:close()
				local saved, status = Preferences.load(path)
				helpers.assert_eq(status, "ok", "the canonical TOML remains readable")
				helpers.assert_eq(registry.apply_hotstring_preferences(saved), false)
				helpers.assert_true(attempts > 0, "the owned backup was attempted")
				helpers.assert_eq(registry.is_section_enabled("rolls", "hc"), false)
				helpers.assert_eq(select(2, storage.read_exact(key)), false)
				helpers.assert_eq(registry.is_group_enabled("rolls"), before_group)
				refuse = false
				helpers.assert_true(registry.apply_hotstring_preferences(saved))
				helpers.assert_eq(registry.is_section_enabled("rolls", "hc"), true)
			end)
		end, debug.traceback)
		files.write_if_unchanged = original_write
		if not ok then error(err, 0) end
	end)
	helpers.it("the actual boot boundary refuses to start when a disabled source cannot replace an enabled cache", function()
		local _, registry = Fixture.fresh_registry()
		registry.register_lua_group("rolls", "Rolls", { { name = "hc" } })
		local storage = require("adapters.storage")
		local key = registry.section_setting_key("rolls", "hc")
		helpers.assert_true(storage.set(key, true))
		local Preferences = helpers.load_with_stubs("infra.preferences")
		local files = require("adapters.file_system")
		local original_write, backups = files.write_if_unchanged, 0
		files.write_if_unchanged = function(path, ...)
			if path:find(".section-settings-", 1, true) then
				backups = backups + 1
				return false, "read-only directory"
			end
			return original_write(path, ...)
		end
		local ok, err = xpcall(function()
			OutputFixture.with_output(function(path)
				local file = assert(io.open(path, "wb"))
				assert(file:write("[hotstrings]\nmodules = { rolls = { hc = false } }\n")); file:close()
				local saved, status = Preferences.load(path)
				helpers.assert_eq(status, "ok", "the canonical TOML remains readable")
				local source = assert(helpers.read_driver_unit("local function has_common_hotstring_groups"))
				local boundary = assert(source:match('(if keymap.apply_hotstring_preferences%(boot_saved_prefs%).-if keymap_started ~= true then.-\nend)'))
				local starts = 0
				local run = assert(load(boundary, "hotstring boot boundary", "t", setmetatable({
					boot_saved_prefs = saved,
					keymap = { apply_hotstring_preferences = registry.apply_hotstring_preferences,
						start = function() starts = starts + 1; return true end },
				}, { __index = _G })))
				local started, failure = pcall(run)
				helpers.assert_eq(started, false)
				helpers.assert_contains(failure, "canonical hotstring preferences did not commit")
				helpers.assert_true(backups > 0)
				helpers.assert_eq(starts, 0, "the real caller must not start the input engine")
				helpers.assert_eq(select(2, storage.read_exact(key)), true,
					"the previous cache remains intact while boot is refused")
			end)
		end, debug.traceback)
		files.write_if_unchanged = original_write
		if not ok then error(err, 0) end
	end)

	helpers.it("does not create a backup for an unchanged cache projection", function()
		local _, registry = Fixture.fresh_registry()
		registry.register_lua_group("rolls", "Rolls", { { name = "hc" } })
		local storage = require("adapters.storage")
		helpers.assert_true(storage.set(registry.section_setting_key("rolls", "hc"), true))
		local Preferences = helpers.load_with_stubs("infra.preferences")
		local files = require("adapters.file_system")
		local original_write, backups = files.write_if_unchanged, 0
		files.write_if_unchanged = function(path, ...)
			if path:find(".section-settings-", 1, true) then backups = backups + 1 end
			return original_write(path, ...)
		end
		local ok, err = xpcall(function()
			OutputFixture.with_output(function(path)
				local file = assert(io.open(path, "wb"))
				assert(file:write("[hotstrings]\nmodules = { rolls = { hc = true } }\n")); file:close()
				local saved, status = Preferences.load(path)
				helpers.assert_eq(status, "ok")
				helpers.assert_true(registry.apply_hotstring_preferences(saved))
				helpers.assert_eq(backups, 0)
			end)
		end, debug.traceback)
		files.write_if_unchanged = original_write
		if not ok then error(err, 0) end
	end)

	helpers.it("fences same-value writers while an unchanged section is published", function()
		local _, registry = Fixture.fresh_registry()
		registry.register_lua_group("rolls", "Rolls", { { name = "hc" } })
		local storage = require("adapters.storage")
		local key = registry.section_setting_key("rolls", "hc")
		helpers.assert_true(storage.set(key, true))
		local concurrent
		local result = registry.set_groups_sections_enabled({ { name = "rolls", sections = { "hc" } } }, true,
			function() concurrent = storage.set(key, true); return true end)
		helpers.assert_true(result)
		helpers.assert_eq(concurrent, false, "the acquired alias excludes even same-value writers")
		helpers.assert_true(storage.set(key, true), "the read-only owner released its gate")
	end)

end)
