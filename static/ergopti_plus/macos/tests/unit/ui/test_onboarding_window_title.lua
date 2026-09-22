--- tests/unit/ui/test_onboarding_window_title.lua

--- ==============================================================================
--- MODULE: Onboarding Window Title
--- DESCRIPTION:
--- Proves the wizard's native title follows the previewed locale and names the
--- product exactly once.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.onboarding_delivery_fixture")
local with_delivery = fixture.with_delivery


--- Makes the fixture's i18n locale-aware: get() returns "<locale>:<key>".
--- @return table i18n The patched stub.
local function locale_aware_i18n()
	local i18n = package.loaded["infra.i18n"]
	local current = "en"
	i18n.get_locale = function() return current end
	i18n.set_locale_no_reload = function(code) current = code; return true end
	i18n.get = function(key) return current .. ":" .. key end
	return i18n
end


helpers.describe("onboarding window title", function()
	helpers.it("(onboarding-window-title) opens with the brand-less window title key", function()
		with_delivery(function(_, state)
			helpers.assert_eq(state.view.options.title, "onboarding.window_title")
		end)
	end)

	helpers.it("(onboarding-window-title) a previewed locale retitles the native window", function()
		with_delivery(function(_, state)
			locale_aware_i18n()
			state.receiver({ body = { action = "previewLocale", locale = "fr" } })
			helpers.assert_eq(#state.titles, 1)
			helpers.assert_eq(state.titles[1].title, "fr:onboarding.window_title")
			helpers.assert_true(state.titles[1].view == state.view)
			state.receiver({ body = { action = "previewLocale", locale = "de" } })
			helpers.assert_eq(state.titles[2].title, "de:onboarding.window_title")
		end)
	end)

	helpers.it("(onboarding-window-title) previewing does not move the active locale", function()
		with_delivery(function(_, state)
			local i18n = locale_aware_i18n()
			state.receiver({ body = { action = "previewLocale", locale = "fr" } })
			helpers.assert_eq(i18n.get_locale(), "en")
		end)
	end)

	helpers.it("(onboarding-window-title) initData retitles in the current locale", function()
		with_delivery(function(_, state, pending)
			locale_aware_i18n()
			state.receiver({ body = { action = "ready" } })
			pending[#pending]()
			helpers.assert_eq(state.titles[#state.titles].title, "en:onboarding.window_title")
		end)
	end)

	helpers.it("(onboarding-window-title) a closed wizard is never retitled", function()
		with_delivery(function(_, state)
			local receiver = state.receiver
			state.view.options.on_close()
			receiver({ body = { action = "previewLocale", locale = "fr" } })
			helpers.assert_eq(#state.titles, 0)
		end)
	end)

	helpers.it("(onboarding-window-title) every locale's window title is brand-less", function()
		local Json = require("tests.stubs.hs").json
		local dir = "../_shared/data/locales/"
		local codes = { "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja",
			"ko", "nl", "no", "pl", "pt", "ru", "sv", "tr", "uk", "zh" }
		for _, code in ipairs(codes) do
			local fh = assert(io.open(dir .. code .. ".json", "rb"))
			local strings = Json.decode(fh:read("*a"))
			fh:close()
			local title = strings["onboarding.window_title"]
			helpers.assert_type(title, "string", code)
			helpers.assert_true(title ~= "", code)
			helpers.assert_nil(title:find("Ergopti", 1, true), code .. " window title repeats the product name")
		end
	end)
end)

helpers.describe("ui_builder window title", function()
	helpers.it("(onboarding-window-title) the product name is prefixed exactly once", function()
		local ui_builder = helpers.load_with_stubs("ui.ui_builder", {})
		local title = ui_builder.window_title("Setup")
		helpers.assert_eq(title, "ErgoptiPlus — Setup")
		local _, count = title:gsub("ErgoptiPlus", "")
		helpers.assert_eq(count, 1)
		helpers.assert_eq(ui_builder.window_title(""), "ErgoptiPlus")
		helpers.assert_eq(ui_builder.window_title(nil), "ErgoptiPlus")
	end)

	helpers.it("(onboarding-window-title) set_window_title applies the composed title", function()
		local ui_builder = helpers.load_with_stubs("ui.ui_builder", {})
		local applied
		local view = { windowTitle = function(_, value) applied = value end }
		helpers.assert_true(ui_builder.set_window_title(view, "Configuration"))
		helpers.assert_eq(applied, "ErgoptiPlus — Configuration")
		helpers.assert_eq(ui_builder.set_window_title(nil, "x"), false)
	end)
end)
