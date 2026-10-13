--- tests/unit/modules/keylogger/test_physical_holds.lua

--- Matches physical releases against immutable accepted presses and retained intervals.
local helpers = require("tests.helpers")
local Delivery = require("modules.keylogger.physical_delivery")
local Clock = require("modules.keylogger.physical_clock")
local Context = require("modules.keylogger.physical_context")
local Frames = require("tests.support.physical_stream_frames")
local with_capture = require("tests.support.physical_capture_fixture").run
local ORIGINAL_DATE = "2026-10-04 23:59:59.500"

local function copy(entry)
	local snapshot = {}
	for name, value in pairs(entry) do snapshot[name] = value end
	return snapshot
end

local function row(sequence, ticks, down, device, cookie, usage)
	return { sequence = tostring(sequence), timestamp = tostring(ticks), value = down and "1" or "0",
		device = device or "41", has_page = true, has_usage = true, page = 7, usage = usage or 44,
		has_cookie = true, cookie = cookie or 44 }
end

local function fixture(overrides)
	overrides = overrides or {}
	local observed = { events = {}, releases = {}, presses = {}, intervals = {} }
	local frames = Frames.new("holds", overrides.lease or "8", {
		{ id = "41", keys = { { page = 7, usage = 44, cookie = 44 },
			{ page = 7, usage = 44, cookie = 45 }, { page = 7, usage = 53, cookie = 53 } } },
		"42",
	})
	local convert = Clock.new({ version = 1, domain = "mach_absolute_time", numer = 125, denom = 3 })
	local history = Context.new(8, function(epoch)
		return epoch < 1500 and ORIGINAL_DATE or "2026-10-05 00:00:00.500"
	end)
	history.observe(0, { allowed = true, app = "Original", epoch = 1000 })
	local dependencies = { batch_limit = 16,
		admit = function(frame) return frame.incarnation .. "/" .. frame.lease end,
		keycode = Frames.keycode,
		context = function(ticks) return history.resolve(convert(ticks)) end,
		emit = function(press)
			observed.presses[#observed.presses + 1] = copy(press)
			observed.events[#observed.events + 1] = { kind = "press", entry = copy(press) }
			return true
		end,
		holds = {
			convert = convert,
			context = function(first, last, device)
				observed.intervals[#observed.intervals + 1] = { first, last, device }
				return history.resolve_interval(convert(first), convert(last))
			end,
			emit = function(release)
				observed.releases[#observed.releases + 1] = copy(release)
				observed.events[#observed.events + 1] = { kind = "release", entry = copy(release) }
				return true
			end,
		},
	}
	for name, value in pairs(overrides) do if name ~= "lease" then dependencies[name] = value end end
	local receiver = Delivery.new(dependencies)
	local function batch(records)
		return { version = 1, kind = "batch", incarnation = "holds", lease = frames.opened.lease,
			coverage = "fixture_only", records = records }
	end
	return { receiver = receiver, observed = observed, frames = frames, history = history,
		dependencies = dependencies, convert = convert, batch = batch,
		start = function() Frames.start(receiver, frames) end }
end

local function rejects(callback, reason)
	local ok, failure = pcall(callback)
	helpers.assert_eq(ok, false)
	helpers.assert_true(tostring(failure):find(reason, 1, true) ~= nil, tostring(failure))
end

helpers.describe("matched physical hold delivery", function()
	helpers.it("publishes one press then its HID duration in mixed FIFO order", function()
		local f = fixture()
		f.start()
		helpers.assert_eq(f.receiver.deliver(f.batch({ row(1, 24000000, true), row(2, 30120000, false) })), "2")
		helpers.assert_eq(f.observed.events, {
			{ kind = "press", entry = { capture = "holds/8", device = "41", keycode = 49,
				app = "Original", timestamp = ORIGINAL_DATE } },
			{ kind = "release", entry = { capture = "holds/8", device = "41", keycode = 49,
				app = "Original", timestamp = ORIGINAL_DATE, hold_ms = 255 } },
		})
		helpers.assert_eq(f.observed.intervals, { { "24000000", "30120000", "41" } })
	end)

	helpers.it("retains matches across batches without crediting repeat values or a second press", function()
		local f = fixture()
		f.start()
		f.receiver.deliver(f.batch({ row(1, 24000000, true), row(2, 24000001, true) }))
		f.receiver.deliver(f.batch({ row(3, 30024000, false), row(4, 30024001, false) }))
		f.receiver.deliver(f.batch({ row(5, 36000000, true), row(6, 36120000, false) }))
		helpers.assert_eq(#f.observed.presses, 2)
		helpers.assert_eq(#f.observed.releases, 2)
		helpers.assert_eq(f.observed.releases[1].hold_ms, 251)
		helpers.assert_eq(f.observed.releases[2].hold_ms, 5)
	end)

	helpers.it("inherits no hold from baseline and matches only a subsequent fresh press", function()
		local f = fixture()
		f.frames.page.rows[2].down = true
		f.start()
		f.receiver.deliver(f.batch({ row(1, 24000000, false) }))
		helpers.assert_eq(f.observed.events, {})
		f.receiver.deliver(f.batch({ row(2, 36000000, true), row(3, 36120000, false) }))
		helpers.assert_eq(#f.observed.presses, 1)
		helpers.assert_eq(#f.observed.releases, 1)
		helpers.assert_eq(f.observed.releases[1].hold_ms, 5)
	end)

	helpers.it("matches exact device and cookie despite identical usage and cross-device arrival order", function()
		local f = fixture()
		f.start()
		f.receiver.deliver(f.batch({ row(1, 24000000, true), row(2, 24000000, true, "41", 45),
			row(3, 24000000, true, "42") }))
		f.receiver.deliver(f.batch({ row(4, 30120000, false, "41", 45), row(5, 36024000, false, "42"),
			row(6, 30024000, false) }))
		helpers.assert_eq(#f.observed.presses, 3)
		helpers.assert_eq(f.observed.releases, {
			{ capture = "holds/8", device = "41", keycode = 49, app = "Original", timestamp = ORIGINAL_DATE, hold_ms = 255 },
			{ capture = "holds/8", device = "42", keycode = 49, app = "Original", timestamp = ORIGINAL_DATE, hold_ms = 501 },
			{ capture = "holds/8", device = "41", keycode = 49, app = "Original", timestamp = ORIGINAL_DATE, hold_ms = 251 },
		})
	end)

	helpers.it("cancels the whole duration across a forbidden interval despite allowed endpoints", function()
		local f = fixture()
		f.history.observe(1050000000, { allowed = false })
		f.history.observe(1150000000, { allowed = true, app = "Resumed", epoch = 2000 })
		f.start()
		f.receiver.deliver(f.batch({ row(1, 24000000, true), row(2, 30120000, false) }))
		helpers.assert_eq(#f.observed.presses, 1)
		helpers.assert_eq(f.observed.releases, {})
		f.receiver.deliver(f.batch({ row(3, 36000000, true), row(4, 36120000, false) }))
		helpers.assert_eq(#f.observed.releases, 1)
		helpers.assert_eq(f.observed.releases[1].hold_ms, 5)
		helpers.assert_eq(f.observed.releases[1].app, "Resumed")
	end)

	helpers.it("keeps immutable original attribution across sink mutation and an app/date change", function()
		local original = { allowed = true, app = "Original", timestamp = ORIGINAL_DATE }
		local f = fixture({ context = function() return original end,
			emit = function(press)
				press.capture, press.device, press.keycode = "Changed", "9", 53
				press.app, press.timestamp = "Changed", "invalid"
				return true
			end })
		f.history.observe(1100000000, { allowed = true, app = "Later", epoch = 2000 })
		f.start()
		f.receiver.deliver(f.batch({ row(1, 24000000, true) }))
		original.app, original.timestamp = "Changed", "invalid"
		f.receiver.deliver(f.batch({ row(2, 30120000, false) }))
		helpers.assert_eq(f.observed.releases, { { capture = "holds/8", device = "41", keycode = 49,
			app = "Original", timestamp = ORIGINAL_DATE, hold_ms = 255 } })
	end)

	helpers.it("never retains an unmapped press and still matches a mapped control", function()
		local f = fixture()
		f.start()
		f.receiver.deliver(f.batch({ row(1, 24000000, true, "41", 53, 53),
			row(2, 30120000, false, "41", 53, 53) }))
		helpers.assert_eq(f.observed.events, {})
		helpers.assert_eq(f.observed.intervals, {})
		f.receiver.deliver(f.batch({ row(3, 36000000, true), row(4, 36120000, false) }))
		helpers.assert_eq(#f.observed.presses, 1)
		helpers.assert_eq(#f.observed.releases, 1)
	end)

	helpers.it("never retains a forbidden press for a later permitted release", function()
		local f = fixture()
		f.history.observe(500000000, { allowed = false })
		f.history.observe(1100000000, { allowed = true, app = "Resumed", epoch = 2000 })
		f.start()
		f.receiver.deliver(f.batch({ row(1, 24000000, true), row(2, 30120000, false) }))
		helpers.assert_eq(f.observed.events, {})
		helpers.assert_eq(f.observed.intervals, {})
		f.receiver.deliver(f.batch({ row(3, 36000000, true), row(4, 36120000, false) }))
		helpers.assert_eq(#f.observed.releases, 1)
		helpers.assert_eq(f.observed.releases[1].app, "Resumed")
	end)

	helpers.it("cancels every unmatched hold on stop and never lends it to a successor capture", function()
		local old = fixture()
		old.start()
		old.receiver.deliver(old.batch({ row(1, 24000000, true) }))
		old.receiver.stop()
		rejects(function() old.receiver.deliver(old.batch({ row(2, 30120000, false) })) end, "not active")
		helpers.assert_eq(old.observed.releases, {})
		local next_capture = fixture({ lease = "9" })
		next_capture.frames.page.rows[2].down = true
		next_capture.start()
		next_capture.receiver.deliver(next_capture.batch({ row(1, 30120000, false),
			row(2, 36000000, true), row(3, 36120000, false) }))
		helpers.assert_eq(#next_capture.observed.presses, 1)
		helpers.assert_eq(#next_capture.observed.releases, 1)
		helpers.assert_eq(next_capture.observed.releases[1].capture, "holds/9")
	end)

	helpers.it("never publishes a release before exact press acceptance", function()
		local f = fixture({ emit = function() return false end })
		f.start()
		rejects(function() f.receiver.deliver(f.batch({ row(1, 24000000, true), row(2, 30120000, false) })) end,
			"sink refused the press")
		helpers.assert_eq(f.observed.releases, {})
		helpers.assert_eq(f.receiver.active(), false)
	end)

	helpers.it("requires exact release acceptance and never replays a partly published batch", function()
		for _, refusal in ipairs({ "false", "nil", "truthy", "thrown" }) do
			local f = fixture()
			local calls = 0
			local emit = function()
				calls = calls + 1
				if refusal == "thrown" then error("Injected release failure") end
				if refusal == "false" then return false end
				if refusal == "truthy" then return "accepted" end
			end
			local g = fixture({ holds = { convert = f.convert, context = f.dependencies.holds.context, emit = emit } })
			g.start()
			rejects(function() g.receiver.deliver(g.batch({ row(1, 24000000, true), row(2, 30120000, false) })) end,
				refusal == "thrown" and "Injected release failure" or "sink refused the release")
			helpers.assert_eq(#g.observed.presses, 1)
			helpers.assert_eq(calls, 1)
			helpers.assert_eq(g.receiver.active(), false)
			rejects(function() g.receiver.deliver(g.batch({ row(1, 24000000, true) })) end, "not active")
			helpers.assert_eq(calls, 1)
		end
	end)

	helpers.it("fences reentry from retained interval resolution before any release publication", function()
		local f, receiver
		local temporary = fixture()
		f = fixture({ holds = { convert = temporary.convert,
			context = function() receiver.stop(); return { allowed = true } end,
			emit = function() error("Revoked interval cannot publish a release") end } })
		receiver = f.receiver
		f.start()
		f.receiver.deliver(f.batch({ row(1, 24000000, true) }))
		rejects(function() f.receiver.deliver(f.batch({ row(2, 30120000, false) })) end, "revoked")
		helpers.assert_eq(#f.observed.presses, 1)
		helpers.assert_eq(f.observed.releases, {})
		helpers.assert_eq(receiver.active(), false)
	end)

	helpers.it("validates every identity before publishing any mixed batch event", function()
		local f = fixture()
		f.start()
		rejects(function() f.receiver.deliver(f.batch({ row(1, 24000000, true),
			row(2, 30120000, false, "41", 999) })) end, "identity changed")
		helpers.assert_eq(f.observed.events, {})
		helpers.assert_eq(f.receiver.active(), false)
	end)

	helpers.it("refuses partial hold capability instead of falling back to point permission", function()
		for _, missing in ipairs({ "convert", "context", "emit" }) do
			local f = fixture()
			local capability = { convert = f.convert, context = f.dependencies.holds.context, emit = function() return true end }
			capability[missing] = nil
			rejects(function() fixture({ holds = capability }) end, "Missing physical hold port: " .. missing)
		end
	end)

	helpers.it("binds the dormant capture's validated native clock and explicit interval/release owners", function()
		with_capture(function(capture, observed, controls)
			local history, convert
			local releases = {}
			controls.dependencies.clock_ready = function(_, native_convert)
				convert = native_convert
				history = Context.new(4, function() return ORIGINAL_DATE end)
				history.observe(0, { allowed = true, app = "Original", epoch = 1000 })
				return true
			end
			controls.dependencies.context = function(ticks) return history.resolve(convert(ticks)) end
			controls.dependencies.context_interval = function(first, last) return history.resolve_interval(convert(first), convert(last)) end
			controls.dependencies.emit_release = function(entry) releases[#releases + 1] = copy(entry); return true end
			controls.frames.batch = { version = 1, kind = "batch", coverage = "complete",
				incarnation = "production-fixture", lease = "7", records = {
					row(1, 24000000, true), row(2, 30120000, false) } }
			capture.init(controls.dependencies)
			capture.start(controls.options)
			controls.verified()
			controls.open()
			observed.tasks[3].chunk(nil, "batch\n")
			helpers.assert_eq(releases, { { capture = "production-fixture/7", device = "41", keycode = 49,
				app = "Original", timestamp = ORIGINAL_DATE, hold_ms = 255 } })
			helpers.assert_eq(observed.writes[#observed.writes], "2\n")
			helpers.assert_eq(observed.errors, {})
		end)
	end)

	helpers.it("freezes every raw row before a mapping callback can rewrite a future duration", function()
		local records = { row(1, 24000000, true), row(2, 30120000, false) }
		local f = fixture({ keycode = function(...)
			records[2].timestamp = "36120000"
			return Frames.keycode(...)
		end })
		f.start()
		helpers.assert_eq(f.receiver.deliver(f.batch(records)), "2")
		helpers.assert_eq(f.observed.releases[1].hold_ms, 255)
		helpers.assert_eq(records[2].timestamp, "36120000", "The external mutation actually ran")
	end)

	helpers.it("refuses an invalid future identity before a callback can repair its source", function()
		local records = { row(1, 24000000, true), row(2, 30120000, false, "41", 999) }
		local calls = 0
		local f = fixture({ keycode = function(...)
			calls = calls + 1
			records[2].cookie = 44
			return Frames.keycode(...)
		end })
		f.start()
		rejects(function() f.receiver.deliver(f.batch(records)) end, "identity changed")
		helpers.assert_eq(calls, 0)
		helpers.assert_eq(f.observed.events, {})
		local healthy = fixture()
		healthy.start()
		healthy.receiver.deliver(healthy.batch({ row(1, 24000000, true), row(2, 30120000, false) }))
		helpers.assert_eq(#healthy.observed.releases, 1)
	end)

	helpers.it("retains its original callback identities despite caller replacement", function()
		local f = fixture()
		f.dependencies.admit = function() error("Replaced admission must not run") end
		f.dependencies.context = function() return { allowed = false } end
		f.dependencies.keycode = function() return nil, "replaced" end
		f.dependencies.emit = function() return false end
		f.dependencies.holds.emit = function() return false end
		f.start()
		helpers.assert_eq(f.receiver.deliver(f.batch({ row(1, 24000000, true), row(2, 30120000, false) })), "2")
		helpers.assert_eq(#f.observed.presses, 1)
		helpers.assert_eq(#f.observed.releases, 1)
	end)

	helpers.it("fences mapping revocation before invoking a later context callback", function()
		local receiver
		local contexts = 0
		local f = fixture({ keycode = function(...)
			receiver.stop()
			return Frames.keycode(...)
		end, context = function()
			contexts = contexts + 1
			return { allowed = true, app = "Original", timestamp = ORIGINAL_DATE }
		end })
		receiver = f.receiver
		f.start()
		rejects(function() receiver.deliver(f.batch({ row(1, 24000000, true) })) end, "revoked")
		helpers.assert_eq(contexts, 0)
		helpers.assert_eq(f.observed.events, {})
	end)

	helpers.it("requires explicit production interval and release ports before acquiring a capture", function()
		for _, missing in ipairs({ "context_interval", "emit_release" }) do
			with_capture(function(capture, observed, controls)
				local original = controls.dependencies[missing]
				controls.dependencies[missing] = nil
				rejects(function() capture.init(controls.dependencies) end, "Missing physical capture port: " .. missing)
				helpers.assert_eq(observed.spawns, {})
				helpers.assert_eq(controls.mode.credit_source(), "legacy")
				controls.dependencies[missing] = original or function() return true end
				helpers.assert_true(capture.init(controls.dependencies))
			end)
		end
	end)
end)
