--- tests/unit/modules/dynamic_hotstrings/test_rules_engine_stop_clears_rules.lua

--- Regression test for dynhotstrings-5: rules_engine.stop() only cleared
--- _km but did not call SharedEngine.reset_rules(). On the next start(),
--- register_date_rules() was called again, appending three duplicate rules
--- to the shared engine and causing double-expansion of "td", "dt", "date".
---
--- Fix: added SharedEngine.reset_rules() at the top of M.stop() so the
--- date rules are cleared before the engine is re-initialized.

local helpers = require("tests.helpers")

local function fake_keymap(revoke_allowed)
	return {
		register_lua_group = function() end,
		set_post_load_hook = function() end,
		register_interceptor = function() end,
		register_preview_provider = function() end,
		invalidate_hotstring_preview = function() return revoke_allowed ~= false end,
	}
end

helpers.describe("rules_engine.stop clears shared rule ownership", function()
	helpers.it("a stop/start cycle registers one date-rule set, never two", function()
		package.loaded["dynamic_hotstrings"] = nil
		package.loaded["modules.dynamic_hotstrings.rules_engine"] = nil
		local SharedEngine = helpers.load_with_stubs("dynamic_hotstrings")
		local RulesEngine = require("modules.dynamic_hotstrings.rules_engine")

		SharedEngine.reset_rules()
		RulesEngine.start(fake_keymap())
		helpers.assert_eq(#SharedEngine.get_rules(), 3,
			"the first start must install the three canonical date rules")
		RulesEngine.stop()
		helpers.assert_eq(#SharedEngine.get_rules(), 0,
			"stop must release every shared rule, not merely clear the keymap handle")

		RulesEngine.start(fake_keymap())
		helpers.assert_eq(#SharedEngine.get_rules(), 3,
			"restart must not append a duplicate date-rule set")
		RulesEngine.stop()
	end)

	helpers.it("fails closed when preview revocation refuses teardown", function()
		package.loaded["dynamic_hotstrings"] = nil
		package.loaded["modules.dynamic_hotstrings.rules_engine"] = nil
		local SharedEngine = helpers.load_with_stubs("dynamic_hotstrings")
		local RulesEngine = require("modules.dynamic_hotstrings.rules_engine")

		SharedEngine.reset_rules()
		helpers.assert_true(RulesEngine.start(fake_keymap(false)))
		helpers.assert_eq(#SharedEngine.get_rules(), 3)
		helpers.assert_eq(RulesEngine.stop(), false,
			"teardown must report the unrecoverable native-surface failure")
		helpers.assert_eq(#SharedEngine.get_rules(), 0,
			"a failed surface hide must never leave the feature active after stop")
	end)
end)

return true
