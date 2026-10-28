--- tests/unit/modules/keystats/core/test_keystats_pointer_metrics.lua

--- ==============================================================================
--- MODULE: Mouse Columns Of The Linux Typing Rows
--- DESCRIPTION:
--- events_typing has mouse_clicks, mouse_scrolls and mouse_distance_px, which
--- macOS fills and Linux wrote as zeroes. The evdev reports the keyboard hook
--- already forwards are measured by modules/keystats/pointer_metrics.lua and
--- carried to the focused application's next typing row. The pointer reports
--- are scripted; no physical mouse is read here.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")
local EvdevCodes = require("infra.evdev_codes")
local InputEvent = require("infra.input_event")
local PointerMetrics = require("modules.keystats.pointer_metrics")

-- A code no pointer counts: the middle button
local MIDDLE = EvdevCodes.BTN_MIDDLE

--- Feeds one movement frame: its axes, then the SYN_REPORT closing it.
local function move(observe, dx, dy)
	local deltas = {}
	if dx ~= 0 then deltas[#deltas + 1] = observe("motion", InputEvent.REL_X, dx) end
	if dy ~= 0 then deltas[#deltas + 1] = observe("motion", InputEvent.REL_Y, dy) end
	deltas[#deltas + 1] = observe("frame", InputEvent.SYN_REPORT, 0)
	return deltas
end

helpers.describe("pointer metrics: what one evdev report adds", function()
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
		local deltas = move(tracker.observe, 3, 4)
		helpers.assert_eq(#deltas, 1, "only the frame's SYN_REPORT reports the distance")
		helpers.assert_eq(deltas[1].distance, 5)
		helpers.assert_nil(tracker.observe("frame", InputEvent.SYN_REPORT, 0), "an empty frame adds nothing")
		helpers.assert_eq(move(tracker.observe, -6, 0)[1].distance, 6)
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
		keystats.init({ sqlite_path = "/tmp/ergopti_keystats_pointer_mock.sqlite" })
		require("tests.support.metrics_consent_fixture").enable(keystats)
		keystats.reset_session()
		script(keystats)
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
