--- tests/unit/modules/shortcuts/test_case_transforms.lua

--- ==============================================================================
--- MODULE: Shortcut Case Transforms
--- DESCRIPTION:
--- Proves the Linux handlers match the macOS/Windows toggle behavior and pass
--- Unicode results into the clipboard selection transaction.
--- ==============================================================================

local helpers = require("tests.helpers")

local function with_manager(selected, body)
	local names = {
		manager = "modules.shortcuts.manager",
		clipboard = "adapters.clipboard",
		event_loop = "adapters.event_loop",
		combo = "modules.gestures.combo_emitter",
		injector = "modules.hotstrings.injector",
		keylogger = "modules.keylogger.keylogger",
	}
	local previous = {}
	for key, name in pairs(names) do previous[key] = package.loaded[name] end

	local state = { selected = selected, replacement = nil }
	package.loaded[names.clipboard] = {
		transform_selection = function(transform)
			state.replacement = transform(state.selected)
			return true
		end,
		read_checked = function() return true, "clipboard", nil end,
	}
	package.loaded[names.event_loop] = { sleep_ms = function() return true end }
	package.loaded[names.combo] = { press = function() return true end }
	package.loaded[names.injector] = { inject = function() return { ok = true } end }
	package.loaded[names.keylogger] = { record_shortcut = function() return true end }
	package.loaded[names.manager] = nil

	local ok, err = pcall(function()
		body(require(names.manager), state)
	end)
	for key, name in pairs(names) do package.loaded[name] = previous[key] end
	helpers.assert_true(ok, "shortcut case probe must not throw: " .. tostring(err))
end

helpers.describe("shortcut case transforms", function()
	helpers.it("toggles an international selection between uppercase and lowercase", function()
		with_manager("été Straße Москва", function(manager, state)
			helpers.assert_true(manager.transform_uppercase())
			helpers.assert_eq(state.replacement, "ÉTÉ STRASSE МОСКВА")

			state.selected = state.replacement
			helpers.assert_true(manager.transform_uppercase())
			helpers.assert_eq(state.replacement, "été strasse москва")
		end)
	end)

	helpers.it("toggles title case like the macOS and Windows actions", function()
		with_manager("«ÉTÉ» STRAẞE МОСКВА", function(manager, state)
			helpers.assert_true(manager.transform_titlecase())
			helpers.assert_eq(state.replacement, "«Été» Straße Москва")

			state.selected = state.replacement
			helpers.assert_true(manager.transform_titlecase())
			helpers.assert_eq(state.replacement, "«été» straße москва")
		end)
	end)

	helpers.it("lowercases explicitly without applying toggle semantics", function()
		with_manager("ÉTÉ STRAẞE", function(manager, state)
			helpers.assert_true(manager.transform_lowercase())
			helpers.assert_eq(state.replacement, "été straße")
		end)
	end)

	helpers.it("capitalizes a non-ASCII CapsWord character after Unicode punctuation", function()
		with_manager("unused", function(manager)
			manager.toggle_caps_word()
			helpers.assert_eq(manager.process_caps_word("é"), "É")
			helpers.assert_eq(manager.process_caps_word("—"), nil)
			helpers.assert_eq(manager.process_caps_word("я"), "Я")
		end)
	end)
end)
