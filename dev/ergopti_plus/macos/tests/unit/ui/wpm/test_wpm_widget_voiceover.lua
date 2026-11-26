--- tests/unit/ui/wpm/test_wpm_widget_voiceover.lua

--- ==============================================================================
--- MODULE: WPM widget for VoiceOver
--- DESCRIPTION:
--- The widget is an hs.canvas, which VoiceOver cannot read, and the speed it
--- draws changes on every refresh. These cases pin what a running VoiceOver
--- hears: the burst's last speed once, when the widget hides; nothing per
--- refresh, nothing for a burst at zero, nothing on a stop (a11y-macos-wpm).
--- ==============================================================================

local helpers = require("tests.helpers")
local with_widget = require("tests.support.wpm_widget_fixture")

helpers.describe("WPM widget for VoiceOver (a11y-macos-wpm)", function()
	helpers.it("(a11y-macos-wpm) says the burst's last speed once, when the widget hides", function()
		with_widget(function(widget, state)
			helpers.assert_true(widget.start(false))
			local canvas = state.canvases[1]
			state.now, state.last_input = 1.02, 1.02
			state.timers[1].run()
			state.wpm = 57
			state.now, state.last_input = 1.03, 1.03
			state.timers[1].run()
			helpers.assert_eq(canvas.hidden, false)
			helpers.assert_eq(#state.spoken, 0, "nothing is said while the burst goes on")
			state.now = 100
			state.timers[1].run()
			helpers.assert_eq(canvas.hidden, true)
			helpers.assert_eq(state.spoken, { "57 WPM" }, "the last speed drawn, with its unit")
			state.now = 101
			state.timers[1].run()
			helpers.assert_eq(#state.spoken, 1, "a refresh that keeps it hidden says nothing")
			helpers.assert_true(widget.stop())
		end)
	end)

	helpers.it("(a11y-macos-wpm) says nothing for a burst at zero or on a stop", function()
		with_widget(function(widget, state)
			state.wpm = 0
			helpers.assert_true(widget.start(false))
			state.now, state.preview = 1.02, true
			state.timers[1].run()
			state.now, state.preview = 100, false
			state.timers[1].run()
			helpers.assert_eq(#state.spoken, 0, "no speed, nothing to say")
			state.wpm = 40
			state.now, state.last_input = 101, 101
			state.timers[1].run()
			helpers.assert_true(widget.stop())
			helpers.assert_eq(#state.spoken, 0, "a stop or a pause is no burst ending")
		end)
	end)
end)
