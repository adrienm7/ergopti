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
