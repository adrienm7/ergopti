-- tests/unit/infra/i18n/test_locale_lazy_fallback.lua

--- ==============================================================================
--- MODULE: Regression - the English fallback locale loads only on a miss
--- DESCRIPTION:
--- Every macOS boot decoded en.json (3823 keys, about 20 ms on the Mac) right
--- after the active French locale, although a complete locale never falls back.
--- The shared locale core now decodes a fallback only when the active locale
--- lacks a key, or when the merged page catalogue is asked for.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Initializes a fresh shared locale core over in-memory locale tables.
--- @return table core, table loads (code -> count)
local function fresh_core()
	package.loaded["locale.core"] = nil
	local Core = require("locale.core")
	local tables = {
		fr = { ["menu.present"] = "présent" },
		en = { ["menu.present"] = "present", ["menu.english_only"] = "english" },
	}
	local loads = {}
	Core.init({
		resolve_locale_path = function(code) return "/locales/" .. code .. ".json" end,
		read_file = function(path) return path:match("([%a_]+)%.json$") end,
		json_decode = function(code)
			loads[code] = (loads[code] or 0) + 1
			return tables[code]
		end,
	})
	return Core, loads
end

helpers.describe("locale core: lazy fallback", function()
	helpers.it("decodes only the active locale while it has every key", function()
		local Core, loads = fresh_core()
		Core.set_locale("fr")
		helpers.assert_eq(Core.get("menu.present"), "présent")
		helpers.assert_eq(loads.fr, 1, "the active locale is decoded once")
		helpers.assert_eq(loads.en, nil, "a complete active locale must not decode en.json")
		package.loaded["locale.core"] = nil
	end)

	helpers.it("decodes English on the first miss and serves it", function()
		local Core, loads = fresh_core()
		Core.set_locale("fr")
		helpers.assert_eq(Core.get("menu.english_only"), "english")
		helpers.assert_eq(Core.get("menu.english_only"), "english")
		helpers.assert_eq(loads.en, 1, "the fallback is decoded once, on the miss")
		package.loaded["locale.core"] = nil
	end)

	helpers.it("the merged catalogue still carries every fallback key", function()
		local Core = fresh_core()
		Core.set_locale("fr")
		local catalogue = Core.catalogue()
		helpers.assert_eq(catalogue["menu.english_only"], "english")
		helpers.assert_eq(catalogue["menu.present"], "présent")
		package.loaded["locale.core"] = nil
	end)
end)
