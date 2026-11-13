--- tests/unit/metrics/ui/wpm/test_widget_default_anchor_display_change.lua

--- ==============================================================================
--- MODULE: Regression — WPM default anchor follows display changes (WPMM-002)
--- DESCRIPTION:
--- Without a stored position the widget derives its anchor from the main
--- screen. That default used to be written into the cached position, so after a
--- display shrink the canvas stayed at the old, now off-desktop coordinates.
--- The default must be recomputed every draw; only a dragged position persists.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("wpm_widget: default anchor is recomputed after a display shrink (WPMM-002)", function()
	--- @param captured table Output slot receiving the canvas and the mutable screen frame.
	--- @return table Widget module.
	local function load_widget(captured)
		captured.full_frame = { x = 0, y = 0, w = 1600, h = 1000 }
		package.loaded["metrics.engine"] = {
			get_live_stats = function() return { wpm = 42, last_input_time = hs.timer.absoluteTime() / 1000000000 } end,
		}
		package.loaded["core.ui.adapters.graphics_renderer"] = nil
		return helpers.load_with_stubs("metrics.ui.wpm.widget", {
			screen = {
				mainScreen = function()
					return {
						fullFrame = function() return captured.full_frame end,
						frame = function() return captured.full_frame end,
					}
				end,
			},
			canvas = {
				new = function(initial_frame)
					local self = { _frame = initial_frame }
					function self.level(s) return s end
					function self.behavior(s) return s end
					function self.replaceElements(s) return s end
					function self.show(s) return s end
					function self.hide(s) return s end
					function self.delete(s) return s end
					function self.mouseCallback(s) return s end
					function self.canvasMouseEvents(s) return s end
					function self.frame(s, new_frame)
						if new_frame then s._frame = new_frame end
						return s._frame
					end
					captured.canvas = self
					return self
				end,
				windowBehaviors = { canJoinAllSpaces = 0 },
				windowLevels = { overlay = 0, floating = 0 },
			},
			timer = {
				new = function(_interval, fn)
					local timer = { active = false, _fn = fn }
					timer.start = function() timer.active = true; return timer end
					timer.stop = function() timer.active = false; return timer end
					timer.running = function() return timer.active end
					captured.timer_fn = fn
					return timer
				end,
				absoluteTime = function() return 0 end,
			},
			eventtap = {
				new = function()
					local tap = { enabled = false }
					tap.start = function(self) self.enabled = true; return self end
					tap.stop = function(self) self.enabled = false; return self end
					tap.isEnabled = function(self) return self.enabled end
					return tap
				end,
				event = { types = { mouseMoved = 1, leftMouseDown = 2, rightMouseDown = 3, scrollWheel = 4 } },
			},
		})
	end

	helpers.it("moves the canvas onto the shrunken desktop on the next draw", function()
		local captured = {}
		local Widget = load_widget(captured)
		Widget.start(false)
		local before = captured.canvas:frame()
		helpers.assert_true(before.x + before.w <= 1600 and before.y + before.h <= 1000,
			"initial default anchor lies inside the 1600x1000 desktop")

		captured.full_frame = { x = 0, y = 0, w = 800, h = 600 }
		Widget.start(true)  -- a mode change forces another draw on the same canvas
		Widget.start(false)
		local after = captured.canvas:frame()
		helpers.assert_true(after.x + after.w <= 800 and after.y + after.h <= 600,
			"the default anchor must follow the shrunken desktop, got " .. tostring(after.x) .. "," .. tostring(after.y))
		Widget.stop()
	end)
end)
