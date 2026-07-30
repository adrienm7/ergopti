--- tests/unit/ui/test_wpm_widget_mouse_callback_stale_geometry.lua

--- ==============================================================================
--- MODULE: Regression — WPM widget mouseCallback stale geometry (F-LOW-9)
--- DESCRIPTION:
--- The floating widget's canvas mouseCallback closure is installed exactly once,
--- inside `if not _canvas then` at canvas-creation time. That closure's mouseUp
--- handler converts the dragged frame back into a "compact anchor" position using
--- canvas_width/compact_w/compact_h — but those are plain locals re-declared on
--- every update_widget_body() cycle, so the closure kept reading whichever
--- values happened to be in scope the ONE time it was created.
---
--- If the user later toggles graph mode (M.start(show_graph) with a different
--- mode while already running), update_widget_body() runs again and recomputes
--- fresh geometry for the NEW mode, but the existing canvas is only repositioned
--- (:frame()), never recreated, so the stale closure survives untouched. A drag
--- performed after the toggle then persists a corrupted _pos_x/_pos_y computed
--- from the OLD mode's dimensions.
---
--- Fix: publish each cycle's geometry into a shared, mutable _canvas_geom table
--- that update_widget_body() overwrites every call, and have the mouseCallback
--- closure read from that table instead of the frozen locals.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("wpm_widget: mouseCallback reads live geometry across a graph-mode toggle (F-LOW-9)", function()
	--- Builds a minimal but stateful hs.canvas mock: level/behavior/replaceElements/
	--- show/hide/delete are no-ops, frame() is a real get-or-set, and
	--- mouseCallback(fn) captures fn into `captured.mouse_cb` so the test can
	--- invoke it directly, exactly like a real drag would trigger it.
	--- @param captured table Output slot; captured.mouse_cb receives the callback.
	--- @return function hs.canvas.new-compatible constructor.
	local function make_canvas_ctor(captured)
		return function(initial_frame)
			local self = { _frame = initial_frame }
			function self.level(s, _lvl) return s end
			function self.behavior(s, _b) return s end
			function self.replaceElements(s, _elems) return s end
			function self.show(s) return s end
			function self.hide(s) return s end
			function self.delete(s) return s end
			function self.frame(s, new_frame)
				if new_frame then s._frame = new_frame end
				return s._frame
			end
			function self.mouseCallback(s, fn) captured.mouse_cb = fn; return s end
			captured.canvas = self
			return self
		end
	end

	--- Loads wpm_widget with a full screen/canvas/timer stub set so
	--- update_widget_body() can run to completion headlessly.
	--- @return table Widget module, table Captured mouseCallback + canvas handle.
	local function load_widget()
		local captured = {}
		local full_frame = { x = 0, y = 0, w = 2000, h = 1200 }
		local work_frame = { x = 0, y = 0, w = 2000, h = 1160 }  -- 40px dock/menu bar

		-- Must be installed BEFORE load_with_stubs — wpm_widget.lua captures
		-- `local keylogger = require("modules.keylogger")` at its own require
		-- time, which happens INSIDE load_with_stubs (it returns require(name)
		-- at the end). Setting package.loaded afterwards would be too late.
		package.loaded["modules.keylogger"] = {
			-- A non-zero wpm keeps update_widget_body's "show" branch active on
			-- every cycle, regardless of the idle-timer bookkeeping.
			get_live_stats = function() return { wpm = 42 } end,
		}
		-- GraphicsRenderer captures `hs` at module load. Reload it under this
		-- scenario's canvas constructor rather than reusing a prior test's adapter.
		package.loaded["adapters.graphics_renderer"] = nil
		local Widget = helpers.load_with_stubs("ui.wpm.wpm_widget", {
			screen = {
				mainScreen = function()
					return {
						fullFrame = function() return full_frame end,
						frame     = function() return work_frame end,
					}
				end,
			},
			canvas = {
				new = make_canvas_ctor(captured),
				-- The production adapter applies these constants before returning the
				-- canvas. Keep this focused fixture contract-faithful rather than
				-- accidentally relying on a canvas stub cached by an earlier test.
				windowBehaviors = { canJoinAllSpaces = 0 },
				windowLevels = { overlay = 0, floating = 0 },
			},
			timer = {
				new = function(_interval, fn) return { start = function() end, stop = function() end, _fn = fn } end,
				absoluteTime = function() return 0 end,
			},
			eventtap = {
				new = function(_types, _cb) return { start = function() end, stop = function() end } end,
				event = { types = { mouseMoved = 1, leftMouseDown = 2, rightMouseDown = 3, scrollWheel = 4 } },
			},
		})
		return Widget, captured
	end

	helpers.it("mouseUp after a graph-mode toggle uses the NEW geometry, not the creation-time one", function()
		local Widget, captured = load_widget()

		-- First cycle: starts in compact mode, creates the canvas and captures
		-- the mouseCallback closure with compact-mode geometry in scope.
		Widget.start(false)
		helpers.assert_true(type(captured.mouse_cb) == "function",
			"update_widget_body must install a mouseCallback on canvas creation")

		-- Toggle graph mode while already running: start()'s _running-guard only
		-- skips the redundant work when the mode is UNCHANGED, so a real mode
		-- flip still falls through and calls update_widget_body() again with
		-- graph-mode geometry — same canvas instance, new dimensions.
		Widget.start(true)

		-- Simulate a drag ending at an arbitrary drop point: mouseDown captures
		-- the start frame, then the canvas frame is set to the drop position
		-- (exactly what a real mouseMove sequence would leave behind), then
		-- mouseUp reads c:frame() to compute the persisted anchor.
		captured.mouse_cb(captured.canvas, "mouseDown", 1, 0, 0)
		local drop_frame = { x = 300, y = 200, w = 999, h = 999 }
		captured.canvas:frame(drop_frame)
		captured.mouse_cb(captured.canvas, "mouseUp", 1, 0, 0)

		-- Graph-mode geometry for this fixture: dock_height = (full_frame.y+h)
		-- - (work_frame.y+h) = 1200 - 1160 = 40 (>= the 20 clamp floor, so it is
		-- used as-is). canvas_height = dock_height - graph_margin - 5 = 40-5-5 = 30.
		-- canvas_width = canvas_height * 3 = 90.
		local expected_canvas_w = 90
		local expected_canvas_h = 30

		-- compact_w/compact_h come from the real shared CONFIG (no test double —
		-- reuse the widget's own exposed loader so this test does not hardcode
		-- a magic number that could silently drift from constants.toml).
		local cfg = Widget._load_shared_const()
		local compact_w = cfg.compact_width
		local compact_h = cfg.compact_height_number + cfg.compact_height_gap + cfg.compact_height_unit

		local expected_x = drop_frame.x + expected_canvas_w - compact_w
		local expected_y = drop_frame.y + expected_canvas_h - compact_h

		local pos_x = hs.settings.get("ergopti.wpm_widget.pos_x")
		local pos_y = hs.settings.get("ergopti.wpm_widget.pos_y")

		helpers.assert_eq(pos_x, expected_x,
			"mouseUp must convert the drop frame using the CURRENT (graph-mode) canvas_width/compact_w, not a stale compact-mode value")
		helpers.assert_eq(pos_y, expected_y,
			"mouseUp must convert the drop frame using the CURRENT (graph-mode) canvas_height/compact_h, not a stale compact-mode value")
	end)
end)

