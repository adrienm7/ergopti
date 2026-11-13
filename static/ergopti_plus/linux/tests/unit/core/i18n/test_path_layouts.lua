--- tests/unit/core/i18n/test_path_layouts.lua

--- ==============================================================================
--- MODULE: Locale Files Resolve In Every Shipped Layout
--- DESCRIPTION:
--- core/i18n/engine/locale.lua used to find _shared/core/i18n/data/locales by cutting three levels
--- off its OWN chunk name. The test runner loads it through an absolute
--- checkout path, where that happens to work, so the suite was green while:
---   - the .deb and .rpm (/usr/lib/ergopti/infra/locale.lua) read
---     /usr/lib/_shared/core/i18n/data/locales — a directory no package owns;
---   - a checkout launch ("./infra/locale.lua") read nothing at all.
--- Every lookup then returned its raw key: the tray menu said
--- "menu.global.reload" and the first-run notification its key names.
---
--- The real source is loaded here under the chunk names those two layouts
--- produce, so the defect is reproduced rather than described.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads the real core/i18n/engine/locale.lua as if it lived at `chunk_path`.
--- @param chunk_path string
--- @return table The locale module.
local function load_as(chunk_path)
	local source = assert(helpers.read_module_source("core.i18n.engine.locale"))
	package.loaded["core.i18n.engine.core"] = nil
	local chunk = assert((loadstring or load)(source, "@" .. chunk_path))
	return chunk()
end

--- The English label the lookups must return, read from the file itself.
--- @return string
local function english(key)
	local Paths = helpers.load_module("core.fs.engine.paths")
	local fh = assert(io.open(Paths.shared("core/i18n/data/locales/en.json"), "r"))
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
			package.loaded["core.i18n.engine.core"] = nil
			helpers.assert_eq(got, english(key),
				"a raw key here is what every tray label showed on an installed package")
		end)
	end

end)
