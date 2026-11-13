--- tests/unit/metrics/ui/wpm/test_widget_mouse_throttle.lua

--- A single pointer event after a real key must survive adjacent mouse events.
--- Rendering an effective WPM or a held source cannot refresh that key's clock.

local helpers = require("tests.helpers")
local with_widget = require("tests.support.metrics.wpm_widget_fixture")

helpers.describe("WPM widget physical input visibility", function()
	helpers.it("(wpm-pointer-parity) hides for a single move after a key, including inside the former throttle", function()
		with_widget(function(widget, state)
			helpers.assert_true(widget.start(false))
			local canvas = state.canvases[1]
			state.now = 1.01
			state.taps[1].run()
			state.timers[1].run()
			helpers.assert_eq(canvas.hidden, true, "nonzero WPM does not override the pointer")
			state.now, state.last_input = 1.02, 1.02
			state.timers[1].run()
			helpers.assert_eq(canvas.hidden, false, "a real key restores visibility")
			state.now = 1.03
			state.taps[1].run()
			state.timers[1].run()
			helpers.assert_eq(canvas.hidden, true, "the sole move after that key cannot be throttled")
			state.now, state.preview = 1.04, true
			state.timers[1].run()
			helpers.assert_eq(canvas.hidden, false, "preview overrides pointer hiding")
			state.now, state.preview = 1.05, false
			state.timers[1].run()
			helpers.assert_eq(canvas.hidden, true, "closing preview restores pointer hiding")
			state.now, state.last_input = 1.1, 1.1
			state.timers[1].run()
			helpers.assert_eq(canvas.hidden, false)
			state.now = 100
			state.timers[1].run()
			helpers.assert_eq(canvas.hidden, true, "refreshes cannot postpone keyboard idle")
			helpers.assert_true(widget.stop())
		end)
	end)
	helpers.it("(wpm-pointer-parity) keeps the canvas visible until its active drag releases", function()
		with_widget(function(widget, state)
			helpers.assert_true(widget.start(false))
			local canvas = state.canvases[1]
			state.now = 1.1
			state.taps[1].run()
			canvas.mouse_callback(canvas, "mouseDown", 1, 0, 0)
			state.timers[1].run()
			helpers.assert_eq(canvas.hidden, false, "the held widget cannot disappear during its drag")
			canvas.mouse_callback(canvas, "mouseUp", 1, 0, 0)
			state.timers[1].run()
			helpers.assert_eq(canvas.hidden, true, "release restores the real keyboard/pointer rule")
			helpers.assert_true(widget.stop())
		end)
	end)
end)