helpers.describe("wpm_widget: mouseCallback closure sources geometry from _canvas_geom (F-LOW-9)", function()
	local function read_src()
		-- Selected by a declaration unique to ui/wpm/wpm_widget.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function resolve_shared_constants_path")
		helpers.assert_true(src ~= nil, "ui/wpm/wpm_widget.lua source must be locatable")
		return src
	end

	helpers.it("declares a shared, mutable _canvas_geom table", function()
		local src = read_src()
		helpers.assert_true(src:find("local _canvas_geom", 1, true) ~= nil,
			"wpm_widget.lua must declare a _canvas_geom table shared between update_widget_body and the mouseCallback closure")
	end)

	helpers.it("the mouseUp handler reads _canvas_geom fields, not the plain creation-time locals", function()
		local src = read_src()
		local mouseup_pos = src:find('elseif event == "mouseUp" then', 1, true)
		helpers.assert_true(mouseup_pos ~= nil, "mouseCallback must handle the mouseUp event")
		local mouseup_body = src:sub(mouseup_pos, mouseup_pos + 700)
		helpers.assert_true(mouseup_body:find("_canvas_geom.canvas_width", 1, true) ~= nil,
			"mouseUp must read _canvas_geom.canvas_width instead of the frozen canvas_width local")
		helpers.assert_true(mouseup_body:find("_canvas_geom.compact_w", 1, true) ~= nil,
			"mouseUp must read _canvas_geom.compact_w instead of the frozen compact_w local")
	end)
end)
