--- tests/unit/ui/dialogs/test_app_cloner_python_offer.lua

--- ==============================================================================
--- MODULE: App Cloner Python Offer Tests
--- DESCRIPTION:
--- Pins ui/app_cloner_python_offer.lua: an installed managed PyObjC opens App
--- Cloner with its link at once; otherwise nothing installs before « Install »,
--- a success opens App Cloner with the link, and a decline or a failure still
--- opens it without one, the failure reported first.
---
--- ROOT CAUSE ENCODED: moving App Cloner off /usr/bin/python3 needs an install
--- the user agreed to; installing silently on a menu click, or leaving App
--- Cloner unopened after a failure, would trade one surprise for another.
--- ==============================================================================

local helpers = require("tests.helpers")

local STUBBED = { "core.i18n.engine.i18n", "infra.dialog_util", "infra.deferred_work", "infra.notifications",
	"ui.app_cloner_python_offer" }
local ORIGINALS = {}
for _, name in ipairs(STUBBED) do ORIGINALS[name] = package.loaded[name] end

--- Puts the real modules back.
local function restore()
	for _, name in ipairs(STUBBED) do package.loaded[name] = ORIGINALS[name] end
end

local LINK = "/Users/test/Library/Application Support/Ergopti/native-bootstrap/app-cloner/python3"

--- Loads the offer over recorded dialogs and notifications.
--- @param answer string The confirmation's clicked button, by i18n key.
--- @return table Offer
--- @return table world
local function load(answer)
	local world = { alerts = {}, notices = 0 }
	package.loaded["core.i18n.engine.i18n"] = {
		get = function(key) return key end,
		format = function(key, ...) return key .. "|" .. table.concat({ ... }, "|") end,
	}
	package.loaded["infra.dialog_util"] = {
		block_alert = function(title, body, first)
			world.alerts[#world.alerts + 1] = { title = title, body = body }
			if #world.alerts == 1 then return answer end
			return first
		end,
	}
	package.loaded["infra.deferred_work"] = { after = function(_, fn) fn(); return true end }
	package.loaded["infra.notifications"] = { notify = function() world.notices = world.notices + 1 end }
	package.loaded["ui.app_cloner_python_offer"] = nil
	return require("ui.app_cloner_python_offer"), world
end

--- An owner double.
local function owner(ready, outcome)
	local calls = { installs = 0 }
	return {
		ready = function() return ready end,
		link = function() return LINK end,
		install = function(callback)
			calls.installs = calls.installs + 1
			callback(outcome[1], outcome[2])
		end,
	}, calls
end

helpers.describe("App Cloner Python offer", function()
	helpers.it("opens App Cloner with the link when the managed PyObjC is installed", function()
		local Offer, world = load("unused")
		local launched
		Offer.open(owner(true, {}), function(environment) launched = environment end)
		helpers.assert_eq(launched, { "ERGOPTI_CLONER_PYTHON=" .. LINK,
			"PATH=/Users/test/Library/Application Support/Ergopti/native-bootstrap/app-cloner:/usr/bin:/bin:/usr/sbin:/sbin" })
		helpers.assert_eq(#world.alerts, 0, "nothing is asked when it is installed")
		restore()
	end)

	helpers.it("installs nothing before the click and opens App Cloner after a decline", function()
		local Offer, world = load("common.later")
		local double, calls = owner(false, { true, LINK })
		local launched
		Offer.open(double, function(environment) launched = environment end)
		helpers.assert_eq(calls.installs, 0)
		helpers.assert_eq(launched, {})
		helpers.assert_eq(world.alerts[1].body, "apps.cloner.python_offer.body")
		restore()
	end)

	helpers.it("installs on « Install » and opens App Cloner with the installed link", function()
		local Offer, world = load("apps.cloner.python_offer.install")
		local double, calls = owner(false, { true, LINK })
		local launched
		Offer.open(double, function(environment) launched = environment end)
		helpers.assert_eq(calls.installs, 1)
		helpers.assert_eq(world.notices, 1, "the install is announced")
		helpers.assert_eq(launched, { "ERGOPTI_CLONER_PYTHON=" .. LINK,
			"PATH=/Users/test/Library/Application Support/Ergopti/native-bootstrap/app-cloner:/usr/bin:/bin:/usr/sbin:/sbin" })
		restore()
	end)

	helpers.it("reports a failed install, then still opens App Cloner without the link", function()
		local Offer, world = load("apps.cloner.python_offer.install")
		local order = {}
		Offer.open(owner(false, { false, "pyobjc_install_failed" }), function(environment)
			order[#order + 1] = { "launch", #environment }
		end)
		helpers.assert_eq(world.alerts[2].body, "apps.cloner.python_offer.failed|pyobjc_install_failed")
		helpers.assert_eq(order, { { "launch", 0 } })
		restore()
	end)

	helpers.it("opens App Cloner when the failure dialog raises", function()
		local Offer, world = load("apps.cloner.python_offer.install")
		local dialog = package.loaded["infra.dialog_util"]
		local original = dialog.block_alert
		dialog.block_alert = function(...)
			if #world.alerts > 0 then error("result dialog failed") end
			return original(...)
		end
		local launched = 0
		Offer.open(owner(false, { false, "pyobjc_install_failed" }), function(environment)
			launched = launched + 1
			helpers.assert_eq(environment, {})
		end)
		helpers.assert_eq(launched, 1)
		restore()
	end)

	helpers.it("still installs after the user agrees if the progress notice raises", function()
		local Offer = load("apps.cloner.python_offer.install")
		package.loaded["infra.notifications"].notify = function() error("notification failed") end
		local double, calls = owner(false, { true, LINK })
		local launched = 0
		Offer.open(double, function() launched = launched + 1 end)
		helpers.assert_eq(calls.installs, 1)
		helpers.assert_eq(launched, 1)
		restore()
	end)
end)
