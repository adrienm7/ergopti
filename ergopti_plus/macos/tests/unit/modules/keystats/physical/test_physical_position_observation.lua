--- tests/unit/modules/keystats/physical/test_physical_position_observation.lua

--- Genuine receiver controls with modeled native ports; no GUI or hardware claim.
local helpers = require("tests.helpers")
local Delivery = require("modules.keystats.physical_delivery")
local Identity = require("modules.keystats.physical_key_identity")
local Frames = require("tests.support.physical_stream_frames")
local function fixture(options)
	options = options or {}
	local emitted, received, devices = {}, {}, {}
	local receiver = Delivery.new({ batch_limit = 64, admit = function() return "fixture-capture" end,
		keycode = Identity.resolve,
		context = function() return { allowed = options.allowed ~= false, app = "FixtureApp", timestamp = "2026-10-13 00:00:00.000" } end,
		emit = function(press) emitted[#emitted + 1] = press; if options.metric then return options.metric(press) end; return true end })
	for _, id in ipairs({ "41", "42" }) do
		local keys = {}
		for _, usage in ipairs({ 4, 5, 0xE0, 0xE1, 0xE4, 0x39, 0x35, 0x64 }) do keys[#keys + 1] = { page = 7, usage = usage, cookie = usage } end
		keys[#keys + 1] = { page = 0xFF, usage = 3, cookie = 300 }
		devices[#devices + 1] = { id = id, keyboard_type = options.form or "ansi", keys = keys }
	end
	local frames = Frames.new("observed", "1", devices)
	if options.initial then for _, key in ipairs(frames.page.rows) do
		if key.kind == "key" and options.initial(key) then key.down = true end
	end end
	local function receive(facts) received[#received + 1] = facts; return true end
	local sequence = 0
	local function batch(rows)
		local records = {}
		for _, row in ipairs(rows) do
			sequence = sequence + 1
			records[#records + 1] = { sequence = tostring(sequence), device = row.device or "41", timestamp = tostring(sequence),
				has_page = true, has_usage = true, has_cookie = true, page = row.page or 7,
				usage = row.usage, cookie = row.cookie or row.usage, value = tostring(row.down == false and 0 or 1) }
		end
		return { version = 1, kind = "batch", incarnation = "observed", lease = "1", coverage = "fixture_only", records = records }
	end
	return receiver, emitted, received, frames, receive, batch
end
helpers.describe("physical position observation", function()
	helpers.it("requires completed baseline before observation", function()
		local r, _, _, frames = fixture()
		helpers.assert_eq(r.position_available(), false)
		helpers.assert_nil(r.capture_position(function() return true end, function() end))
		r.open(frames.opened); r.baseline(frames.page)
		helpers.assert_eq(r.position_available(), false)
		r.baseline(frames.ready); helpers.assert_true(r.position_available())
	end)
	helpers.it("publishes only after original metric acknowledgement and keeps facts closed", function()
		local r, emitted, received, frames, receive, batch = fixture(); Frames.start(r, frames)
		local token = r.capture_position(function() return true end, function(facts)
			helpers.assert_eq(#emitted, 1); return receive(facts)
		end)
		helpers.assert_true(type(token) == "table")
		helpers.assert_eq(r.deliver(batch({ { usage = 4 } })), "1")
		helpers.assert_eq(received, { { native_code = 0, mods = {} } })
		helpers.assert_true(r.cancel_position(token)); helpers.assert_true(r.active())
	end)
	helpers.it("freezes the modifier roster at each row before final batch state", function()
		local r, _, received, frames, receive, batch = fixture(); Frames.start(r, frames)
		r.capture_position(function() return true end, receive)
		r.deliver(batch({ { usage = 0xE1 }, { usage = 4 }, { usage = 0xE1, down = false } }))
		helpers.assert_eq(received, { { native_code = 0, mods = { shift = true } } })
	end)
	helpers.it("joins inherited modifiers but waits for a fresh primary transition", function()
		local r, _, received, frames, receive, batch = fixture({ initial = function(key)
			return key.device == "41" and (key.usage == 0xE0 or key.usage == 4)
		end }); Frames.start(r, frames); r.capture_position(function() return true end, receive)
		r.deliver(batch({ { usage = 4 } })); helpers.assert_eq(received, {})
		r.deliver(batch({ { usage = 4, down = false }, { usage = 4 } }))
		helpers.assert_eq(received, { { native_code = 0, mods = { ctrl = true } } })
	end)
	helpers.it("excludes presses preceding enrollment inside metric callbacks", function()
		local r, receive, token
		local options = { metric = function() if not token then token = r.capture_position(function() return true end, receive) end; return true end }
		local emitted, received, frames, batch
		r, emitted, received, frames, receive, batch = fixture(options); Frames.start(r, frames)
		r.deliver(batch({ { usage = 4 } })); helpers.assert_eq(received, {})
		r.deliver(batch({ { usage = 5 } })); helpers.assert_eq(received, { { native_code = 11, mods = {} } })
	end)
	for _, form in ipairs({ "ansi", "iso", "jis" }) do
		helpers.it("refuses dependent positions for " .. form, function()
			local r, _, received, frames, receive, batch = fixture({ form = form }); Frames.start(r, frames)
			r.capture_position(function() return true end, receive)
			r.deliver(batch({ { usage = 0x35 }, { usage = 0x64 }, { usage = 4 } }))
			helpers.assert_eq(received, { { native_code = 0, mods = {} } })
		end)
	end
	helpers.it("refuses mixed-device modifier joins without discarding primary metrics", function()
		local r, emitted, received, frames, receive, batch = fixture(); Frames.start(r, frames)
		r.capture_position(function() return true end, receive)
		r.deliver(batch({ { usage = 0xE0, device = "42" }, { usage = 4 } })); helpers.assert_eq(received, {})
		r.deliver(batch({ { usage = 0xE0, device = "42", down = false }, { usage = 5 } }))
		helpers.assert_eq(received, { { native_code = 11, mods = {} } }); helpers.assert_eq(#emitted, 3)
	end)
	for _, key in ipairs({ { usage = 0x39 }, { usage = 3, page = 0xFF, cookie = 300 } }) do
		helpers.it("refuses unrepresentable modifier " .. key.usage, function()
			local r, _, received, frames, receive, batch = fixture(); Frames.start(r, frames)
			r.capture_position(function() return true end, receive); r.deliver(batch({ key, { usage = 4 } }))
			helpers.assert_eq(received, {})
		end)
	end
	helpers.it("isolates refusal and exceptions from original delivery", function()
		for _, mode in ipairs({ "refuse", "throw" }) do
			local r, emitted, _, frames, _, batch = fixture(); Frames.start(r, frames)
			local calls = 0
			local token = r.capture_position(function() return true end, function()
				calls = calls + 1; if mode == "throw" then error("controlled refusal") end; return false
			end)
			helpers.assert_eq(r.deliver(batch({ { usage = 4 }, { usage = 5 } })), "2")
			helpers.assert_eq(calls, 1); helpers.assert_eq(#emitted, 2); helpers.assert_true(r.active()); helpers.assert_true(r.cancel_position(token))
		end
	end)
	helpers.it("retains cancellation debt until callback unwinds and cannot cancel a successor", function()
		local r, _, received, frames, receive, batch = fixture(); Frames.start(r, frames)
		local token
		token = r.capture_position(function() return true end, function(facts)
			helpers.assert_eq(r.cancel_position(token), false)
			helpers.assert_nil(r.capture_position(function() return true end, receive)); return receive(facts)
		end)
		r.deliver(batch({ { usage = 4 } })); helpers.assert_eq(#received, 1); helpers.assert_true(r.cancel_position(token))
		local successor = r.capture_position(function() return true end, receive); helpers.assert_true(type(successor) == "table")
		helpers.assert_true(r.cancel_position(token)); r.deliver(batch({ { usage = 5 } })); helpers.assert_eq(#received, 2)
	end)
	for _, mode in ipairs({ "false", "throw" }) do
		helpers.it("revokes only observation after page predicate " .. mode, function()
			local r, emitted, received, frames, receive, batch = fixture(); Frames.start(r, frames)
			local live = true
			local token = r.capture_position(function() if live then return true end; if mode == "throw" then error("stale") end; return false end, receive)
			live = false; helpers.assert_eq(r.deliver(batch({ { usage = 4 } })), "1")
			helpers.assert_eq(received, {}); helpers.assert_eq(#emitted, 1); helpers.assert_true(r.active()); helpers.assert_true(r.cancel_position(token))
		end)
	end
	helpers.it("excludes privacy-refused presses", function()
		local r, emitted, received, frames, receive, batch = fixture({ allowed = false }); Frames.start(r, frames)
		r.capture_position(function() return true end, receive); r.deliver(batch({ { usage = 4 } }))
		helpers.assert_eq(emitted, {}); helpers.assert_eq(received, {})
	end)
	helpers.it("preserves metric failure and revokes its observation", function()
		local r, _, received, frames, receive, batch = fixture({ metric = function() return false end }); Frames.start(r, frames)
		local token = r.capture_position(function() return true end, receive)
		local accepted, failure = pcall(r.deliver, batch({ { usage = 4 } }))
		helpers.assert_eq(accepted, false)
		helpers.assert_eq(type(failure), "string")
		helpers.assert_true(failure:find("Physical sink refused the", 1, true) ~= nil)
		helpers.assert_eq(received, {}); helpers.assert_eq(r.active(), false); helpers.assert_true(r.cancel_position(token))
	end)
	helpers.it("revokes on primary stop and refuses foreign tokens", function()
		local r, _, _, frames, receive = fixture(); Frames.start(r, frames)
		local token = r.capture_position(function() return true end, receive)
		helpers.assert_eq(r.cancel_position({}), false); r.stop()
		helpers.assert_true(r.cancel_position(token)); helpers.assert_eq(r.position_available(), false)
	end)
end)

helpers.describe("physical position observation: independently frozen reentrancy and inventory", function()
	helpers.it("keeps outer cursor1 when receive commits a nested genuine cursor2", function()
		local r, emitted, received, frames, receive, batch = fixture(); Frames.start(r, frames)
		local inner
		local token = r.capture_position(function() return true end, function(facts)
			receive(facts)
			inner = r.deliver(batch({ { usage = 5 } }))
			return true
		end)
		local outer = r.deliver(batch({ { usage = 4 } }))
		helpers.assert_eq(outer, "1"); helpers.assert_eq(inner, "2")
		helpers.assert_eq(#emitted, 2); helpers.assert_eq(received, { { native_code = 0, mods = {} } })
		helpers.assert_true(r.active()); helpers.assert_true(r.cancel_position(token))
	end)
	helpers.it("reserves outer observation across exact predicate nested primary delivery", function()
		local r, emitted, received, frames, receive, batch = fixture(); Frames.start(r, frames)
		local publishing, nested, inner = false, false, nil
		local token = r.capture_position(function()
			if publishing and not nested then
				nested = true
				inner = r.deliver(batch({ { usage = 5 } }))
			end
			return true
		end, receive)
		publishing = true
		local outer = r.deliver(batch({ { usage = 4 } }))
		helpers.assert_eq(outer, "1"); helpers.assert_eq(inner, "2")
		helpers.assert_eq(#emitted, 2); helpers.assert_eq(received, { { native_code = 0, mods = {} } })
		helpers.assert_true(r.active()); helpers.assert_true(r.cancel_position(token))
	end)
	local unavailable = {
		{ name = "consumer-only", keyboard = false, keyboard_type = "none", keys = { { page = 12, usage = 0xCD, cookie = 1 } } },
		{ name = "modifier-only", keyboard = true, keyboard_type = "ansi", keys = { { page = 7, usage = 0xE1, cookie = 1 } } },
		{ name = "form-dependent-only", keyboard = true, keyboard_type = "iso", keys = { { page = 7, usage = 0x35, cookie = 1 } } },
		{ name = "unmapped-only", keyboard = true, keyboard_type = "ansi", keys = { { page = 7, usage = 0xFE, cookie = 1 } } },
	}
	for _, spec in ipairs(unavailable) do
		helpers.it("refuses availability for an admitted " .. spec.name .. " fixed inventory", function()
			local r, _, received, _, receive = fixture()
			Frames.start(r, Frames.new("observed", "1", { { id = "41", keyboard = spec.keyboard,
				keyboard_type = spec.keyboard_type, keys = spec.keys } }))
			helpers.assert_true(r.ready(), "actual baseline admission remains intact")
			helpers.assert_true(r.active(), "candidate refusal must not stop primary metrics")
			helpers.assert_eq(r.position_available(), false)
			helpers.assert_nil(r.capture_position(function() return true end, receive))
			helpers.assert_eq(received, {})
		end)
	end
end)
