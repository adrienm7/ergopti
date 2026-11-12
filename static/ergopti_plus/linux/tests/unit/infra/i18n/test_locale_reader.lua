--- linux/tests/unit/infra/i18n/test_locale_reader.lua

local helpers = require("tests.helpers")

helpers.describe("linux/infra/locale.lua", function()
	helpers.it("module loads without error", function()
		local ok, mod = pcall(require, "infra.locale")
		helpers.assert_true(ok, "require('infra.locale') should succeed")
		helpers.assert_true(type(mod) == "table", "should return a table")
	end)

	helpers.it("locale refuses a missing JSON decoder before reading data", function()
		local saved_json, saved_preload = package.loaded.json, package.preload.json
		local saved_locale, saved_core = package.loaded["infra.locale"], package.loaded["locale.core"]
		package.loaded.json, package.loaded["infra.locale"] = nil, nil
		package.preload.json = function() error("controlled missing decoder") end
		local ok, detail = pcall(require, "infra.locale")
		package.loaded.json, package.preload.json = saved_json, saved_preload
		package.loaded["infra.locale"], package.loaded["locale.core"] = saved_locale, saved_core
		helpers.assert_eq(ok, false, "a missing JSON decoder must not become an executable data fallback")
		helpers.assert_true(tostring(detail):find("JSON decoder", 1, true) ~= nil)
	end)

	helpers.it("locale.get returns a non-empty string for a known key", function()
		local locale = require("infra.locale")
		-- The default locale is 'fr', so "menu.global.quit" should exist
		local s = locale.get("menu.global.quit")
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
		local s_en = locale.get("menu.global.quit")
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

helpers.describe("Linux keycode JSON admission", function()
	helpers.it("input reader refuses a missing JSON decoder before loading keycodes", function()
		local saved_json, saved_preload = package.loaded.json, package.preload.json
		local saved_reader, saved_evdev = package.loaded["modules.hotstrings.input_reader"], package.loaded["keycodes.evdev"]
		local calls = 0
		package.loaded.json, package.loaded["modules.hotstrings.input_reader"] = nil, nil
		package.preload.json = function() error("controlled missing decoder") end
		package.loaded["keycodes.evdev"] = { load = function() calls = calls + 1; return {} end }
		local ok = pcall(require, "modules.hotstrings.input_reader")
		package.loaded.json, package.preload.json = saved_json, saved_preload
		package.loaded["modules.hotstrings.input_reader"], package.loaded["keycodes.evdev"] = saved_reader, saved_evdev
		helpers.assert_eq(ok, false, "missing JSON must refuse keycode admission")
		helpers.assert_eq(calls, 0, "no keycode data is read with an executable fallback")
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
		local s = i18n.get("menu.global.quit")
		helpers.assert_true(type(s) == "string" and #s > 0, "should return non-empty")
		helpers.assert_true(s ~= "menu.global.quit", "should NOT return the key itself")
	end)

	helpers.it("i18n.get falls back to key name on missing", function()
		local i18n = require("infra.i18n")
		local s = i18n.get("this.key.does.not.exist")
		helpers.assert_eq(s, "this.key.does.not.exist", "falls back to key name")
	end)

	-- A key written twice decodes under the default decoder, the last value
	-- winning, and refuses under the lossless one every owner reading a whole
	-- catalogue uses: one duplicated inventory key in all 21 files once failed
	-- every such reader on Linux.
	helpers.it("every locale catalogue decodes losslessly, with no key written twice", function()
		local Json = require("json")
		local Paths = require("infra.paths")
		local directory = Paths.shared("data/locales")
		local listing = assert(io.popen("ls " .. require("text_utils").shell_quote(directory)))
		local names = {}
		for name in listing:lines() do
			if name:match("^%a%a%.json$") then names[#names + 1] = name end
		end
		listing:close()
		helpers.assert_true(#names > 1, "the catalogues must be listed")
		local seen_english = false
		for _, name in ipairs(names) do
			seen_english = seen_english or name == "en.json"
			local file = assert(io.open(directory .. "/" .. name, "rb"))
			local text = file:read("*a")
			file:close()
			helpers.assert_type(Json.decode_lossless(text), "table", name .. " must decode losslessly")
		end
		helpers.assert_true(seen_english, "the canonical English catalogue must be among them")
	end)

	helpers.it("i18n.get_locale returns default 'fr'", function()
		local i18n = require("infra.i18n")
		helpers.assert_eq(i18n.get_locale(), "fr", "default locale is fr")
	end)
	helpers.it("i18n warns once per raw key shown, never for a probe (i18n-miss-warned)", function()
		local names = { "logger.shim", "infra.i18n", "infra.locale", "locale.core" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		local logs = {}
		local logger = assert(dofile(require("infra.paths").shared("lua/logger/init.lua")))
		logger.set_level("trace"); logger.set_sink(function(line) logs[#logs + 1] = line end)
		package.loaded["logger.shim"] = logger
		package.loaded["infra.locale"] = nil
		local ok, detail = pcall(function()
			local i18n = helpers.load_module("infra.i18n")
			local function count(pattern)
				local found = 0
				for _, line in ipairs(logs) do if line:find(pattern, 1, true) then found = found + 1 end end
				return found
			end
			helpers.assert_eq(i18n.has("this.key.does.not.exist.anywhere"), false)
			helpers.assert_eq(count("No translation"), 0, "a probe is not a defect")
			helpers.assert_eq(i18n.get("this.key.does.not.exist.anywhere"), "this.key.does.not.exist.anywhere")
			logger.info("test", "separator")
			i18n.get("this.key.does.not.exist.anywhere")
			helpers.assert_eq(count("No translation for 'this.key.does.not.exist.anywhere'"), 1)
			helpers.assert_true(i18n.has("menu.global.quit"))
		end)
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		assert(ok, detail)
	end)
end)
