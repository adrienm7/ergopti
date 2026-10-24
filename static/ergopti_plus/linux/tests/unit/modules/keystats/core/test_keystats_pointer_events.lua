--- tests/unit/modules/keystats/core/test_keystats_pointer_events.lua

--- ==============================================================================
--- MODULE: Pointer Events In The Linux Metrics Database
--- DESCRIPTION:
--- Windows writes events_mouse: one mouse_click per press and one mouse_scroll
--- per burst of wheel turns (keystats_mouse.ahk). Linux wrote none. This pins
--- the tracker's clicks and bursts, the recorder's flush, its privacy gate and
--- the writer's canonical columns. Pointer reports are scripted; no physical
--- mouse is read here.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")
local EvdevCodes = require("infra.evdev_codes")
local InputEvent = require("infra.input_event")
local Timings = require("infra.timings")
local PointerEvents = require("modules.keystats.pointer_events")

local GAP = Timings.ms("keystats", "mouse_scroll_burst_gap_ms")

helpers.describe("pointer events: the tracker", function()
	helpers.it("names the button of each click, and nothing for another button", function()
		local tracker = PointerEvents.new({ burst_gap_ms = GAP })
		helpers.assert_eq(tracker.observe("press", EvdevCodes.BTN_LEFT, 1, 0),
			{ { kind = "mouse_click", meta = { button = "left" } } })
		helpers.assert_eq(tracker.observe("press", EvdevCodes.BTN_MIDDLE, 1, 0)[1].meta.button, "middle")
		helpers.assert_eq(tracker.observe("press", EvdevCodes.BTN_DIGI_FIRST, 1, 0), {})
	end)

	helpers.it("coalesces wheel turns into one burst closed by the shared gap", function()
		local tracker = PointerEvents.new({ burst_gap_ms = GAP })
		helpers.assert_eq(tracker.observe("motion", InputEvent.REL_WHEEL, -1, 1000), {})
		helpers.assert_eq(tracker.observe("motion", InputEvent.REL_WHEEL, -1, 1250), {})
		helpers.assert_eq(tracker.observe("motion", InputEvent.REL_WHEEL, -2, 1500), {})
		helpers.assert_eq(tracker.tick(1500 + GAP), {}, "the gap has not passed yet")
		helpers.assert_eq(tracker.tick(1501 + GAP), { { kind = "mouse_scroll",
			meta = { direction = "down", ticks = 4, velocity = 8, duration_ms = 500 } } })
		helpers.assert_eq(tracker.tick(5000 + GAP), {}, "a burst is closed once")
	end)

	helpers.it("closes the previous burst when a new turn comes after the gap", function()
		local tracker = PointerEvents.new({ burst_gap_ms = GAP })
		tracker.observe("motion", InputEvent.REL_HWHEEL, 1, 0)
		local events = tracker.observe("motion", InputEvent.REL_WHEEL, 1, GAP + 1)
		helpers.assert_eq(events, { { kind = "mouse_scroll",
			meta = { direction = "horizontal", ticks = 1, velocity = 0, duration_ms = 0 } } })
		helpers.assert_eq(tracker.tick(2 * GAP + 2)[1].meta.direction, "up")
	end)

	helpers.it("refuses a tracker without its gap", function()
		helpers.assert_eq(pcall(PointerEvents.new, {}), false)
	end)
end)

helpers.describe("pointer events: the recorder", function()
	--- Runs the real recorder against a fake writer.
	local function recorded(script)
		local fake_writer = setmetatable({
			open_db = function() return true end,
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
		local ok, err = pcall(function()
			local keystats = require(keystats_name)
			keystats.init({ sqlite_path = "/tmp/ergopti_keystats_pointer_events_mock.sqlite" })
			require("tests.support.metrics_consent_fixture").enable(keystats)
			keystats.reset_session()
			script(keystats)
			keystats.flush()
			for _, entry in ipairs(fake_writer.mouse_events) do rows[#rows + 1] = entry.row end
			keystats.flush()
			helpers.assert_eq(#fake_writer.mouse_events, #rows, "a second flush must not replay the events")
		end)
		package.loaded[writer_name], package.loaded[keystats_name] = previous_writer, previous_keystats
		if not ok then error(err, 0) end
		return rows
	end

	helpers.it("writes a click under the focused application", function()
		local rows = recorded(function(keystats)
			keystats.on_app_focus("org.mozilla.firefox", 1000)
			keystats.record_pointer("press", EvdevCodes.BTN_RIGHT, 1)
			keystats.record_pointer("motion", InputEvent.REL_X, 4)
		end)
		helpers.assert_eq(#rows, 1, "a movement is no events_mouse row")
		helpers.assert_eq(rows[1].kind, "mouse_click")
		helpers.assert_eq(rows[1].meta, { button = "right" })
		helpers.assert_eq(type(rows[1].app), "string")
	end)

	helpers.it("records no click in an application kept out of the metrics", function()
		local rows = recorded(function(keystats)
			keystats.set_disabled_apps({ "org.keepassxc.KeePassXC" })
			keystats.on_app_focus("org.keepassxc.KeePassXC", 1000)
			keystats.record_pointer("press", EvdevCodes.BTN_LEFT, 1)
		end)
		helpers.assert_eq(#rows, 0)
	end)
end)

helpers.describe("pointer events: the writer", function()
	helpers.it("stores the canonical events_mouse columns", function()
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
			helpers.assert_true(writer.insert_mouse_events("owned-device", { {
				ts = "2026-10-24 10:00:00", date = "2026-10-24", kind = "mouse_click", app = "Firefox",
				meta = { button = "left" },
			} }))
			local rows = assert(writer.query_rows("SELECT kind,app,meta_json FROM events_mouse;"))
			helpers.assert_eq(rows, { 'mouse_click|Firefox|{"button":"left"}' })
		end, debug.traceback)
		writer.close_db()
		os.execute("rm -rf '" .. dir .. "'")
		if not ok then error(failure, 0) end
	end)
end)
