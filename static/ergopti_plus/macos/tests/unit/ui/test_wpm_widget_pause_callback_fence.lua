--- tests/unit/ui/test_wpm_widget_pause_callback_fence.lua

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
	"modules.keylogger",
	"infra.logger",
	"infra.notifications",
	"infra.i18n",
	"infra.keycodes",
	"infra.paths",
	"adapters.graphics_renderer",
	"adapters.event_provenance",
	"adapters.synthetic_input",
	"adapters.timer_scheduler",
	"adapters.key_state",
	"modules.gestures.engine",
	"modules.gestures.actions",
	"modules.llm.api_mlx",
	"modules.llm.warmup_controller",
	"modules.llm.api_ollama",
	"modules.llm.api_remote",
	"platform.remap.onboarding",
	"ui.tooltip",
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
			hs_stub.settings.set = function(key, value)
				observed.settings_writes = observed.settings_writes + 1
				return original_settings_set(key, value)
			end
			hs_stub.timer.absoluteTime = function() return 1000000000 end
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

			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.notifications"] = { notify = function() end }
			package.loaded["infra.i18n"] = { get = function(key) return key end }
			package.loaded["infra.keycodes"] = {
				F13_KARABINER_RETURN = 106,
				F14_KARABINER_BACKSPACE = 107,
				F15_KARABINER_ESCAPE = 108,
				BACKSPACE = 51,
				RETURN = 36,
				ESCAPE = 53,
			}
			package.loaded["infra.paths"] = {
				shared = function(relative_path) return helpers.shared(relative_path) end,
			}
			package.loaded["modules.keylogger"] = {
				get_live_stats = function()
					observed.stats_reads = observed.stats_reads + 1
					return { wpm = 42 }
				end,
				resync_context = function() return true end,
			}
			package.loaded["ui.wpm.shared"] = {
				get_active_source = function() return "manual" end,
				get_source_color = function(_, alpha)
					return { hex = "#336699", alpha = alpha }
				end,
			}
			package.loaded["adapters.timer_scheduler"] = {
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
			package.loaded["adapters.graphics_renderer"] = {
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
					canvases[#canvases + 1] = canvas
					return canvas
				end,
			}
			package.loaded["ui.tooltip"] = {
				is_visible = function() return false end,
				hide_forced = function() return true end,
			}

			local Widget = require("ui.wpm.wpm_widget")
			helpers.assert_true(Widget.start(false))
			helpers.assert_eq(#timer_handles, 1)
			helpers.assert_eq(#tap_handles, 1)
			helpers.assert_eq(#canvases, 1)
			helpers.assert_true(type(canvases[1].mouse_callback) == "function")

			local event = {
				getType = function()
					observed.event_reads = observed.event_reads + 1
					return hs_stub.eventtap.event.types.leftMouseDown
				end,
			}
			local stats_before_control = observed.stats_reads
			timer_handles[1].callback()
			helpers.assert_eq(observed.stats_reads, stats_before_control + 1,
				"the retained timer callback must have a live positive control")
			tap_handles[1].callback(event)
			helpers.assert_eq(observed.event_reads, 1,
				"the retained eventtap callback must have a live positive control")
			canvases[1].mouse_callback(canvases[1], "mouseDown", 1, 0, 0)
			canvases[1].mouse_callback(canvases[1], "mouseUp", 1, 0, 0)
			helpers.assert_eq(observed.settings_writes, 2,
				"the retained canvas callback must have a live positive control")
			-- Begin another drag but deliberately omit mouseUp. PAUSE destroys this
			-- canvas, so its release callback can never settle the module-level lease.
			canvases[1].mouse_callback(canvases[1], "mouseDown", 1, 0, 0)

			package.loaded["adapters.event_provenance"] = {}
			package.loaded["adapters.key_state"] = {
				is_right_altgr_held = function() return false end,
				describe_held_modifiers = function() return "(none)" end,
			}
			package.loaded["adapters.synthetic_input"] = {
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
			package.loaded["modules.gestures.engine"] = {}
			package.loaded["modules.gestures.actions"] = {
				get_label = function(name) return name end,
				execute_single = function() return true end,
				SG_NAMES = { "none", "script_pause_toggle" },
				AX_NAMES = {},
			}
			package.loaded["modules.llm.api_mlx"] = {
				pause_warmup = function() return true end,
				resume_warmup = function() return true end,
			}
			package.loaded["modules.llm.warmup_controller"] = {
				pause_warmup = function() return true end,
				resume_warmup = function() return true end,
			}
			package.loaded["modules.llm.api_ollama"] = {
				pause_warmup = function() return true end,
				resume_warmup = function() return true end,
			}
			package.loaded["modules.llm.api_remote"] = {
				pause_warmup = function() return true end,
				resume_warmup = function() return true end,
			}
			package.loaded["ui.wpm.wpm_menubar"] = {
				is_running = function() return false end,
				stop = function() return true end,
				resume_after_pause = function() return true end,
			}
			package.loaded["platform.remap.onboarding"] = { stop = function() return true end }

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
			tap_handles[1].callback(event)
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
			tap_handles[1].callback(event)
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
			tap_handles[2].callback(event)
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
