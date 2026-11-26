--- linux/tests/unit/core/i18n/test_reader.lua

local helpers = require("tests.helpers")

helpers.describe("linux/core/i18n/engine/locale.lua", function()
	helpers.it("module loads without error", function()
		local ok, mod = pcall(require, "core.i18n.engine.locale")
		helpers.assert_true(ok, "require('core.i18n.engine.locale') should succeed")
		helpers.assert_true(type(mod) == "table", "should return a table")
	end)

	helpers.it("locale refuses a missing JSON decoder before reading data", function()
		local saved_json, saved_preload = package.loaded["core.text.engine.json"], package.preload["core.text.engine.json"]
		local saved_locale, saved_core = package.loaded["core.i18n.engine.locale"], package.loaded["core.i18n.engine.core"]
		package.loaded["core.text.engine.json"], package.loaded["core.i18n.engine.locale"] = nil, nil
		package.preload["core.text.engine.json"] = function() error("controlled missing decoder") end
		local ok, detail = pcall(require, "core.i18n.engine.locale")
		package.loaded["core.text.engine.json"], package.preload["core.text.engine.json"] = saved_json, saved_preload
		package.loaded["core.i18n.engine.locale"], package.loaded["core.i18n.engine.core"] = saved_locale, saved_core
		helpers.assert_eq(ok, false, "a missing JSON decoder must not become an executable data fallback")
		helpers.assert_true(tostring(detail):find("JSON decoder", 1, true) ~= nil)
	end)

	helpers.it("locale.get returns a non-empty string for a known key", function()
		local locale = require("core.i18n.engine.locale")
		-- The default locale is 'fr', so "menu.global.quit" should exist
		local s = locale.get("menu.global.quit")
		helpers.assert_true(type(s) == "string" and #s > 0, "should return non-empty string")
	end)

	helpers.it("locale.get returns empty string for unknown key", function()
		local locale = require("core.i18n.engine.locale")
		local s = locale.get("this.key.does.not.exist.anywhere")
		helpers.assert_true(s == "" or s == nil, "unknown key returns empty/nil")
	end)

	helpers.it("locale.set_locale switches language", function()
		local locale = require("core.i18n.engine.locale")
		locale.set_locale("en")
		local s_en = locale.get("menu.global.quit")
		locale.set_locale("fr")
		helpers.assert_true(type(s_en) == "string" and #s_en > 0, "en locale should resolve")
	end)

	helpers.it("locale.all returns a table", function()
		local locale = require("core.i18n.engine.locale")
		locale.set_locale("fr")
		local all = locale.all()
		helpers.assert_true(type(all) == "table", "all() returns a table")
		local count = 0; for _ in pairs(all) do count = count + 1 end
		helpers.assert_true(count > 10, "should have more than 10 keys")
	end)
end)

helpers.describe("Linux keycode JSON admission", function()
	helpers.it("input reader refuses a missing JSON decoder before loading keycodes", function()
		local saved_json, saved_preload = package.loaded["core.text.engine.json"], package.preload["core.text.engine.json"]
		local saved_reader, saved_evdev = package.loaded["hotstrings.engine.input_reader"], package.loaded["platform.input.keycodes.evdev"]
		local calls = 0
		package.loaded["core.text.engine.json"], package.loaded["hotstrings.engine.input_reader"] = nil, nil
		package.preload["core.text.engine.json"] = function() error("controlled missing decoder") end
		package.loaded["platform.input.keycodes.evdev"] = { load = function() calls = calls + 1; return {} end }
		local ok = pcall(require, "hotstrings.engine.input_reader")
		package.loaded["core.text.engine.json"], package.preload["core.text.engine.json"] = saved_json, saved_preload
		package.loaded["hotstrings.engine.input_reader"], package.loaded["platform.input.keycodes.evdev"] = saved_reader, saved_evdev
		helpers.assert_eq(ok, false, "missing JSON must refuse keycode admission")
		helpers.assert_eq(calls, 0, "no keycode data is read with an executable fallback")
	end)
end)

helpers.describe("linux/core/i18n/engine/i18n.lua", function()
	helpers.it("module loads without error", function()
		local ok, mod = pcall(require, "core.i18n.engine.i18n")
		helpers.assert_true(ok, "require('core.i18n.engine.i18n') should succeed")
		helpers.assert_true(type(mod) == "table", "should return a table")
	end)

	helpers.it("i18n.get returns translated string", function()
		local i18n = require("core.i18n.engine.i18n")
		local s = i18n.get("menu.global.quit")
		helpers.assert_true(type(s) == "string" and #s > 0, "should return non-empty")
		helpers.assert_true(s ~= "menu.global.quit", "should NOT return the key itself")
	end)

	helpers.it("i18n.get falls back to key name on missing", function()
		local i18n = require("core.i18n.engine.i18n")
		local s = i18n.get("this.key.does.not.exist")
		helpers.assert_eq(s, "this.key.does.not.exist", "falls back to key name")
	end)

	-- A key written twice decodes under the default decoder, the last value
	-- winning, and refuses under the lossless one every owner reading a whole
	-- catalogue uses: one duplicated inventory key in all 21 files once failed
	-- every such reader on Linux.
	helpers.it("every locale catalogue decodes losslessly, with no key written twice", function()
		local Json = require("core.text.engine.json")
		local Paths = require("core.fs.engine.paths")
		local directory = Paths.shared("core/i18n/data/locales")
		local listing = assert(io.popen("ls " .. require("core.text.engine.utils_core").shell_quote(directory)))
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
		local i18n = require("core.i18n.engine.i18n")
		helpers.assert_eq(i18n.get_locale(), "fr", "default locale is fr")
	end)
	helpers.it("i18n warns once per raw key shown, never for a probe (i18n-miss-warned)", function()
		local names = { "core.logger.engine.shim", "core.i18n.engine.i18n", "core.i18n.engine.locale", "core.i18n.engine.core" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		local logs = {}
		local logger = assert(dofile(require("core.fs.engine.paths").shared("core/logger/engine/init.lua")))
		logger.set_level("trace"); logger.set_sink(function(line) logs[#logs + 1] = line end)
		package.loaded["core.logger.engine.shim"] = logger
		package.loaded["core.i18n.engine.locale"] = nil
		local ok, detail = pcall(function()
			local i18n = helpers.load_module("core.i18n.engine.i18n")
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
