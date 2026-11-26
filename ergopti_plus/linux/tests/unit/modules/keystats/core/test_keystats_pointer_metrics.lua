--- tests/unit/modules/keystats/core/test_keystats_pointer_metrics.lua

--- ==============================================================================
--- MODULE: Mouse Columns Of The Linux Typing Rows
--- DESCRIPTION:
--- events_typing has mouse_clicks, mouse_scrolls and mouse_distance_px, which
--- macOS fills and Linux wrote as zeroes. The evdev reports the keyboard hook
--- already forwards are measured by modules/keystats/pointer_metrics.lua and
--- carried to the focused application's next typing row. The distance is the
--- cursor's travel in screen pixels, the unit Windows and macOS store: a
--- scripted cursor follows every relative report, as the desktop's does, and
--- no physical mouse is read here.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")
local unpack_values = table.unpack or unpack
local EvdevCodes = require("platform.input.evdev_codes")
local InputEvent = require("platform.input.event")
local PointerMetrics = require("modules.keystats.pointer_metrics")

-- A code no pointer counts: the middle button
local MIDDLE = EvdevCodes.BTN_MIDDLE

-- The scripted cursor: every REL_X/REL_Y report moves it, delivered or not.
local cursor = { x = 0, y = 0, now = 0 }
local function read_cursor() return cursor.x, cursor.y end
-- Each read is a frame apart, so no read is rate-limited away.
local function tick() cursor.now = cursor.now + 100; return cursor.now end

--- Wraps an observer so its relative reports move the scripted cursor first.
local function following(observe)
	return function(kind, code, value, source, at_us)
		if kind == "motion" and code == InputEvent.REL_X then cursor.x = cursor.x + value end
		if kind == "motion" and code == InputEvent.REL_Y then cursor.y = cursor.y + value end
		return observe(kind, code, value, source, at_us)
	end
end

