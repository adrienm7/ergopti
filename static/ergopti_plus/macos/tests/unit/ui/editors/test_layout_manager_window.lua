--- tests/unit/ui/editors/test_layout_manager_window.lua

--- ==============================================================================
--- MODULE: Layout Manager Window (macOS host)
--- DESCRIPTION:
--- The macOS host of the layout manager page sends the strings strings.json
--- declares, and a controller bound to a window pushes into that exact window
--- only, so a late callback of a closed window never writes into its successor
--- (layout-manager-bridge).
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

helpers.describe("layout manager window (macOS)", function()
	helpers.it("sends every string the page declares, translated (layout-manager-bridge)", function()
		local Host = helpers.load_with_stubs("ui.layout_manager")
		local declared = Json.decode(assert(io.open(helpers.shared("ui/layout_manager/strings.json"), "rb")):read("*a"))
		local strings = Host._page_strings()
		local count = 0
		for _, key in ipairs(declared.keys) do
			helpers.assert_type(strings[key], "string", key .. " is sent to the page")
			count = count + 1
		end
		helpers.assert_true(count >= 35, "the page declares its strings")
	end)

	helpers.it("pushes only into the window it was created for (layout-manager-bridge)", function()
		local Host = helpers.load_with_stubs("ui.layout_manager")
		local refreshed = 0
		local saved = package.loaded["modules.keymap.layout_registry"]
		package.loaded["modules.keymap.layout_registry"] = {
			snapshot = function() return { platform = "macos", installed = {} } end,
			refresh = function(on_done) refreshed = refreshed + 1; on_done({}) end,
		}
		local evaluated = {}
		local stale = { evaluateJavaScript = function(_, js) evaluated[#evaluated + 1] = js end }
		local ok, err = pcall(function()
			local controller = Host._controller_for(stale)
			helpers.assert_true(controller.on_message({ action = "refresh" }) == true)
			helpers.assert_true(controller.on_message({ action = "ready" }) == true)
			helpers.assert_true(controller.on_message({ action = "ready" }) == false, "dual native/page readiness is deduplicated")
			helpers.assert_true(controller.on_message({ action = "refresh" }) == true, "explicit refresh remains available")
			local replacement = Host._controller_for(stale)
			helpers.assert_true(replacement.on_message({ action = "ready" }) == true, "new window owns new readiness")
		end)
		package.loaded["modules.keymap.layout_registry"] = saved
		helpers.assert_true(ok, tostring(err))
		helpers.assert_eq(refreshed, 4, "each initial window refresh runs once, with explicit refreshes preserved")
		helpers.assert_eq(#evaluated, 0, "a window that is not the current one receives nothing")
	end)

	helpers.it("offers the navigation layer save once the menu binds it (layout-editor-nav-apply)", function()
		local Host = helpers.load_with_stubs("ui.layout_manager")
		helpers.assert_true(not pcall(Host.set_nav_applier, "not a function"), "only a function binds")
		local saved = package.loaded["modules.keymap.layout_registry"]
		package.loaded["modules.keymap.layout_registry"] = {
			snapshot = function() return { platform = "macos", installed = {} } end,
			refresh = function() end,
		}
		local texts = {}
		local ok, err = pcall(function()
			local view = { evaluateJavaScript = function() end }
			helpers.assert_true(Host._controller_for(view).on_message({ action = "nav_save", text = "a" }) == false,
				"without a bound save nav_save is refused")
			Host.set_nav_applier(function(text)
				texts[#texts + 1] = text
				return { saved = true, applied = true, errors = {} }
			end)
			helpers.assert_true(Host._controller_for(view).on_message({ action = "nav_save", text = "b" }) == true)
		end)
		Host.set_nav_applier(nil)
		package.loaded["modules.keymap.layout_registry"] = saved
		helpers.assert_true(ok, tostring(err))
		helpers.assert_eq(#texts, 1)
		helpers.assert_eq(texts[1], "b")
	end)

	helpers.it("emulates a source once the menu binds the emulation preferences (layout-editor-emulate)", function()
		local Host = helpers.load_with_stubs("ui.layout_manager")
		helpers.assert_true(not pcall(Host.set_emulation_applier, "not a function"), "only a function binds")
		local saved = package.loaded["modules.keymap.layout_registry"]
		local stored, emulated = {}, {}
		package.loaded["modules.keymap.layout_registry"] = {
			snapshot = function() return { platform = "macos", installed = {} } end,
			refresh = function() end,
			composer_emulate = function(payload, on_done)
				stored[#stored + 1] = payload
				on_done(true, nil, nil, "composed")
			end,
		}
		local ok, err = pcall(function()
			local view = { evaluateJavaScript = function() end }
			local message = { action = "composer_emulate", source = "s", keylayout = "k" }
			helpers.assert_true(Host._controller_for(view).on_message(message) == false,
				"without the bound preferences composer_emulate is refused")
			Host.set_emulation_applier(function(id)
				emulated[#emulated + 1] = id
				return true
			end)
			helpers.assert_true(Host._controller_for(view).on_message(message) == true)
		end)
		Host.set_emulation_applier(nil)
		package.loaded["modules.keymap.layout_registry"] = saved
		helpers.assert_true(ok, tostring(err))
		helpers.assert_eq(#stored, 1, "a refused message stores nothing")
		helpers.assert_eq(emulated, { "composed" })
	end)

	helpers.it("defers the menu's editor command to the window owner (layout-editor-menu)", function()
		local Host = helpers.load_with_stubs("ui.layout_manager")
		helpers.assert_eq(type(Host.editor_menu_command()), "function")
		helpers.assert_eq(type(Host.open_editor), "function")
	end)
end)
