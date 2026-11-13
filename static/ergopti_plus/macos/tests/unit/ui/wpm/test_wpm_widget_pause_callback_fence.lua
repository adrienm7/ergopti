--- tests/unit/ui/wpm/test_wpm_widget_pause_callback_fence.lua

--- Behavioral regression for the WPM widget's native callback ownership.
--- A timer, eventtap, or canvas callback may already be queued when a committed
--- ScriptControl PAUSE releases its native handle. Retained callbacks must be
--- inert while PAUSED and must stay stale after RESUME creates new identities.

local helpers = require("tests.helpers")

local FIXTURE_MODULES = {
	"tests.stubs.hs",
	"hs",
	"ui.wpm.wpm_widget",
	"ui.wpm.wpm_menubar",
	"ui.wpm.shared",
	"modules.keystats",
	"core.logger.engine.logger",
	"core.ui.engine.notifications",
	"core.i18n.engine.i18n",
	"platform.input.keycodes",
	"core.fs.engine.paths",
	"core.fs.adapters.storage",
	"core.ui.adapters.graphics_renderer",
	"diagnostics.adapters.event_provenance",
	"platform.input.synthetic_input",
	"core.events.timer_scheduler",
	"platform.input.key_state",
	"gestures.engine.engine",
	"gestures.engine.actions",
	"ai.engine.api.mlx",
	"ai.engine.local_servers.warmup_controller",
	"ai.engine.api.ollama",
	"ai.engine.api.remote",
	"keyboard.engine.runtime.onboarding",
	"core.ui.ui.tooltip",
	"modules.shortcuts.script_control",
}

