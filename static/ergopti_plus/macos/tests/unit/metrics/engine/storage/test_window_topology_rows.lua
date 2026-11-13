--- tests/unit/metrics/engine/storage/test_window_topology_rows.lua

--- ==============================================================================
--- MODULE: macOS Window Topology And Capture Presence Rows
--- DESCRIPTION:
--- Windows records the focused window's moves, resizes, state and monitor
--- changes in events_window_topo and the presence of a capture program in
--- events_av; macOS recorded neither, and build_inserts discarded any such
--- entry as an unknown type. These tests drive the real watcher over scripted
--- ports and the real writer, so the join from the reading to the row is
--- proven, not each half alone.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Starts a fresh watcher over scripted ports.
--- @return table watcher, table entries, table control
local function scripted()
	local Watcher = helpers.load_with_stubs("metrics.adapters.topology_watcher")
	local Timings = require("core.timing.engine.timings")
	local entries, now, observation, ids, private = {}, 0, nil, {}, false
	helpers.assert_true(Watcher.start({
		append = function(entry) entries[#entries + 1] = entry end,
		app = function() return "Code" end,
		private = function() return private end,
		ports = {
			focused = function() return observation end,
			running_bundle_ids = function() return ids end,
			now_ms = function() return now end,
		},
	}))
	local topo_ms = Timings.ms("keystats", "topo_tick_ms")
	local scan_ms = Timings.ms("keystats", "av_state_slow_tick_ms")
	local control = {}
	function control.window(window, x, y, w, h, state, monitor)
		observation = { window = window, x = x, y = y, w = w, h = h, state = state or "normal", monitor = monitor }
		Watcher.tick()
		now = now + topo_ms
	end
	function control.ids(list) ids = list end
	function control.scan() now = now + scan_ms; Watcher.tick() end
	function control.private(value) private = value end
	return Watcher, entries, control
end

helpers.describe("macOS window topology: the watcher", function()
	helpers.it("macos-topology-move: a settled move is one window_move entry for the focused app", function()
		local Watcher, entries, control = scripted()
		control.window(3, 10, 10, 800, 600)
		control.window(3, 200, 10, 800, 600)
		control.window(3, 210, 12, 800, 600)
		helpers.assert_eq(entries, { { type = "window_move", app = "Code", from_x = 10, from_y = 10, to_x = 210, to_y = 12 } })
		Watcher.stop()
	end)

	helpers.it("macos-topology-monitor: a screen change by UUID is a monitor_focus_change", function()
		local Watcher, entries, control = scripted()
		local a, b = { id = "UUID-A", width = 1512 }, { id = "UUID-B", width = 2560 }
		control.window(3, 10, 10, 800, 600, "normal", a)
		control.window(3, 10, 10, 800, 600, "normal", b)
		control.window(3, 10, 10, 800, 600, "normal", b)
		helpers.assert_eq(entries, { { type = "monitor_focus_change", app = "Code", from_monitor = "UUID-A", to_monitor = "UUID-B" } })
		Watcher.stop()
	end)

	helpers.it("macos-topology-private: a private window records nothing and is no baseline", function()
		local Watcher, entries, control = scripted()
		control.private(true)
		control.window(3, 10, 10, 800, 600)
		control.window(3, 400, 10, 800, 600)
		control.window(3, 400, 10, 800, 600)
		helpers.assert_eq(#entries, 0)
		Watcher.stop()
	end)

	-- The capture scan wrote its rows whatever the context (KMM-002,
	-- macos-topology-private).
	helpers.it("macos-topology-private: a capture start seen while logging is refused is not recorded", function()
		local Watcher, entries, control = scripted()
		control.private(true)
		control.ids({ "us.zoom.xos" })
		control.scan()
		helpers.assert_eq(#entries, 0)
		Watcher.stop()
	end)

	-- watchers.lua handed the watchers only the private-window flag, so a
	-- disabled app, a secure field or a system-auth prompt was recorded. The
	-- real watchers.lua starts the real watchers here, over scripted adapters
	-- and a PrivacyContext that refuses on demand.
	helpers.it("macos-topology-private: the watchers ask the whole privacy context", function()
		helpers.with_stub_scope({ "metrics.engine.system.watchers", "metrics.engine.journal.log_manager", "core.logger.engine.logger",
			"metrics.engine.privacy.context", "metrics.adapters.topology_watcher", "metrics.adapters.network_watcher",
			"platform.focus.window_info", "core.network.adapters.info", "core.events.timer_scheduler",
			"metrics.engine.capture.physical_lifecycle_observation", "adapters.physical_observation_clock" }, function()
			package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
			local rows, refused, now, window, ids, reach = {}, true, 0, nil, {}, nil
			package.loaded["metrics.engine.journal.log_manager"] = { append_log = function(entry) rows[#rows + 1] = entry end }
			package.loaded["metrics.engine.privacy.context"] = { allows_logging = function() return not refused end }
			package.loaded["platform.focus.window_info"] = {
				focused_topology = function() return window end,
				running_bundle_ids = function() return ids end,
			}
			package.loaded["core.network.adapters.info"] = {
				watch_host_reachability = function(_, on_status) reach = on_status; return { stop = function() end } end,
				probe_vpn_status = function(answer) answer("down"); return true end,
			}
			local real_scheduler = helpers.load_with_stubs("core.events.timer_scheduler")
			package.loaded["core.events.timer_scheduler"] = setmetatable({ now_ns = function() return now * 1000000 end },
				{ __index = real_scheduler })
			local W = helpers.load_with_stubs("metrics.engine.system.watchers", {
				wifi = false, battery = false, spaces = false, audiodevice = false,
			})
			local Topology = require("metrics.adapters.topology_watcher")
			local Network = require("metrics.adapters.network_watcher")
			helpers.assert_eq(W.init({ is_enabled = true, session_app_name = "Excluded" }, function() return false end), true)
			helpers.assert_eq(W.init_hardware_watchers(), true)
			local function tick() Topology.tick(); Network.tick(); now = now + 60000 end
			local function move(x)
				window = { window = 3, x = x, y = 10, w = 800, h = 600, state = "normal" }
				tick(); tick()
			end
			tick()
			move(10); move(400); ids = { "us.zoom.xos" }; reach("down"); tick(); tick()
			helpers.assert_eq(#rows, 0, "a refused context records no topology, capture or network row")
			refused = false
			move(10); move(400); ids = {}; reach("up"); tick(); tick()
			local kinds = {}
			for _, row in ipairs(rows) do kinds[row.type] = true end
			helpers.assert_true(kinds.window_move == true, "the control records the move")
			W.stop_hardware_watchers()
		end)
	end)

	helpers.it("macos-capture-presence: bundle ids open and close the interval, stop closes it too", function()
		local Watcher, entries, control = scripted()
		control.ids({ "com.apple.Safari", "us.zoom.xos" })
		control.scan()
		control.ids(nil)
		control.scan()
		helpers.assert_eq(#entries, 1, "an unreadable application list is no end")
		control.ids({ "com.apple.Safari" })
		control.scan()
		control.ids({ "com.obsproject.obs-studio" })
		control.scan()
		Watcher.stop()
		helpers.assert_eq(entries, {
			{ type = "screen_recording_start", app = "Code", exe = "us.zoom.xos" },
			{ type = "screen_recording_end", app = "Code", exe = "us.zoom.xos" },
			{ type = "screen_recording_start", app = "Code", exe = "com.obsproject.obs-studio" },
			{ type = "screen_recording_end", app = "Code", exe = "com.obsproject.obs-studio" },
		})
		helpers.assert_eq(Watcher.is_running(), false)
	end)
end)

helpers.describe("macOS window topology: the writer", function()
	helpers.it("macos-topology-rows: each kind is an INSERT into its Windows table with its metadata", function()
		local Writer = helpers.load_with_stubs("metrics.engine.journal.sqlite_writer")
		Writer.init({
			paths = { db = "/tmp/ergopti_test.db" },
			device_obj = { id = "test-device" },
			device_id = "00000000-0000-4000-8000-000000000001",
		})
		local topo = Writer.build_inserts({ type = "window_resize", timestamp = "2026-11-10 10:00:00.000",
			app = "Code", old_w = 800, old_h = 600, new_w = 1000, new_h = 700 })
		helpers.assert_eq(#topo, 1)
		helpers.assert_true(topo[1]:find("INSERT OR IGNORE INTO events_window_topo", 1, true) == 1, topo[1])
		helpers.assert_true(topo[1]:find("'window_resize', 'Code'", 1, true) ~= nil, topo[1])
		helpers.assert_true(topo[1]:find('"new_w":1000', 1, true) ~= nil, topo[1])
		local av = Writer.build_inserts({ type = "screen_recording_start", timestamp = "2026-11-10 10:00:00.000",
			app = "Code", exe = "us.zoom.xos" })
		helpers.assert_true(av[1]:find("INSERT OR IGNORE INTO events_av", 1, true) == 1, av[1])
		helpers.assert_true(av[1]:find('{"exe":"us.zoom.xos"}', 1, true) ~= nil, av[1])
	end)
end)
