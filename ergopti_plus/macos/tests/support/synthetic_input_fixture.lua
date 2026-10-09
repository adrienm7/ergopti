--- tests/support/synthetic_input_fixture.lua

--- ==============================================================================
--- MODULE: Synthetic Input Native Fixture
--- DESCRIPTION:
--- Constructs independent Quartz, timer, and provenance worlds without shared mutable state.
--- ==============================================================================

local helpers = require("tests.helpers")

local USER_DATA = 201
local SOURCE_PID = 202
local MOUSE_BUTTON = 203
local KEY_DOWN = 10
local KEY_UP = 11
local FLAGS_CHANGED = 12
local LEFT_MOUSE_DOWN = 20
local LEFT_MOUSE_UP = 21
local RIGHT_MOUSE_DOWN = 22
local RIGHT_MOUSE_UP = 23
local MOUSE_MOVED = 24
local LEFT_MOUSE_DRAGGED = 25
local OTHER_MOUSE_UP = 26
local RIGHT_MOUSE_DRAGGED = 27
local OTHER_MOUSE_DRAGGED = 28
local CURRENT_PID = 7001


--- Builds a controllable HS/Quartz world for behavior rather than source grep.
--- @param options table|nil Fixture options.
--- @return table fixture
local function make_fixture(options)
	options = options or {}
	local fixture = {
		options = options,
		settings_store = options.settings_store or {},
		timers = {},
		logs = {},
		taps = {},
		triggers = {},
		delayed_handles = {},
		post_count = 0,
		trigger_posts = 0,
		key_posts = 0,
		global_key_posts = 0,
		targeted_key_posts = 0,
		pid_reads = 0,
		deliver_trigger = options.deliver_trigger ~= false,
		tap_should_enable = options.tap_should_enable ~= false,
		pump_deliveries = {},
		paced_sleeps = {},
		posted_targets = {},
		key_attempts = {},
		frontmost_app = options.frontmost_app,
		do_after_calls = 0,
		timer_new_calls = 0,
		timer_start_calls = 0,
		raw_do_every_calls = 0,
	}

	local logger = helpers.make_logger_stub()
	for _, level in ipairs({ "debug", "info", "success", "warn", "error" }) do
		logger[level] = function(_, format, ...)
			fixture.logs[#fixture.logs + 1] = level .. ":" .. string.format(format, ...)
		end
	end
	fixture.logger = logger

	local timer = {}
	function timer.absoluteTime()
		if fixture.absolute_time_throws then error("clock unavailable") end
		return options.absolute_time or 987654321000
	end
	function timer.secondsSinceEpoch() return options.epoch or 1900000000.125 end
	function timer.usleep(delay)
		helpers.assert_true(not fixture.callback_active,
			"hs.timer.usleep must never run inside the originating eventtap callback")
		fixture.paced_sleeps[#fixture.paced_sleeps + 1] = delay
	end
	function timer.doAfter(delay, callback)
		fixture.do_after_calls = fixture.do_after_calls + 1
		if options.throw_on_do_after_call == fixture.do_after_calls then
			error("doAfter exploded")
		end
		if fixture.fail_next_do_after then
			fixture.fail_next_do_after = false
			return nil
		end
		if (options.do_after_failures or 0) > 0 then
			options.do_after_failures = options.do_after_failures - 1
			return nil
		end
		if options.fail_on_do_after_call == fixture.do_after_calls then return nil end
		if options.false_on_do_after_call == fixture.do_after_calls then return false end
		local entry = {
			delay = delay,
			callback = callback,
			stopped = false,
		}
		fixture.timers[#fixture.timers + 1] = entry
		local handle = { stop = function() entry.stopped = true end }
		if options.gc_cancels_unretained_timers then
			setmetatable(handle, {
				__gc = function() entry.stopped = true end,
			})
		end
		if options.do_after_synchronous then
			callback()
			entry.stopped = true
		end
		return handle
	end
	function timer.new(interval, callback)
		fixture.timer_new_calls = fixture.timer_new_calls + 1
		local call_index = fixture.timer_new_calls
		if options.throw_on_timer_new_call == call_index then
			error("timer.new exploded")
		end
		if fixture.fail_next_timer_new then
			fixture.fail_next_timer_new = false
			return nil
		end
		if (options.timer_new_failures or 0) > 0 then
			options.timer_new_failures = options.timer_new_failures - 1
			return nil
		end
		if options.fail_on_timer_new_call == call_index then return nil end
		if options.false_on_timer_new_call == call_index then return false end
		local entry = {
			delay = interval,
			callback = callback,
			stopped = true,
			running = false,
			recurring = true,
			start_calls = 0,
			stop_calls = 0,
			stop_failures = options.timer_stop_failures_by_call
				and (options.timer_stop_failures_by_call[call_index] or 0)
				or (options.timer_stop_failures or 0),
			stop_nils = options.timer_stop_nils_by_call
				and (options.timer_stop_nils_by_call[call_index] or 0)
				or (options.timer_stop_nils or 0),
			stop_throws = options.timer_stop_throws_by_call
				and (options.timer_stop_throws_by_call[call_index] or 0)
				or (options.timer_stop_throws or 0),
		}
		fixture.timers[#fixture.timers + 1] = entry
		local handle = {}
		function handle:start()
			fixture.timer_start_calls = fixture.timer_start_calls + 1
			entry.start_calls = entry.start_calls + 1
			entry.stopped = false
			entry.running = true
			local inline = options.timer_start_inline_by_call
				and options.timer_start_inline_by_call[call_index]
			if inline == true or options.timer_start_inline == true then callback() end
			local mode = options.timer_start_modes_by_call
				and options.timer_start_modes_by_call[call_index]
				or options.timer_start_mode
			if mode == "throw" then error("periodic start exploded") end
			if mode == "false" then return false end
			if mode == "nil" then return nil end
			if mode == "stopped" then
				entry.stopped = true
				entry.running = false
			end
			return self
		end
		function handle:running() return entry.running end
		function handle:stop()
			entry.stop_calls = entry.stop_calls + 1
			if entry.stop_throws > 0 then
				entry.stop_throws = entry.stop_throws - 1
				error("periodic stop exploded")
			end
			if entry.stop_failures > 0 then
				entry.stop_failures = entry.stop_failures - 1
				return false
			end
			if entry.stop_nils > 0 then
				entry.stop_nils = entry.stop_nils - 1
				return nil
			end
			entry.stopped = true
			entry.running = false
			return self
		end
		entry.handle = handle
		return handle
	end
	function timer.doEvery()
		fixture.raw_do_every_calls = fixture.raw_do_every_calls + 1
		error("synthetic_input must route recurring timers through TimerScheduler")
	end
	timer.delayed = {}
	local delayed_new_calls = 0
	function timer.delayed.new(default_delay, callback)
		delayed_new_calls = delayed_new_calls + 1
		local handle = { entry = nil, running = false }
		local function remove_pending(entry)
			if entry == nil then return end
			for index = #fixture.timers, 1, -1 do
				if fixture.timers[index] == entry then
					table.remove(fixture.timers, index)
					return
				end
			end
		end
		function handle:start(delay)
			fixture.delayed_start_calls = (fixture.delayed_start_calls or 0) + 1
			if (options.delayed_start_failures or 0) > 0 then
				options.delayed_start_failures = options.delayed_start_failures - 1
				return nil
			end
			if options.watchdog_start_returns_nil and default_delay > 0 then
				return nil
			end
			if self.entry then
				self.entry.stopped = true
				remove_pending(self.entry)
			end
			self.running = true
			local entry = {
				delay = delay == nil and default_delay or delay,
				callback = function()
					self.running = false
					callback()
				end,
				stopped = false,
			}
			self.entry = entry
			fixture.timers[#fixture.timers + 1] = entry
			return self
		end
		function handle:stop()
			if self.entry then
				self.entry.stopped = true
				remove_pending(self.entry)
			end
			self.running = false
			return self
		end
		if options.gc_cancels_unretained_timers then
			setmetatable(handle, {
				__gc = function(self) self:stop() end,
			})
		end
		fixture.delayed_handles[#fixture.delayed_handles + 1] = handle
		handle.creation_index = delayed_new_calls
		return handle
	end
	fixture.timer = timer

	function fixture.fire_next_timer()
		local entry = table.remove(fixture.timers, 1)
		helpers.assert_not_nil(entry, "expected a pending timer")
		if not entry.stopped then entry.callback() end
		if entry.recurring and not entry.stopped then
			fixture.timers[#fixture.timers + 1] = entry
		end
		return entry.delay
	end

	function fixture.fire_last_timer()
		local entry = table.remove(fixture.timers)
		helpers.assert_not_nil(entry, "expected a pending timer")
		if not entry.stopped then entry.callback() end
		if entry.recurring and not entry.stopped then
			fixture.timers[#fixture.timers + 1] = entry
		end
		return entry.delay
	end

	function fixture.fire_timer_matching(delay, from_end)
		local first = from_end and #fixture.timers or 1
		local last = from_end and 1 or #fixture.timers
		local step = from_end and -1 or 1
		for index = first, last, step do
			local entry = fixture.timers[index]
			if math.abs(entry.delay - delay) < 0.000001 then
				table.remove(fixture.timers, index)
				if not entry.stopped then entry.callback() end
				if entry.recurring and not entry.stopped then
					fixture.timers[#fixture.timers + 1] = entry
				end
				return entry
			end
		end
		return nil
	end

	local settings = {}
	function settings.get(key) return fixture.settings_store[key] end
	function settings.set(key, value) fixture.settings_store[key] = value end
	fixture.settings = settings

	local function make_event(kind, key, is_down)
		local event = {
			kind = kind,
			key = key,
			isDown = is_down,
			type = is_down == nil and nil or (is_down and KEY_DOWN or KEY_UP),
			properties = {},
			source_pid = CURRENT_PID,
		}
		function event:setUnicodeString(value) self.unicode = value; return self end
		function event:setType(value) self.type = value; return self end
		function event:getType() return self.type end
		function event:setProperty(property, value)
			if self.kind == "trigger" and options.trigger_set_property_fail then
				error("trigger setProperty exploded")
			end
			if self.kind == "external" and options.physical_set_property_throw then
				error("physical setProperty exploded")
			end
			self.properties[property] = value
			return self
		end
		function event:getProperty(property)
			if self.throw_on_get then error("property read exploded") end
			if property == MOUSE_BUTTON and options.throw_on_mouse_button_read then
				error("mouse button read exploded")
			end
			if property == SOURCE_PID then
				fixture.pid_reads = fixture.pid_reads + 1
				return self.source_pid
			end
			return self.properties[property] or 0
		end
		function event:copy()
			if options.physical_copy_throw and self.kind == "external" then
				error("physical copy exploded")
			end
			if options.physical_copy_nil and self.kind == "external" then return nil end
			local copy = make_event(self.kind, self.key, self.isDown)
			copy.type = self.type
			copy.source_pid = self.source_pid
			copy.unicode = self.unicode
			copy.modifiers = self.modifiers
			copy.position = self.position
			for property, value in pairs(self.properties) do copy.properties[property] = value end
			return copy
		end
		function event:post(app)
			helpers.assert_true(not fixture.callback_active,
				"event.post must never run inside the originating eventtap callback")
			fixture.post_count = fixture.post_count + 1
			self.posted_app = app
			fixture.posted_targets[#fixture.posted_targets + 1] = app
			if self.kind == "trigger" then
				fixture.watchdog_armed_at_post = false
				for _, handle in ipairs(fixture.delayed_handles) do
					if handle.running then fixture.watchdog_armed_at_post = true break end
				end
				fixture.last_trigger = self
				fixture.triggers[#fixture.triggers + 1] = self
				fixture.trigger_posts = fixture.trigger_posts + 1
				if fixture.deliver_trigger and fixture.active_tap then
					helpers.assert_true(fixture.active_tap.enabled,
						"Quartz cannot deliver through a stopped event tap")
					local consume, events = fixture.active_tap.callback(self)
					fixture.pump_deliveries[#fixture.pump_deliveries + 1] = {
						consume = consume, events = events,
					}
				end
			else
				fixture.key_attempts[#fixture.key_attempts + 1] = self
				if options.key_post_always_throws
					or options.key_post_throw_at == #fixture.key_attempts then
					error("key post exploded")
				end
				fixture.key_posts = fixture.key_posts + 1
				if app == nil then
					fixture.global_key_posts = fixture.global_key_posts + 1
					if fixture.global_key_observer then fixture.global_key_observer(self) end
				else
					fixture.targeted_key_posts = fixture.targeted_key_posts + 1
				end
				if fixture.key_observer then fixture.key_observer(self, app) end
			end
			return self
		end
		return event
	end

	function fixture.deliver_posted_trigger(trigger)
		trigger = trigger or fixture.last_trigger
		helpers.assert_not_nil(trigger, "expected a posted trigger")
		helpers.assert_not_nil(fixture.active_tap, "expected an active pump")
		helpers.assert_true(fixture.active_tap.enabled,
			"Quartz cannot deliver through a stopped event tap")
		local consume, events = fixture.active_tap.callback(trigger)
		fixture.pump_deliveries[#fixture.pump_deliveries + 1] = {
			consume = consume, events = events,
		}
		return consume, events
	end

	function fixture.external_event(tag, source_pid)
		local event = make_event("external", "x", true)
		if tag ~= nil then event.properties[USER_DATA] = tag end
		event.source_pid = source_pid or CURRENT_PID
		return event
	end

	function fixture.mouse_event(event_type)
		local event = make_event("external-mouse", nil, nil)
		event.type = event_type or LEFT_MOUSE_DOWN
		return event
	end

	local new_key_event_calls = 0
	local eventtap = {
		event = {
			properties = {
				eventSourceUserData = USER_DATA,
				eventSourceUnixProcessID = SOURCE_PID,
				mouseEventButtonNumber = MOUSE_BUTTON,
			},
				types = {
					keyDown = KEY_DOWN,
					keyUp = KEY_UP,
					flagsChanged = FLAGS_CHANGED,
					leftMouseDown = LEFT_MOUSE_DOWN,
					leftMouseUp = LEFT_MOUSE_UP,
					rightMouseDown = RIGHT_MOUSE_DOWN,
					rightMouseUp = RIGHT_MOUSE_UP,
					mouseMoved = MOUSE_MOVED,
					leftMouseDragged = LEFT_MOUSE_DRAGGED,
					rightMouseDragged = RIGHT_MOUSE_DRAGGED,
					otherMouseDragged = OTHER_MOUSE_DRAGGED,
					otherMouseUp = OTHER_MOUSE_UP,
			},
			newKeyEvent = function(modifiers, key, is_down)
				new_key_event_calls = new_key_event_calls + 1
				if options.new_key_event_throw_at == new_key_event_calls then
					error("newKeyEvent exploded")
				end
				if options.new_key_event_nil_at == new_key_event_calls then return nil end
				local event = make_event("key", key, is_down)
				event.modifiers = modifiers
				return event
			end,
			newMouseEvent = function(event_type, position, modifiers)
				local event = make_event("trigger", nil, nil)
				event.type = event_type
				event.position = position
				event.modifiers = modifiers
				return event
			end,
		},
	}
	function eventtap.new(types, callback)
		local tap_index = #fixture.taps + 1
		local tap = {
			types = types,
			callback = callback,
			enabled = false,
			start_count = 0,
			stop_count = 0,
			stop_throws = options.tap_stop_throws_by_call
				and (options.tap_stop_throws_by_call[tap_index] or 0)
				or 0,
		}
		function tap:start()
			self.start_count = self.start_count + 1
			self.enabled = fixture.tap_should_enable
			fixture.active_tap = self
			local mode = options.tap_start_modes_by_call
				and options.tap_start_modes_by_call[tap_index]
			if mode == "throw" then error("tap start exploded") end
			if mode == "false" then return false end
			if mode == "nil" then return nil end
			return self
		end
		function tap:stop()
			self.stop_count = self.stop_count + 1
			if self.stop_throws > 0 then
				self.stop_throws = self.stop_throws - 1
				error("tap stop exploded")
			end
			self.enabled = false
			return self
		end
		function tap:isEnabled() return self.enabled end
		fixture.taps[#fixture.taps + 1] = tap
		return tap
	end
	fixture.eventtap = eventtap

	fixture.hs_overrides = {
		eventtap = eventtap,
		timer = timer,
		settings = settings,
		processInfo = { processID = CURRENT_PID },
		mouse = { absolutePosition = function() return { x = 321, y = 654 } end },
		application = {
			frontmostApplication = function() return fixture.frontmost_app end,
			get = function(pid)
				return fixture.live_applications and fixture.live_applications[pid] or nil
			end,
		},
	}

	function fixture.load()
		package.loaded["infra.logger"] = fixture.logger
		package.loaded["adapters.storage"] = nil
		package.loaded["adapters.timer_scheduler"] = nil
		local synthetic = helpers.load_with_stubs(
			"adapters.synthetic_input", fixture.hs_overrides)
		package.loaded["adapters.storage"] = nil
		package.loaded["infra.logger"] = fixture.logger
		package.loaded["adapters.event_provenance"] = nil
		local provenance = require("adapters.event_provenance")
		return synthetic, provenance
	end

	return fixture
end

return {
	make = make_fixture,
	USER_DATA = USER_DATA,
	SOURCE_PID = SOURCE_PID,
	MOUSE_BUTTON = MOUSE_BUTTON,
	KEY_DOWN = KEY_DOWN,
	KEY_UP = KEY_UP,
	FLAGS_CHANGED = FLAGS_CHANGED,
	LEFT_MOUSE_DOWN = LEFT_MOUSE_DOWN,
	LEFT_MOUSE_UP = LEFT_MOUSE_UP,
	RIGHT_MOUSE_DOWN = RIGHT_MOUSE_DOWN,
	RIGHT_MOUSE_UP = RIGHT_MOUSE_UP,
	MOUSE_MOVED = MOUSE_MOVED,
	LEFT_MOUSE_DRAGGED = LEFT_MOUSE_DRAGGED,
	OTHER_MOUSE_UP = OTHER_MOUSE_UP,
	RIGHT_MOUSE_DRAGGED = RIGHT_MOUSE_DRAGGED,
	OTHER_MOUSE_DRAGGED = OTHER_MOUSE_DRAGGED,
	CURRENT_PID = CURRENT_PID,
}
