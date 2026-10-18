--- tests/unit/ui/wpm/test_wpm_widget_render_transaction.lua

--- ==============================================================================
--- MODULE: WPM Widget Render Transaction Tests
--- DESCRIPTION:
--- Retired renders cannot resurrect a stopped canvas or mutate its successor.
--- Native render failure must roll back an uncommitted widget startup.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Exercises a fresh widget with independently observable native capabilities.
--- @param callback function Receives the widget and its native state.
--- @param position table|nil Persisted coordinates keyed by storage setting.
local function with_widget(callback, position)
	helpers.with_stub_scope({ "ui.wpm.wpm_widget", "ui.wpm.shared", "ui.tooltip",
		"modules.keylogger", "infra.logger", "infra.paths", "infra.timings", "adapters.timer_scheduler",
		"adapters.graphics_renderer", "adapters.storage" }, function()
		local state = { timers = {}, taps = {}, canvases = {}, logs = {} }
		local function phase(name)
			if state.on_phase then state.on_phase(name) end
		end
		local logger = helpers.make_logger_stub()
		for _, level in ipairs({ "debug", "info", "error" }) do
			logger[level] = function(_, message)
				state.logs[#state.logs + 1] = { level = level, message = message }
				phase(message)
			end
		end
		package.loaded["infra.logger"] = logger
		package.loaded["infra.paths"] = { shared = helpers.shared }
		package.loaded["adapters.storage"] = { get = function(key) return position and position[key] end,
			set = function() end, delete = function() end }
		package.loaded["modules.keylogger"] = { get_live_stats = function()
			phase("stats")
			if state.stats_failure then error("PRIVATE_DETAIL") end
			return { wpm = 42 }
		end }
		package.loaded["ui.wpm.shared"] = { get_active_source = function() return "manual" end,
			resolve_group_hex = function() return nil end, unit_label = function() return "WPM" end }
		package.loaded["ui.tooltip"] = { is_visible = function() phase("tooltip"); return false end }
		package.loaded["adapters.timer_scheduler"] = {
			every = function(_, run)
				local handle = { run = run, active = true }
				state.timers[#state.timers + 1] = handle
				return handle, true
			end,
			cancel = function(handle) handle.active = false; return true end,
		}
		package.loaded["adapters.graphics_renderer"] = { createWindow = function(frame)
			if state.canvas_failure == "zero" then return 0 end
			if state.canvas_failure == "throw" then error("PRIVATE_DETAIL") end
			local canvas = { current_frame = frame, deleted = false, shows = 0 }
			for _, name in ipairs({ "level", "behavior", "replaceElements", "hide" }) do
				canvas[name] = function(self)
					helpers.assert_eq(self.deleted, false, "retired canvas cannot receive " .. name)
					phase(name)
					return self
				end
			end
			function canvas:show()
				helpers.assert_eq(self.deleted, false, "retired canvas cannot be shown")
				self.shows = self.shows + 1
				phase("show")
				return self
			end
			function canvas:delete() self.deleted = true; return self end
			function canvas:frame(next_frame)
				helpers.assert_eq(self.deleted, false, "retired canvas cannot be repositioned")
				if next_frame then self.current_frame = next_frame end
				return self.current_frame
			end
			function canvas:mouseCallback(fn) self.mouse_callback = fn; return self end
			state.canvases[#state.canvases + 1] = canvas
			phase("create")
			return canvas
		end }
		local widget = helpers.load_with_stubs("ui.wpm.wpm_widget", {
			timer = { absoluteTime = function() return 1000000000 end },
			screen = { mainScreen = function()
				phase("screen")
				return { fullFrame = function() return { x = 0, y = 0, w = 1600, h = 1000 } end }
			end },
			eventtap = {
				event = { types = { mouseMoved = 1, leftMouseDown = 2, rightMouseDown = 3, scrollWheel = 4 } },
				new = function(_, run)
					local tap = { run = run, enabled = false }
					function tap:start() self.enabled = true; return self end
					function tap:stop() self.enabled = false; return self end
					function tap:isEnabled() return self.enabled end
					state.taps[#state.taps + 1] = tap
					return tap
				end,
			},
		})
		callback(widget, state)
	end)
end

helpers.describe("WPM widget render lifecycle", function()
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
