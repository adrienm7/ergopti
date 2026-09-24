--- tests/unit/infra/test_locale_path_layouts.lua

--- ==============================================================================
--- MODULE: Locale Files Resolve In Every Shipped Layout
--- DESCRIPTION:
--- infra/locale.lua used to find _shared/data/locales by cutting three levels
--- off its OWN chunk name. The test runner loads it through an absolute
--- checkout path, where that happens to work, so the suite was green while:
---   - the .deb and .rpm (/usr/lib/ergopti/infra/locale.lua) read
---     /usr/lib/_shared/data/locales — a directory no package owns;
---   - a checkout launch ("./infra/locale.lua") read nothing at all.
--- Every lookup then returned its raw key: the tray menu said
--- "menu.global.reload" and the first-run notification its key names.
---
--- The real source is loaded here under the chunk names those two layouts
--- produce, so the defect is reproduced rather than described.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads the real infra/locale.lua as if it lived at `chunk_path`.
--- @param chunk_path string
--- @return table The locale module.
local function load_as(chunk_path)
	local fh = assert(io.open(helpers.driver_root() .. "/infra/locale.lua", "r"))
	local source = fh:read("*a")
	fh:close()
	package.loaded["locale.core"] = nil
	local chunk = assert((loadstring or load)(source, "@" .. chunk_path))
	return chunk()
end

--- The English label the lookups must return, read from the file itself.
--- @return string
local function english(key)
	local Paths = helpers.load_module("infra.paths")
	local fh = assert(io.open(Paths.shared("data/locales/en.json"), "r"))
	local text = fh:read("*a")
	fh:close()
	local value = text:match('"' .. key:gsub("%.", "%%.") .. '":%s*"([^"]*)"')
	return assert(value, "en.json has no " .. key)
end

helpers.describe("locale: the catalogue is found in every layout", function()

	for _, case in ipairs({
		{ name = "a system package (/usr/lib/ergopti)", chunk = "/usr/lib/ergopti/infra/locale.lua" },
		{ name = "a relative checkout launch", chunk = "./infra/locale.lua" },
	}) do
		helpers.it("translates when loaded from " .. case.name, function()
			local Locale = load_as(case.chunk)
			Locale.set_locale("en")
			local key = "menu.global.reload"
			local got = Locale.get(key)
			package.loaded["locale.core"] = nil
			helpers.assert_eq(got, english(key),
				"a raw key here is what every tray label showed on an installed package")
		end)
	end

end)
