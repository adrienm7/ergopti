--- tests/unit/modules/keystats/core/test_keystats_window_switches.lua

--- ==============================================================================
--- MODULE: Window Switches In The Linux Metrics Database
--- DESCRIPTION:
--- Windows and macOS write events_window_switch for every change of the focused
--- window's title; the dashboard reads them as per-application context shifts.
--- Linux tracked the titles' time and wrote no switch. This proves the recorder
--- buffers each change under the application that owned the outgoing title,
--- flushes it once, keeps excluded applications out, and that the writer stores
--- the row in the canonical columns.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")

--- Runs the real recorder against a fake writer and returns its window rows.
--- @param script function Receives the keystats module.
--- @return table rows Window-switch rows the flush wrote.
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
		keystats.init({ sqlite_path = "/tmp/ergopti_keystats_windows_mock.sqlite" })
		require("tests.support.metrics_consent_fixture").enable(keystats)
		keystats.reset_session()
		script(keystats)
		keystats.flush()
		for _, entry in ipairs(fake_writer.window_switches) do rows[#rows + 1] = entry.row end
		keystats.flush()
		helpers.assert_eq(#fake_writer.window_switches, #rows, "a second flush must not replay the switches")
	end)
	package.loaded[writer_name], package.loaded[keystats_name] = previous_writer, previous_keystats
	if not ok then error(err, 0) end
	return rows
end

helpers.describe("keystats window switches: the recorder", function()
	helpers.it("writes each title change with the outgoing title's time", function()
		local rows = recorded(function(keystats)
			keystats.set_window_title("org.mozilla.firefox", "Inbox", 1000)
			keystats.set_window_title("org.mozilla.firefox", "Inbox", 1500)
			keystats.set_window_title("org.mozilla.firefox", "Docs", 4000)
		end)
		helpers.assert_eq(#rows, 1, "an unchanged title is no switch")
		helpers.assert_eq(rows[1].prev_title, "Inbox")
		helpers.assert_eq(rows[1].next_title, "Docs")
		helpers.assert_eq(rows[1].duration_ms, 3000)
		helpers.assert_eq(type(rows[1].app), "string")
	end)

	helpers.it("files a switch into another application under the outgoing one, as Windows does", function()
		local rows = recorded(function(keystats)
			keystats.set_window_title("org.mozilla.firefox", "Inbox", 1000)
			keystats.set_window_title("org.gnome.TextEditor", "notes.txt", 2000)
		end)
		helpers.assert_eq(#rows, 1)
		helpers.assert_eq(rows[1].prev_title, "Inbox")
		helpers.assert_eq(rows[1].next_title, "notes.txt")
	end)

	helpers.it("records no title of an application kept out of the metrics", function()
		local rows = recorded(function(keystats)
			keystats.set_disabled_apps({ "org.keepassxc.KeePassXC" })
			keystats.set_window_title("org.mozilla.firefox", "Inbox", 1000)
			keystats.set_window_title("org.keepassxc.KeePassXC", "Passwords.kdbx", 2000)
			keystats.set_window_title("org.mozilla.firefox", "Inbox again", 3000)
		end)
		helpers.assert_eq(#rows, 0)
	end)
end)

helpers.describe("keystats window switches: the writer", function()
	helpers.it("stores the canonical events_window_switch columns", function()
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
			helpers.assert_true(writer.insert_window_switch_events("owned-device", { {
				ts = "2026-10-24 10:00:00", date = "2026-10-24", app = "Firefox",
				prev_title = "It's mine", next_title = "Docs", duration_ms = 3000,
			} }))
			local rows = assert(writer.query_rows(
				"SELECT date,app,prev_title,next_title,duration_ms FROM events_window_switch;"))
			helpers.assert_eq(rows, { "2026-10-24|Firefox|It's mine|Docs|3000" })
		end, debug.traceback)
		writer.close_db()
		os.execute("rm -rf '" .. dir .. "'")
		if not ok then error(failure, 0) end
	end)
end)
