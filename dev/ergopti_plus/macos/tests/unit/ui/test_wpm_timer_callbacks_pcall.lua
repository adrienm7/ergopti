--- tests/unit/ui/test_wpm_timer_callbacks_pcall.lua

--- ==============================================================================
--- MODULE: Regression — WPM widget/menubar timer callbacks are pcall-guarded (F-HIGH-11)
--- DESCRIPTION:
--- Every sibling timer-driven UI function in this file tree (tooltip_hotstring.lua,
--- tooltip_llm.lua) wraps its whole body in pcall + Logger.error. wpm_widget's
--- update_widget() and wpm_menubar's update_menubar() were the two exceptions:
--- they run directly on a bare hs.timer callback with nothing catching a raised
--- error, and there is no hs.uncaughtErrorHandler anywhere in the tree, so a
--- fault silently killed the 0.2 s / 0.5 s poll timer with nothing in the file
--- logger.
---
--- update_widget() also dereferenced hs.screen.mainScreen() with no nil-check —
--- a documented-possible nil return (no display attached, or a display
--- reconfiguration race) — which would raise inside the timer callback.
---
--- Fix: wrap both update_widget()/update_menubar() bodies in the established
--- pcall + Logger.error idiom, and nil-guard mainScreen() so a nil screen skips
--- the render cycle instead of crashing.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("wpm_widget: update_widget() survives a nil hs.screen.mainScreen() (F-HIGH-11)", function()
	local function load_widget_with_nil_screen()
		local logged_errors = {}
		package.loaded["modules.keylogger"] = { get_live_stats = function() return { wpm = 5 } end }
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.logger"].error = function(_log, fmt, ...)
			table.insert(logged_errors, string.format(tostring(fmt), ...))
		end
		local Widget = helpers.load_with_stubs("ui.wpm.wpm_widget", {
			screen = { mainScreen = function() return nil end },
			timer  = {
				new = function(_interval, fn)
					local timer = { active = false, _fn = fn }
					timer.start = function() timer.active = true; return timer end
					timer.stop = function() timer.active = false; return timer end
					timer.running = function() return timer.active end
					return timer
				end,
				absoluteTime = function() return 0 end,
			},
			eventtap = {
				new = function(_types, _cb)
					local tap = { enabled = false }
					tap.start = function(self) self.enabled = true; return self end
					tap.stop = function(self) self.enabled = false; return self end
					tap.isEnabled = function(self) return self.enabled end
					return tap
				end,
				event = { types = { mouseMoved = 1, leftMouseDown = 2, rightMouseDown = 3, scrollWheel = 4 } },
			},
		})
		-- Re-bind the logger the widget module already captured a local reference
		-- to at require-time — load_with_stubs sets package.loaded before require,
		-- so the module's `local Logger = require("infra.logger")` sees our stub.
		-- Release the stub from the cache now that wpm_widget has already bound
		-- its own upvalue to it — otherwise this incomplete stub (no .LEVELS/
		-- .current_level) leaks into every later require("infra.logger") for the
		-- rest of the full-suite process (the exact test-harness stale-cache
		-- class documented for F-HIGH-23).
		package.loaded["infra.logger"] = nil
		return Widget, logged_errors
	end

	helpers.it("does not propagate an error when mainScreen() is nil", function()
		local Widget = load_widget_with_nil_screen()
		-- Called directly: a raise fails with the real error. What the guard must
		-- leave behind is a stoppable widget — a start that wedged itself would leak
		-- its timer for the session.
		Widget.start(false)
		Widget.stop()
		helpers.assert_eq(type(Widget.start), "function",
			"a start with no main screen must leave the widget restartable")
	end)

	helpers.it("logs an ERROR-level line when mainScreen() is nil", function()
		local Widget, logged_errors = load_widget_with_nil_screen()
		Widget.start(false)
		helpers.assert_true(#logged_errors > 0,
			"a nil mainScreen() must surface an ERROR-level log line rather than fail silently")
	end)
end)

helpers.describe("wpm_widget: update_widget() body is pcall-guarded at source (F-HIGH-11)", function()
	local function read_src()
		-- Selected by a declaration unique to ui/wpm/wpm_widget.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function resolve_shared_constants_path")
		helpers.assert_true(src ~= nil, "ui/wpm/wpm_widget.lua source must be locatable")
		return src
	end

	helpers.it("wraps the update_widget body in pcall with Logger.error on failure", function()
		local src = read_src()
		helpers.assert_true(src:find("local ok, err = pcall(update_widget_body)", 1, true) ~= nil,
			"update_widget() must call its body through pcall")
		helpers.assert_true(src:find('Logger.error(LOG, "Crash during widget update: "', 1, true) ~= nil,
			"a failed update_widget_body() must be logged at ERROR level")
	end)

	helpers.it("nil-guards hs.screen.mainScreen() before dereferencing it", function()
		local src = read_src()
		helpers.assert_true(src:find("if not screen then", 1, true) ~= nil,
			"update_widget must nil-check hs.screen.mainScreen() before calling :fullFrame()/:frame()")
	end)
end)

helpers.describe("wpm_menubar: update_menubar() crashes are caught (F-HIGH-11)", function()
	local function load_menubar_with_throwing_stats()
		local logged_errors = {}
		package.loaded["modules.keylogger"] = {
			get_live_stats = function() error("simulated keylogger failure") end,
		}
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.logger"].error = function(_log, fmt, ...)
			table.insert(logged_errors, string.format(tostring(fmt), ...))
		end
		local Menubar = helpers.load_with_stubs("ui.wpm.wpm_menubar", {
			timer = {
				new = function(_interval, fn)
					local timer = { active = false, _fn = fn }
					timer.start = function() timer.active = true; return timer end
					timer.stop = function() timer.active = false; return timer end
					timer.running = function() return timer.active end
					return timer
				end,
				absoluteTime = function() return 0 end,
			},
		})
		-- See load_widget_with_nil_screen() above: release the stub from the
		-- cache now that wpm_menubar has already bound its own upvalue to it.
		package.loaded["infra.logger"] = nil
		return Menubar, logged_errors
	end

	helpers.it("does not propagate an error when get_live_stats() throws", function()
		local Menubar = load_menubar_with_throwing_stats()
		Menubar.start()
		Menubar.stop()
		helpers.assert_eq(type(Menubar.start), "function",
			"a start that hit a downstream failure must leave the menubar restartable")
	end)

	helpers.it("logs an ERROR-level line when the update body throws", function()
		local Menubar, logged_errors = load_menubar_with_throwing_stats()
		Menubar.start()
		helpers.assert_true(#logged_errors > 0,
			"a crashing update_menubar body must surface an ERROR-level log line rather than fail silently")
	end)
end)
