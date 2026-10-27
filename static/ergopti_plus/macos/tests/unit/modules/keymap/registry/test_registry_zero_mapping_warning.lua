--- tests/unit/modules/keymap/registry/test_registry_zero_mapping_warning.lua
--- Regression coverage for the zero-mapping warning of a TOML group: a file
--- whose every section the user disabled registers nothing on purpose, so the
--- warning that points at a path problem must not fire for it (field session
--- 2026-10-27 logged it on every boot for a pack with its only section off).

local helpers = require("tests.helpers")

local OWNED_MODULES = {
	"modules.keymap.registry",
	"modules.keymap.registry_groups",
	"modules.keymap.registry_index",
	"modules.keymap.terminators",
	"modules.keymap.state",
	"modules.keymap.utils",
	"infra.toml.reader",
	"infra.timings",
	"modules.hotstrings.hotstrings_config",
}

local function one_section(trigger)
	return {
		sections_order = { "greetings" },
		sections = { greetings = { [trigger] = { output = trigger:upper() } } },
		meta = {},
	}
end

local function with_registry(data_by_path, callback)
	return helpers.with_fresh_modules(OWNED_MODULES, function()
		package.loaded["infra.toml.reader"] = {
			parse = function(path) return data_by_path[path], true end,
		}
		package.loaded["modules.hotstrings.hotstrings_config"] = {
			get_user_override = function() return nil end,
		}
		local State = helpers.load_with_stubs("modules.keymap.state")
		package.loaded["infra.timings"] = { sec = function() return 0.01 end }
		local Registry = require("modules.keymap.registry")
		local state = State.new({ trigger_char = "★", expansion_delay = 0.4 }, {})
		helpers.assert_eq(Registry.init(state), true)

		local Logger = require("infra.logger")
		local warnings, infos = {}, {}
		local original_warn, original_info = Logger.warn, Logger.info
		Logger.warn = function(_, fmt, ...) table.insert(warnings, string.format(fmt, ...)) end
		Logger.info = function(_, fmt, ...) table.insert(infos, string.format(fmt, ...)) end
		local ok, err = pcall(callback, Registry, warnings, infos)
		Logger.warn, Logger.info = original_warn, original_info
		if not ok then error(err, 0) end
	end)
end

local function count_matching(lines, needle)
	local count = 0
	for _, line in ipairs(lines) do
		if line:find(needle, 1, true) then count = count + 1 end
	end
	return count
end

helpers.describe("Registry zero-mapping warning", function()
	helpers.it("stays silent for a file whose every section is disabled", function()
		with_registry({ ["/virtual/off.toml"] = one_section("hiya") }, function(Registry, warnings, infos)
			_G.hs.settings.set("ergopti.hotstrings_section_pack_off_greetings", false)
			helpers.assert_eq(Registry.load_toml("pack_off", "/virtual/off.toml"), true)
			helpers.assert_eq(count_matching(warnings, "ZERO mappings"), 0,
				"a file whose sections are all disabled is not a path problem")
			helpers.assert_eq(count_matching(infos, "section(s) are disabled"), 1,
				"the empty registration must still be explained once")
			_G.hs.settings.set("ergopti.hotstrings_section_pack_off_greetings", nil)
		end)
	end)

	helpers.it("still warns for a file with no section at all", function()
		with_registry({ ["/virtual/empty.toml"] = { sections_order = {}, sections = {}, meta = {} } },
			function(Registry, warnings)
				helpers.assert_eq(Registry.load_toml("pack_empty", "/virtual/empty.toml"), true)
				helpers.assert_eq(count_matching(warnings, "ZERO mappings"), 1,
					"an empty or unreadable file is the case the warning exists for")
			end)
	end)
end)
