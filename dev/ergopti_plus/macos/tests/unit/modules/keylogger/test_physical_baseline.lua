--- tests/unit/modules/keylogger/test_physical_baseline.lua

--- Exercises held input, queued history and strict paged state without native doubles.
local helpers = require("tests.helpers")
local Baseline = require("modules.keylogger.physical_baseline")

-- HID usage pages.
local PAGE_KEYBOARD, PAGE_CONSUMER, PAGE_TOP_CASE = 0x07, 0x0C, 0x00FF

-- The device every scenario inventories.
local DEVICE = "18446744073709551615"

local function envelope(kind)
	return { version = 1, kind = kind, coverage = "fixture_only", incarnation = "fixture", lease = "1" }
end

--- Builds a one-page baseline for explicit device and key rows.
local function paged(rows)
	local owner = Baseline.new({ version = Baseline.VERSION, boundary = "200", rows = #rows })
	local page = envelope("baseline")
	page.boundary, page.offset, page.next, page.total, page.complete = "200", 0, #rows, #rows, true
	page.rows = rows
	return owner, page
end

local function fixture(held)
	return paged({
		{ kind = "device", device = DEVICE, keyboard = true, keyboard_type = "ansi", elements = 2 },
		{ kind = "key", device = DEVICE, page = PAGE_KEYBOARD, usage = 44, cookie = 109, timestamp = "100", down = held },
		{ kind = "key", device = DEVICE, page = PAGE_KEYBOARD, usage = 44, cookie = 289, timestamp = "100", down = false },
	})
end

local function event(timestamp, down, cookie, page, usage)
	return { device = DEVICE, timestamp = tostring(timestamp),
		has_page = true, page = page or PAGE_KEYBOARD, has_usage = true, usage = usage or 44, has_cookie = true,
		cookie = cookie or 109, value = down and "1" or "0" }
end

local function rejected(callback, fragment)
	local ok, err = pcall(callback)
	helpers.assert_eq(ok, false)
	if fragment then helpers.assert_true(tostring(err):find(fragment, 1, true) ~= nil, tostring(err)) end
end

local function ready(owner, page)
	owner.accept(page)
	owner.accept(envelope("baseline_ready"))
	helpers.assert_eq(owner.ready(), true)
end

helpers.describe("physical baseline", function()
	helpers.it("preserves an inherited release and credits only a fresh press", function()
		local owner, page = fixture(true)
		helpers.assert_eq(owner.accept(page), "3")
		helpers.assert_eq(owner.ready(), false)
		helpers.assert_eq(owner.accept(envelope("baseline_ready")), nil)
		helpers.assert_eq(owner.ready(), true)
		helpers.assert_eq(owner.press(event(90, false)), false)
		helpers.assert_eq(owner.press(event(100, true)), false)
		helpers.assert_eq(owner.press(event(210, false)), false)
		helpers.assert_eq(owner.press(event(220, true)), true)
		helpers.assert_eq(owner.press(event(230, true)), false)
		helpers.assert_eq(owner.press(event(240, false)), false)
	end)

	helpers.it("replays delayed pre-opening state and keeps same-usage cookies separate", function()
		local owner, page = fixture(false)
		owner.accept(page)
		owner.accept(envelope("baseline_ready"))
		helpers.assert_eq(owner.press(event(150, true)), false)
		helpers.assert_eq(owner.press(event(210, true)), false)
		helpers.assert_eq(owner.press(event(205, true, 289)), true)
		helpers.assert_eq(owner.press(event(220, false)), false)
		helpers.assert_eq(owner.press(event(230, true)), true)
	end)

	helpers.it("fails permanently on incomplete, repeated or contradictory baseline input", function()
		for _, variant in ipairs({ "missing", "duplicate", "future", "count", "sparse" }) do
			local owner, page = fixture(false)
			if variant == "missing" then page.kind = "baseline_ready" end
			if variant == "duplicate" then page.rows[3].cookie = 109 end
			if variant == "future" then page.rows[2].timestamp = "201" end
			if variant == "count" then page.next = 2 end
			if variant == "sparse" then page.rows[1] = nil end
			rejected(function() owner.accept(page) end)
			helpers.assert_eq(owner.ready(), false)
			rejected(function() owner.accept(envelope("baseline_ready")) end)
		end
	end)

	helpers.it("rejects unknown identity, clock conflicts and ambiguous opening transitions", function()
		for _, variant in ipairs({ "device", "cookie", "usage", "page", "missing", "frontier", "opening", "backwards" }) do
			local owner, page = fixture(false)
			owner.accept(page)
			owner.accept(envelope("baseline_ready"))
			local row = event(210, true)
			if variant == "device" then row.device = "41" end
			if variant == "cookie" then row.cookie = 999 end
			if variant == "usage" then row.usage = 41 end
			if variant == "page" then row.page = PAGE_CONSUMER end
			if variant == "missing" then row.has_cookie = false end
			if variant == "frontier" then row.timestamp = "100" end
			if variant == "opening" then row.timestamp = "200" end
			if variant == "backwards" then owner.press(event(220, true)) end
			rejected(function() owner.press(row) end)
			helpers.assert_eq(owner.ready(), false)
			rejected(function() owner.press(event(300, false)) end)
		end
	end)

	helpers.it("refuses the historical version-1 descriptor", function()
		rejected(function() Baseline.new({ version = 1, boundary = "200", rows = 3 }) end,
			"Unsupported physical baseline version")
	end)

	helpers.it("requires a keyboard type exactly for devices with keyboard-page elements", function()
		for _, variant in ipairs({ "none_on_keyboard", "unknown_type", "type_on_consumer", "missing" }) do
			local owner, page = fixture(false)
			local device = page.rows[1]
			if variant == "none_on_keyboard" then device.keyboard_type = "none" end
			if variant == "unknown_type" then device.keyboard_type = "qwertz" end
			if variant == "type_on_consumer" then
				device.keyboard, device.keyboard_type = false, "ansi"
			end
			if variant == "missing" then device.keyboard_type = nil end
			rejected(function() owner.accept(page) end)
			helpers.assert_eq(owner.ready(), false)
		end
		for _, keyboard_type in ipairs({ "ansi", "iso", "jis" }) do
			local owner, page = fixture(false)
			page.rows[1].keyboard_type = keyboard_type
			ready(owner, page)
			helpers.assert_eq(owner.keyboard_type(DEVICE), keyboard_type)
		end
	end)

	helpers.it("tracks consumer elements on a consumer interface and keeps keyboard keys off it", function()
		local owner, page = paged({
			{ kind = "device", device = DEVICE, keyboard = false, keyboard_type = "none", elements = 1 },
			{ kind = "key", device = DEVICE, page = PAGE_CONSUMER, usage = 0xE2, cookie = 7, timestamp = "100", down = false },
		})
		ready(owner, page)
		helpers.assert_eq(owner.keyboard_type(DEVICE), "none")
		helpers.assert_eq(owner.press(event(210, true, 7, PAGE_CONSUMER, 0xE2)), true)
		helpers.assert_eq(owner.press(event(220, false, 7, PAGE_CONSUMER, 0xE2)), false)
		rejected(function() owner.press(event(230, true, 7, PAGE_KEYBOARD, 44)) end,
			"Keyboard input arrived on a consumer interface")
		local refused, keyboard_page = paged({
			{ kind = "device", device = DEVICE, keyboard = false, keyboard_type = "none", elements = 1 },
			{ kind = "key", device = DEVICE, page = PAGE_KEYBOARD, usage = 44, cookie = 7, timestamp = "100", down = false },
		})
		rejected(function() refused.accept(keyboard_page) end, "Keyboard element on a physical consumer interface")
	end)

	helpers.it("treats a held fn/globe as a key while keyboard error usages stay errors", function()
		local owner, page = paged({
			{ kind = "device", device = DEVICE, keyboard = true, keyboard_type = "iso", elements = 1 },
			{ kind = "key", device = DEVICE, page = PAGE_TOP_CASE, usage = 3, cookie = 5, timestamp = "100", down = true },
		})
		ready(owner, page)
		helpers.assert_eq(owner.press(event(210, false, 5, PAGE_TOP_CASE, 3)), false)
		helpers.assert_eq(owner.press(event(220, true, 5, PAGE_TOP_CASE, 3)), true)
		local refused, error_page = paged({
			{ kind = "device", device = DEVICE, keyboard = true, keyboard_type = "iso", elements = 1 },
			{ kind = "key", device = DEVICE, page = PAGE_KEYBOARD, usage = 3, cookie = 5, timestamp = "100", down = true },
		})
		rejected(function() refused.accept(error_page) end, "Invalid physical baseline value")
	end)

	helpers.it("ignores observations on pages that carry no keys", function()
		local owner, page = fixture(false)
		ready(owner, page)
		helpers.assert_eq(owner.press(event(210, true, 1, 0x08, 1)), false)
		helpers.assert_eq(owner.ready(), true)
		local unkeyed, element_page = paged({
			{ kind = "device", device = DEVICE, keyboard = true, keyboard_type = "ansi", elements = 1 },
			{ kind = "key", device = DEVICE, page = 0x08, usage = 1, cookie = 5, timestamp = "100", down = false },
		})
		rejected(function() unkeyed.accept(element_page) end, "not on a key page")
	end)
end)
