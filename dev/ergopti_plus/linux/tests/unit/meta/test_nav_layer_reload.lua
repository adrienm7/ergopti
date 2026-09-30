--- tests/unit/meta/test_nav_layer_reload.lua

--- ==============================================================================
--- MODULE: Native Navigation Reload Transactions
--- DESCRIPTION:
--- A rejected layer must preserve both the installed engine and its admission
--- state, even when the tap-hold file changed in the same reload.
--- ==============================================================================

local helpers = require("tests.helpers")

local function write(path, text)
	local file = assert(io.open(path, "wb"))
	file:write(text)
	file:close()
end

helpers.describe("native navigation reload transactions", function()
	helpers.it("retains the installed engine and admission after a malformed layer", function()
		local dir = os.tmpname()
		os.remove(dir)
		local made = os.execute('mkdir "' .. dir .. '"')
		assert(made == true or made == 0)
		local Manager = helpers.load_module("platform.remap.tap_hold_manager")
		local hook = { key_text = function() return nil end,
			held_modifiers = function() return {} end,
			held_text_modifier_codes = function() return {} end,
			held_shortcut_modifier_codes = function() return {} end }
		function hook.set_remapper(engine) hook.engine = engine end
		local ok, err = pcall(function()
			write(dir .. "/tap_hold.toml", '[tap_hold]\nenabled = true\n')
			Manager.init({ keyboard_hook = hook, execute_action = function() end,
				action_names = function() return {} end, on_text_injected = function() end,
				defaults_path = helpers.driver_root() .. "/../_shared/tap_hold/defaults.toml",
				user_path = dir .. "/tap_hold.toml" })
			local original = assert(hook.engine)
			write(dir .. "/tap_hold.toml", '[tap_hold]\nenabled = false\n')
			write(dir .. "/layers.toml", '[broken')
			helpers.assert_eq(Manager.reload(), false, "invalid layer refuses the entire reload")
			helpers.assert_true(hook.engine == original, "no partial engine publication")
			Manager.set_enabled(true)
			helpers.assert_true(hook.engine == original, "the previous file admission remains in force")
		end)
		Manager._reset_for_test()
		os.remove(dir .. "/layers.toml")
		os.remove(dir .. "/tap_hold.toml")
		os.execute('rmdir "' .. dir .. '"')
		if not ok then error(err, 0) end
	end)
end)

helpers.describe("outdated layers.toml entries (config-outdated-layers)", function()
	helpers.it("starts with the valid bindings and warns once per outdated entry, naming the file", function()
		local dir = os.tmpname()
		os.remove(dir)
		local made = os.execute('mkdir "' .. dir .. '"')
		assert(made == true or made == 0)
		local warnings = {}
		local recorder = helpers.make_logger_stub()
		recorder.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
		local previous_logger = package.loaded["logger.shim"]
		package.loaded["logger.shim"] = recorder
		require("config_outdated").reset_for_tests()
		local ok, err = pcall(function()
			write(dir .. "/layers.toml", table.concat({
				"[_meta]", "schema_version = 1", "retired_field = 1",
				"[layers.nav.all]", '"KeyD" = "retired_nav_action"', '"KeyZZ" = "none"', '"KeyJ" = "keystroke:Home"',
				"[layers.symbols.all]", '"KeyK" = "none"', "",
			}, "\n"))
			local NavLayer = helpers.load_module("platform.remap.nav_layer")
			local shared_root = helpers.driver_root() .. "/../_shared"
			local layer = NavLayer.load({ shared_root = shared_root, config_dir = dir })
			local ctx = require("keymap.layers").load_context({ shared_root = shared_root,
				json_decode = require("json").decode, toml_decode = require("toml_codec").decode,
				read_file = require("keymap.layer_editor").read_shipped })
			local key_j, home = ctx.registry.keys.KeyJ.evdev, ctx.registry.keys.Home.evdev
			helpers.assert_eq(layer[key_j], { chords = { { mods = {}, keys = { home } } } },
				"the valid binding of the same file still loads")
			local bound = 0
			for _ in pairs(layer) do bound = bound + 1 end
			helpers.assert_eq(bound, 1, "no outdated entry reaches the engine")
			local text = table.concat(warnings, "\n")
			for _, entry in ipairs({ "layers.nav.all.KeyD", "layers.nav.all.KeyZZ", "_meta.retired_field", "layers.symbols" }) do
				helpers.assert_true(text:find("'" .. entry .. "' in '" .. dir .. "/layers.toml'", 1, true) ~= nil,
					entry .. " is named with its file: " .. text)
			end
			helpers.assert_eq(#warnings, 4, "one WARNING per outdated entry: " .. text)
			NavLayer.load({ shared_root = shared_root, config_dir = dir })
			helpers.assert_eq(#warnings, 4, "a reload does not repeat them")
			write(dir .. "/layers.toml", "[_meta]\nschema_version = 99\n")
			helpers.assert_throws(function() NavLayer.load({ shared_root = shared_root, config_dir = dir }) end,
				"a file of another layers schema is still refused as a whole")
		end)
		package.loaded["logger.shim"] = previous_logger
		os.remove(dir .. "/layers.toml")
		os.execute('rmdir "' .. dir .. '"')
		if not ok then error(err, 0) end
	end)
end)
