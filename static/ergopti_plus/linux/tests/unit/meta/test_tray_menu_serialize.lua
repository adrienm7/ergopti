--- tests/unit/meta/test_tray_menu_serialize.lua

--- ==============================================================================
--- MODULE: Tray Menu Serialize Load-Order Regression Guard
--- DESCRIPTION:
--- Regression test for a nil-global crash in adapters/tray_menu.lua.
---
--- ROOT CAUSE ENCODED:
--- _serialize_menu() reads the module-level _registry (and _signal_file) to
--- register each menu item's callback, but those locals were declared BELOW
--- _serialize_menu. Lua does not hoist locals, so inside _serialize_menu the name
--- _registry bound to the (nil) global; the first menu item with a callback did
--- `_registry[#_registry + 1] = item.fn` and crashed with "attempt to index a nil
--- value" — the tray menu could never be built
--- (project-lua-closure-before-local-nil-global). Moving the declarations above
--- _serialize_menu fixes it.
---
--- The existing setMenu tests never caught this: on a box without yad, setMenu →
--- _yad_launch returns early (no yad) and never reaches _yad_serialize_menu. This
--- test calls the yad serializer directly (exposed as M._yad_serialize_menu) so
--- the callback path always runs.
---
--- Renamed _serialize_menu → _yad_serialize_menu (SNI backend added a
--- separate XML path; the yad path is now explicitly namespaced).
--- ==============================================================================

local helpers = require("tests.helpers")





-- ==================================================================
-- ==================================================================
-- ======= 1/ Behavioural: serialize an item with a callback ========
-- ==================================================================
-- ==================================================================

helpers.describe("tray_menu._yad_serialize_menu: registers item callbacks without a nil-global crash", function()
	helpers.it("serializes an item with a fn and emits its signal command", function()
		local tray = helpers.load_module("adapters.tray_menu")
		helpers.assert_true(type(tray._yad_serialize_menu) == "function", "tray_menu must expose _yad_serialize_menu")
		local ok, result = pcall(tray._yad_serialize_menu, {
			{ title = "Quit", fn = function() end },
			{ title = "Header", disabled = true },
		})
		helpers.assert_true(ok, "_yad_serialize_menu must not crash on an item with a callback; got: " .. tostring(result))
		helpers.assert_true(type(result) == "string" and #result > 0, "_yad_serialize_menu must return a non-empty yad menu string")
		-- The callback path (which reads _yad_registry) must have run: it emits a
		-- "MENU:<idx>" signal command for the item that carries a fn.
		helpers.assert_true(result:find("MENU:", 1, true) ~= nil, "the callback item must produce a MENU: signal command")
	end)
end)