--- Feeds one movement frame: its axes, then the SYN_REPORT closing it.
local function move(observe, dx, dy)
	local deltas = {}
	if dx ~= 0 then deltas[#deltas + 1] = observe("motion", InputEvent.REL_X, dx) end
	if dy ~= 0 then deltas[#deltas + 1] = observe("motion", InputEvent.REL_Y, dy) end
	deltas[#deltas + 1] = observe("frame", InputEvent.SYN_REPORT, 0)
	return deltas
end

helpers.describe("pointer metrics: what one evdev report adds", function()
	helpers.it("drops only empty committed distance remainders", function()
		local tracker = PointerMetrics.new()
		tracker.commit_fractions({ old = { zero = 0, partial = 0.25 }, empty = { only = 0 } })
		local saved = tracker.snapshot_fractions()
		helpers.assert_eq(saved.old.partial, 0.25, "older dates can receive delayed events")
		helpers.assert_nil(saved.old.zero)
		helpers.assert_nil(saved.empty)
	end)

	helpers.it("counts a left or right press as a click, no other button", function()
		local tracker = PointerMetrics.new()
		helpers.assert_eq(tracker.observe("press", EvdevCodes.BTN_LEFT, 1).clicks, 1)
		helpers.assert_eq(tracker.observe("press", EvdevCodes.BTN_RIGHT, 1).clicks, 1)
		helpers.assert_nil(tracker.observe("press", MIDDLE, 1))
		helpers.assert_nil(tracker.observe("press", EvdevCodes.BTN_DIGI_FIRST, 1), "a finger contact is no click")
	end)

	helpers.it("counts one scroll per classic wheel report, never the high-resolution echo", function()
		local tracker = PointerMetrics.new()
		helpers.assert_eq(tracker.observe("motion", InputEvent.REL_WHEEL, -1).scrolls, 1)
		helpers.assert_eq(tracker.observe("motion", InputEvent.REL_HWHEEL, 1).scrolls, 1)
		for code in pairs(InputEvent.REL_WHEEL_AXES) do
			if code ~= InputEvent.REL_WHEEL and code ~= InputEvent.REL_HWHEEL then
				helpers.assert_nil(tracker.observe("motion", code, 120), "axis " .. code .. " repeats a counted turn")
			end
		end
	end)

	helpers.it("measures each frame's movement once, as one vector", function()
		local tracker = PointerMetrics.new()
		tracker.bind_position(read_cursor, tick)
		local observe = following(tracker.observe)
		tracker.reseed()
		local deltas = move(observe, 3, 4)
		helpers.assert_eq(#deltas, 1, "only the frame's SYN_REPORT reports the distance")
		helpers.assert_eq(deltas[1].distance, 5)
		helpers.assert_nil(tracker.observe("frame", InputEvent.SYN_REPORT, 0), "an empty frame adds nothing")
		helpers.assert_eq(move(observe, -6, 0)[1].distance, 6)
	end)

	helpers.it("pointer-distance-pixels: credits screen pixels, never the device units of the reports", function()
		local tracker = PointerMetrics.new()
		local position = { x = 100, y = 100 }
		local now = 0
		tracker.bind_position(function() return position.x, position.y end, function() now = now + 100; return now end)
		tracker.reseed()
		-- Acceleration: a 3-unit report moved the cursor 30 pixels.
		tracker.observe("motion", InputEvent.REL_X, 3)
		position.x = 130
		helpers.assert_eq(tracker.observe("frame", InputEvent.SYN_REPORT, 0).distance, 30)
		helpers.assert_eq(tracker.availability().unit, "px")
	end)

	helpers.it("pointer-distance-pixels: reads at most once per sample interval during a movement", function()
		local tracker = PointerMetrics.new()
		local reads, now = 0, 0
		tracker.bind_position(function() reads = reads + 1; return reads * 10, 0 end, function() return now end)
		tracker.reseed()
		for _ = 1, 5 do move(tracker.observe, 1, 0) end
		helpers.assert_eq(reads, 1, "frames inside the interval do not read the cursor")
		now = PointerMetrics.POSITION_SAMPLE_MS
		helpers.assert_eq(move(tracker.observe, 1, 0)[1].distance, 10, "the next read credits the whole line")
	end)

	helpers.it("pointer-distance-unavailable: without a cursor source no distance is invented", function()
		local tracker = PointerMetrics.new()
		tracker.bind_position(nil, nil, "platform_reason.pointer_distance_needs_cursor_position")
		helpers.assert_nil(move(tracker.observe, 3, 4)[1])
		local availability = tracker.availability()
		helpers.assert_eq(availability.measured, false)
		helpers.assert_eq(availability.reason, "platform_reason.pointer_distance_needs_cursor_position")
	end)

	helpers.it("pointer-distance-unbound: an unbound tracker names a localized reason", function()
		-- The menu localizes the reason; the unbound fallback was raw English
		-- text, shown verbatim in the Metrics submenu of a field tray.
		local reason = PointerMetrics.new().availability().reason
		helpers.assert_eq(reason, "platform_reason.pointer_distance_needs_cursor_position")
		local file = assert(io.open(helpers.driver_root() .. "/../_shared/core/i18n/data/locales/en.json", "rb"))
		local locale = file:read("*a"); file:close()
		helpers.assert_contains(locale, '"' .. reason .. '"')
	end)

	helpers.it("refuses a kind the hook does not report", function()
		local tracker = PointerMetrics.new()
		helpers.assert_eq(pcall(tracker.observe, "release", EvdevCodes.BTN_LEFT, 0), false)
	end)
end)

--- Runs the real recorder against a fake writer and returns its typing rows.
--- @param script function Receives the keystats module.
--- @return table rows Typing rows the flush wrote.
local function recorded(script)
	local fake_writer = setmetatable({
		open_db = function() return true end,
		ensure_token_encoding = function() return true end,
		ensure_awake_definition = function() return true end,
		register_device = function() return true end,
		read_open_walk = function() return nil, true end,
		upsert_open_walk = function() return true end,
		is_available = function() return true end,
		bump_rev = function() return true end,
	}, { __index = Fakes.sqlite_writer() })
	require("tests.support.sqlite_flush_fake").attach(fake_writer)
	local writer_name, keystats_name = "modules.keystats.sqlite_writer", "modules.keystats.keystats"
	local previous_writer, previous_keystats = package.loaded[writer_name], package.loaded[keystats_name]
	package.loaded[writer_name], package.loaded[keystats_name] = fake_writer, nil
	local rows = {}
	cursor.x, cursor.y = 0, 0
	local ok, err = pcall(function()
		local keystats = require(keystats_name)
		keystats.init({ sqlite_path = "/tmp/ergopti_keystats_pointer_mock.sqlite" })
		keystats.bind_pointer_position(read_cursor, tick)
		require("tests.support.metrics_consent_fixture").enable(keystats)
		keystats.reset_session()
		script(setmetatable({ record_pointer = following(keystats.record_pointer) }, { __index = keystats }), fake_writer)
		keystats.flush()
		for _, entry in ipairs(fake_writer.typing) do rows[#rows + 1] = entry.row end
		keystats.flush()
		helpers.assert_eq(#fake_writer.typing, #rows, "a second flush must not replay the mouse activity")
	end)
	package.loaded[writer_name], package.loaded[keystats_name] = previous_writer, previous_keystats
	if not ok then error(err, 0) end
	return rows
end

helpers.describe("pointer metrics: the recorder writes them with the typing row", function()
	helpers.it("retains diagonal distance fractions across committed flushes", function()
		local rows = recorded(function(keystats)
			keystats.on_app_focus("owned-app", 1000)
			for _ = 1, 3 do
				move(keystats.record_pointer, 1, 1)
				keystats.flush()
			end
		end)
		local total = 0
		for _, row in ipairs(rows) do total = total + row.mouse_distance_px end
		helpers.assert_eq(total, math.floor(3 * math.sqrt(2)), "flush boundaries must not discard each fraction")
	end)

	helpers.it("keeps fractional distance separate for each application", function()
		local rows = recorded(function(keystats)
			for _ = 1, 2 do
				for _, app in ipairs({ "first", "second" }) do
					keystats.on_app_focus(app, 1000)
					move(keystats.record_pointer, 1, 1)
					helpers.assert_true(keystats.flush())
				end
			end
		end)
		local totals = {}
		for _, row in ipairs(rows) do totals[row.app] = (totals[row.app] or 0) + row.mouse_distance_px end
		helpers.assert_eq(totals.first, 2)
		helpers.assert_eq(totals.second, 2)
	end)

	helpers.it("does not carry fractional distance into another database", function()
		local rows = recorded(function(keystats)
			keystats.on_app_focus("owned-app", 1000)
			move(keystats.record_pointer, 1, 1); helpers.assert_true(keystats.flush())
			helpers.assert_true(keystats.init({ sqlite_path = "/tmp/ergopti_other_pointer_mock.sqlite" }))
			require("tests.support.metrics_consent_fixture").enable(keystats)
			keystats.on_app_focus("owned-app", 1000)
			for _ = 1, 2 do move(keystats.record_pointer, 1, 1); helpers.assert_true(keystats.flush()) end
		end)
		local total = 0
		for _, row in ipairs(rows) do total = total + row.mouse_distance_px end
		helpers.assert_eq(total, 3, "the second database starts without the first's remainder")
	end)

	helpers.it("does not publish fractional distance on refused flush admission", function()
		local rows = recorded(function(keystats, writer)
			keystats.on_app_focus("owned-app", 1000)
			local original = writer.start_flush
			move(keystats.record_pointer, 1, 1)
			writer.start_flush = function() return nil end
			helpers.assert_eq(keystats.flush(), false)
			writer.start_flush = original
			helpers.assert_true(keystats.flush())
			for _ = 1, 2 do move(keystats.record_pointer, 1, 1); helpers.assert_true(keystats.flush()) end
		end)
		local total = 0
		for _, row in ipairs(rows) do total = total + row.mouse_distance_px end
		helpers.assert_eq(total, math.floor(3 * math.sqrt(2)))
	end)

	helpers.it("publishes the distance fraction only after a failed transaction retries", function()
		local rows = recorded(function(keystats, writer)
			keystats.on_app_focus("owned-app", 1000)
			local original = writer.start_flush
			writer.start_flush = function(...)
				writer.start_flush = original
				local args = { ... }
				local operation = { result = { committed = false } }
				function operation:pump() return true end
				function operation:is_read_safe() return true end
				function operation:phase() return "done" end
				function operation:is_retryable() return self.result.committed == false end
				function operation:retry() self.result = original(unpack_values(args)).result; return true end
				return operation
			end
			move(keystats.record_pointer, 1, 1)
			helpers.assert_eq(keystats.flush(), false)
			move(keystats.record_pointer, 1, 1)
			helpers.assert_true(keystats.flush(), "the original snapshot commits on retry")
			helpers.assert_true(keystats.flush(), "newer motion follows the original snapshot")
			move(keystats.record_pointer, 1, 1); helpers.assert_true(keystats.flush())
		end)
		local total = 0
		for _, row in ipairs(rows) do total = total + row.mouse_distance_px end
		helpers.assert_eq(total, math.floor(3 * math.sqrt(2)))
	end)

	helpers.it("keeps reentrant motion behind the committed distance fraction", function()
		local rows = recorded(function(keystats, writer)
			keystats.on_app_focus("owned-app", 1000)
			local original = writer.start_flush
			writer.start_flush = function(...)
				writer.start_flush = original
				move(keystats.record_pointer, 1, 1)
				return original(...)
			end
			move(keystats.record_pointer, 1, 1)
			helpers.assert_true(keystats.flush())
			helpers.assert_true(keystats.flush())
			move(keystats.record_pointer, 1, 1); helpers.assert_true(keystats.flush())
		end)
		local total = 0
		for _, row in ipairs(rows) do total = total + row.mouse_distance_px end
		helpers.assert_eq(total, math.floor(3 * math.sqrt(2)))
	end)

	helpers.it("forgets partial pointer frames across a collection pause", function()
		local rows = recorded(function(keystats)
			keystats.on_app_focus("owned-app", 1000)
			keystats.record_pointer("motion", InputEvent.REL_X, 3, "mouse-a")
			keystats.suppress()
			keystats.unsuppress()
			keystats.on_app_focus("owned-app", 2000)
			keystats.record_pointer("motion", InputEvent.REL_Y, 4, "mouse-a")
			keystats.record_pointer("frame", InputEvent.SYN_REPORT, 0, "mouse-a")
		end)
		helpers.assert_eq(#rows, 1)
		helpers.assert_eq(rows[1].mouse_distance_px, 4)
	end)

	helpers.it("does not attribute a prior application's partial movement to the next", function()
		local rows = recorded(function(keystats)
			keystats.on_app_focus("first-app", 1000)
			keystats.record_pointer("motion", InputEvent.REL_X, 3, "mouse-a")
			keystats.on_app_focus("second-app", 2000)
			keystats.record_pointer("motion", InputEvent.REL_Y, 4, "mouse-a")
			keystats.record_pointer("frame", InputEvent.SYN_REPORT, 0, "mouse-a")
		end)
		helpers.assert_eq(#rows, 1)
		helpers.assert_eq(rows[1].mouse_distance_px, 4)
	end)

	helpers.it("keeps queue-loss protection across collection resumption", function()
		local rows = recorded(function(keystats)
			keystats.on_app_focus("owned-app", 1000)
			keystats.suppress()
			keystats.record_pointer("dropped", 3, 0, "mouse-a")
			keystats.unsuppress()
			keystats.on_app_focus("owned-app", 2000)
			keystats.record_pointer("motion", InputEvent.REL_X, 9, "mouse-a")
			keystats.record_pointer("frame", InputEvent.SYN_REPORT, 0, "mouse-a")
			keystats.record_pointer("motion", InputEvent.REL_Y, 2, "mouse-a")
			keystats.record_pointer("frame", InputEvent.SYN_REPORT, 0, "mouse-a")
		end)
		-- The pause forgot the cursor; resuming focus seeds it at (0,0), and the
		-- dropped frame's report still moved it before the read at (9,2).
		helpers.assert_eq(#rows, 1)
		helpers.assert_eq(rows[1].mouse_distance_px, math.floor(math.sqrt(85)))
	end)

	helpers.it("keeps interleaved device frames independent through the recorder", function()
		local rows = recorded(function(keystats)
			keystats.on_app_focus("owned-app", 1000)
			keystats.record_pointer("motion", InputEvent.REL_X, 3, "mouse-a")
			keystats.record_pointer("motion", InputEvent.REL_Y, 4, "mouse-b")
			keystats.record_pointer("frame", InputEvent.SYN_REPORT, 0, "mouse-a")
			keystats.record_pointer("frame", InputEvent.SYN_REPORT, 0, "mouse-b")
		end)
		-- One cursor: the two devices moved it to (3, 4), five pixels away.
		helpers.assert_eq(#rows, 1)
		helpers.assert_eq(rows[1].mouse_distance_px, 5)
	end)

	helpers.it("discards a departed pointer's incomplete frame before reconnection", function()
		local rows = recorded(function(keystats)
			keystats.on_app_focus("owned-app", 1000)
			keystats.record_pointer("motion", InputEvent.REL_X, 3, "mouse-a")
			keystats.record_pointer("motion", InputEvent.REL_X, 3, "mouse-b")
			keystats.record_pointer("dropped", 3, 0, "mouse-a")
			keystats.record_pointer("reset", nil, nil, "mouse-a")
			keystats.record_pointer("reset", nil, nil, "mouse-b")
			keystats.record_pointer("motion", InputEvent.REL_Y, 4, "mouse-a")
			keystats.record_pointer("frame", InputEvent.SYN_REPORT, 0, "mouse-a")
			keystats.record_pointer("motion", InputEvent.REL_Y, 4, "mouse-b")
			keystats.record_pointer("frame", InputEvent.SYN_REPORT, 0, "mouse-b")
		end)
		-- The cursor still travelled with the discarded reports: (0,0) -> (6,4) -> (6,8).
		helpers.assert_eq(#rows, 1)
		helpers.assert_eq(rows[1].mouse_distance_px, math.floor(math.sqrt(52) + 4))
	end)

	helpers.it("discards a dropped pointer packet without affecting another device", function()
		local rows = recorded(function(keystats)
			keystats.on_app_focus("owned-app", 1000)
			keystats.record_pointer("motion", InputEvent.REL_X, 3, "mouse-a")
			keystats.record_pointer("dropped", 3, 0, "mouse-a")
			keystats.record_pointer("motion", InputEvent.REL_Y, 4, "mouse-a")
			keystats.record_pointer("press", EvdevCodes.BTN_LEFT, 1, "mouse-a")
			keystats.record_pointer("motion", InputEvent.REL_X, 6, "mouse-b")
			keystats.record_pointer("frame", InputEvent.SYN_REPORT, 0, "mouse-b")
			keystats.record_pointer("frame", InputEvent.SYN_REPORT, 0, "mouse-a")
			keystats.record_pointer("motion", InputEvent.REL_Y, 2, "mouse-a")
			keystats.record_pointer("frame", InputEvent.SYN_REPORT, 0, "mouse-a")
		end)
		-- A dropped packet loses its click, not the cursor's travel: (0,0) -> (9,4) -> (9,6).
		helpers.assert_eq(#rows, 1)
		helpers.assert_eq(rows[1].mouse_distance_px, math.floor(math.sqrt(97) + 2))
		helpers.assert_eq(rows[1].mouse_clicks, 0)
	end)
	helpers.it("carries clicks, scrolls and distance to the focused application's row", function()
		local rows = recorded(function(keystats)
			keystats.on_app_focus("org.mozilla.firefox", 1000)
			keystats.record_pointer("press", EvdevCodes.BTN_LEFT, 1)
			keystats.record_pointer("press", EvdevCodes.BTN_RIGHT, 1)
			keystats.record_pointer("motion", InputEvent.REL_WHEEL, -1)
			move(keystats.record_pointer, 30, 40)
			move(keystats.record_pointer, 0, 2)
			keystats.on_keydown("a", 2000, "org.mozilla.firefox", 30)
		end)
		helpers.assert_eq(#rows, 1)
		helpers.assert_eq(rows[1].mouse_clicks, 2)
		helpers.assert_eq(rows[1].mouse_scrolls, 1)
		helpers.assert_eq(rows[1].mouse_distance_px, 52)
		helpers.assert_eq(rows[1].text, "a")
	end)

	helpers.it("writes pointer activity without typing as a row with no text, as macOS does", function()
		local rows = recorded(function(keystats)
			keystats.on_app_focus("org.gnome.Nautilus", 1000)
			keystats.record_pointer("press", EvdevCodes.BTN_LEFT, 1)
		end)
		helpers.assert_eq(#rows, 1)
		helpers.assert_eq(rows[1].mouse_clicks, 1)
		helpers.assert_eq(rows[1].text, "")
		helpers.assert_eq(rows[1].events_json, "[]")
	end)

	helpers.it("records nothing for an application kept out of the metrics", function()
		local rows = recorded(function(keystats)
			keystats.set_disabled_apps({ "org.keepassxc.KeePassXC" })
			keystats.on_app_focus("org.keepassxc.KeePassXC", 1000)
			keystats.record_pointer("press", EvdevCodes.BTN_LEFT, 1)
		end)
		helpers.assert_eq(#rows, 0)
	end)
end)

helpers.describe("pointer metrics: the writer stores the mouse columns", function()
	helpers.it("writes the row's clicks, scrolls and distance, not zeroes", function()
		local has_sqlite = os.execute("command -v sqlite3 >/dev/null 2>&1")
		local writer = helpers.load_module("modules.keystats.sqlite_writer")
		local dir = os.tmpname()
		os.remove(dir)
		local ok, failure = xpcall(function()
			local opened = writer.open_db(dir .. "/metrics.sqlite")
			if not (has_sqlite == true or has_sqlite == 0) then
				helpers.assert_eq(opened, false, "without sqlite3 the writer refuses, it does not pretend")
				return
			end
			helpers.assert_true(opened)
			helpers.assert_true(writer.insert_typing_events("owned-device", { { app = "owned-app", text = "a",
				mouse_clicks = 3, mouse_scrolls = 7, mouse_distance_px = 512 } }))
			local rows = assert(writer.query_rows("SELECT mouse_clicks,mouse_scrolls,mouse_distance_px FROM events_typing;"))
			helpers.assert_eq(rows, { "3|7|512" })
		end, debug.traceback)
		writer.close_db()
		os.execute("rm -rf '" .. dir .. "'")
		if not ok then error(failure, 0) end
	end)
end)




-- =================================================================
-- =================================================================
-- ======= Touchpad tap-to-click ===================================
-- =================================================================
-- =================================================================

local Record = helpers.load_module("tests.support.touchpad_record")

local PAD = "pointer:/dev/input/event7"

--- The recorded trace of tests/fixtures/tap_click_record_synaptics.yml.
local function tap_trace()
	local file = assert(io.open(helpers.driver_root() .. "/tests/fixtures/tap_click_record_synaptics.yml", "rb"))
	local trace = assert(Record.decode(file:read("*a")))
	file:close()
	return trace
end

--- Replays evdev events as the keyboard hook reports them to its observer:
--- a contact per EV_ABS report and per BTN_DIGI edge, a press per key down,
--- a frame with the kernel stamp per SYN_REPORT. EV_MSC is not forwarded.
--- A contact carries the tracker's privacy context; keystats.record_pointer
--- takes no sixth argument and computes its own.
--- @param observe function (kind, code, value, source, at_us, context) -> delta|nil
--- @param events table
--- @param source string
--- @return integer clicks The clicks the deltas add up to.
local function replay_as_hook(observe, events, source)
	local clicks = 0
	local function add(delta) if delta then clicks = clicks + delta.clicks end end
	for _, event in ipairs(events) do
		if event.type == InputEvent.EV_ABS then
			add(observe("contact", event.code, event.value, source, nil, "fixture-context"))
		elseif event.type == InputEvent.EV_KEY then
			if not InputEvent.is_pointer_button(event.code) then
				add(observe("contact", event.code, event.value, source, nil, "fixture-context"))
			end
			if event.value == 1 then add(observe("press", event.code, event.value, source)) end
		elseif event.type == InputEvent.EV_SYN and event.code == InputEvent.SYN_REPORT then
			add(observe("frame", event.code, event.value, source, event.timestamp_us))
		end
	end
	return clicks
end

--- A tracker whose touchpad answers a scripted setting.
--- @param setting table|function The setting answer, or a function returning it.
--- @return table tracker, table calls { describe, read }
local function pad_tracker(setting)
	local tracker, calls, now = PointerMetrics.new(), { describe = 0, read = 0 }, { ms = 0 }
	tracker.bind_touchpads(function(source)
		calls.describe = calls.describe + 1
		helpers.assert_eq(source, PAD, "only the touch source is described")
		return { path = "/dev/input/event7", name = "SYNA8004:00 06CB:CD8B Touchpad", units_x = 12, units_y = 12 }
	end, function(device)
		calls.read = calls.read + 1
		helpers.assert_eq(device.path, "/dev/input/event7")
		return type(setting) == "function" and setting() or setting
	end, function() return now.ms end)
	return tracker, calls, now
end

local LRM_ON = { known = true, enabled = true, map = "lrm", source = "fixture" }

helpers.describe("pointer metrics: touchpad tap-to-click", function()
	helpers.it("(tap-click) counts the recorded left and right taps and the button press as clicks", function()
		local tracker = pad_tracker(LRM_ON)
		-- Taps of 1, 2, 3, 1, 1, 1 fingers: the middle (three-finger) one is no
		-- click, as a middle press is none; the clickpad press of H is one.
		helpers.assert_eq(replay_as_hook(tracker.observe, tap_trace().events, PAD), 6)
		helpers.assert_eq(tracker.tap_click_availability(), { measured = true })
	end)

	helpers.it("(tap-click) counts the two-finger tap as no click under the lmr map", function()
		local lmr = pad_tracker({ known = true, enabled = true, map = "lmr", source = "fixture" })
		-- lmr: 1 left, 2 middle, 3 right, then four left taps and the press.
		helpers.assert_eq(replay_as_hook(lmr.observe, tap_trace().events, PAD), 6)
		local events = {}
		for _, event in ipairs(tap_trace().events) do
			-- Section B alone: the two-finger tap, 0.7 s to 1.6 s into the trace.
			if event.timestamp_us >= 1700000 and event.timestamp_us < 2600000 then events[#events + 1] = event end
		end
		helpers.assert_eq(replay_as_hook(pad_tracker(LRM_ON).observe, events, PAD), 1, "a right click under lrm")
		helpers.assert_eq(replay_as_hook(pad_tracker({ known = true, enabled = true, map = "lmr", source = "fixture" }).observe,
			events, PAD), 0, "a middle click under lmr")
	end)

	helpers.it("(tap-click) counts no tap while the desktop has tap-to-click off", function()
		local tracker = pad_tracker({ known = true, enabled = false, map = "lrm", source = "fixture" })
		helpers.assert_eq(replay_as_hook(tracker.observe, tap_trace().events, PAD), 1, "the button press only")
		helpers.assert_eq(tracker.tap_click_availability(), { measured = true })
	end)

	helpers.it("(tap-click) an unreadable setting counts no tap and says why", function()
		local tracker = pad_tracker({ known = false, reason = "platform_reason.tap_to_click_setting_unreadable",
			detail = "fixture" })
		helpers.assert_eq(replay_as_hook(tracker.observe, tap_trace().events, PAD), 1)
		helpers.assert_eq(tracker.tap_click_availability(),
			{ measured = false, reason = "platform_reason.tap_to_click_setting_unreadable" })
	end)

	helpers.it("(tap-click) reads the setting at the first tap, then only from the tick while the pad is in use", function()
		local tracker, calls, now = pad_tracker(LRM_ON)
		tracker.refresh_tap_settings()
		helpers.assert_eq(calls.read, 0, "an untouched pad is never read")
		replay_as_hook(tracker.observe, tap_trace().events, PAD)
		helpers.assert_eq(calls.describe, 1, "the pad is described once")
		helpers.assert_eq(calls.read, 1, "the input path reads once, at the first tap")
		now.ms = PointerMetrics.TAP_SETTING_READ_INTERVAL_MS - 1
		tracker.refresh_tap_settings()
		helpers.assert_eq(calls.read, 1, "a fresh answer is reused")
		now.ms = PointerMetrics.TAP_SETTING_READ_INTERVAL_MS
		tracker.refresh_tap_settings()
		helpers.assert_eq(calls.read, 2, "a due answer is read again by the tick")
		now.ms = PointerMetrics.TAP_SETTING_IDLE_MS + 1
		tracker.refresh_tap_settings()
		helpers.assert_eq(calls.read, 2, "a pad at rest costs no fork")
	end)

	helpers.it("(tap-click) a setting turned off between two taps stops the count", function()
		local answer = LRM_ON
		local tracker, _, now = pad_tracker(function() return answer end)
		local trace = tap_trace().events
		local first, rest = {}, {}
		for _, event in ipairs(trace) do
			if event.timestamp_us < 1700000 then first[#first + 1] = event else rest[#rest + 1] = event end
		end
		helpers.assert_eq(replay_as_hook(tracker.observe, first, PAD), 1, "tap A")
		answer = { known = true, enabled = false, map = "lrm", source = "fixture" }
		now.ms = PointerMetrics.TAP_SETTING_READ_INTERVAL_MS
		tracker.refresh_tap_settings()
		helpers.assert_eq(replay_as_hook(tracker.observe, rest, PAD), 1, "only the button press after the change")
	end)

	helpers.it("(tap-click) a mouse never becomes a pad, and a departed pad is forgotten", function()
		local tracker, calls = pad_tracker(LRM_ON)
		tracker.observe("press", EvdevCodes.BTN_LEFT, 1, "pointer:/dev/input/event3")
		tracker.observe("frame", InputEvent.SYN_REPORT, 0, "pointer:/dev/input/event3", 1000)
		helpers.assert_eq(calls.describe, 0, "button presses and frames describe nothing")
		replay_as_hook(tracker.observe, tap_trace().events, PAD)
		tracker.observe("reset", nil, nil, PAD)
		replay_as_hook(tracker.observe, tap_trace().events, PAD)
		helpers.assert_eq(calls.describe, 2, "a reconnected pad is described afresh")
	end)

	helpers.it("(tap-click) a pad whose frames carry no kernel time counts no tap", function()
		local tracker = pad_tracker(LRM_ON)
		local unstamped = {}
		for _, event in ipairs(tap_trace().events) do
			unstamped[#unstamped + 1] = { type = event.type, code = event.code, value = event.value }
		end
		helpers.assert_eq(replay_as_hook(tracker.observe, unstamped, PAD), 1, "the button press only")
	end)

	helpers.it("(tap-click) carries the counted taps to the focused application's row", function()
		local rows = recorded(function(keystats)
			keystats.bind_touchpads(function()
				return { path = "/dev/input/event7", name = "pad", units_x = 12, units_y = 12 }
			end, function() return LRM_ON end, function() return 0 end)
			keystats.on_app_focus("org.gnome.TextEditor", 1000)
			replay_as_hook(keystats.record_pointer, tap_trace().events, PAD)
		end)
		helpers.assert_eq(#rows, 1)
		helpers.assert_eq(rows[1].mouse_clicks, 6)
	end)
end)




-- =================================================================
-- =================================================================
-- ======= Touchpad clicks and the field's privacy verdict =========
-- =================================================================
-- =================================================================

local EDITOR = "org.gnome.TextEditor"

-- The focus guard reads a field again once the pointer has been still for its
-- settle delay; the trace's sections are farther apart than this.
local SETTLE_US = 300000

--- Replays the trace as the daemon sees it: the hook reports a landing or a
--- button press, then runs the click callback, whose guard invalidation is
--- the press's own withdrawal (ergopti_hotstrings on_click). Before the first
--- event after a still pointer, read_field(event) gives the field's verdict,
--- as the guard's refresh does.
--- @param keystats table
--- @param events table
--- @param read_field function (event) -> "admitted" or "secure".
--- @param during function|nil (keystats, event) called after each event.
--- @param source string|nil The pointer's identity, the touchpad by default.
--- @param withdraws boolean|nil false for a press that withdraws nothing,
--- as on a desktop that never moves the field on a click.
local function replay_with_withdrawals(keystats, events, read_field, during, source, withdraws)
	local pointer = source or PAD
	local function withdraw()
		if withdraws == false then return end
		keystats.withdraw_for_pointer(function() keystats.set_secure_field(true) end)
	end
	local last_frame_us = nil
	for _, event in ipairs(events) do
		if not last_frame_us or event.timestamp_us - last_frame_us > SETTLE_US then
			-- One read, before the frame's first report; the rest are the same touch.
			last_frame_us = event.timestamp_us
			if read_field(event) == "admitted" then
				keystats.set_secure_field(false)
				keystats.on_app_focus(EDITOR, math.floor(event.timestamp_us / 1000))
			else
				keystats.set_secure_field(true)
			end
		end
		if event.type == InputEvent.EV_ABS then
			keystats.record_pointer("contact", event.code, event.value, pointer)
		elseif event.type == InputEvent.EV_REL then
			keystats.record_pointer("motion", event.code, event.value, pointer)
		elseif event.type == InputEvent.EV_KEY and event.value ~= 2 then
			local button = InputEvent.is_pointer_button(event.code)
			if event.value == 1 and button then keystats.record_pointer("press", event.code, 1, pointer) end
			if not button then keystats.record_pointer("contact", event.code, event.value, pointer) end
			if event.value == 1 then withdraw() end
			if event.value == 1 and not button then keystats.record_pointer("press", event.code, 1, pointer) end
		elseif event.type == InputEvent.EV_SYN and event.code == InputEvent.SYN_REPORT then
			keystats.record_pointer("frame", event.code, event.value, pointer, event.timestamp_us)
			last_frame_us = event.timestamp_us
		end
		if during then during(keystats, event) end
	end
end

--- Tap A alone: its touch's first frame, then the frame that makes it a click.
local function tap_a()
	local events = {}
	for _, event in ipairs(tap_trace().events) do
		if event.timestamp_us < 1700000 then events[#events + 1] = event end
	end
	return events
end

--- Records a replay with the fixture pad bound and the editor focused.
--- @param read_field function See replay_with_withdrawals.
--- @param options table|nil { events, during, prepare(keystats), source, withdraws }
local function recorded_with_withdrawals(read_field, options)
	options = options or {}
	return recorded(function(keystats)
		keystats.bind_touchpads(function()
			return { path = "/dev/input/event7", name = "pad", units_x = 12, units_y = 12 }
		end, function() return LRM_ON end, function() return 0 end)
		if options.prepare then options.prepare(keystats) end
		keystats.on_app_focus(EDITOR, 1000)
		replay_with_withdrawals(keystats, options.events or tap_trace().events, read_field, options.during,
			options.source, options.withdraws)
	end)
end

local function admitted() return "admitted" end

--- Calls change(keystats) once, after the first frame of the replayed touch.
local function after_first_frame(change)
	local frames = 0
	return function(keystats, event)
		if event.type == InputEvent.EV_SYN then
			frames = frames + 1
			if frames == 1 then change(keystats) end
		end
	end
end

helpers.describe("pointer metrics: a touch's clicks and the field's verdict", function()
	-- Before, a tap was counted on the frame ending it, after its own landing
	-- had withdrawn the field: until the guard read the field again, every tap
	-- and every clickpad press met an unknown field and the clicks stayed 0.
	helpers.it("(tap-click-touch-context) counts a tap and a clickpad press in the field the touch began in", function()
		local rows = recorded_with_withdrawals(admitted)
		-- A, B (right), F's tap, G's two taps and H's press. G's second tap
		-- lands 117 ms after the first withdrew the field, before any read,
		-- and is counted in the field G began in (pointer-span-context).
		helpers.assert_eq(#rows, 1)
		helpers.assert_eq(rows[1].app, EDITOR)
		helpers.assert_eq(rows[1].mouse_clicks, 6)
	end)

	helpers.it("(tap-click-touch-context) never records a click of a touch begun in a secure field", function()
		helpers.assert_eq(#recorded_with_withdrawals(function() return "secure" end), 0,
			"no tap and no clickpad press of a secure field is recorded")
		local rows = recorded_with_withdrawals(function(event)
			return (event.timestamp_us >= 1700000 and event.timestamp_us < 2600000) and "secure" or "admitted"
		end)
		helpers.assert_eq(rows[1].mouse_clicks, 5, "B, begun in a secure field, is not counted")
	end)

	helpers.it("(tap-click-touch-context) a verdict read during the touch ends the context it began in", function()
		-- A password field focused from the keyboard while the finger is down.
		local rows = recorded_with_withdrawals(admitted, { events = tap_a(),
			during = after_first_frame(function(keystats) keystats.set_secure_field(true) end) })
		helpers.assert_eq(#rows, 0, "the tap meets the secure verdict, not its touch's first one")
	end)

	helpers.it("(tap-click-touch-context) the focus worker's answer to the landing keeps the touch's context", function()
		local rows = recorded_with_withdrawals(admitted, { events = tap_a(),
			during = after_first_frame(function(keystats) keystats.set_secure_field(true, false) end) })
		helpers.assert_eq(#rows, 1, "a withdrawal that reads nothing is the landing's own")
		helpers.assert_eq(rows[1].mouse_clicks, 1)
		rows = recorded_with_withdrawals(admitted, { events = tap_a(),
			during = after_first_frame(function(keystats) keystats.set_secure_field(true, true) end) })
		helpers.assert_eq(#rows, 0, "a password role read during the touch ends its context")
	end)

	helpers.it("(tap-click-touch-context) a field admitted again during the touch counts the tap there", function()
		local rows = recorded_with_withdrawals(admitted, { events = tap_a(),
			during = after_first_frame(function(keystats)
				keystats.set_secure_field(false)
				keystats.on_app_focus("org.gnome.Nautilus", 2000)
			end) })
		helpers.assert_eq(#rows, 1)
		helpers.assert_eq(rows[1].app, "org.gnome.Nautilus", "the fresh verdict is the one the click meets")
		helpers.assert_eq(rows[1].mouse_clicks, 1)
	end)

	helpers.it("(tap-click-touch-context) a pause, a private window or an exclusion before the tap ends drops it", function()
		local Preferences = require("tests.support.metrics_preferences_fixture")
		local changes = {
			pause = function(keystats) keystats.suppress() end,
			private = function(keystats) keystats.set_private_window(true) end,
			excluded = function(keystats)
				Preferences.with(function() helpers.assert_true(keystats.set_disabled_apps({ EDITOR })) end)
			end,
		}
		for name, change in pairs(changes) do
			local rows = recorded_with_withdrawals(admitted, { events = tap_a(), during = after_first_frame(change),
				prepare = function(keystats)
					Preferences.with(function() helpers.assert_true(keystats.set_private_filter_enabled(true)) end)
				end })
			helpers.assert_eq(#rows, 0, name .. " ends the tap's context")
		end
	end)

	helpers.it("(tap-click-touch-context) a withdrawal that fails is no withdrawal a touch may cross", function()
		local rows = recorded_with_withdrawals(admitted, { events = tap_a(),
			during = after_first_frame(function(keystats)
				helpers.assert_eq(pcall(keystats.withdraw_for_pointer, function() error("controlled failure") end), false,
					"the failure is raised, not swallowed")
			end) })
		helpers.assert_eq(#rows, 0)
	end)

	helpers.it("(tap-click-touch-context) the tracker returns the context of the touch's first contact report", function()
		local tracker = pad_tracker(LRM_ON)
		local contexts, touch = {}, 0
		for _, event in ipairs(tap_a()) do
			local delta
			if event.type == InputEvent.EV_ABS or event.type == InputEvent.EV_KEY then
				touch = touch + 1
				delta = tracker.observe("contact", event.code, event.value, PAD, nil, "report " .. touch)
			elseif event.type == InputEvent.EV_SYN and event.code == InputEvent.SYN_REPORT then
				delta = tracker.observe("frame", event.code, 0, PAD, event.timestamp_us)
			end
			if delta and delta.clicks > 0 then contexts[#contexts + 1] = delta.touch_context end
		end
		helpers.assert_eq(contexts, { "report 1" }, "one tap, in the context of its first report")
		helpers.assert_eq(pcall(tracker.observe, "contact", 0x39, 1, PAD), false, "a contact names its context")
	end)
end)




-- =================================================================
-- =================================================================
-- ======= The span a click leaves the field unknown ===============
-- =================================================================
-- =================================================================

local MOUSE = "pointer:/dev/input/event3"

--- The trace of tests/fixtures/pointer_record_mouse_click_span.yml, or the
--- part of it whose kernel time falls in [from_us, to_us).
--- @param from_us number|nil
--- @param to_us number|nil
--- @return table events
local function mouse_trace(from_us, to_us)
	local file = assert(io.open(helpers.driver_root() .. "/tests/fixtures/pointer_record_mouse_click_span.yml", "rb"))
	local trace = assert(Record.decode(file:read("*a")))
	file:close()
	local events = {}
	for _, event in ipairs(trace.events) do
		if event.timestamp_us >= (from_us or 0) and event.timestamp_us < (to_us or math.huge) then
			events[#events + 1] = event
		end
	end
	return events
end

-- Sections A and B (travel, then a click and what follows it) end before C
-- (a double-click and two notches) begins, in decoded kernel time.
local DOUBLE_CLICK_US = 3000000

--- Calls change(keystats) once, after B's click has withdrawn the field.
local function after_the_click(change)
	local done = false
	return function(keystats, event)
		if not done and event.type == InputEvent.EV_KEY and event.value == 1 and event.timestamp_us == 1500000 then
			done = true
			change(keystats)
		end
	end
end

--- Sums the mouse columns of the rows, per application.
--- @param rows table
--- @return table totals { [app] = { clicks, scrolls, distance } }
local function mouse_totals(rows)
	local totals = {}
	for _, row in ipairs(rows) do
		local total = totals[row.app] or { clicks = 0, scrolls = 0, distance = 0 }
		total.clicks = total.clicks + (row.mouse_clicks or 0)
		total.scrolls = total.scrolls + (row.mouse_scrolls or 0)
		total.distance = total.distance + (row.mouse_distance_px or 0)
		totals[row.app] = total
	end
	return totals
end

helpers.describe("pointer metrics: the span a click leaves the field unknown", function()
	-- Before, a click withdrew the field until the guard read it again: the
	-- wheel turns and travel of that span and a double-click's second press
	-- met an unknown field, and only the first press of each click was counted.
	helpers.it("(pointer-span-context) counts the wheel, the travel and a double-click as in a field never withdrawn", function()
		local withdrawn = mouse_totals(recorded_with_withdrawals(admitted, { events = mouse_trace(), source = MOUSE }))
		local kept = mouse_totals(recorded_with_withdrawals(admitted,
			{ events = mouse_trace(), source = MOUSE, withdraws = false }))
		helpers.assert_eq(kept[EDITOR].clicks, 3, "B's click and C's two presses")
		helpers.assert_eq(kept[EDITOR].scrolls, 4, "two notches after each click, never the high-resolution repeats")
		helpers.assert_true(kept[EDITOR].distance > 0)
		helpers.assert_eq(withdrawn, kept, "the click's own withdrawal loses nothing")
	end)

	helpers.it("(pointer-span-context) counts a double tap's second tap where the double tap began", function()
		local events = {}
		for _, event in ipairs(tap_trace().events) do
			-- Section G alone: two taps 117 ms apart, 5.8 s into the trace.
			if event.timestamp_us >= 6700000 and event.timestamp_us < 7700000 then events[#events + 1] = event end
		end
		local rows = recorded_with_withdrawals(admitted, { events = events })
		helpers.assert_eq(#rows, 1)
		helpers.assert_eq(rows[1].mouse_clicks, 2, "the second tap lands in the field the first one withdrew")
	end)

	helpers.it("(pointer-span-context) records nothing of a span begun in a secure field", function()
		helpers.assert_eq(#recorded_with_withdrawals(function() return "secure" end,
			{ events = mouse_trace(), source = MOUSE }), 0)
		local totals = mouse_totals(recorded_with_withdrawals(function(event)
			return event.timestamp_us >= DOUBLE_CLICK_US and "secure" or "admitted"
		end, { events = mouse_trace(), source = MOUSE }))
		helpers.assert_eq(totals[EDITOR].clicks, 1, "C, begun in a secure field, adds no click")
		helpers.assert_eq(totals[EDITOR].scrolls, 2, "and no wheel turn")
	end)

	helpers.it("(pointer-span-context) a field read after the click ends the span, the worker's answer does not", function()
		local cases = {
			{ "a password read", function(keystats) keystats.set_secure_field(true, true) end, 0 },
			{ "another withdrawal", function(keystats) keystats.set_secure_field(true) end, 0 },
			{ "the focus worker's answer", function(keystats) keystats.set_secure_field(true, false) end, 2 },
		}
		for _, case in ipairs(cases) do
			local totals = mouse_totals(recorded_with_withdrawals(admitted, { source = MOUSE,
				events = mouse_trace(0, DOUBLE_CLICK_US), during = after_the_click(case[2]) }))
			helpers.assert_eq(totals[EDITOR].clicks, 1, case[1] .. ": the click is counted before its withdrawal")
			helpers.assert_eq(totals[EDITOR].scrolls, case[3], case[1])
		end
	end)

	helpers.it("(pointer-span-context) another window, a pause, a private window or an exclusion ends the span", function()
		local Preferences = require("tests.support.metrics_preferences_fixture")
		local changes = {
			focus = function(keystats) keystats.on_app_focus("org.gnome.Nautilus", 2000) end,
			pause = function(keystats) keystats.suppress() end,
			private = function(keystats) keystats.set_private_window(true) end,
			excluded = function(keystats)
				Preferences.with(function() helpers.assert_true(keystats.set_disabled_apps({ EDITOR })) end)
			end,
		}
		for name, change in pairs(changes) do
			local rows = recorded_with_withdrawals(admitted, { source = MOUSE,
				events = mouse_trace(0, DOUBLE_CLICK_US), during = after_the_click(change),
				prepare = function(keystats)
					Preferences.with(function() helpers.assert_true(keystats.set_private_filter_enabled(true)) end)
				end })
			for app, total in pairs(mouse_totals(rows)) do
				helpers.assert_eq(total.scrolls, 0, name .. " ends the span: no wheel turn for " .. app)
			end
		end
	end)
end)
