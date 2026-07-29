--- tests/unit/ui/test_hot_path_costs_are_cached.lua

--- ==============================================================================
--- MODULE: Regressions — two expensive rebuilds that ran on every trigger
--- DESCRIPTION:
--- 1. update_icon reads a PNG off disk, decodes it and re-renders it through an
---    off-screen hs.canvas. The pause listener runs it SYNCHRONOUSLY inside the
---    script-control eventtap callback — the same tap that carries the key needed
---    to un-pause — and it ran twice per toggle, once from the listener and once
---    from the menu refresh that follows. The icon depends on exactly two inputs.
--- 2. app_picker.discover_apps runs a blocking `find` across two application
---    trees plus one Info.plist read and one icon rasterisation PER INSTALLED
---    APP, on the main run loop. hs.timer.doAfter moves it off the click's stack
---    frame but not off that thread, and the set of installed applications does
---    not change between two menu opens seconds apart.
---
--- ROOT CAUSE ENCODED:
--- Both recompute a value whose inputs did not move. Asserted as the presence of
--- the memo keyed on those inputs, because neither path can be driven headlessly:
--- one needs a real menubar, the other a real filesystem and icon renderer.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("menubar: the icon is not re-rendered when nothing changed", function()

	helpers.it("skips the rebuild when the variant and pause state are unchanged", function()
		local src = helpers.read_driver_source("local function update_icon")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"the menu source must be readable or this asserts nothing")
		local at = src:find("local function update_icon", 1, true)
		local body = src:sub(at, at + 1600)
		helpers.assert_true(body:find("_last_icon_key", 1, true) ~= nil,
			"a PNG decode plus an off-screen canvas render runs inside the script-control "
			.. "eventtap on every pause toggle, twice, for an icon determined by two inputs")
	end)

end)

helpers.describe("app picker: installed applications are discovered once", function()

	helpers.it("serves a warm cache instead of re-running find", function()
		local src = helpers.read_driver_source("Discovering installed applications")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"the app picker source must be readable or this asserts nothing")
		local code = src:gsub("%-%-[^\n]*", "")
		helpers.assert_true(code:find("_apps_cache", 1, true) ~= nil,
			"the scan is a blocking find plus a plist read and an icon rasterisation per "
			.. "installed app, on the main run loop, re-paid on every picker open")
	end)

	helpers.it("does not cache a failed discovery", function()
		local src = helpers.read_driver_source("Failed to execute application discovery")
		local at  = src:find("Failed to execute application discovery", 1, true)
		local body = src:sub(math.max(1, at - 200), at + 300)
		helpers.assert_true(body:find("_apps_cache    = choices", 1, true) == nil,
			"caching a failure would serve an empty picker for the whole TTL; the next open "
			.. "must retry")
	end)

end)
