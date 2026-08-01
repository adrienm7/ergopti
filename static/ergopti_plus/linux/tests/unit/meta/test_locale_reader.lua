--- linux/tests/unit/meta/test_locale_reader.lua

local helpers = require("tests.helpers")

helpers.describe("linux/infra/locale.lua", function()
	helpers.it("module loads without error", function()
		local ok, mod = pcall(require, "infra.locale")
		helpers.assert_true(ok, "require('infra.locale') should succeed")
		helpers.assert_true(type(mod) == "table", "should return a table")
	end)

	helpers.it("locale.get returns a non-empty string for a known key", function()
		local locale = require("infra.locale")
		-- The default locale is 'fr', so "menu.global.enable_all" should exist
		local s = locale.get("menu.global.enable_all")
		helpers.assert_true(type(s) == "string" and #s > 0, "should return non-empty string")
	end)

	helpers.it("locale.get returns empty string for unknown key", function()
		local locale = require("infra.locale")
		local s = locale.get("this.key.does.not.exist.anywhere")
		helpers.assert_true(s == "" or s == nil, "unknown key returns empty/nil")
	end)

	helpers.it("locale.set_locale switches language", function()
		local locale = require("infra.locale")
		locale.set_locale("en")
		local s_en = locale.get("menu.global.enable_all")
		locale.set_locale("fr")
		helpers.assert_true(type(s_en) == "string" and #s_en > 0, "en locale should resolve")
	end)

	helpers.it("locale.all returns a table", function()
		local locale = require("infra.locale")
		locale.set_locale("fr")
		local all = locale.all()
		helpers.assert_true(type(all) == "table", "all() returns a table")
		local count = 0; for _ in pairs(all) do count = count + 1 end
		helpers.assert_true(count > 10, "should have more than 10 keys")
	end)
end)

helpers.describe("linux/infra/i18n.lua", function()
	helpers.it("module loads without error", function()
		local ok, mod = pcall(require, "infra.i18n")
		helpers.assert_true(ok, "require('infra.i18n') should succeed")
		helpers.assert_true(type(mod) == "table", "should return a table")
	end)

	helpers.it("i18n.get returns translated string", function()
		local i18n = require("infra.i18n")
		local s = i18n.get("menu.global.enable_all")
		helpers.assert_true(type(s) == "string" and #s > 0, "should return non-empty")
		helpers.assert_true(s ~= "menu.global.enable_all", "should NOT return the key itself")
	end)

	helpers.it("i18n.get falls back to key name on missing", function()
		local i18n = require("infra.i18n")
		local s = i18n.get("this.key.does.not.exist")
		helpers.assert_eq(s, "this.key.does.not.exist", "falls back to key name")
	end)

	helpers.it("i18n.get_locale returns default 'fr'", function()
		local i18n = require("infra.i18n")
		helpers.assert_eq(i18n.get_locale(), "fr", "default locale is fr")
	end)
end)
