--- tests/support/wpm_widget_fixture.lua

--- Native drawing boundaries around the production WPM widget owner.

local helpers = require("tests.helpers")

--- Exercises a fresh widget with independently observable native capabilities.
--- @param callback function Receives the widget and its native state.
--- @param position table|nil Persisted coordinates keyed by storage setting.
local function with_widget(callback, position)
	helpers.with_stub_scope({ "metrics.ui.wpm.widget", "metrics.ui.wpm.shared", "core.ui.ui.tooltip",
		"metrics.engine", "core.logger.engine.logger", "core.fs.engine.paths", "core.timing.engine.timings", "core.events.timer_scheduler",
		"core.ui.adapters.graphics_renderer", "core.fs.adapters.storage" }, function()
		local state = { timers = {}, taps = {}, canvases = {}, logs = {}, now = 1, last_input = 1, preview = false }
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
		package.loaded["core.logger.engine.logger"] = logger
		package.loaded["core.fs.engine.paths"] = { shared = helpers.shared }
		package.loaded["core.fs.adapters.storage"] = { get = function(key) return position and position[key] end,
			set = function() end, delete = function() end }
		package.loaded["metrics.engine"] = { get_live_stats = function()
			phase("stats")
			if state.stats_failure then error("PRIVATE_DETAIL") end
			return { wpm = 42, last_input_time = state.last_input }
		end }
		package.loaded["metrics.ui.wpm.shared"] = { get_active_source = function() return "manual" end,
			resolve_group_hex = function() return nil end, unit_label = function() return "WPM" end }
		package.loaded["core.ui.ui.tooltip"] = { is_visible = function() phase("tooltip"); return state.preview end }
		package.loaded["core.events.timer_scheduler"] = {
			every = function(_, run)
				local handle = { run = run, active = true }
				state.timers[#state.timers + 1] = handle
				return handle, true
			end,
			cancel = function(handle)
				if state.refuse_timer_once then state.refuse_timer_once = false; return false end
				handle.active = false
				return true
			end,
		}
		package.loaded["core.ui.adapters.graphics_renderer"] = { createWindow = function(frame)
			if state.canvas_failure == "zero" then return 0 end
			if state.canvas_failure == "throw" then error("PRIVATE_DETAIL") end
			local canvas = { current_frame = frame, deleted = false, shows = 0 }
			for _, name in ipairs({ "level", "behavior", "replaceElements", "hide" }) do
				canvas[name] = function(self)
					helpers.assert_eq(self.deleted, false, "retired canvas cannot receive " .. name)
					phase(name)
					if name == "hide" then self.hidden = true end
					return self
				end
			end
			function canvas:show()
				helpers.assert_eq(self.deleted, false, "retired canvas cannot be shown")
				self.shows = self.shows + 1
				self.hidden = false
				phase("show")
				return self
			end
			function canvas:delete()
				if state.refuse_canvas_delete then error("canvas deletion refused") end
				self.deleted = true
				phase("delete")
				return self
			end
			function canvas:frame(next_frame)
				helpers.assert_eq(self.deleted, false, "retired canvas cannot be repositioned")
				if next_frame then self.current_frame = next_frame end
				return self.current_frame
			end
			function canvas:mouseCallback(fn) self.mouse_callback = fn; return self end
			function canvas:canvasMouseEvents() return self end
			state.canvases[#state.canvases + 1] = canvas
			phase("create")
			return canvas
		end }
		local widget = helpers.load_with_stubs("metrics.ui.wpm.widget", {
			timer = { absoluteTime = function() return state.now * 1000000000 end },
			screen = { mainScreen = function()
				phase("screen")
				return { fullFrame = function() return { x = 0, y = 0, w = 1600, h = 1000 } end }
			end },
			eventtap = {
				event = { types = { mouseMoved = 1, leftMouseDown = 2, rightMouseDown = 3, scrollWheel = 4 } },
				new = function(_, run)
					local tap = { run = run, enabled = false }
					function tap:start() self.enabled = true; return self end
					function tap:stop()
						if state.refuse_tap_once then state.refuse_tap_once = false; return self end
						self.enabled = false
						return self
					end
					function tap:isEnabled() return self.enabled end
					state.taps[#state.taps + 1] = tap
					return tap
				end,
			},
		})
		callback(widget, state)
	end)
end

return with_widget
