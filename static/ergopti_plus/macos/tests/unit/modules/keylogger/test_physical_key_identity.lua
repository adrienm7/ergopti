--- tests/unit/modules/keylogger/test_physical_key_identity.lua

--- ==============================================================================
--- MODULE: Physical key identity
--- DESCRIPTION:
--- Checks that a raw HID usage resolves to the macOS keycode the metrics store
--- for that physical key: through the shared registry on either keyboard form,
--- with the ISO swap of the keys left of 1 and left of Z, fn/globe on both Apple
--- vendor pages, and an explicit reason for every usage without an identity.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Identity = require("modules.keylogger.physical_key_identity")
local Keycodes = require("keycodes")

-- HID usage pages.
local PAGE_KEYBOARD = 0x07
local PAGE_CONSUMER = 0x0C
local PAGE_TOP_CASE = 0x00FF
local PAGE_APPLE_KEYBOARD = 0xFF01

-- Keyboard-page usages of the ISO swap pair and of keys outside the registry.
local USAGE_GRAVE = 0x35
local USAGE_NON_US_BACKSLASH = 0x64
local USAGE_F13 = 0x68

--- Loads one shipped keycode data file.
--- @param name string File name under _shared/data/keycodes.
--- @return table data
local function keycode_data(name)
	local handle = assert(io.open(helpers.shared("data/keycodes/" .. name), "r"))
	local text = handle:read("a")
	handle:close()
	return Json.decode(text)
end

--- Loads the physical-key registry and its HID usages by registry key id.
--- @return table registry
--- @return table hid_usages
local function registry()
	return keycode_data("physical_keys.json"), keycode_data("hid_usages.json").keys
end

helpers.describe("physical key identity (hs274)", function()
	helpers.it("resolves every registry key to its macOS keycode on each form", function()
		local data, hid_usages = registry()
		local checked = 0
		for code, entry in pairs(data.keys) do
			if entry.kind == "key" then
				local hid = hid_usages[code]
				helpers.assert_true(type(hid) == "table", code .. " must have a HID usage")
				for _, form in ipairs(data.forms) do
					local override = type(entry["macos_" .. form]) == "table" and entry["macos_" .. form].hs
					local expected = type(override) == "number" and override or entry.hs
					helpers.assert_eq(Identity.resolve(hid.page, hid.usage, form), expected,
						code .. " on " .. form)
				end
				checked = checked + 1
			end
		end
		helpers.assert_true(checked >= 100, "the registry must yield every keyboard key, got " .. checked)
	end)

	helpers.it("swaps only the keys left of 1 and left of Z on an ISO keyboard", function()
		helpers.assert_eq(Identity.resolve(PAGE_KEYBOARD, USAGE_GRAVE, "ansi"), 50)
		helpers.assert_eq(Identity.resolve(PAGE_KEYBOARD, USAGE_NON_US_BACKSLASH, "ansi"), 10)
		helpers.assert_eq(Identity.resolve(PAGE_KEYBOARD, USAGE_GRAVE, "iso"), 10)
		helpers.assert_eq(Identity.resolve(PAGE_KEYBOARD, USAGE_NON_US_BACKSLASH, "iso"), 50)
		local _, hid_usages = registry()
		for code, hid in pairs(hid_usages) do
			if hid.usage ~= USAGE_GRAVE and hid.usage ~= USAGE_NON_US_BACKSLASH then
				helpers.assert_eq(Identity.resolve(hid.page, hid.usage, "iso"),
					Identity.resolve(hid.page, hid.usage, "ansi"), code .. " must not depend on the form")
			end
		end
	end)

	helpers.it("needs a keyboard type only for the swap pair", function()
		local keycode, reason = Identity.resolve(PAGE_KEYBOARD, USAGE_GRAVE, "jis")
		helpers.assert_eq(keycode, nil)
		helpers.assert_eq(reason, Identity.REASON_KEYBOARD_TYPE)
		helpers.assert_eq(Identity.resolve(PAGE_KEYBOARD, 0x04, "jis"), 0, "KeyA resolves on any keyboard")
		helpers.assert_eq(Identity.resolve(PAGE_KEYBOARD, 0x2C, "jis"), 49, "Space resolves on any keyboard")
	end)

	helpers.it("counts fn/globe on both Apple vendor pages as the fn keycode", function()
		helpers.assert_eq(Keycodes.FUNCTION, 63)
		helpers.assert_eq(Identity.resolve(PAGE_TOP_CASE, Identity.USAGE_APPLE_FUNCTION, "iso"), Keycodes.FUNCTION)
		helpers.assert_eq(Identity.resolve(PAGE_APPLE_KEYBOARD, Identity.USAGE_APPLE_FUNCTION, "none"),
			Keycodes.FUNCTION)
	end)

	helpers.it("counts the registry's consumer media keys", function()
		helpers.assert_eq(Identity.resolve(PAGE_CONSUMER, 0xE2, "none"), 74, "Mute")
		helpers.assert_eq(Identity.resolve(PAGE_CONSUMER, 0xE9, "none"), 72, "Volume up")
		helpers.assert_eq(Identity.resolve(PAGE_CONSUMER, 0xEA, "none"), 73, "Volume down")
	end)

	helpers.it("gives every usage without an identity a reason instead of a guess", function()
		for _, case in ipairs({
			{ PAGE_KEYBOARD, USAGE_F13, "ansi" },   -- F13: not in the registry
			{ PAGE_CONSUMER, 0xCD, "none" },        -- Play/Pause: no macOS keycode
			{ PAGE_TOP_CASE, 0x04, "ansi" },        -- a top case usage other than fn
			{ 0x08, 0x01, "ansi" },                 -- not a key page at all
		}) do
			local keycode, reason = Identity.resolve(case[1], case[2], case[3])
			helpers.assert_eq(keycode, nil)
			helpers.assert_eq(reason, Identity.REASON_UNMAPPED)
		end
	end)
end)
