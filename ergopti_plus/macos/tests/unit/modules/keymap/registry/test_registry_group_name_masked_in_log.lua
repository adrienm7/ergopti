--- tests/unit/modules/keymap/registry/test_registry_group_name_masked_in_log.lua

--- ==============================================================================
--- MODULE: Registry Group Names Stay Out of the Log
--- DESCRIPTION:
--- A hotstring category is named by its file, and a personal pack's name is the
--- user's. Loading, disabling, enabling and reloading a group must never print
--- that name in clear text (item 139): the registry logs the shared placeholder
--- instead. Fails if the name appears in any captured log line.
--- ==============================================================================

local helpers = require("tests.helpers")

local SECRET = "zq_secret_pack_name"
local PATH = "/user/packs/" .. SECRET .. ".toml"

local OWNED_MODULES = {
	"modules.keymap.registry", "modules.keymap.registry_groups", "modules.keymap.registry_index",
	"modules.keymap.terminators", "modules.keymap.state", "modules.keymap.utils",
	"infra.toml.reader", "infra.timings", "modules.hotstrings.hotstrings_config",
}

helpers.describe("Registry: a group name is masked in the log", function()
	helpers.it("(group-name-log-mask) never prints the name of a loaded, disabled, enabled or reloaded group", function()
		local lines = {}
		local Logger = helpers.load_with_stubs("infra.logger")
		local previous_level = Logger.current_level
		Logger.set_level("DEBUG")
		Logger.set_sink(function(line) lines[#lines + 1] = tostring(line) end)
		local ok, failure = pcall(function()
			helpers.with_fresh_modules(OWNED_MODULES, function()
				package.loaded["infra.logger"] = Logger
				package.loaded["infra.toml.reader"] = {
					parse = function(path)
						if path ~= PATH then return nil, false end
						return { sections_order = { "main" }, sections = { main = { zqrule = { output = "X" } } },
							meta = {} }, true
					end,
				}
				package.loaded["modules.hotstrings.hotstrings_config"] = { get_user_override = function() return nil end }
				local State = helpers.load_with_stubs("modules.keymap.state")
				package.loaded["infra.timings"] = { sec = function() return 0.01 end }
				local Registry = require("modules.keymap.registry")
				helpers.assert_eq(Registry.init(State.new({ trigger_char = "★", expansion_delay = 0.4 }, { [SECRET] = 0.4 })), true)
				helpers.assert_eq(Registry.load_toml(SECRET, PATH), true)
				helpers.assert_eq(Registry.disable_group(SECRET), true)
				helpers.assert_eq(Registry.enable_group(SECRET), true)
				helpers.assert_eq(Registry.reload_toml(SECRET, PATH), true)
			end)
		end)
		Logger.set_sink(nil)
		Logger.set_level(previous_level)
		helpers.assert_true(ok, tostring(failure))
		helpers.assert_true(#lines > 0, "the fixture must have produced log lines")
		local placeholder = require("diagnostics.private_label").PLACEHOLDER
		local masked = false
		for _, line in ipairs(lines) do
			helpers.assert_true(line:find(SECRET, 1, true) == nil, "the group name reached the log in clear text: " .. line)
			if line:find(placeholder, 1, true) then masked = true end
		end
		helpers.assert_true(masked, "the masked placeholder must appear in the log")
	end)

	helpers.it("(group-name-log-mask) pins the placeholder to the redaction policy", function()
		local file = assert(io.open(helpers.shared("modules/diagnostics/redaction.json"), "rb"))
		local policy = require("json").decode(file:read("*a"))
		file:close()
		require("test.private_label_contract")(helpers, policy)
	end)
end)
