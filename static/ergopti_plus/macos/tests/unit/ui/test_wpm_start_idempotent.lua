--- tests/unit/ui/test_wpm_start_idempotent.lua

--- ==============================================================================
--- MODULE: Regression — WPM widget/menubar start() is idempotent
--- DESCRIPTION:
--- menu_metrics.build() re-syncs WPM visibility on every menu tree rebuild by
--- calling WpmMenubar.start() / WpmWidget.start(). Those start() functions were
--- not idempotent: each call did _timer:start() again AND re-rendered (a full
--- canvas redraw for the widget, a menubar re-title for the menubar). A burst of
--- menu rebuilds (boot, every state toggle) therefore restarted the polling
--- timers and forced redundant redraws — wasted work plus a visible flicker for
--- the floating widget.
---
--- Fix: a `_running` flag guards both modules. start() returns early when already
--- running (the widget also re-runs when the graph mode actually changes), and
--- stop() returns early when there is nothing to tear down. The 0.2 s / 0.5 s
--- timers keep the display fresh, so skipping the redundant immediate redraw is
--- safe. Pause-gating (stop on pause, start on resume) is preserved because the
--- first start after a stop is never "already running".
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("wpm_menubar.start() is idempotent (no redundant timer restart)", function()
	-- Counts hs.timer:start() calls so we can prove a burst of start() calls only
	-- arms the polling timer once. update_menubar reads keylogger stats but never
	-- touches hs.screen, so the menubar is safe to drive headless.
	local function load_menubar()
		package.loaded["modules.keylogger"] = { get_live_stats = function() return {} end }
		local starts = { n = 0 }
		local Menubar = helpers.load_with_stubs("ui.wpm.wpm_menubar", {
			timer = {
				new = function(_interval, _fn)
					return { start = function() starts.n = starts.n + 1 end, stop = function() end }
				end,
				absoluteTime = function() return 0 end,
			},
		})
		return Menubar, starts
	end

	helpers.it("arms the polling timer once across repeated start() calls", function()
		local Menubar, starts = load_menubar()
		Menubar.start()
		Menubar.start()
		Menubar.start()
		helpers.assert_eq(starts.n, 1)
	end)

	helpers.it("re-arms after a stop() (pause/resume cycle still works)", function()
		local Menubar, starts = load_menubar()
		Menubar.start()       -- arm (n = 1)
		Menubar.stop()        -- pause tears it down
		Menubar.start()       -- resume re-arms (n = 2)
		helpers.assert_eq(starts.n, 2)
	end)

	helpers.it("stop() is safe to call repeatedly when already stopped", function()
		local Menubar = (load_menubar())
		-- No start() yet: stop() must early-return without error.
		-- Called directly. A second stop must leave the widget restartable: the menu
		-- toggle stops before it starts.
		Menubar.stop()
		Menubar.stop()
		helpers.assert_eq(type(Menubar.start), "function",
			"a double stop must leave the menubar startable")
	end)
end)

-- The floating widget positions itself via hs.screen at start(), which the stub
-- hs does not model, so its idempotency is pinned structurally at source: the
-- guard exists, keys off the graph mode (so a real graph change still redraws),
-- and the lifecycle flag is set in start()/stop().
helpers.describe("wpm_widget.start() guards redundant restarts at source", function()
	local function read_src()
		-- Selected by a declaration unique to ui/wpm/wpm_widget.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function resolve_shared_constants_path")
		helpers.assert_true(src ~= nil, "ui/wpm/wpm_widget.lua source must be locatable")
		return src
	end

	helpers.it("declares a _running lifecycle flag", function()
		helpers.assert_true(read_src():find("local _running", 1, true) ~= nil,
			"wpm_widget must declare a _running flag to guard redundant start()/stop()")
	end)

	helpers.it("start() early-returns only when already running with the same graph mode", function()
		local src = read_src()
		-- The guard must key off BOTH _running and the graph mode, so a genuine
		-- graph-mode change still falls through to redraw.
		helpers.assert_true(src:find("if _running and _show_graph == want_graph then return end", 1, true) ~= nil,
			"start() must early-return on (already running AND same graph mode) — not on _running alone")
	end)

	helpers.it("sets _running true in start() and false in stop()", function()
		local src = read_src()
		helpers.assert_true(src:find("_running = true", 1, true) ~= nil,
			"start() must set _running = true")
		helpers.assert_true(src:find("_running = false", 1, true) ~= nil,
			"stop() must clear _running = false")
	end)
end)
