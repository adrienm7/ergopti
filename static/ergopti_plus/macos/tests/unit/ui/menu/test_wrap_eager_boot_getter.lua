-- static/ergopti_plus/macos/tests/unit/ui/menu/test_wrap_eager_boot_getter.lua

--- Physical reload feeds the actual menu boot controller before the first menu.
local helpers = require("tests.helpers")
local roundtrip = require("tests.support.preferences_roundtrip_fixture")
local boot = require("tests.support.menu_boot_fixture")
local OWNED = {
	"ui.menu.init", "ui.menu.menu_state", "ui.menu.preferences_transaction", "ui.menu.session_demotions",
	"ui.menu.keymap_lifecycle", "ui.menu.global_actions_transaction", "ui.menu.recoverable_file_moves",
	"infra.logger", "infra.notifications", "infra.i18n", "infra.ui_restore", "infra.text_utils",
	"infra.deferred_work", "infra.preferences", "ui.hotstring_editor", "ui.menu.builder", "ui.menu.hotstring_counter",
	"ui.menu.menu_paths", "infra.factory_reset_journal", "ui.menu.menu_watchers", "modules.updater",
	"adapters.tray_menu", "adapters.hotkey_registrar", "infra.termination_coordinator", "ui.menu.menu_gestures",
	"ui.menu.menu_shortcuts", "ui.menu.menu_keyboard_layout", "ui.menu.menu_hotstrings", "ui.menu.menu_metrics",
	"ui.menu.menu_tap_holds", "ui.menu.menu_apps", "ui.menu.menu_about", "ui.menu.menu_llm", "infra.personal_shortcuts",
	"modules.dynamic_hotstrings", "modules.gestures", "modules.keylogger.text_cipher", "modules.llm",
	"modules.keylogger", "modules.shortcuts", "modules.shortcuts.actions.text", "menu.wrap_mutation",
	"ui.menu.global_scope", "ui.menu.metrics_scope", "ui.menu.gesture_scope", "ui.menu.hotstrings_scope",
	"ui.menu.scoped_preferences", "modules.hotstrings.hotstrings_config",
}
local function with_boot(saved, callback)
	return helpers.with_stub_scope(OWNED, function()
		local fixture = boot.boot({ saved = saved })
		return callback(fixture)
	end)
end
helpers.describe("actual eager Wrap getter after physical reload", function()
	helpers.it("restores saved input before the first lazy menu construction", function()
		roundtrip.with_roundtrip({ shortcuts = true, wrap_symbol_states = { ["("] = false },
			custom_wrap_symbols = { { left = "a", right = "b" } } }, function(saved)
			with_boot(saved, function(f)
				helpers.assert_nil(f.ctx, "the fixture has not opened the lazy menu")
				helpers.assert_type(f.wrap_pairs_getter, "function", "actual start must install the native getter")
				helpers.assert_nil(f.wrap_pairs_getter()["("], "first keystroke respects persisted disabled choice")
				helpers.assert_eq(f.wrap_pairs_getter().a, { left = "a", right = "b" })
			end)
		end)
	end)
	for _, receipt in ipairs({ "false", "nil", "truthy", "throw", "true" }) do
		helpers.it("retains eager input during actual boot transaction " .. receipt, function()
			with_boot({ shortcuts = true, wrap_symbol_states = {}, custom_wrap_symbols = { { left = "a", right = "b" } } }, function(f)
				local observed, calls = nil, 0
				local preferences = package.loaded["infra.preferences"]
				local original_save = preferences.save
				preferences.save = function(...)
					calls = calls + 1
					observed = f.wrap_pairs_getter().a
					if receipt == "throw" then error("controlled native persistence refusal", 0) end
					if receipt == "true" then return original_save(...) end
					if receipt == "false" then return false end
					if receipt == "truthy" then return "accepted" end
				end
				local accepted = require("menu.wrap_mutation").commit(f.state, function(candidate)
					table.remove(candidate.custom_wrap_symbols, 1); return true
				end, f.save_prefs)
				helpers.assert_eq(calls, 1, "actual boot preference transaction must invoke its native persistence port")
				helpers.assert_eq(observed, { left = "a", right = "b" }, "eager native getter keeps last ACK while candidate is pending")
				helpers.assert_eq(accepted, receipt == "true")
				if receipt == "true" then helpers.assert_nil(f.wrap_pairs_getter().a)
				else helpers.assert_eq(f.wrap_pairs_getter().a, { left = "a", right = "b" }) end
			end)
		end)
	end
end)
