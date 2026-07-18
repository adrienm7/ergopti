--- tests/meta/test_e2e_virtual_keyboard_isolation.lua
---
--- Regression: every virtual-keyboard E2E scenario must bind all emitters to
--- its own fresh Hammerspoon stub. A cached TextSender keeps the previous
--- scenario's hs.eventtap closures, which silently loses delete events and
--- corrupts later output/backspace assertions.

local helpers = require("tests.helpers")

local function e2e_source()
	local path = helpers.driver_root() .. "tests/e2e/run_e2e.lua"
	local fh = io.open(path, "r")
	helpers.assert_true(fh ~= nil, "virtual-keyboard E2E harness must be readable")
	local src = fh:read("*a")
	fh:close()
	return src
end

helpers.describe("Virtual-keyboard E2E scenario isolation", function()
	helpers.it("reloads adapters which capture the scenario-local hs stub", function()
		local src = e2e_source()
		helpers.assert_contains(src, 'package.loaded["adapters.text_sender"]        = nil',
			"each E2E scenario must reload TextSender under its fresh hs stub")
		helpers.assert_contains(src, 'package.loaded["adapters.clipboard"]          = nil',
			"each E2E scenario must reload Clipboard with its TextSender dependency")
	end)
end)
