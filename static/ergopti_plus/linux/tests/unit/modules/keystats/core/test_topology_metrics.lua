--- tests/unit/modules/keystats/core/test_topology_metrics.lua

--- ==============================================================================
--- MODULE: Linux Window Topology And Capture Presence
--- DESCRIPTION:
--- Windows records the focused window's moves, resizes, state and monitor
--- changes in events_window_topo and the presence of a capture program in
--- events_av; Linux recorded neither. These tests pin the shared reducers
--- through the Linux sampler, the procfs program scan, the Wayland « not
--- measured » availability, and the join from the recorder to the SQLite rows.
--- ==============================================================================

local helpers = require("tests.helpers")
local it = helpers.it

local Fakes = helpers.load_module("tests.fakes")
local Home = require("tests.support.keystats_home_fixture")
local Preferences = require("tests.support.metrics_preferences_fixture")
local Timings = require("core.timing.engine.timings")

local TOPO_MS = Timings.ms("keystats", "topo_tick_ms")
local SCAN_MS = Timings.ms("keystats", "av_state_slow_tick_ms")

--- A sampler over scripted readings; returns it, the recorded rows and the controls.
--- @param opts table|nil { topology = false } to run without a topology source.
local function scripted(opts)
	opts = opts or {}
	local Topology = helpers.load_module("modules.keystats.topology_metrics")
	local rows, now, observation, names = {}, 0, nil, {}
	local sampler = Topology.new({
		record = function(kind, fields)
			local row = { kind = kind }
			for key, value in pairs(fields) do if key ~= "app" then row[key] = value end end
			rows[#rows + 1] = row
		end,
		topology = opts.topology ~= false and function() return observation end or nil,
		processes = function() return names end,
		now_ms = function() return now end,
	})
	local control = {}
	--- Shows one window, then runs one topology poll.
	function control.window(window, x, y, w, h, state, monitor)
		observation = { window = window, x = x, y = y, w = w, h = h, state = state or "normal", monitor = monitor }
		sampler.tick()
		now = now + TOPO_MS
	end
	function control.processes(list) names = list end
	function control.advance(ms) now = now + ms end
	return sampler, rows, control
end

local LEFT = { id = "0,0,1920,1080", width = 1920 }
local RIGHT = { id = "1920,0,3840,1080", width = 1920 }

helpers.describe("Linux window topology: the shared reducer", function()
	it("linux-topology-move: a settled move is one window_move with the Windows keys", function()
		local _, rows, control = scripted()
		control.window(7, 100, 100, 800, 600)
		control.window(7, 300, 120, 800, 600)
		helpers.assert_eq(#rows, 0, "a change seen on one poll only is a drag in progress")
		control.window(7, 320, 130, 800, 600)
		helpers.assert_eq(rows, { { kind = "window_move", from_x = 100, from_y = 100, to_x = 320, to_y = 130 } })
		control.window(7, 323, 131, 800, 600)
		control.window(7, 323, 131, 800, 600)
		helpers.assert_eq(#rows, 1, "a shift under the move threshold is jitter")
	end)

	it("linux-topology-resize: a settled resize keeps the old and new size", function()
		local _, rows, control = scripted()
		control.window(7, 0, 0, 800, 600)
		control.window(7, 0, 0, 1000, 700)
		control.window(7, 0, 0, 1000, 700)
		helpers.assert_eq(rows, { { kind = "window_resize", old_w = 800, old_h = 600, new_w = 1000, new_h = 700 } })
	end)

	it("linux-topology-state: maximized and snapped are states, a new window is a new baseline", function()
		local _, rows, control = scripted()
		control.window(7, 50, 50, 800, 600, "normal", LEFT)
		control.window(7, 0, 0, 1920, 1080, "maximized", LEFT)
		control.window(7, 0, 0, 1920, 1080, "maximized", LEFT)
		control.window(7, 0, 0, 961, 1080, "normal", LEFT)
		control.window(7, 0, 0, 961, 1080, "normal", LEFT)
		helpers.assert_eq(rows[1], { kind = "window_state_change", from_state = "normal", to_state = "maximized",
			x = 0, y = 0, w = 1920, h = 1080 })
		helpers.assert_eq(rows[2].to_state, "snapped", "half the monitor's width, within the tolerance, is snapped")
		control.window(9, 500, 500, 300, 200, "normal", LEFT)
		control.window(9, 500, 500, 300, 200, "normal", LEFT)
		helpers.assert_eq(#rows, 2, "another window of another size is no resize")
	end)

	it("linux-topology-monitor: a cross-monitor drag records the move and the monitor change", function()
		local _, rows, control = scripted()
		control.window(7, 100, 100, 800, 600, "normal", LEFT)
		control.window(7, 2100, 100, 800, 600, "normal", RIGHT)
		control.window(7, 2100, 100, 800, 600, "normal", RIGHT)
		helpers.assert_eq(rows, {
			{ kind = "window_move", from_x = 100, from_y = 100, to_x = 2100, to_y = 100 },
			{ kind = "monitor_focus_change", from_monitor = LEFT.id, to_monitor = RIGHT.id },
		})
	end)

	it("linux-topology-unmeasured: without a source nothing is read and the menu names the reason", function()
		local Topology = helpers.load_module("modules.keystats.topology_metrics")
		Topology.bind_topology_source(nil, "platform_reason.window_topology_needs_x11")
		helpers.assert_eq(Topology.window_topology_availability(),
			{ measured = false, reason = "platform_reason.window_topology_needs_x11" })
		Topology.bind_topology_source(function() return nil end)
		helpers.assert_eq(Topology.window_topology_availability(), { measured = true })
		local _, rows, control = scripted({ topology = false })
		control.window(7, 0, 0, 800, 600)
		control.window(7, 300, 0, 800, 600)
		control.window(7, 300, 0, 800, 600)
		helpers.assert_eq(#rows, 0, "Wayland records no topology at all")
	end)
end)

helpers.describe("Linux capture-program presence", function()
	it("linux-capture-presence: start and end name the program, an unreadable list keeps the state", function()
		local sampler, rows, control = scripted({ topology = false })
		control.processes({ "bash", "OBS", "zoom" })
		sampler.tick()
		helpers.assert_eq(rows, { { kind = "screen_recording_start", exe = "obs" } })
		control.advance(SCAN_MS - 1)
		control.processes({ "bash" })
		sampler.tick()
		helpers.assert_eq(#rows, 1, "the scan runs at the Windows slow cadence, not on every tick")
		control.advance(1)
		control.processes(nil)
		sampler.tick()
		helpers.assert_eq(#rows, 1, "an unreadable process list is no end")
		control.advance(SCAN_MS)
		control.processes({ "zoom" })
		sampler.tick()
		helpers.assert_eq(#rows, 1, "another capture program keeps the interval the first one opened")
		control.advance(SCAN_MS)
		control.processes({ "bash" })
		sampler.tick()
		helpers.assert_eq(rows[2], { kind = "screen_recording_end", exe = "obs" })
		control.processes({ "kooha" })
		control.advance(SCAN_MS)
		sampler.tick()
		sampler.close()
		helpers.assert_eq(rows[4], { kind = "screen_recording_end", exe = "kooha" }, "stopping closes an open interval")
	end)

	it("linux-capture-procfs: the scan reads numeric entries' comm, bounded, without forking", function()
		local Topology = helpers.load_module("modules.keystats.topology_metrics")
		local reads = 0
		local function list() return { { name = "self" }, { name = "12" }, { name = "13" }, { name = "14" } } end
		local function read(path)
			reads = reads + 1
			return ({ ["/p/12/comm"] = "obs", ["/p/13/comm"] = "" })[path]
		end
		helpers.assert_eq(Topology.process_names("/p", list, read), { "obs" }, "an exited process has no name")
		helpers.assert_eq(reads, 3, "non-numeric entries are not processes")
		helpers.assert_nil(Topology.process_names("/p", function() return nil end, read), "an unlistable /proc is unknown")
		local saved = Topology.MAX_PROCESSES
		Topology.MAX_PROCESSES, reads = 2, 0
		Topology.process_names("/p", list, read)
		Topology.MAX_PROCESSES = saved
		helpers.assert_eq(reads, 1, "the listing is bounded")
	end)
end)

--- Runs the real recorder with a fake writer.
--- @param script function Receives the keystats module and the fake writer.
local function with_recorder(script)
	Preferences.with(function()
		Home.run(function()
			local fake_writer = setmetatable({
				open_db = function() return true end,
				ensure_token_encoding = function() return true end,
				ensure_awake_definition = function() return true end,
				register_device = function() return true end,
				read_open_walk = function() return nil, true end,
				upsert_open_walk = function() return true end,
				read_system_day = function() return nil, true end,
				is_available = function() return true end,
				bump_rev = function() return true end,
			}, { __index = Fakes.sqlite_writer() })
			require("tests.support.sqlite_flush_fake").attach(fake_writer)
			local names = { "modules.keystats.sqlite_writer", "modules.keystats.keystats" }
			local previous = {}
			for _, name in ipairs(names) do previous[name] = package.loaded[name] end
			package.loaded[names[1]], package.loaded[names[2]] = fake_writer, nil
			local ok, err = pcall(function()
				local keystats = require(names[2])
				keystats.init(Home.options())
				require("tests.support.metrics_consent_fixture").enable(keystats)
				script(keystats, fake_writer)
			end)
			for _, name in ipairs(names) do package.loaded[name] = previous[name] end
			if not ok then error(err, 0) end
		end)
	end)
end

helpers.describe("Linux topology rows: the recorder and the writer", function()
	it("linux-topology-recorder: each kind reaches its Windows table with only its own keys", function()
		with_recorder(function(keystats, writer)
			keystats.record_topology_event("window_move", { from_x = 1, from_y = 2, to_x = 30, to_y = 40, title = "secret" })
			keystats.record_topology_event("screen_recording_start", { exe = "obs", pid = 4242 })
			keystats.set_enabled(false)
			keystats.record_topology_event("window_resize", { old_w = 1, old_h = 1, new_w = 20, new_h = 20 })
			keystats.set_enabled(true)
			keystats.flush()
			helpers.assert_eq(#writer.window_topo_events, 1, "a change seen while recording is off is dropped")
			helpers.assert_eq(writer.window_topo_events[1].row.kind, "window_move")
			helpers.assert_eq(writer.window_topo_events[1].row.meta, { from_x = 1, from_y = 2, to_x = 30, to_y = 40 })
			helpers.assert_eq(#writer.av_events, 1)
			helpers.assert_eq(writer.av_events[1].row.meta, { exe = "obs" }, "no pid reaches a row")
			helpers.assert_true(not pcall(keystats.record_topology_event, "virtual_desktop_switch", {}),
				"the Windows focus heuristic is no Linux kind: X11 records the real desktop")
		end)
	end)

	it("linux-topology-writer: the rows are stored in events_window_topo and events_av", function()
		local has_sqlite = os.execute("command -v sqlite3 >/dev/null 2>&1")
		if not (has_sqlite == true or has_sqlite == 0) then
			print("  [topology writer not executed: sqlite3 unavailable]")
			return
		end
		local writer = helpers.load_module("modules.keystats.sqlite_writer")
		local dir = os.tmpname()
		os.remove(dir)
		local ok, failure = xpcall(function()
			helpers.assert_true(writer.open_db(dir .. "/metrics.sqlite"))
			helpers.assert_true(writer.insert_window_topo_events("owned-device", {
				{ ts = "2026-11-10 10:00:00", date = "2026-11-10", kind = "monitor_focus_change", app = "Editor's",
					meta = { from_monitor = "0,0,1920,1080", to_monitor = "1920,0,3840,1080" } },
			}))
			helpers.assert_true(writer.insert_av_events("owned-device", {
				{ ts = "2026-11-10 10:00:01", date = "2026-11-10", kind = "screen_recording_end", app = "Editor's",
					meta = { exe = "obs" } },
			}))
			helpers.assert_eq(assert(writer.query_rows("SELECT kind,app,meta_json FROM events_window_topo;")),
				{ 'monitor_focus_change|Editor\'s|{"from_monitor":"0,0,1920,1080","to_monitor":"1920,0,3840,1080"}' })
			helpers.assert_eq(assert(writer.query_rows("SELECT kind,meta_json FROM events_av;")),
				{ 'screen_recording_end|{"exe":"obs"}' })
		end, debug.traceback)
		writer.close_db()
		os.execute("rm -rf '" .. dir .. "'")
		if not ok then error(failure, 0) end
	end)

	it("linux-topology-ledger: the device ledger exports both tables", function()
		local Ledger = helpers.load_module("modules.keystats.metrics_ledger")
		local sql = Ledger.export_query("linux-device", 0, 10)
		helpers.assert_true(sql:find("FROM events_window_topo WHERE", 1, true) ~= nil)
		helpers.assert_true(sql:find("FROM events_av WHERE", 1, true) ~= nil)
	end)
end)
