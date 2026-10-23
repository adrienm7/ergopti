--- tests/unit/modules/keystats/physical/test_physical_delivery.lua

--- Exercises decoded native delivery without claiming production capture coverage.
local helpers = require("tests.helpers")
local Delivery = require("modules.keystats.physical_delivery")
local AccountingScope = require("tests.support.physical_accounting_scope")
local Frames = require("tests.support.physical_stream_frames")
local Identity = require("modules.keystats.physical_key_identity")

-- HID usage pages and usages the identity scenarios press.
local PAGE_KEYBOARD, PAGE_CONSUMER, PAGE_TOP_CASE = 0x07, 0x0C, 0x00FF
local USAGE_A, USAGE_GRAVE, USAGE_NON_US_BACKSLASH = 0x04, 0x35, 0x64
local USAGE_MUTE, USAGE_PLAY_PAUSE = 0xE2, 0xCD

local function fixture(overrides)
	local emitted, contexts = {}, {}
	local dependencies = {
		batch_limit = 64,
		admit = function(frame)
			-- Only this isolated fixture admits the experimental producer contract.
			helpers.assert_eq(frame.coverage, "fixture_only")
			return "test-capture"
		end,
		keycode = Frames.keycode,
		context = function(timestamp, device)
			contexts[#contexts + 1] = { timestamp, device }
			return { allowed = true, app = "CapturedApp", timestamp = "2026-09-12 10:00:00.000" }
		end,
		emit = function(entry) emitted[#emitted + 1] = entry; return true end,
	}
	for key, value in pairs(overrides or {}) do dependencies[key] = value end
	return Delivery.new(dependencies), emitted, contexts
end

local function opened()
	return Frames.new("native-epoch", "18446744073709551615").opened
end

local function start(receiver)
	Frames.start(receiver, Frames.new("native-epoch", "18446744073709551615"))
end

local function batch(rows)
	local frame = opened()
	frame.baseline = nil
	frame.kind, frame.records = "batch", rows
	return frame
end

local function row(sequence, usage, value, device, page, cookie)
	return { sequence = tostring(sequence), device = device or "18446744073709551614",
		timestamp = "1844674407370955" .. string.format("%04d", sequence - 1), has_page = true, has_usage = true,
		page = page or PAGE_KEYBOARD, usage = usage, value = tostring(value), has_cookie = true,
		cookie = cookie or usage }
end

--- Opens a receiver on explicit devices, resolving keys through the real identity policy.
local function identity_fixture(devices, overrides)
	local dependencies = { keycode = Identity.resolve }
	for key, value in pairs(overrides or {}) do dependencies[key] = value end
	local receiver, emitted = fixture(dependencies)
	Frames.start(receiver, Frames.new("native-epoch", "18446744073709551615", devices))
	return receiver, emitted
end

local function rejects(callback, fragment)
	local ok, err = pcall(callback)
	helpers.assert_eq(ok, false)
	helpers.assert_true(tostring(err):find(fragment, 1, true) ~= nil, tostring(err))
end

helpers.describe("physical delivery (hs274)", function()
	helpers.it("never acknowledges a batch whose sink did not accept its physical press", function()
		for _, refusal in ipairs({ false, "accepted" }) do
			local receiver = fixture({ emit = function() return refusal end })
			start(receiver)
			rejects(function() receiver.deliver(batch({ row(1, 41, 1) })) end, "sink refused")
			helpers.assert_eq(receiver.active(), false)
		end
		local receiver = fixture({ emit = function() end })
		start(receiver)
		rejects(function() receiver.deliver(batch({ row(1, 41, 1) })) end, "sink refused")
		helpers.assert_eq(receiver.active(), false)
	end)

	helpers.it("requires complete initial state and never admits an old opening", function()
		local receiver, emitted = fixture()
		receiver.open(opened())
		rejects(function() receiver.deliver(batch({ row(1, 44, 1) })) end, "not active")
		helpers.assert_eq(#emitted, 0)
		helpers.assert_eq(receiver.active(), false)
		local old = opened()
		old.baseline = nil
		local legacy = fixture()
		rejects(function() legacy.open(old) end, "physical object")
		helpers.assert_eq(legacy.active(), false)
	end)

	helpers.it("preserves held releases and credits subsequent presses without repeated values", function()
		local receiver, emitted, contexts = fixture()
		local frames = Frames.new("native-epoch", "18446744073709551615")
		for _, key in ipairs(frames.page.rows) do
			if key.kind == "key" and key.usage == 44 then key.down = true end
		end
		Frames.start(receiver, frames)
		receiver.deliver(batch({ row(1, 44, 0), row(2, 44, 1), row(3, 44, 1), row(4, 44, 0), row(5, 44, 1) }))
		helpers.assert_eq(#emitted, 2)
		helpers.assert_eq(#contexts, 2)
		helpers.assert_eq(contexts[1][1], row(2, 44, 1).timestamp)
		helpers.assert_eq(contexts[2][1], row(5, 44, 1).timestamp)
	end)

	helpers.it("resolves keycodes using the exact originating device", function()
		local devices = { "18446744073709551613", "18446744073709551614" }
		local calls = {}
		local receiver, emitted = fixture({ keycode = function(page, usage, keyboard_type, device)
			calls[#calls + 1] = { page = page, usage = usage, keyboard_type = keyboard_type, device = device }
			if device == devices[1] then return 10 end
			if device == devices[2] then return 50 end
			error("Unknown physical device")
		end })
		start(receiver)
		receiver.deliver(batch({ row(1, 53, 1, devices[1]), row(2, 53, 1, devices[2]) }))
		helpers.assert_eq(calls, {
			{ page = PAGE_KEYBOARD, usage = 53, keyboard_type = "ansi", device = devices[1] },
			{ page = PAGE_KEYBOARD, usage = 53, keyboard_type = "ansi", device = devices[2] },
		})
		helpers.assert_eq({ emitted[1].keycode, emitted[2].keycode }, { 10, 50 })
		helpers.assert_eq({ emitted[1].device, emitted[2].device }, devices)
	end)

	helpers.it("delivers original presses to the real aggregator independently of logical output", function()
		AccountingScope.run(function(events, state)
			local receiver = fixture({ emit = function(press)
				press.action = "physical_press"
				events.walk_system_event(press)
				return true
			end })
			start(receiver)
			receiver.deliver(batch({ row(1, 41, 1), row(2, 41, 0), row(3, 44, 1), row(4, 44, 0) }))
			events.walk_typing({ timestamp = "2026-09-12 10:00:00.000", app = "CapturedApp",
				events = { { " ", 100, { s = false } }, { " ", 100, { s = false } } } })
			local counts = {}
			for _, aggregate in pairs(state.agg_batch.kc_ngram) do counts[aggregate.keycode] = aggregate.count end
			helpers.assert_eq(counts, { [53] = 1, [49] = 1 })
			helpers.assert_eq(state.agg_batch.chars_class["2026-09-12\1CapturedApp"].space, 2)
		end)
	end)

	helpers.it("retains original keys and exact capture timestamps alongside auxiliary rows", function()
		local receiver, emitted, contexts = fixture()
		start(receiver)
		receiver.deliver(batch({ row(1, -1, 41), row(2, 1, 0), row(3, 41, 1),
			row(4, 41, 0), row(5, 44, 1), row(6, 44, 0) }))
		helpers.assert_eq(#emitted, 2)
		helpers.assert_eq({ emitted[1].keycode, emitted[2].keycode }, { 53, 49 })
		helpers.assert_eq(emitted[1].capture, "test-capture")
		helpers.assert_eq(emitted[1].app, "CapturedApp")
		helpers.assert_eq(contexts[1], { "18446744073709550002", "18446744073709551614" })
	end)

	helpers.it("validates a complete batch before emitting any credit", function()
		local receiver, emitted = fixture()
		start(receiver)
		rejects(function() receiver.deliver(batch({ row(1, 41, 1), row(3, 44, 1) })) end, "sequence gap")
		helpers.assert_eq(#emitted, 0)
		helpers.assert_eq(receiver.active(), false)
	end)

	helpers.it("fences a replay and a stale lease without adding credits", function()
		for _, stale in ipairs({ false, true }) do
			local receiver, emitted = fixture()
			start(receiver)
			receiver.deliver(batch({ row(1, 41, 1) }))
			local frame = batch({ row(stale and 2 or 1, 44, 1) })
			if stale then frame.lease = "1" end
			rejects(function() receiver.deliver(frame) end, stale and "ownership changed" or "sequence gap")
			helpers.assert_eq(#emitted, 1)
		end
	end)

	helpers.it("does not replay a partially published batch after a sink failure", function()
		local calls = 0
		local receiver = fixture({ emit = function()
			calls = calls + 1
			if calls == 2 then error("sink refused") end
			return true
		end })
		start(receiver)
		local frame = batch({ row(1, 41, 1), row(2, 44, 1) })
		rejects(function() receiver.deliver(frame) end, "sink refused")
		rejects(function() receiver.deliver(frame) end, "not active")
		helpers.assert_eq(calls, 2)
	end)

	helpers.it("honors captured privacy and refuses unavailable context", function()
		local receiver, emitted = fixture({ context = function() return { allowed = false } end })
		start(receiver)
		receiver.deliver(batch({ row(1, 41, 1) }))
		helpers.assert_eq(#emitted, 0)
		helpers.assert_eq(receiver.active(), true)
		local missing = fixture({ context = function() return nil end })
		start(missing)
		rejects(function() missing.deliver(batch({ row(1, 41, 1) })) end, "context is unavailable")
	end)

	helpers.it("cannot reactivate a receiver revoked during admission", function()
		local receiver
		receiver = fixture({ admit = function() receiver.stop(); return "test-capture" end })
		rejects(function() receiver.open(opened()) end, "admission was revoked")
		helpers.assert_eq(receiver.active(), false)
	end)

	helpers.it("stops the remainder of a batch when its sink revokes delivery", function()
		local receiver, calls
		calls = 0
		receiver = fixture({ emit = function()
			helpers.assert_eq(receiver.active(), true)
			calls = calls + 1
			receiver.stop()
			return true
		end })
		start(receiver)
		rejects(function() receiver.deliver(batch({ row(1, 41, 1), row(2, 44, 1) })) end, "delivery was revoked")
		helpers.assert_eq(calls, 1)
		helpers.assert_eq(receiver.active(), false)
	end)

	helpers.it("refuses unadmitted coverage and active HID errors", function()
		local refused = fixture({ admit = function() return nil end })
		rejects(function() refused.open(opened()) end, "coverage was not admitted")
		local receiver, emitted = fixture()
		start(receiver)
		rejects(function() receiver.deliver(batch({ row(1, 41, 1), row(2, 1, 1) })) end, "keyboard error")
		helpers.assert_eq(#emitted, 0)
	end)

	helpers.it("tallies an unattributed press as uncounted coverage instead of retiring the capture", function()
		local receiver, emitted = fixture()
		start(receiver)
		receiver.deliver(batch({ row(1, 53, 1), row(2, 53, 0), row(3, 41, 1), row(4, 53, 1) }))
		helpers.assert_eq(receiver.active(), true)
		helpers.assert_eq(#emitted, 1)
		helpers.assert_eq(emitted[1].keycode, 53)
		receiver.deliver(batch({ row(5, 44, 1) }))
		helpers.assert_eq(#emitted, 2, "later presses are still credited")
		helpers.assert_eq(receiver.uncounted(), {
			{ page = PAGE_KEYBOARD, usage = 53, keyboard_type = "ansi", reason = "unmapped_usage", count = 2 },
		})
	end)

	helpers.it("tallies nothing for a privacy-excluded press or a batch that fails", function()
		local private = fixture({ context = function() return { allowed = false } end })
		start(private)
		private.deliver(batch({ row(1, 53, 1) }))
		helpers.assert_eq(private.uncounted(), {})
		local receiver = fixture()
		start(receiver)
		rejects(function() receiver.deliver(batch({ row(1, 53, 1), row(3, 41, 1) })) end, "sequence gap")
		helpers.assert_eq(receiver.uncounted(), {})
	end)

	helpers.it("fences a keycode resolver that neither attributes a press nor says why", function()
		local receiver, emitted = fixture({ keycode = function() return nil end })
		start(receiver)
		rejects(function() receiver.deliver(batch({ row(1, 41, 1) })) end, "has no reason")
		helpers.assert_eq(#emitted, 0)
		helpers.assert_eq(receiver.active(), false)
	end)

	helpers.it("resolves the keys left of 1 and left of Z by each device's keyboard type", function()
		local ansi, iso = "18446744073709551613", "18446744073709551614"
		local keys = { { page = PAGE_KEYBOARD, usage = USAGE_GRAVE, cookie = 1 },
			{ page = PAGE_KEYBOARD, usage = USAGE_NON_US_BACKSLASH, cookie = 2 } }
		local receiver, emitted = identity_fixture({
			{ id = ansi, keyboard_type = "ansi", keys = keys }, { id = iso, keyboard_type = "iso", keys = keys },
		})
		receiver.deliver(batch({
			row(1, USAGE_GRAVE, 1, ansi, PAGE_KEYBOARD, 1), row(2, USAGE_NON_US_BACKSLASH, 1, ansi, PAGE_KEYBOARD, 2),
			row(3, USAGE_GRAVE, 1, iso, PAGE_KEYBOARD, 1), row(4, USAGE_NON_US_BACKSLASH, 1, iso, PAGE_KEYBOARD, 2),
		}))
		local keycodes = {}
		for index, press in ipairs(emitted) do keycodes[index] = press.keycode end
		helpers.assert_eq(keycodes, { 50, 10, 10, 50 })
		helpers.assert_eq(receiver.uncounted(), {})
	end)

	helpers.it("leaves only the swap pair uncounted on a keyboard type the registry lacks", function()
		local jis = "18446744073709551614"
		local receiver, emitted = identity_fixture({ { id = jis, keyboard_type = "jis", keys = {
			{ page = PAGE_KEYBOARD, usage = USAGE_A, cookie = 1 },
			{ page = PAGE_KEYBOARD, usage = USAGE_GRAVE, cookie = 2 },
		} } })
		receiver.deliver(batch({ row(1, USAGE_A, 1, jis, PAGE_KEYBOARD, 1), row(2, USAGE_GRAVE, 1, jis, PAGE_KEYBOARD, 2) }))
		helpers.assert_eq(#emitted, 1)
		helpers.assert_eq(emitted[1].keycode, 0)
		helpers.assert_eq(receiver.uncounted(), {
			{ page = PAGE_KEYBOARD, usage = USAGE_GRAVE, keyboard_type = "jis",
				reason = Identity.REASON_KEYBOARD_TYPE, count = 1 },
		})
	end)

	helpers.it("counts fn/globe and consumer media keys from their own pages", function()
		local keyboard, consumer = "18446744073709551613", "18446744073709551614"
		local receiver, emitted = identity_fixture({
			{ id = keyboard, keyboard_type = "iso", keys = {
				{ page = PAGE_KEYBOARD, usage = USAGE_A, cookie = 1 },
				{ page = PAGE_TOP_CASE, usage = Identity.USAGE_APPLE_FUNCTION, cookie = 2 },
			} },
			{ id = consumer, keyboard = false, keys = {
				{ page = PAGE_CONSUMER, usage = USAGE_MUTE, cookie = 7 },
				{ page = PAGE_CONSUMER, usage = USAGE_PLAY_PAUSE, cookie = 8 },
			} },
		})
		receiver.deliver(batch({
			row(1, Identity.USAGE_APPLE_FUNCTION, 1, keyboard, PAGE_TOP_CASE, 2),
			row(2, Identity.USAGE_APPLE_FUNCTION, 0, keyboard, PAGE_TOP_CASE, 2),
			row(3, USAGE_MUTE, 1, consumer, PAGE_CONSUMER, 7),
			row(4, USAGE_PLAY_PAUSE, 1, consumer, PAGE_CONSUMER, 8),
		}))
		local keycodes = {}
		for index, press in ipairs(emitted) do keycodes[index] = press.keycode end
		helpers.assert_eq(keycodes, { 63, 74 })
		helpers.assert_eq(receiver.uncounted(), {
			{ page = PAGE_CONSUMER, usage = USAGE_PLAY_PAUSE, keyboard_type = "none",
				reason = Identity.REASON_UNMAPPED, count = 1 },
		})
	end)
end)

--- Creates a shared media policy independently of the native delivery capability.
local function semantic_policy()
	local file = assert(io.open(helpers.shared("data/keycodes/metrics_media_keys.json"), "rb"))
	local text = file:read("*a"); assert(file:close())
	return require("keystats.media_identity").new(require("json").decode(text))
end

local MEDIA_DEVICE = "18446744073709551614"
local MEDIA_ELEMENTS = {
	{ page = 12, usage = 205, cookie = 1 }, { page = 12, usage = 181, cookie = 2 },
	{ page = 12, usage = 182, cookie = 3 }, { page = 12, usage = 111, cookie = 4 },
	{ page = 12, usage = 112, cookie = 5 }, { page = 12, usage = 226, cookie = 6 },
	{ page = 12, usage = 176, cookie = 7 },
}

helpers.describe("opt-in semantic media delivery", function()
	helpers.it("delivers all five semantic presses and keeps the numeric volume identity separate", function()
		local policy, media_rows = semantic_policy(), {}
		local receiver, numeric = identity_fixture({ { id = MEDIA_DEVICE, keyboard = false, keys = MEDIA_ELEMENTS } }, {
			media = { resolve = policy.resolve_hid, is_known = policy.is_known,
				emit = function(press) media_rows[#media_rows + 1] = press; return true end },
		})
		local records = {}
		for index, element in ipairs(MEDIA_ELEMENTS) do
			records[#records + 1] = row(index, element.usage, 1, MEDIA_DEVICE, 12, element.cookie)
		end
		helpers.assert_eq(receiver.deliver(batch(records)), "7")
		local identities = {}
		for _, press in ipairs(media_rows) do
			identities[#identities + 1] = press.media_id
			helpers.assert_nil(press.keycode)
			helpers.assert_eq(press.capture, "test-capture")
			helpers.assert_eq(press.device, MEDIA_DEVICE)
		end
		helpers.assert_eq(identities, { "media.play_pause", "media.next_track", "media.previous_track",
			"media.brightness_up", "media.brightness_down" })
		helpers.assert_eq(#numeric, 1)
		helpers.assert_eq(numeric[1].keycode, 74)
		helpers.assert_nil(numeric[1].media_id)
		helpers.assert_eq(receiver.uncounted(), { { page = 12, usage = 176, keyboard_type = "none",
			reason = Identity.REASON_UNMAPPED, count = 1 } })
	end)

	helpers.it("keeps omitted capability and repeated physical media edges in their original default paths", function()
		local receiver, numeric = identity_fixture({ { id = MEDIA_DEVICE, keyboard = false, keys = MEDIA_ELEMENTS } })
		receiver.deliver(batch({ row(1, 205, 1, MEDIA_DEVICE, 12, 1), row(2, 205, 1, MEDIA_DEVICE, 12, 1) }))
		helpers.assert_eq(numeric, {})
		helpers.assert_eq(receiver.uncounted(), { { page = 12, usage = 205, keyboard_type = "none",
			reason = Identity.REASON_UNMAPPED, count = 1 } })
		local policy, media = semantic_policy(), {}
		receiver = identity_fixture({ { id = MEDIA_DEVICE, keyboard = false, keys = MEDIA_ELEMENTS } }, {
			media = { resolve = policy.resolve_hid, is_known = policy.is_known,
				emit = function(press) media[#media + 1] = press; return true end },
		})
		receiver.deliver(batch({ row(1, 205, 1, MEDIA_DEVICE, 12, 1), row(2, 205, 1, MEDIA_DEVICE, 12, 1) }))
		helpers.assert_eq(#media, 1)
		helpers.assert_eq(receiver.uncounted(), {})
	end)

	helpers.it("retains initial-down suppression for semantic media and counts only a fresh edge", function()
		local policy, media = semantic_policy(), {}
		local receiver = fixture({ keycode = Identity.resolve, media = {
			resolve = policy.resolve_hid, is_known = policy.is_known,
			emit = function(press) media[#media + 1] = press; return true end,
		} })
		local frames = Frames.new("native-epoch", "18446744073709551615", {
			{ id = MEDIA_DEVICE, keyboard = false, keys = { { page = 12, usage = 205, cookie = 1, down = true } } },
		})
		for _, initial_row in ipairs(frames.page.rows) do
			if initial_row.kind == "key" then initial_row.down = true end
		end
		Frames.start(receiver, frames)
		receiver.deliver(batch({ row(1, 205, 1, MEDIA_DEVICE, 12, 1), row(2, 205, 0, MEDIA_DEVICE, 12, 1),
			row(3, 205, 1, MEDIA_DEVICE, 12, 1) }))
		helpers.assert_eq(#media, 1)
	end)

	helpers.it("never credits media excluded by the same captured privacy context", function()
		local policy, media = semantic_policy(), {}
		local receiver = identity_fixture({ { id = MEDIA_DEVICE, keyboard = false, keys = MEDIA_ELEMENTS } }, {
			context = function() return { allowed = false } end,
			media = { resolve = policy.resolve_hid, is_known = policy.is_known,
				emit = function(press) media[#media + 1] = press; return true end },
		})
		helpers.assert_eq(receiver.deliver(batch({ row(1, 205, 1, MEDIA_DEVICE, 12, 1) })), "1")
		helpers.assert_eq(media, {})
		helpers.assert_eq(receiver.uncounted(), {})
	end)

	for _, refused in ipairs({ false, "accepted" }) do
		helpers.it("fences semantic media sink refusal " .. tostring(refused) .. " without false batch acknowledgement", function()
			local policy = semantic_policy()
			local receiver = identity_fixture({ { id = MEDIA_DEVICE, keyboard = false, keys = MEDIA_ELEMENTS } }, {
				media = { resolve = policy.resolve_hid, is_known = policy.is_known, emit = function() return refused end },
			})
			rejects(function() receiver.deliver(batch({ row(1, 205, 1, MEDIA_DEVICE, 12, 1) })) end,
				"Physical sink refused the press")
			helpers.assert_eq(receiver.active(), false)
		end)
	end

	for _, invalid in ipairs({ false, 205, "keyboard.play_pause", "media.unknown" }) do
		helpers.it("refuses unadmitted semantic identity " .. tostring(invalid) .. " before a sink sees it", function()
			local policy, media = semantic_policy(), {}
			local receiver = identity_fixture({ { id = MEDIA_DEVICE, keyboard = false, keys = MEDIA_ELEMENTS } }, {
				media = { resolve = function() return invalid end, is_known = policy.is_known,
					emit = function(press) media[#media + 1] = press; return true end },
			})
			rejects(function() receiver.deliver(batch({ row(1, 205, 1, MEDIA_DEVICE, 12, 1) })) end,
				"Invalid semantic media identity")
			helpers.assert_eq(media, {})
		end)
	end

	helpers.it("qualifies the entire batch before the first semantic media publication", function()
		local policy, media = semantic_policy(), {}
		local receiver = identity_fixture({ { id = MEDIA_DEVICE, keyboard = false, keys = MEDIA_ELEMENTS } }, {
			media = { resolve = policy.resolve_hid, is_known = policy.is_known,
				emit = function(press) media[#media + 1] = press; return true end },
		})
		local invalid = row(2, 181, 1, MEDIA_DEVICE, 12, 2); invalid.sequence = "3"
		rejects(function() receiver.deliver(batch({ row(1, 205, 1, MEDIA_DEVICE, 12, 1), invalid })) end,
			"Physical sequence gap or replay")
		helpers.assert_eq(media, {})
	end)

	helpers.it("refuses reentrant media resolution after the exact delivery owner stops", function()
		local policy, media, receiver = semantic_policy(), {}, nil
		receiver = identity_fixture({ { id = MEDIA_DEVICE, keyboard = false, keys = MEDIA_ELEMENTS } }, {
			media = { resolve = function(page, usage) receiver.stop(); return policy.resolve_hid(page, usage) end,
				is_known = policy.is_known, emit = function(press) media[#media + 1] = press; return true end },
		})
		rejects(function() receiver.deliver(batch({ row(1, 205, 1, MEDIA_DEVICE, 12, 1) })) end,
			"Physical delivery was revoked")
		helpers.assert_eq(media, {})
	end)

	for _, missing in ipairs({ "resolve", "is_known", "emit" }) do
		helpers.it("requires the explicit media callback " .. missing, function()
			local policy = semantic_policy()
			local capability = { resolve = policy.resolve_hid, is_known = policy.is_known, emit = function() return true end }
			capability[missing] = nil
			rejects(function() fixture({ media = capability }) end, "Missing semantic media port: " .. missing)
		end)
	end
end)
