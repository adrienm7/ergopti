--- tests/unit/ui/dialogs/test_virtual_hid_update.lua

--- ==============================================================================
--- MODULE: VirtualHIDDevice Driver Update Offer Tests
--- DESCRIPTION:
--- Pins ui/virtual_hid_update.lua over a fake remap facade: nothing runs before
--- the user confirms, a cancelled administrator prompt shows nothing, a refusal
--- is reported with its reason, and only a success reloads, after the report.
---
--- ROOT CAUSE ENCODED: the driver-only update replaces the driver every
--- Karabiner on the Mac uses (ADR 011), so starting it without the explicit
--- click, or reloading before the user read the outcome, would act behind the
--- user's back.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The modules this file stubs, restored after each case so later files see the real ones.
local STUBBED = { "core.i18n.engine.i18n", "infra.dialog_util", "infra.deferred_work", "ui.virtual_hid_update" }
local ORIGINALS = {}
for _, name in ipairs(STUBBED) do ORIGINALS[name] = package.loaded[name] end

--- Puts the real modules back.
local function restore()
	for _, name in ipairs(STUBBED) do package.loaded[name] = ORIGINALS[name] end
end

--- Loads the dialog module over recorded dialogs and an immediate scheduler.
--- @param answer string|function The button the confirmation returns, by i18n key.
--- @return table Offer The module.
--- @return table world { alerts, reloads }
local function load(answer)
	local world = { alerts = {}, reloads = 0 }
	package.loaded["core.i18n.engine.i18n"] = {
		get = function(key) return key end,
		format = function(key, ...) return key .. "|" .. table.concat({ ... }, "|") end,
	}
	package.loaded["infra.dialog_util"] = {
		block_alert = function(title, body, first, second)
			world.alerts[#world.alerts + 1] = { title = title, body = body, first = first, second = second }
			if #world.alerts == 1 then return answer end
			return first
		end,
	}
	package.loaded["infra.deferred_work"] = { after = function(_, fn) fn(); return true end }
	package.loaded["ui.virtual_hid_update"] = nil
	local Offer = require("ui.virtual_hid_update")
	return Offer, world
end

--- A remap facade double whose update settles with the given outcome.
--- @param ok boolean
--- @param reason string|nil
--- @return table remap
--- @return table calls
local function remap(ok, reason)
	local calls = { updates = 0 }
	return {
		owned_virtual_hid_version = function() return "8.5.0" end,
		update_virtual_hid_driver = function(on_done)
			calls.updates = calls.updates + 1
			on_done(ok, reason)
			return true
		end,
	}, calls
end

helpers.describe("VirtualHIDDevice driver update offer", function()
	helpers.it("names the version and starts nothing until the user confirms", function()
		local Offer, world = load("common.later")
		local facade, calls = remap(true)
		helpers.assert_eq(Offer.open(facade, function() world.reloads = world.reloads + 1 end), false)
		helpers.assert_eq(calls.updates, 0)
		helpers.assert_eq(world.alerts[1].body, "karabiner.vhid_update.body|8.5.0")
		helpers.assert_eq(world.alerts[1].first, "karabiner.vhid_update.confirm")
		helpers.assert_eq(world.reloads, 0)
		restore()
	end)

	helpers.it("reports a success, then reloads", function()
		local Offer, world = load("karabiner.vhid_update.confirm")
		local facade, calls = remap(true)
		local order = {}
		world.alerts = setmetatable(world.alerts, { __newindex = function(t, k, v) order[#order + 1] = "alert"; rawset(t, k, v) end })
		helpers.assert_eq(Offer.open(facade, function() order[#order + 1] = "reload" end), true)
		helpers.assert_eq(calls.updates, 1)
		helpers.assert_eq(world.alerts[2].body, "karabiner.vhid_update.done")
		helpers.assert_eq(order, { "alert", "alert", "reload" })
		restore()
	end)

	helpers.it("reloads after a successful install even if its result dialog fails", function()
		local Offer, world = load("karabiner.vhid_update.confirm")
		local dialog = package.loaded["infra.dialog_util"]
		local original = dialog.block_alert
		dialog.block_alert = function(...)
			if #world.alerts > 0 then error("result dialog unavailable") end
			return original(...)
		end
		helpers.assert_true(Offer.open(remap(true), function() world.reloads = world.reloads + 1 end))
		helpers.assert_eq(world.reloads, 1, "the installed driver still requires a reload")
		restore()
	end)

	helpers.it("shows nothing after a cancelled administrator prompt and never reloads on a refusal", function()
		local Offer, world = load("karabiner.vhid_update.confirm")
		local facade = remap(false, "vhid_update_cancelled")
		Offer.open(facade, function() world.reloads = world.reloads + 1 end)
		helpers.assert_eq(#world.alerts, 1, "a cancelled prompt is not reported")
		local Refused, refused_world = load("karabiner.vhid_update.confirm")
		Refused.open(remap(false, "vhid_update_signature_refused"),
			function() refused_world.reloads = refused_world.reloads + 1 end)
		helpers.assert_eq(refused_world.alerts[2].body, "karabiner.vhid_update.failed|vhid_update_signature_refused")
		helpers.assert_eq(refused_world.reloads, 0)
		restore()
	end)
end)
