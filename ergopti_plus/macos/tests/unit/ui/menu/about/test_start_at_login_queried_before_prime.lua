-- tests/unit/ui/menu/about/test_start_at_login_queried_before_prime.lua

--- ==============================================================================
--- MODULE: Regression - the login item state is asked before the prime build
--- DESCRIPTION:
--- The login item state was asked only by the first menu build, after it had
--- baked the default (off) state. With the login item on, the answer flipped it
--- and scheduled a second full rebuild at every boot: two 0.5 to 0.6 s
--- main-thread holds on the Mac (23:34 field run). Menu start now asks before
--- arming the prime build, whose own question then finds the state unchanged.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("menu start: login item state before the prime build", function()
	helpers.it("asks the status before scheduling the prime rebuild", function()
		local src = helpers.read_driver_source("Warm the expensive menu-discovery caches off the boot path")
		local prime = src:find("MENU_CACHE_PRIME_DELAY_SEC,", 1, true)
		helpers.assert_true(prime ~= nil, "the prime timer must be locatable")
		local setup_start = src:find("TrayMenu.setMenu(dynamic_menu_provider)", 1, true)
		helpers.assert_true(setup_start ~= nil and setup_start < prime, "the dynamic menu install must precede the prime")
		local early = src:find('start_at_login").request("status"', setup_start, true)
		helpers.assert_true(early ~= nil and early < prime,
			"menu start must ask the login item state before the prime build bakes it")
	end)

	helpers.it("a status answer equal to the baked state requests no rebuild", function()
		package.loaded["ui.menu.start_at_login"] = nil
		local StartAtLogin = require("ui.menu.start_at_login")
		local callback
		local deps = {
			resolver = { resolve = function() return "/bin/launcher", nil, {} end },
			shell = { spawn = function(_, _, on_exit) callback = on_exit; return { start = function() return true end } end },
			logger = helpers.make_logger_stub(),
		}
		local changes = 0
		helpers.assert_true(StartAtLogin.request("status", function() changes = changes + 1 end, deps))
		callback(0, "enabled\n")
		helpers.assert_eq(changes, 1, "the first answer flips the default off state")
		helpers.assert_true(StartAtLogin.request("status", function() changes = changes + 1 end, deps))
		callback(0, "enabled\n")
		helpers.assert_eq(changes, 1, "the prime build's own question then changes nothing")
		package.loaded["ui.menu.start_at_login"] = nil
	end)
end)