helpers.describe("WPM widget callbacks are fenced by a real ScriptControl PAUSE", function()
	helpers.it("makes retained timer, tap, and canvas callbacks inert until and after RESUME", function()
		helpers.with_fresh_modules(FIXTURE_MODULES, function()
			local hs_stub = require("tests.stubs.hs")
			hs_stub.__reset()
			_G.hs = hs_stub
			package.loaded["hs"] = hs_stub

			local observed = {
				stats_reads = 0,
				event_reads = 0,
				mouse_reads = 0,
				settings_writes = 0,
				frame_writes = 0,
			}
			local timer_handles = {}
			local tap_handles = {}
			local canvases = {}
			local idle_callback = nil
			local admission_fence = nil

			local original_settings_set = hs_stub.settings.set
			original_settings_set("ergopti.wpm_widget.pos_x", "1e999")
			original_settings_set("ergopti.wpm_widget.pos_y", 50)
			hs_stub.settings.set = function(key, value)
				observed.settings_writes = observed.settings_writes + 1
				return original_settings_set(key, value)
			end
			local mouse_callback_active = false
			hs_stub.timer.absoluteTime = function()
				if mouse_callback_active then observed.event_reads = observed.event_reads + 1 end
				return 1000000000
			end
			local function emit_mouse(tap, event)
				mouse_callback_active = true
				tap.callback(event)
				mouse_callback_active = false
			end
			local mouse_position = { x = 30, y = 40 }
			hs_stub.mouse.absolutePosition = function()
				observed.mouse_reads = observed.mouse_reads + 1
				return { x = mouse_position.x, y = mouse_position.y }
			end
			hs_stub.screen.mainScreen = function()
				return {
					fullFrame = function() return { x = 0, y = 0, w = 1600, h = 1000 } end,
					frame = function() return { x = 0, y = 0, w = 1600, h = 960 } end,
				}
			end
			hs_stub.eventtap.event.types = {
				mouseMoved = 1,
				leftMouseDown = 2,
				rightMouseDown = 3,
				scrollWheel = 4,
			}
			hs_stub.eventtap.new = function(_, callback)
				local tap = { callback = callback, enabled = false }
				function tap:start()
					self.enabled = true
					return self
				end
				function tap:stop()
					self.enabled = false
					return self
				end
				function tap:isEnabled() return self.enabled end
				tap_handles[#tap_handles + 1] = tap
				return tap
			end

			package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
			package.loaded["core.ui.engine.notifications"] = { notify = function() end }
			package.loaded["core.i18n.engine.i18n"] = { get = function(key) return key end }
			package.loaded["platform.input.keycodes"] = {
				F13_KARABINER_RETURN = 106,
				F14_KARABINER_BACKSPACE = 107,
				F15_KARABINER_ESCAPE = 108,
				BACKSPACE = 51,
				RETURN = 36,
				ESCAPE = 53,
			}
			package.loaded["core.fs.engine.paths"] = {
				shared = function(relative_path) return helpers.shared(relative_path) end,
			}
			package.loaded["modules.keystats"] = {
				get_live_stats = function()
					observed.stats_reads = observed.stats_reads + 1
					return { wpm = 42, last_input_time = hs.timer.absoluteTime() / 1000000000 }
				end,
				resync_context = function() return true end,
			}
			package.loaded["ui.wpm.shared"] = {
				get_active_source = function() return "manual" end,
				get_source_color = function(_, alpha)
					return { hex = "#336699", alpha = alpha }
				end,
				resolve_group_hex = function() return nil end,
				unit_label = function() return "MPM" end,
			}
			package.loaded["core.events.timer_scheduler"] = {
				every = function(_, callback)
					local handle = { callback = callback, active = true }
					timer_handles[#timer_handles + 1] = handle
					return handle, true
				end,
				cancel = function(handle)
					handle.active = false
					return true
				end,
			}
			package.loaded["core.ui.adapters.graphics_renderer"] = {
				createWindow = function(frame)
					local canvas = { current_frame = frame, deleted = false }
					function canvas:level() return self end
					function canvas:behavior() return self end
					function canvas:replaceElements() return self end
					function canvas:show() return self end
					function canvas:hide() return self end
					function canvas:delete()
						self.deleted = true
						return self
					end
					function canvas:frame(next_frame)
						if next_frame ~= nil then
							observed.frame_writes = observed.frame_writes + 1
							self.current_frame = next_frame
						end
						return self.current_frame
					end
					function canvas:mouseCallback(callback)
						self.mouse_callback = callback
						return self
					end
					function canvas:canvasMouseEvents() return self end
					canvases[#canvases + 1] = canvas
					return canvas
				end,
			}
			package.loaded["core.ui.ui.tooltip"] = {
				is_visible = function() return false end,
				hide_forced = function() return true end,
			}

			local Widget = require("ui.wpm.wpm_widget")
			helpers.assert_true(Widget.start(false))
			helpers.assert_eq(#timer_handles, 1)
			helpers.assert_eq(#tap_handles, 1)
			helpers.assert_eq(#canvases, 1)
			helpers.assert_true(canvases[1].current_frame.x ~= math.huge,
				"a nonfinite stored coordinate must use the default anchor")
			helpers.assert_true(type(canvases[1].mouse_callback) == "function")

			local event = {
				getType = function()
					return hs_stub.eventtap.event.types.leftMouseDown
				end,
			}
			local stats_before_control = observed.stats_reads
			timer_handles[1].callback()
			helpers.assert_eq(observed.stats_reads, stats_before_control + 1,
				"the retained timer callback must have a live positive control")
			emit_mouse(tap_handles[1], event)
			helpers.assert_eq(observed.event_reads, 1,
				"the retained eventtap callback must have a live positive control")
			canvases[1].mouse_callback(canvases[1], "mouseDown", 1, 0, 0)
			canvases[1].mouse_callback(canvases[1], "mouseUp", 1, 0, 0)
			helpers.assert_eq(observed.settings_writes, 2,
				"the retained canvas callback must have a live positive control")
			local prior_x = canvases[1].current_frame.x
			canvases[1].current_frame.x = math.huge
			canvases[1].mouse_callback(canvases[1], "mouseUp", 1, 0, 0)
			helpers.assert_eq(observed.settings_writes, 2, "invalid native coordinates must not be persisted")
			canvases[1].current_frame.x = prior_x
			-- Begin another drag but deliberately omit mouseUp. PAUSE destroys this
			-- canvas, so its release callback can never settle the module-level lease.
			canvases[1].mouse_callback(canvases[1], "mouseDown", 1, 0, 0)

			package.loaded["diagnostics.adapters.event_provenance"] = {}
			package.loaded["platform.input.key_state"] = {
				is_right_altgr_held = function() return false end,
				describe_held_modifiers = function() return "(none)" end,
			}
			package.loaded["platform.input.synthetic_input"] = {
				when_idle = function(callback)
					idle_callback = callback
					return true
				end,
				acquire_admission_fence = function()
					if admission_fence ~= nil then return nil end
					admission_fence = { active = true }
					return admission_fence
				end,
				release_admission_fence = function(token)
					if token ~= admission_fence or token.active ~= true then return false end
					token.active = false
					admission_fence = nil
					return true
				end,
				admission_open = function() return admission_fence == nil end,
			}
			package.loaded["gestures.engine.engine"] = {}
			package.loaded["gestures.engine.actions"] = {
				get_label = function(name) return name end,
				execute_single = function() return true end,
				SG_NAMES = { "none", "script_pause_toggle" },
				AX_NAMES = {},
			}
			package.loaded["ai.engine.api.mlx"] = {
				pause_warmup = function() return true end,
				resume_warmup = function() return true end,
			}
			package.loaded["ai.engine.local_servers.warmup_controller"] = {
				pause_warmup = function() return true end,
				resume_warmup = function() return true end,
			}
			package.loaded["ai.engine.api.ollama"] = {
				pause_warmup = function() return true end,
				resume_warmup = function() return true end,
			}
			package.loaded["ai.engine.api.remote"] = {
				pause_warmup = function() return true end,
				resume_warmup = function() return true end,
			}
			package.loaded["ui.wpm.wpm_menubar"] = {
				is_running = function() return false end,
				stop = function() return true end,
				resume_after_pause = function() return true end,
			}
			package.loaded["keyboard.engine.runtime.onboarding"] = { stop = function() return true end }

			local ScriptControl = require("modules.shortcuts.script_control")
			helpers.assert_true(ScriptControl.pause_all())
			helpers.assert_true(ScriptControl.is_pause_transition_pending())
			helpers.assert_eq(ScriptControl.is_paused(), false)
			helpers.assert_not_nil(idle_callback)
			idle_callback()
			helpers.assert_true(ScriptControl.is_paused())
			helpers.assert_eq(Widget.is_running(), false)

			local paused_snapshot = {
				stats_reads = observed.stats_reads,
				event_reads = observed.event_reads,
				mouse_reads = observed.mouse_reads,
				settings_writes = observed.settings_writes,
				frame_writes = observed.frame_writes,
			}
			timer_handles[1].callback()
			emit_mouse(tap_handles[1], event)
			canvases[1].mouse_callback(canvases[1], "mouseDown", 1, 0, 0)
			canvases[1].mouse_callback(canvases[1], "mouseUp", 1, 0, 0)
			for key, value in pairs(paused_snapshot) do
				helpers.assert_eq(observed[key], value,
					"retained " .. key .. " activity must be inert after committed PAUSED")
			end

			helpers.assert_true(ScriptControl.resume_all())
			helpers.assert_eq(ScriptControl.is_paused(), false)
			helpers.assert_true(Widget.is_running())
			helpers.assert_eq(#timer_handles, 2)
			helpers.assert_eq(#tap_handles, 2)
			helpers.assert_eq(#canvases, 2)

			local resumed_snapshot = {
				stats_reads = observed.stats_reads,
				event_reads = observed.event_reads,
				mouse_reads = observed.mouse_reads,
				settings_writes = observed.settings_writes,
				frame_writes = observed.frame_writes,
			}
			timer_handles[1].callback()
			emit_mouse(tap_handles[1], event)
			canvases[1].mouse_callback(canvases[1], "mouseDown", 1, 0, 0)
			canvases[1].mouse_callback(canvases[1], "mouseUp", 1, 0, 0)
			for key, value in pairs(resumed_snapshot) do
				helpers.assert_eq(observed[key], value,
					"old-generation " .. key .. " activity must stay inert after RESUME")
			end

			local frame_writes_before_reposition = observed.frame_writes
			timer_handles[2].callback()
			helpers.assert_eq(observed.frame_writes, frame_writes_before_reposition + 1,
				"the resumed timer must reposition the new canvas after a drag loses mouseUp during PAUSE")
			emit_mouse(tap_handles[2], event)
			local frame_writes_after_reposition = observed.frame_writes
			mouse_position = { x = 130, y = 140 }
			canvases[2].mouse_callback(canvases[2], "mouseMove", 1, 0, 0)
			helpers.assert_eq(observed.frame_writes, frame_writes_after_reposition,
				"the first mouseMove after RESUME must not apply the destroyed canvas drag delta")
			canvases[2].mouse_callback(canvases[2], "mouseDown", 1, 0, 0)
			canvases[2].mouse_callback(canvases[2], "mouseUp", 1, 0, 0)
			helpers.assert_eq(observed.stats_reads, resumed_snapshot.stats_reads + 1,
				"the current timer generation must remain live")
			helpers.assert_eq(observed.event_reads, resumed_snapshot.event_reads + 1,
				"the current tap generation must remain live")
			helpers.assert_eq(observed.settings_writes, resumed_snapshot.settings_writes + 2,
				"the current canvas identity must remain live")

			helpers.assert_true(Widget.stop())
			helpers.assert_true(ScriptControl.stop())
		end)
	end)
end)
