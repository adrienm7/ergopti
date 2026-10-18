--- tests/unit/modules/keylogger/physical/test_physical_key_identity.lua

--- ==============================================================================
--- MODULE: Physical key identity
--- DESCRIPTION:
--- Checks that a raw HID usage resolves to the macOS keycode the metrics store
--- for that physical key: through the shared registry on either keyboard form,
--- with the ISO swap of the keys left of 1 and left of Z, fn/globe on both Apple
--- vendor pages, the further usages real keyboards send for known keys (Non-US #,
--- F13 to F20, keypad =, the JIS keys), and an explicit reason for every usage
--- without an identity.
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
local USAGE_NON_US_HASH = 0x32
local USAGE_F21 = 0x70

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

	helpers.it("resolves the PC ISO key left of Return as Backslash on every keyboard type", function()
		for _, keyboard_type in ipairs({ "ansi", "iso", "jis" }) do
			helpers.assert_eq(Identity.resolve(PAGE_KEYBOARD, USAGE_NON_US_HASH, keyboard_type), 42,
				"Non-US # on " .. keyboard_type)
		end
	end)

	helpers.it("resolves the keys real keyboards send that no layer can bind", function()
		for _, case in ipairs({
			{ 0x46, 105, "PrintScreen is F13 on macOS" },
			{ 0x47, 107, "ScrollLock is F14 on macOS" },
			{ 0x48, 113, "Pause is F15 on macOS" },
			{ 0x67, 81, "keypad =" },
			{ 0x68, 105, "F13" }, { 0x69, 107, "F14" }, { 0x6A, 113, "F15" }, { 0x6B, 106, "F16" },
			{ 0x6C, 64, "F17" }, { 0x6D, 79, "F18" }, { 0x6E, 80, "F19" }, { 0x6F, 90, "F20" },
			{ 0x85, 95, "JIS keypad comma" }, { 0x87, 94, "JIS Ro" }, { 0x89, 93, "JIS Yen" },
			{ 0x90, 104, "JIS Kana" }, { 0x91, 102, "JIS Eisu" },
			{ 0x7F, 74, "keyboard-page Mute" }, { 0x80, 72, "keyboard-page Volume Up" },
			{ 0x81, 73, "keyboard-page Volume Down" },
		}) do
			helpers.assert_eq(Identity.resolve(PAGE_KEYBOARD, case[1], "jis"), case[2], case[3])
		end
	end)

	helpers.it("gives every usage without an identity a reason instead of a guess", function()
		for _, case in ipairs({
			{ PAGE_KEYBOARD, USAGE_F21, "ansi" },   -- F21: no macOS keycode
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

--- Reads the independent handwritten media vectors, not generated expectations.
---@return table vectors Frozen source-independent behavior.
local function media_vectors()
	local file = assert(io.open(helpers.shared("tests/corpus/keylogger/media_identity_vectors.json"), "rb"))
	local text = file:read("*a"); assert(file:close())
	return Json.decode(text)
end

local function media_policy()
	helpers.assert_type(Identity.media_policy, "function", "the explicit semantic identity API must exist")
	return Identity.media_policy(keycode_data("metrics_media_keys.json"))
end

helpers.describe("closed semantic media identity", function()
	helpers.it("resolves the five independent consumer identities without inventing a virtual keycode", function()
		local policy = media_policy()
		for _, vector in ipairs(media_vectors().positive) do
			helpers.assert_eq(policy.resolve_hid(vector.page, vector.usage), vector.id)
			helpers.assert_eq(policy.resolve_system_name(vector.system), vector.id)
			helpers.assert_eq(policy.resolve_evdev(vector.evdev), vector.id)
			helpers.assert_eq(policy.label_key(vector.id), vector.label)
			helpers.assert_true(policy.is_known(vector.id))
			helpers.assert_nil(Identity.resolve(vector.page, vector.usage, "none"), "the numeric API keeps its old refusal")
		end
	end)

	helpers.it("keeps volumes, vendor guesses and unknown values outside the new semantic namespace", function()
		local policy = media_policy()
		for _, vector in ipairs(media_vectors().negative_hid) do
			helpers.assert_nil(policy.resolve_hid(vector[1], vector[2]))
		end
		for _, value in ipairs({ -1, 1.5, math.huge, "205", {} }) do
			helpers.assert_nil(policy.resolve_hid(12, value))
			helpers.assert_nil(policy.resolve_evdev(value))
			helpers.assert_eq(policy.is_known(value), false)
		end
		helpers.assert_eq(policy.is_known("media.unknown"), false)
		helpers.assert_nil(policy.resolve_system_name("SOUND_UP"))
		helpers.assert_eq(Identity.resolve(12, 0xE2, "none"), 74)
		helpers.assert_eq(Identity.resolve(12, 0xE9, "none"), 72)
		helpers.assert_eq(Identity.resolve(12, 0xEA, "none"), 73)
	end)

	helpers.it("freezes admitted identity mappings independently of caller catalogue mutation", function()
		local catalogue = keycode_data("metrics_media_keys.json")
		local policy = Identity.media_policy(catalogue)
		catalogue.keys[1].id, catalogue.keys[1].hid.usage = "media.changed", 1
		catalogue.keys[1].label_key, catalogue.keys[1].macos_system = "sg_actions.changed", "CHANGED"
		catalogue.keys[1].linux_evdev = 1
		helpers.assert_eq(policy.resolve_hid(12, 205), "media.play_pause")
		helpers.assert_eq(policy.resolve_system_name("PLAY"), "media.play_pause")
		helpers.assert_eq(policy.resolve_evdev(164), "media.play_pause")
		helpers.assert_eq(policy.label_key("media.play_pause"), "sg_actions.track_play")
		helpers.assert_eq(policy.is_known("media.changed"), false)
	end)

	for _, invalid in ipairs({ "version", "namespace", "extra", "page", "usage", "duplicate_usage", "duplicate_id", "duplicate_system", "duplicate_evdev", "hole" }) do
		helpers.it("refuses malformed media catalogue " .. invalid, function()
			local catalogue = keycode_data("metrics_media_keys.json")
			if invalid == "version" then catalogue.schema_version = 2 end
			if invalid == "namespace" then catalogue.keys[1].id = "keyboard.play_pause" end
			if invalid == "extra" then catalogue.keys[1].path = "arbitrary-private-data" end
			if invalid == "page" then catalogue.keys[1].hid.page = 7 end
			if invalid == "usage" then catalogue.keys[1].hid.usage = 65536 end
			if invalid == "duplicate_usage" then catalogue.keys[2].hid.usage = catalogue.keys[1].hid.usage end
			if invalid == "duplicate_id" then catalogue.keys[2].id = catalogue.keys[1].id end
			if invalid == "duplicate_system" then catalogue.keys[2].macos_system = catalogue.keys[1].macos_system end
			if invalid == "duplicate_evdev" then catalogue.keys[2].linux_evdev = catalogue.keys[1].linux_evdev end
			if invalid == "hole" then catalogue.keys[2] = nil end
			helpers.assert_type(Identity.media_policy, "function", "malformed catalogues must reach a real validator")
			local ok, failure = pcall(Identity.media_policy, catalogue)
			helpers.assert_eq(ok, false)
			helpers.assert_type(failure, "string", "invalid input must raise an explicit error")
		end)
	end
end)

local function media_entry(id)
	return { capture = "source/8", device = "18446744073709551615", media_id = id,
		app = "CapturedApp", timestamp = "2026-10-13 12:00:00.000" }
end

helpers.describe("media-only aggregate interface", function()
	helpers.it("credits media presses and matched holds without introducing keycode or text rows", function()
		local policy, press, hold = media_policy(), {}, {}
		for _, id in ipairs({ "media.play_pause", "media.next_track", "media.play_pause" }) do
			policy.aggregate_press(press, media_entry(id))
		end
		for id, count in pairs(media_vectors().press_expected) do
			local row = press["2026-10-13\1CapturedApp\1" .. id]
			helpers.assert_eq(row, { date = "2026-10-13", app = "CapturedApp", media_id = id, count = count })
		end
		local entry = media_entry("media.play_pause")
		entry.hold_ms = 150; policy.aggregate_hold(hold, entry, 150)
		entry.hold_ms = 201; local row = policy.aggregate_hold(hold, entry, 150)
		for key, value in pairs(media_vectors().hold_expected) do helpers.assert_eq(row[key], value) end
		helpers.assert_nil(row.keycode)
		helpers.assert_nil(row.text)
		helpers.assert_nil(row.wpm)
		helpers.assert_eq(press["2026-10-13\1CapturedApp\1media.play_pause"].count, 2, "release never adds a press")
	end)

	helpers.it("partitions captured dates and applications without leaking capture/device metadata into projections", function()
		local policy, press = media_policy(), {}
		local entry = media_entry("media.play_pause")
		policy.aggregate_press(press, entry)
		entry.app = "OtherApp"; policy.aggregate_press(press, entry)
		entry.timestamp = "2026-10-14 00:00:00.000"; policy.aggregate_press(press, entry)
		local count = 0
		for _, row in pairs(press) do
			count = count + 1
			helpers.assert_eq(row.count, 1)
			helpers.assert_nil(row.capture); helpers.assert_nil(row.device)
		end
		helpers.assert_eq(count, 3)
	end)

	for _, invalid in ipairs({ "unknown", "fake_keycode", "capture", "device", "app", "timestamp" }) do
		helpers.it("refuses invalid media event " .. invalid .. " before aggregate mutation", function()
			local policy, bucket = media_policy(), {}
			local entry = media_entry("media.play_pause")
			if invalid == "unknown" then entry.media_id = "media.unknown" end
			if invalid == "fake_keycode" then entry.keycode = 205 end
			if invalid == "capture" then entry.capture = "" end
			if invalid == "device" then entry.device = "18446744073709551616" end
			if invalid == "app" then entry.app = nil end
			if invalid == "timestamp" then entry.timestamp = "invalid" end
			local ok, failure = pcall(policy.aggregate_press, bucket, entry)
			helpers.assert_eq(ok, false)
			helpers.assert_type(failure, "string", "invalid input must raise an explicit error")
			helpers.assert_eq(bucket, {})
		end)
	end

	for _, invalid in ipairs({ -1, 0.5, math.huge, "150" }) do
		helpers.it("rejects invalid media duration " .. tostring(invalid) .. " without a release or press", function()
			local policy, bucket = media_policy(), {}
			local entry = media_entry("media.play_pause"); entry.hold_ms = invalid
			local ok, failure = pcall(policy.aggregate_hold, bucket, entry, 150)
			helpers.assert_eq(ok, false)
			helpers.assert_type(failure, "string", "invalid input must raise an explicit error")
			helpers.assert_eq(bucket, {})
		end)
	end

	helpers.it("refuses corrupted or saturated aggregate counters instead of returning false success", function()
		local policy, bucket = media_policy(), {}
		local entry = media_entry("media.play_pause")
		local row = policy.aggregate_press(bucket, entry)
		row.count = 2 ^ 53 - 1
		local ok, failure = pcall(policy.aggregate_press, bucket, entry)
		helpers.assert_eq(ok, false)
		helpers.assert_type(failure, "string", "invalid input must raise an explicit error")
		helpers.assert_eq(row.count, 2 ^ 53 - 1)
		entry.hold_ms = 150
		local holds = {}; local hold = policy.aggregate_hold(holds, entry, 150)
		hold.sum_ms = -1
		local ok, failure = pcall(policy.aggregate_hold, holds, entry, 150)
		helpers.assert_eq(ok, false)
		helpers.assert_type(failure, "string", "invalid input must raise an explicit error")
		helpers.assert_eq(hold.count, 1)
	end)
end)

helpers.describe("media aggregate consistency before mutation", function()
	for _, variant in ipairs({ "counts", "duration" }) do
		helpers.it("refuses inconsistent " .. variant .. " without changing the caller row", function()
			local policy, bucket = media_policy(), {}
			local entry = media_entry("media.play_pause"); entry.hold_ms = 50
			local row = { date = "2026-10-13", app = "CapturedApp", media_id = "media.play_pause",
				sum_ms = variant == "duration" and 50 or 100, count = 1, max_ms = 100,
				tap_count = variant == "counts" and 0 or 1, hold_count = 0 }
			local expected = {}; for key, value in pairs(row) do expected[key] = value end
			bucket["2026-10-13\1CapturedApp\1media.play_pause"] = row
			local ok, failure = pcall(policy.aggregate_hold, bucket, entry, 150)
			helpers.assert_eq(ok, false)
			helpers.assert_type(failure, "string", "invalid input must raise an explicit error")
			helpers.assert_eq(row, expected)
			helpers.assert_true(rawequal(bucket["2026-10-13\1CapturedApp\1media.play_pause"], row))
		end)
	end
end)
