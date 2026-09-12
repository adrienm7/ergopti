--- tests/unit/modules/shortcuts/system_actions/test_provenance_fences.lua

--- ==============================================================================
--- MODULE: System Action Regression Tests
--- DESCRIPTION:
--- Exercises system actions while preserving exact native and dependency ownership.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.system_actions_fixture")
local with_fixture = fixture.with_fixture
local fire_latest_timer = fixture.fire_latest_timer
local fire_post_callback_actions = fixture.fire_post_callback_actions
local extend_contract = fixture.extend_contract
local fresh_hs_contract = fixture.fresh_hs_contract
local load_h01_system = fixture.load_h01_system
local owned_key_down = fixture.owned_key_down
local physical_key_down = fixture.physical_key_down
local physical_scroll = fixture.physical_scroll
local owned_scroll = fixture.owned_scroll

helpers.describe("shortcuts.actions.system: exact provenance and ordered fences (HS-H-01)", function()
	helpers.it("an owned @ event cannot trigger the screenshot tap (HS-H-01)", function()
		with_fixture(function()
			local fixture = load_h01_system()
			local window_reads = 0
			fixture.hs.window.frontmostWindow = function()
				window_reads = window_reads + 1
				return { id = function() return 42 end }
			end
			fixture.system.bind_instant_screenshot()
			local tap = fixture.hs.eventtap.__taps[#fixture.hs.eventtap.__taps]
			local event = owned_key_down(fixture, "@", 10, "@", {})
			local timers_before = #fixture.hs.timer.__timers

			local consume, returned = tap.fn(event)

			helpers.assert_true(not consume, "owned output must continue downstream unchanged")
			helpers.assert_nil(returned)
			helpers.assert_eq(window_reads, 0,
				"an Ergopti-owned @ must not be reinterpreted as a physical screenshot command")
			helpers.assert_eq(#fixture.hs.timer.__timers, timers_before,
				"the ignored owned event must not schedule a screenshot action")
		end)
	end)

	helpers.it("an owned Cmd+star cannot recurse into Cmd+S (HS-H-01)", function()
		with_fixture(function()
			local fixture = load_h01_system()
			local trigger_count = 0
			fixture.system.bind_cmd_star(function() trigger_count = trigger_count + 1 end)
			local tap = fixture.hs.eventtap.__taps[#fixture.hs.eventtap.__taps]
			local event = owned_key_down(fixture, "*", 28, "*", { cmd = true, shift = true })
			local pending_before = fixture.synthetic.stats().pending
			local timers_before = #fixture.hs.timer.__timers

			local consume, returned = tap.fn(event)

			helpers.assert_true(not consume)
			helpers.assert_nil(returned)
			helpers.assert_eq(trigger_count, 0)
			helpers.assert_eq(fixture.synthetic.stats().pending, pending_before,
				"the owned chord must not queue a second synthetic shortcut")
			helpers.assert_eq(#fixture.hs.timer.__timers, timers_before)
		end)
	end)

	helpers.it("an owned wrap symbol cannot consume output or probe AX (HS-H-01)", function()
		with_fixture(function()
			local ax_reads, wraps = 0, 0
			local fixture = load_h01_system({
				text_actions = {
					WRAP_PAIRS = { ["("] = { left = "(", right = ")" } },
					read_ax_selection = function() ax_reads = ax_reads + 1 return "selected" end,
					wrap_selection = function() wraps = wraps + 1 end,
				},
			})
			fixture.system.bind_wrap_text_if_selected(nil)
			local tap = fixture.hs.eventtap.__taps[#fixture.hs.eventtap.__taps]
			local consume, returned = tap.fn(owned_key_down(fixture, "(", 25, "(", {}))

			helpers.assert_true(not consume)
			helpers.assert_nil(returned)
			helpers.assert_eq(ax_reads, 0)
			helpers.assert_eq(wraps, 0,
				"tagged expansion/LLM text must reach the app, never recurse into wrap")
		end)
	end)

	helpers.it("wrap fails open on a non-empty fence and never consumes/replays the symbol (HS-H-01)", function()
		with_fixture(function()
			local ax_reads, wraps = 0, 0
			local fixture = load_h01_system({
				text_actions = {
					WRAP_PAIRS = { ["("] = { left = "(", right = ")" } },
					read_ax_selection = function() ax_reads = ax_reads + 1 return "stale selection" end,
					wrap_selection = function() wraps = wraps + 1 end,
				},
			})
			fixture.system.bind_wrap_text_if_selected(nil)
			local tap = fixture.hs.eventtap.__taps[#fixture.hs.eventtap.__taps]
			fixture.synthetic.emit_key_stroke({ "cmd" }, "tab", 0)
			local handoffs_before = fixture.synthetic.stats().action_handoffs

			local consume, fence_events = tap.fn(physical_key_down(fixture, 25, "(", {}))

			helpers.assert_true(not consume,
				"the original physical symbol must continue to keymap/app after the fence")
			helpers.assert_true(type(fence_events) == "table" and #fence_events == 2)
			helpers.assert_eq(ax_reads, 0,
				"pre-return AX state belongs to the pre-fence application and cannot be used")
			helpers.assert_eq(wraps, 0)
			helpers.assert_eq(fixture.synthetic.stats().pending, 0,
				"the symbol is passed physically; no owned replay may desynchronise CoreState")
			helpers.assert_eq(fixture.synthetic.stats().action_handoffs, handoffs_before + 1,
				"only the older fenced action is handed off")
		end)
	end)

	helpers.it("wrap with no AX selection passes the physical symbol without a synthetic action (HS-H-01)", function()
		with_fixture(function()
			local fixture = load_h01_system({
				text_actions = {
					WRAP_PAIRS = { ["("] = { left = "(", right = ")" } },
					read_ax_selection = function() return nil end,
					wrap_selection = function() error("no selection must not wrap") end,
				},
			})
			fixture.system.bind_wrap_text_if_selected(nil)
			local tap = fixture.hs.eventtap.__taps[#fixture.hs.eventtap.__taps]
			local handoffs_before = fixture.synthetic.stats().action_handoffs

			local consume, returned = tap.fn(physical_key_down(fixture, 25, "(", {}))

			helpers.assert_true(not consume)
			helpers.assert_nil(returned)
			helpers.assert_eq(fixture.synthetic.stats().pending, 0)
			helpers.assert_eq(fixture.synthetic.stats().action_handoffs, handoffs_before,
				"passthrough must stay physical so keymap buffer/preview observe the same character")
		end)
	end)

	helpers.it("a declined wrap passes the physical symbol and preserves the cached selection (HS-H-01)", function()
		with_fixture(function()
			local ax_reads, wrap_attempts = 0, 0
			local fixture = load_h01_system({
				text_actions = {
					WRAP_PAIRS = { ["("] = { left = "(", right = ")" } },
					read_ax_selection = function()
						ax_reads = ax_reads + 1
						return "selected"
					end,
					wrap_selection = function()
						wrap_attempts = wrap_attempts + 1
						return false
					end,
				},
			})
			fixture.system.bind_wrap_text_if_selected(nil)
			local tap = fixture.hs.eventtap.__taps[#fixture.hs.eventtap.__taps]
			local pending_before = fixture.synthetic.stats().pending

			local first_consume, first_returned = tap.fn(
				physical_key_down(fixture, 25, "(", {}))
			local second_consume, second_returned = tap.fn(
				physical_key_down(fixture, 25, "(", {}))

			helpers.assert_true(not first_consume and not second_consume,
				"a declined replacement must leave both original physical symbols untouched")
			helpers.assert_nil(first_returned)
			helpers.assert_nil(second_returned)
			helpers.assert_eq(wrap_attempts, 2,
				"declining is not a fire; the cached live selection must remain eligible")
			helpers.assert_eq(ax_reads, 1,
				"the second attempt must reuse, not invalidate, the still-live AX cache")
			helpers.assert_eq(fixture.synthetic.stats().pending, pending_before,
				"passthrough stays physical and must not enqueue an owned replay")
		end)
	end)

	helpers.it("a successful wrap consumes the cached selection exactly once (HS-H-01)", function()
		with_fixture(function()
			local ax_reads, wrap_attempts = 0, 0
			local fixture = load_h01_system({
				text_actions = {
					WRAP_PAIRS = { ["("] = { left = "(", right = ")" } },
					read_ax_selection = function()
						ax_reads = ax_reads + 1
						return "selected"
					end,
					wrap_selection = function()
						wrap_attempts = wrap_attempts + 1
						return true
					end,
				},
			})
			fixture.system.bind_wrap_text_if_selected(nil)
			local tap = fixture.hs.eventtap.__taps[#fixture.hs.eventtap.__taps]

			local first_consume = tap.fn(physical_key_down(fixture, 25, "(", {}))
			local second_consume = tap.fn(physical_key_down(fixture, 25, "(", {}))

			helpers.assert_true(first_consume,
				"a replacement confirmed as scheduled must consume its physical symbol")
			helpers.assert_true(not second_consume,
				"the stale selection must become a cached negative after the first wrap")
			helpers.assert_eq(wrap_attempts, 1,
				"the consumed AX selection must never be wrapped a second time")
			helpers.assert_eq(ax_reads, 1,
				"the cached negative must avoid a second synchronous AX read inside the TTL")
		end)
	end)

	helpers.it("F19 state is immediate, while owned F19/scroll events never control volume (HS-H-01)", function()
		with_fixture(function()
			local cleanup_count = 0
			local click_held = true
			local fixture = load_h01_system({
				gestures = {
					isRightClickHeld = function() return click_held end,
					forceCleanup = function()
						click_held = false
						cleanup_count = cleanup_count + 1
					end,
				},
			})
			local media_events = {}
			fixture.hs.eventtap.event.newSystemKeyEvent = function(key, is_down)
				return {
					post = function(self)
						media_events[#media_events + 1] = { key, is_down }
						return self
					end,
				}
			end
			fixture.system.bind_layer_scroll()
			local taps = fixture.hs.eventtap.__taps
			local key_tap = taps[#taps - 1]
			local scroll_tap = taps[#taps]
			local f19 = require("infra.keycodes").F19_VOLUME_SCROLL_MODIFIER

			key_tap.fn(owned_key_down(fixture, "f19", f19, "", {}))
			local owned_consume = scroll_tap.fn(owned_scroll(fixture, 1))
			helpers.assert_true(not owned_consume,
				"an owned F19 must not arm the physical layer, and owned scroll is never a command")

			local down = physical_key_down(fixture, f19, "", {})
			local down_consume = key_tap.fn(down)
			helpers.assert_true(not down_consume, "the physical F19 itself remains visible to the OS")
			-- Do not fire the deferred gesture-cleanup timer. The very first following
			-- scroll must already observe layer_held=true.
			local scroll_consume = scroll_tap.fn(physical_scroll(fixture, 1))
			helpers.assert_true(scroll_consume,
				"F19 layer state must be O(1) synchronous or the first scroll notch leaks")
			helpers.assert_eq(#media_events, 0,
				"media emission and gesture cleanup must still run after the tap returns")
			fire_post_callback_actions(fixture.hs)
			helpers.assert_eq(#media_events, 2, "one notch must emit one media down/up pair")
			helpers.assert_eq(cleanup_count, 1)
		end)
	end)

	helpers.it("reports every refused F19 media-key phase", function()
		with_fixture(function()
			for _, mode in ipairs({ "false", "nil", "throw" }) do
				local errors = {}
				local logger = helpers.make_logger_stub()
				logger.error = function(_, format, ...)
					errors[#errors + 1] = string.format(format, ...)
				end
				local fixture = load_h01_system({ gestures = {}, logger = logger })
				local post_attempts = {}
				fixture.hs.eventtap.event.newSystemKeyEvent = function(key, is_down)
					return {
						post = function(self)
							post_attempts[#post_attempts + 1] = { key, is_down }
							if mode == "false" then return false end
							if mode == "nil" then return nil end
							error("system-key post exploded")
						end,
					}
				end

				fixture.system.bind_layer_scroll()
				local taps = fixture.hs.eventtap.__taps
				local key_tap = taps[#taps - 1]
				local scroll_tap = taps[#taps]
				local f19 = require("infra.keycodes").F19_VOLUME_SCROLL_MODIFIER
				key_tap.fn(physical_key_down(fixture, f19, "", {}))
				helpers.assert_true(scroll_tap.fn(physical_scroll(fixture, 1)),
					mode .. " refusal must still consume the admitted physical scroll")
				fire_post_callback_actions(fixture.hs)

				helpers.assert_eq(#post_attempts, 2,
					mode .. " refusal must still attempt the down and up phases")
				helpers.assert_eq(#errors, 2,
					mode .. " refusal must report both failed native phases")
				helpers.assert_contains(errors[1], "SOUND_UP down post was refused")
				helpers.assert_contains(errors[2], "SOUND_UP up post was refused")
			end
		end)
	end)

	helpers.it("screenshot target lookup happens after every older fence event (HS-H-01)", function()
		with_fixture(function()
			local fixture = load_h01_system()
			fixture.hs.fs.pathToAbsolute = function(path)
				if path == "~" then return "/tmp/hs015-home" end
				return path
			end
			local current_window_id = 1
			local tasks = {}
			fixture.hs.window.frontmostWindow = function()
				local captured_id = current_window_id
				return { id = function() return captured_id end }
			end
			fixture.hs.task.new = function(path, on_done, args)
				local rec = { path = path, on_done = on_done, args = args }
				tasks[#tasks + 1] = rec
				return helpers.attach_native_task_environment({
					start = function() return true end,
					terminate = function() end,
				})
			end
			fixture.system.bind_instant_screenshot()
			local tap = fixture.hs.eventtap.__taps[#fixture.hs.eventtap.__taps]

			fixture.synthetic.emit_key_stroke({ "cmd" }, "tab", 0)
			local consume, fence_events = tap.fn(physical_key_down(fixture, 10, "@", {}))
			helpers.assert_true(consume)
			helpers.assert_true(type(fence_events) == "table" and #fence_events == 2,
				"the older action must be returned ahead of the consumed screenshot key")
			helpers.assert_eq(#tasks, 0,
				"window lookup/subprocess work must not run before the returned fence")

			-- Models the returned Cmd+Tab reaching the application before timer-zero.
			current_window_id = 2
			fire_post_callback_actions(fixture.hs)
			helpers.assert_eq(#tasks, 1)
			local argv = table.concat(tasks[1].args or {}, " ")
			helpers.assert_true(argv:find("-p", 1, true) ~= nil,
				"the first deferred subprocess must still be mkdir")
			-- Finish mkdir; screencapture must inherit the post-fence target id.
			tasks[1].on_done(0, "", "")
			helpers.assert_eq(#tasks, 2)
			helpers.assert_eq(tasks[2].args and tasks[2].args[2], "2",
				"capture must target the window frontmost after the fence, never the stale id 1")
		end)
	end)

	helpers.it("Cmd+star returns older output before scheduling its replacement and telemetry (HS-H-01)", function()
		with_fixture(function()
			local fixture = load_h01_system()
			local trigger_count = 0
			fixture.system.bind_cmd_star(function() trigger_count = trigger_count + 1 end)
			local tap = fixture.hs.eventtap.__taps[#fixture.hs.eventtap.__taps]
			fixture.synthetic.emit_key_stroke({}, "a", 0)

			local consume, fence_events = tap.fn(
				physical_key_down(fixture, 28, "*", { cmd = true, shift = true }))
			helpers.assert_true(consume)
			helpers.assert_true(type(fence_events) == "table" and #fence_events == 2)
			helpers.assert_eq(fixture.synthetic.stats().pending, 0,
				"the older batch is adopted into the callback return, not left in the pump")
			helpers.assert_eq(trigger_count, 0,
				"telemetry must not execute on the eventtap or before its ordering fence")

			fire_post_callback_actions(fixture.hs)
			helpers.assert_eq(trigger_count, 1)
			helpers.assert_eq(fixture.synthetic.stats().pending, 1,
				"the Cmd+S replacement is queued only after the older batch was handed off")
		end)
	end)

	helpers.it("Cmd+star contains telemetry errors after queueing its replacement (HS-016)", function()
		with_fixture(function()
			local failures = {}
			local logger = helpers.make_logger_stub()
			logger.callback = function(_, label, fn, ...)
				local results = table.pack(xpcall(fn, debug.traceback, ...))
				if not results[1] then
					failures[#failures + 1] = tostring(label) .. ": " .. tostring(results[2])
				end
				return table.unpack(results, 1, results.n)
			end
			local fixture = load_h01_system({logger = logger})
			fixture.system.bind_cmd_star(function() error("telemetry exploded") end)
			local tap = fixture.hs.eventtap.__taps[#fixture.hs.eventtap.__taps]

			local consumed = tap.fn(
				physical_key_down(fixture, 28, "*", {cmd = true, shift = true}))
			fire_post_callback_actions(fixture.hs)

			helpers.assert_true(consumed)
			helpers.assert_eq(fixture.synthetic.stats().pending, 1,
				"the user-visible Cmd+S replacement must survive telemetry failure")
			helpers.assert_eq(#failures, 1)
			helpers.assert_contains(failures[1], "Cmd-star telemetry")
			helpers.assert_contains(failures[1], "telemetry exploded")
			helpers.assert_contains(failures[1], "stack traceback")
		end)
	end)

	helpers.it("the real tagged pump trigger cannot auto-disable keep-awake (HS-H-01)", function()
		with_fixture(function()
			local posted_trigger = nil
			local contract = fresh_hs_contract()
			local base_new_mouse = contract.eventtap.event.newMouseEvent
			local event_api = extend_contract(contract.eventtap.event, {
				newMouseEvent = function(event_type, position, modifiers)
					local event = base_new_mouse(event_type, position, modifiers)
					event.getType = function(self) return self.t end
					event.post = function(self)
						posted_trigger = self
						return self
					end
					return event
				end,
			})
			local eventtap = extend_contract(contract.eventtap, { event = event_api })
			local fixture = load_h01_system({ hs_overrides = { eventtap = eventtap } })
			local now = 1000
			fixture.hs.timer.secondsSinceEpoch = function() return now end
			local close_count = 0
			fixture.hs.alert.show = function() return "awake" end
			fixture.hs.alert.closeSpecific = function() close_count = close_count + 1 end
			fixture.system.toggle_awake()
			now = now + 10

			local watcher = nil
			for _, tap in ipairs(fixture.hs.eventtap.__taps) do
				for _, event_type in ipairs(tap.types or {}) do
					if event_type == fixture.hs.eventtap.event.types.keyDown then watcher = tap end
				end
			end
			helpers.assert_not_nil(watcher)

			fixture.system._emit_activity_keystroke()
			fire_latest_timer(fixture.hs)
			helpers.assert_not_nil(posted_trigger,
				"the production broker must post its exact-tag control trigger")
			local consume, returned = watcher.fn(posted_trigger)
			helpers.assert_true(not consume)
			helpers.assert_nil(returned)
			helpers.assert_eq(close_count, 0,
				"otherMouseUp is user activity only when foreign; the owned pump control is not")

			local pump = nil
			for _, tap in ipairs(fixture.hs.eventtap.__taps) do
				if tap.types and #tap.types == 1
					and tap.types[1] == fixture.hs.eventtap.event.types.otherMouseUp then
					pump = tap
				end
			end
			helpers.assert_not_nil(pump)
			local pump_consume, payload = pump.fn(posted_trigger)
			helpers.assert_true(pump_consume)
			helpers.assert_eq(#payload, 2,
				"ignoring the control event in the watcher must still let the pump return F18")
		end)
	end)

	helpers.it("unreadable keyboard provenance fails closed and still returns the older fence (HS-H-01)", function()
		with_fixture(function()
			local cases = {
				{
					name = "screenshot",
					bind = function(fixture, effects)
						fixture.hs.window.frontmostWindow = function()
							effects.count = effects.count + 1
							return { id = function() return 42 end }
						end
						fixture.system.bind_instant_screenshot()
					end,
					keycode = 10, characters = "@", flags = {},
				},
				{
					name = "cmd-star",
					bind = function(fixture, effects)
						fixture.system.bind_cmd_star(function() effects.count = effects.count + 1 end)
					end,
					keycode = 28, characters = "*", flags = { cmd = true, shift = true },
				},
				{
					name = "wrap",
					text_actions = function(effects)
						return {
							WRAP_PAIRS = { ["("] = { left = "(", right = ")" } },
							read_ax_selection = function() effects.count = effects.count + 1 return "x" end,
							wrap_selection = function() effects.count = effects.count + 1 end,
						}
					end,
					bind = function(fixture) fixture.system.bind_wrap_text_if_selected(nil) end,
					keycode = 25, characters = "(", flags = {},
				},
			}

			for _, case in ipairs(cases) do
				local effects = { count = 0 }
				local text_actions = case.text_actions and case.text_actions(effects) or nil
				local fixture = load_h01_system({ text_actions = text_actions })
				case.bind(fixture, effects)
				local tap = fixture.hs.eventtap.__taps[#fixture.hs.eventtap.__taps]
				fixture.synthetic.emit_key_stroke({}, "a", 0)
				local unreadable = {
					getType = function() return fixture.hs.eventtap.event.types.keyDown end,
					getProperty = function() error("Quartz user-data unavailable") end,
					getKeyCode = function() return case.keycode end,
					getCharacters = function() return case.characters end,
					getFlags = function() return case.flags end,
				}
				local consume, fence_events = tap.fn(unreadable)
				helpers.assert_true(not consume, case.name .. " must pass an unreadable original")
				helpers.assert_true(type(fence_events) == "table" and #fence_events == 2,
					case.name .. " must not drop the older batch while failing closed")
				helpers.assert_eq(effects.count, 0,
					case.name .. " must not interpret unreadable provenance as a user command")
			end
		end)
	end)

	helpers.it("unreadable F19 and scroll provenance cannot mutate layer state or emit media (HS-H-01)", function()
		with_fixture(function()
			local fixture = load_h01_system({ gestures = {} })
			local media_count = 0
			fixture.hs.eventtap.event.newSystemKeyEvent = function()
				return {
					post = function(self)
						media_count = media_count + 1
						return self
					end,
				}
			end
			fixture.system.bind_layer_scroll()
			local taps = fixture.hs.eventtap.__taps
			local key_tap = taps[#taps - 1]
			local scroll_tap = taps[#taps]
			local f19 = require("infra.keycodes").F19_VOLUME_SCROLL_MODIFIER

			fixture.synthetic.emit_key_stroke({}, "a", 0)
			local unreadable_key = {
				getType = function() return fixture.hs.eventtap.event.types.keyDown end,
				getProperty = function() error("unreadable") end,
				getKeyCode = function() return f19 end,
			}
			local key_consume, key_fence = key_tap.fn(unreadable_key)
			helpers.assert_true(not key_consume)
			helpers.assert_true(type(key_fence) == "table" and #key_fence == 2)
			helpers.assert_true(not scroll_tap.fn(physical_scroll(fixture, 1)),
				"unreadable F19 must not arm the volume layer")

			key_tap.fn(physical_key_down(fixture, f19, "", {}))
			fixture.synthetic.emit_key_stroke({}, "b", 0)
			local unreadable_scroll = {
				getType = function() return fixture.hs.eventtap.event.types.scrollWheel end,
				getProperty = function() error("unreadable") end,
			}
			local scroll_consume, scroll_fence = scroll_tap.fn(unreadable_scroll)
			helpers.assert_true(not scroll_consume)
			helpers.assert_true(type(scroll_fence) == "table" and #scroll_fence == 2)
			helpers.assert_eq(media_count, 0,
				"unreadable scroll provenance must fail closed even while physical F19 is held")
		end)
	end)
end)
