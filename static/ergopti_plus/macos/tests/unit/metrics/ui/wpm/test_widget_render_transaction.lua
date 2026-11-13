--- tests/unit/metrics/ui/wpm/test_widget_render_transaction.lua

--- ==============================================================================
--- MODULE: WPM Widget Render Transaction Tests
--- DESCRIPTION:
--- Retired renders cannot resurrect a stopped canvas or mutate its successor.
--- Native render failure must roll back an uncommitted widget startup.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_menubar = require("tests.support.wpm_menubar_fixture")

local with_widget = require("tests.support.wpm_widget_fixture")

helpers.describe("WPM widget render lifecycle", function()
	helpers.it("retains a canvas after deletion failure and retries on stop", function()
		with_widget(function(widget, state)
			helpers.assert_true(widget.start(false))
			state.refuse_canvas_delete = true
			helpers.assert_eq(widget.stop(), false)
			helpers.assert_eq(state.canvases[1].deleted, false)
			helpers.assert_eq(widget.start(false), false, "unsettled canvas blocks restart")
			helpers.assert_eq(#state.canvases, 1)
			state.refuse_canvas_delete = false
			helpers.assert_true(widget.stop())
			helpers.assert_true(state.canvases[1].deleted)
		end)
	end)
	helpers.it("refuses a reentrant start while the previous canvas is being deleted", function()
		with_widget(function(widget, state)
			helpers.assert_true(widget.start(false))
			local attempted = false
			state.on_phase = function(name)
				if name ~= "delete" then return end
				state.on_phase = nil
				attempted = true
				helpers.assert_eq(widget.start(false), false)
			end
			helpers.assert_true(widget.stop())
			helpers.assert_true(attempted)
			helpers.assert_true(widget.start(false))
			helpers.assert_eq(#state.canvases, 2)
			helpers.assert_true(widget.stop())
		end)
	end)
	helpers.it("(wpm-menubar-stop-owner) timer failure logging preserves a restarted native item", function()
		with_menubar(function(menubar, state)
			helpers.assert_eq(menubar.start(), true)
			local scheduler = package.loaded["core.events.timer_scheduler"]
			local cancel, refused = scheduler.cancel, false
			scheduler.cancel = function(handle)
				if not refused then refused = true; return false end
				return cancel(handle)
			end
			state.on_log = function(_, message)
				if not message:find("timer cleanup failed", 1, true) then return end
				state.on_log = nil
				helpers.assert_eq(menubar.start(), true)
			end
			helpers.assert_eq(menubar.stop(), false)
			helpers.assert_eq(menubar.is_running(), true)
			helpers.assert_type(state.timers[2].timer, "table")
			helpers.assert_eq(state.items[#state.items].deleted, false,
				"retired cleanup cannot delete the successor's native item")
			helpers.assert_eq(menubar.stop(), true)
		end)
	end)
	for _, capability in ipairs({ "timer", "tap" }) do
		helpers.it("(wpm-widget-stop-owner) cleanup failure logging preserves a restarted owner: " .. capability, function()
			with_widget(function(widget, state)
				helpers.assert_eq(widget.start(false), true)
				state["refuse_" .. capability .. "_once"] = true
				state.on_phase = function(name)
					if not name:find("cleanup failed", 1, true) then return end
					state.on_phase = nil
					helpers.assert_eq(widget.start(false), true)
				end
				helpers.assert_eq(widget.stop(), false)
				helpers.assert_eq(widget.is_running(), true)
				helpers.assert_eq(state.timers[1].active, false)
				helpers.assert_eq(state.taps[1].enabled, false)
				helpers.assert_eq(state.timers[2].active, true)
				helpers.assert_eq(state.taps[2].enabled, true, "retired cleanup cannot stop a successor tap")
				helpers.assert_eq(state.canvases[#state.canvases].deleted, false,
					"retired cleanup cannot delete a successor surface")
				helpers.assert_eq(widget.stop(), true)
			end)
		end)
	end
	helpers.it("(wpm-widget-start-owner) a stop during startup logging revokes acquisition", function()
		with_widget(function(widget, state)
			state.on_phase = function(name)
				if name ~= "Starting floating WPM widget…" then return end
				state.on_phase = nil
				helpers.assert_eq(widget.stop(), true)
			end
			helpers.assert_eq(widget.start(false), false)
			helpers.assert_eq(widget.is_running(), false)
			helpers.assert_eq(#state.timers, 0)
			helpers.assert_eq(#state.canvases, 0)
		end)
	end)
	helpers.it("(wpm-menubar-start-owner) a stop during startup logging revokes acquisition", function()
		with_menubar(function(menubar, state)
			state.on_log = function(_, message)
				if message ~= "Starting WPM menubar widget…" then return end
				state.on_log = nil
				helpers.assert_eq(menubar.stop(), true)
			end
			helpers.assert_eq(menubar.start(), false)
			helpers.assert_eq(menubar.is_running(), false)
			helpers.assert_eq(#state.timers, 0)
			helpers.assert_eq(#state.items, 0)
		end)
	end)
	for _, boundary in ipairs({ "Stopping floating WPM widget…", "Floating WPM widget stopped." }) do
		helpers.it("(wpm-widget-stop-owner) retains a successor started by " .. boundary, function()
			with_widget(function(widget, state)
				helpers.assert_eq(widget.start(false), true)
				state.on_phase = function(name)
					if name ~= boundary then return end
					state.on_phase = nil
					helpers.assert_eq(widget.start(false), true)
				end
				helpers.assert_eq(widget.stop(), false)
				helpers.assert_eq(widget.is_running(), true)
				helpers.assert_eq(state.timers[1].active, false)
				helpers.assert_eq(state.timers[2].active, true)
				helpers.assert_eq(state.canvases[1].deleted, true)
				helpers.assert_eq(state.canvases[2].deleted, false)
				helpers.assert_eq(widget.stop(), true)
			end)
		end)
	end
	helpers.it("(wpm-widget-start-owner) a start log cannot replace its committed successor", function()
		with_widget(function(widget, state)
			state.on_phase = function(name)
				if name ~= "Starting floating WPM widget…" then return end
				state.on_phase = nil
				helpers.assert_eq(widget.start(false), true)
			end
			helpers.assert_eq(widget.start(false), false)
			helpers.assert_eq(widget.is_running(), true)
			helpers.assert_eq(#state.timers, 1)
			helpers.assert_eq(state.timers[1].active, true)
			helpers.assert_eq(state.canvases[1].deleted, false)
			helpers.assert_eq(widget.stop(), true)
		end)
	end)
	helpers.it("(wpm-menubar-stop-owner) terminal logging cannot certify a restarted menubar as stopped", function()
		with_menubar(function(menubar, state)
			helpers.assert_eq(menubar.start(), true)
			state.on_log = function(_, message)
				if message ~= "WPM menubar widget stopped." then return end
				state.on_log = nil
				helpers.assert_eq(menubar.start(), true)
			end
			helpers.assert_eq(menubar.stop(), false)
			helpers.assert_eq(menubar.is_running(), true)
			helpers.assert_nil(state.timers[1].timer)
			helpers.assert_type(state.timers[2].timer, "table")
			helpers.assert_eq(state.items[1].deleted, true)
			helpers.assert_eq(state.items[2].deleted, false)
			helpers.assert_eq(menubar.stop(), true)
		end)
	end)
	helpers.it("(wpm-widget-partial-position) preserves valid zero and negative coordinates", function()
		with_widget(function(widget, state)
			helpers.assert_eq(widget.start(false), true)
			helpers.assert_eq(state.canvases[1].current_frame.x, -120)
			helpers.assert_eq(state.canvases[1].current_frame.y, 0)
			helpers.assert_eq(widget.stop(), true)
		end, { ["wpm_widget.pos_x"] = "-120", ["wpm_widget.pos_y"] = "0" })
	end)
	for _, graph in ipairs({ false, true }) do
		for _, invalid_y in ipairs({ false, "invalid" }) do
			helpers.it("(wpm-widget-partial-position) recovers an incomplete pair; graph="
				.. tostring(graph) .. "; y=" .. tostring(invalid_y), function()
				with_widget(function(widget, state)
					helpers.assert_eq(widget.start(graph), true)
					local frame = state.canvases[1].current_frame
					helpers.assert_type(frame.y, "number", "both persisted coordinates must form one usable anchor")
					helpers.assert_true(frame.y > 0)
					helpers.assert_eq(widget.stop(), true)
				end, { ["wpm_widget.pos_x"] = 120, ["wpm_widget.pos_y"] = invalid_y or nil })
			end)
		end
	end
	for _, failure in ipairs({ "stats", "zero", "throw" }) do
		helpers.it("(wpm-widget-render-owner) rolls back failed first render: " .. failure, function()
			with_widget(function(widget, state)
				state.stats_failure = failure == "stats"
				state.canvas_failure = failure
				helpers.assert_eq(widget.start(false), false)
				helpers.assert_eq(widget.is_running(), false)
				helpers.assert_eq(state.timers[1].active, false)
				helpers.assert_eq(state.taps[1].enabled, false)
				state.stats_failure, state.canvas_failure = false, nil
				helpers.assert_eq(widget.start(false), true)
				helpers.assert_eq(state.canvases[#state.canvases].shows, 1)
				helpers.assert_eq(widget.stop(), true)
			end)
		end)
	end
	for _, boundary in ipairs({ "stats", "tooltip", "screen", "create", "level", "behavior", "replaceElements" }) do
		for _, restart in ipairs({ false, true }) do
			helpers.it("(wpm-widget-render-owner) retires " .. boundary .. "; restart=" .. tostring(restart), function()
				with_widget(function(widget, state)
					state.on_phase = function(name)
						if name ~= boundary then return end
						state.on_phase = nil
						helpers.assert_eq(widget.stop(), true)
						if restart then helpers.assert_eq(widget.start(false), true) end
					end
					helpers.assert_eq(widget.start(false), false, "retired startup cannot publish success")
					helpers.assert_eq(widget.is_running(), restart)
					helpers.assert_eq(state.timers[1].active, false)
					helpers.assert_eq(state.taps[1].enabled, false)
					local current = restart and state.canvases[#state.canvases] or nil
					for _, canvas in ipairs(state.canvases) do
						if canvas ~= current then helpers.assert_eq(canvas.deleted, true) end
					end
					if current then
						helpers.assert_eq(current.deleted, false)
						helpers.assert_eq(current.shows, 1, "retired render cannot redraw its successor")
					end
					state.timers[1].run()
					helpers.assert_eq(widget.stop(), true)
				end)
			end)
		end
	end
end)
