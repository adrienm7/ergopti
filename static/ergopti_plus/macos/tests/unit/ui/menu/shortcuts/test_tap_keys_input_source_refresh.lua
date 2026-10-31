--- tests/unit/ui/menu/shortcuts/test_tap_keys_input_source_refresh.lua

--- ==============================================================================
--- MODULE: Regression — an input-source notification without a change keeps the menu
--- DESCRIPTION:
--- The tap-key rows rebuild the whole menu when the input source changes. macOS
--- also notifies without a change: the 2026-10-30 field report shows 26
--- notifications in 3.5 min, all naming the same layout, and each rebuilt the
--- menu (300 to 650 ms holds of the main thread). A rebuild is now asked only
--- when the source id or a tap-key name differs from the last render.
--- ==============================================================================

local helpers = require("tests.helpers")
local names = {
	"ui.menu.menu_tap_keys", "modules.shortcuts.tap_keys", "infra.logger",
	"adapters.input_source_broker", "ui.menu.menu_keyboard_slots", "ui.menu.shortcut_utils",
	"ui.action_picker", "modules.shortcuts.bindings", "infra.deferred_work",
}

helpers.describe("tap-key rows follow the input source", function()
	helpers.it("rebuild only when the source or a key name changes", function()
		helpers.with_fresh_modules(names, function()
			local callback
			local source_id, key_name = "com.apple.keyboardlayout.ergopti.plus", "1"
			local original_source = hs.keycodes.currentSourceID
			hs.keycodes.currentSourceID = function() return source_id end
			package.loaded["adapters.input_source_broker"] = {
				subscribe = function(_, fn) callback = fn; return true end,
			}
			package.loaded["modules.shortcuts.tap_keys"] = {
				ensure_loaded = function() end, keys = function() return { { id = "number_row_left" } } end,
				get_action = function() return "none" end, display_name = function() return key_name end,
				binding_id = function(id) return "tap." .. id end,
			}
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			local rebuilds = 0
			local ctx = {
				gestures = { is_assignable = function() return true end, get_action_label = function(a) return a end },
				updateMenu = function() rebuilds = rebuilds + 1 end,
			}
			local ok, err = pcall(function()
				local TapKeysMenu = require("ui.menu.menu_tap_keys")
				helpers.assert_eq(#TapKeysMenu.provide_rows(ctx), 1)
				helpers.assert_type(callback, "function", "the rows subscribe to input-source changes")
				callback()
				callback()
				helpers.assert_eq(rebuilds, 0, "a notification naming the rendered source must keep the menu")
				source_id = "com.apple.keylayout.French"
				callback()
				helpers.assert_eq(rebuilds, 1, "a real source switch must rebuild (the layout submenu ticks it)")
				TapKeysMenu.provide_rows(ctx)
				key_name = "&"
				callback()
				helpers.assert_eq(rebuilds, 2, "a changed tap-key name must rebuild")
			end)
			hs.keycodes.currentSourceID = original_source
			if not ok then error(err, 0) end
		end)
	end)
end)
