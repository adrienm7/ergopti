--- tests/unit/modules/keylogger/test_physical_baseline.lua

--- Exercises held input, queued history and strict paged state without native doubles.
local helpers = require("tests.helpers")
local Baseline = require("modules.keylogger.physical_baseline")

local function envelope(kind)
	return { version = 1, kind = kind, coverage = "fixture_only", incarnation = "fixture", lease = "1" }
end

local function fixture(held)
	local owner = Baseline.new({ version = 1, boundary = "200", rows = 3 })
	local page = envelope("baseline")
	page.boundary, page.offset, page.next, page.total, page.complete = "200", 0, 3, 3, true
	page.rows = {
		{ kind = "device", device = "18446744073709551615", keyboard = true, elements = 2 },
		{ kind = "key", device = "18446744073709551615", usage = 44, cookie = 109, timestamp = "100", down = held },
		{ kind = "key", device = "18446744073709551615", usage = 44, cookie = 289, timestamp = "100", down = false },
	}
	return owner, page
end

local function event(timestamp, down, cookie)
	return { device = "18446744073709551615", timestamp = tostring(timestamp),
		has_page = true, page = 7, has_usage = true, usage = 44, has_cookie = true,
		cookie = cookie or 109, value = down and "1" or "0" }
end

local function rejected(callback)
	local ok = pcall(callback)
	helpers.assert_eq(ok, false)
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
		for _, variant in ipairs({ "device", "cookie", "usage", "missing", "frontier", "opening", "backwards" }) do
			local owner, page = fixture(false)
			owner.accept(page)
			owner.accept(envelope("baseline_ready"))
			local row = event(210, true)
			if variant == "device" then row.device = "41" end
			if variant == "cookie" then row.cookie = 999 end
			if variant == "usage" then row.usage = 41 end
			if variant == "missing" then row.has_cookie = false end
			if variant == "frontier" then row.timestamp = "100" end
			if variant == "opening" then row.timestamp = "200" end
			if variant == "backwards" then owner.press(event(220, true)) end
			rejected(function() owner.press(row) end)
			helpers.assert_eq(owner.ready(), false)
			rejected(function() owner.press(event(300, false)) end)
		end
	end)
end)
