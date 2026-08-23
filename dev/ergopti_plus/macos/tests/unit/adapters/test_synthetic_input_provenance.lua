--- tests/unit/adapters/test_synthetic_input_provenance.lua

--- ==============================================================================
--- MODULE: Synthetic Input and Provenance Adapter Unit Tests
--- DESCRIPTION:
--- Exercises the runtime contract that PID/timing heuristics could not prove:
--- unique per-event tags, per-consumer loopback dedupe, bounded-ledger and
--- reload fallback, atomic action epochs, callback-return batching, deferred
--- pump liveness, and F16 loopback re-entry through a global Quartz post.
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
		local tap = {
			types = types,
			callback = callback,
			enabled = false,
			start_count = 0,
			stop_count = 0,
		}
		function tap:start()
			self.start_count = self.start_count + 1
			self.enabled = fixture.tap_should_enable
			fixture.active_tap = self
			return self
		end
		function tap:stop()
			self.stop_count = self.stop_count + 1
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
		package.loaded["adapters.timer_scheduler"] = nil
		local synthetic = helpers.load_with_stubs(
			"adapters.synthetic_input", fixture.hs_overrides)
		package.loaded["infra.logger"] = fixture.logger
		package.loaded["adapters.event_provenance"] = nil
		local provenance = require("adapters.event_provenance")
		return synthetic, provenance
	end

	return fixture
end


helpers.describe("synthetic input: explicit per-event provenance", function()
	helpers.it("loads production adapters and claims reordered events once per consumer", function()
		local fixture = make_fixture()
		local synthetic, provenance = fixture.load()
		local epoch_before = synthetic.current_action_epoch()
		local tx = synthetic.begin("unit.action", "action")
		local batch = synthetic.begin_callback(tx)
		helpers.assert_true(synthetic.keyStrokes(batch, "ab"))
		local completed = false
		synthetic.on_complete(tx, function(_, status)
			completed = status == "complete"
		end)
		local consume, events = synthetic.finish_callback(batch, true)
		helpers.assert_true(synthetic.seal(tx))
		helpers.assert_true(consume)
		helpers.assert_eq(#events, 4)
		helpers.assert_eq(fixture.post_count, 0,
			"originating callback path must never call event:post()")
		helpers.assert_true(not completed,
			"completion must wait until timer zero after callback return")
		helpers.assert_true(synthetic.current_action_epoch() ~= epoch_before,
			"a successful nonempty action handoff must replace the epoch token")
		helpers.assert_eq(synthetic.stats().action_handoffs, 1)

		local tags = {}
		for _, event in ipairs(events) do
			local tag = event:getProperty(USER_DATA)
			helpers.assert_nil(tags[tag], "every phase needs a unique user-data tag")
			tags[tag] = true
		end

		-- Ordinal 2 arrives before ordinal 1: immutable metadata follows the event,
		-- while only a repeated delivery of that exact tag is a duplicate.
		local second = provenance.classify(events[3], "keymap")
		helpers.assert_eq(second.ordinal, 2)
		helpers.assert_eq(second.phase, "down")
		helpers.assert_true(not second.duplicate)
		helpers.assert_eq(second.effect, "action")

		local first_late = provenance.classify(events[1], "keymap")
		helpers.assert_eq(first_late.ordinal, 1)
		local duplicate = provenance.classify(events[3], "keymap")
		helpers.assert_true(duplicate.duplicate)

		local other_consumer = provenance.classify(events[3], "keylogger")
		helpers.assert_true(not other_consumer.duplicate)
		helpers.assert_true(synthetic.current_action_epoch() == synthetic.current_action_epoch(),
			"epoch reads must return the same allocation until another handoff")

		-- Metadata is a copy: callers cannot corrupt the ledger seen by a sibling.
		other_consumer.owner = "mutated"
		local copied = provenance.classify(events[4], "third-consumer")
		helpers.assert_eq(copied.owner, "unit.action")

		fixture.fire_next_timer() -- post-return confirmation reaches terminal state
		helpers.assert_true(not completed,
			"terminal lifecycle callbacks must never run inline with confirmation")
		fixture.fire_next_timer() -- retained lifecycle dispatcher
		helpers.assert_true(completed)
	end)

	helpers.it("rejects same-PID untagged input and keeps PID secondary", function()
		local fixture = make_fixture()
		local synthetic, provenance = fixture.load()
		local pid_reads_before = fixture.pid_reads
		helpers.assert_nil(provenance.classify(
			fixture.external_event(nil, CURRENT_PID), "keymap"))
		helpers.assert_eq(fixture.pid_reads, pid_reads_before,
			"unknown tags must not pay the PID diagnostic read")

		local tx = synthetic.begin("unit.pid", "replacement")
		local batch = synthetic.begin_callback(tx)
		synthetic.keyStroke(batch, {}, "x")
		local _, events = synthetic.finish_callback(batch, true)
		events[1].source_pid = 9999
		local metadata = provenance.classify(events[1], "keymap")
		helpers.assert_true(metadata.owned,
			"known tag stays authoritative across a PID mismatch")
		helpers.assert_true(metadata.pid_matches == false)
	end)

	helpers.it("keeps evicted and pre-reload tags fail-closed with decoded effect", function()
		local fixture = make_fixture()
		local synthetic, provenance = fixture.load()
		local tx = synthetic.begin("unit.large", "replacement")
		local batch = synthetic.begin_callback(tx)
		synthetic.keyStroke(batch, {}, "a")
		local first_event = batch.events[1]
		local first_tag = first_event:getProperty(USER_DATA)
		helpers.assert_throws(function() synthetic.claim_tag(first_tag, {}) end,
			"live tags must reject an invalid consumer ID")
		-- 2,050 pairs exceed the real 4,096-record bound inside one batch.
		for _ = 2, 2050 do synthetic.keyStroke(batch, {}, "a") end
		local evicted = provenance.classify(first_event, "keymap")
		helpers.assert_true(evicted.owned)
		helpers.assert_true(not evicted.enriched)
		helpers.assert_true(evicted.stale)
		helpers.assert_eq(evicted.effect, "replacement")
		helpers.assert_eq(synthetic.stats().action_handoffs, 0,
			"current-session replacement eviction must not publish a false boundary")
		helpers.assert_eq(synthetic.stats().stale_context_tags, 0)
		helpers.assert_true(synthetic.decode_tag(first_tag).owned)
		helpers.assert_throws(function() synthetic.claim_tag(first_tag, {}) end,
			"stale tags must enforce the same fail-fast consumer contract")

		local reservation_before = fixture.settings_store[
			"ergopti_plus.synthetic_input.next_tag_sequence_v2"]
		local stale_loop_tx = synthetic.begin("unit.stale-loop", "action")
		local stale_loop_batch = synthetic.begin_callback(stale_loop_tx)
		synthetic.loopbackKeyStroke(stale_loop_batch, {}, "f16")
		local stale_loop_event = stale_loop_batch.events[1]
		synthetic.finish_callback(stale_loop_batch, true)
		synthetic.seal(stale_loop_tx)

		fixture.timers = {}
		local reloaded, provenance_after_reload = fixture.load()
		local reservation_after = fixture.settings_store[
			"ergopti_plus.synthetic_input.next_tag_sequence_v2"]
		helpers.assert_true(reservation_after > reservation_before,
			"each load must reserve a disjoint persisted sequence block")
		local old_epoch = reloaded.current_action_epoch()
		helpers.assert_true(provenance_after_reload.is_owned(first_event))
		helpers.assert_true(reloaded.current_action_epoch() == old_epoch,
			"is_owned must remain a read-only ownership probe")
		helpers.assert_eq(reloaded.stats().stale_context_tags, 0)
		local old = provenance_after_reload.classify(first_event, "keymap")
		helpers.assert_true(old.owned)
		helpers.assert_eq(old.effect, "replacement")
		helpers.assert_true(not old.enriched)
		helpers.assert_true(reloaded.current_action_epoch() ~= old_epoch,
			"a pre-reload replacement must invalidate the new logical context")
		helpers.assert_eq(reloaded.stats().stale_context_tags, 1)

		local new_tx = reloaded.begin("unit.reload", "action")
		local new_batch = reloaded.begin_callback(new_tx)
		reloaded.keyStroke(new_batch, {}, "b")
		helpers.assert_true(new_batch.events[1]:getProperty(USER_DATA) ~= first_tag,
			"reload must not reuse an old Quartz tag")

		local epoch_before_stale_loop = reloaded.current_action_epoch()
		local stale_loop = provenance_after_reload.classify(stale_loop_event, "keymap")
		helpers.assert_true(stale_loop.owned)
		helpers.assert_true(not stale_loop.loopback)
		helpers.assert_true(stale_loop.stale_loopback,
			"an old F16 must never be routed into a new prediction")
		helpers.assert_true(reloaded.current_action_epoch() == epoch_before_stale_loop,
			"an old internal loopback is not an observable user action")
		helpers.assert_eq(reloaded.stats().stale_context_tags, 1,
			"the stale loopback must not enter non-loopback context dedupe")
	end)

	helpers.it("advances one bounded conservative epoch per stale non-loopback tag", function()
		local fixture = make_fixture()
		local prior = fixture.load()

		local function prior_action_events(key)
			local tx = prior.begin("unit.prior-action", "action")
			local batch = prior.begin_callback(tx)
			prior.keyStroke(batch, {}, key)
			local down, up = batch.events[1], batch.events[2]
			prior.finish_callback(batch, true)
			prior.seal(tx)
			return down, up
		end

		local first_down, first_up = prior_action_events("a")
		local second_down = prior_action_events("b")
		fixture.timers = {}
		local synthetic, provenance = fixture.load() -- old events lose live enrichment
		synthetic.STALE_CONTEXT_DEDUPE_LIMIT = 2
		local initial_epoch = synthetic.current_action_epoch()

		helpers.assert_true(provenance.is_owned(first_down))
		helpers.assert_true(synthetic.current_action_epoch() == initial_epoch,
			"a nil-consumer ownership probe must not mutate the epoch")
		helpers.assert_eq(synthetic.stats().stale_context_tags, 0)

		local first = provenance.classify(first_down, "keymap")
		local first_epoch = synthetic.current_action_epoch()
		helpers.assert_true(first.stale and first.effect == "action")
		helpers.assert_true(first_epoch ~= initial_epoch,
			"the first consumer of a stale action tag must invalidate current context")
		helpers.assert_eq(synthetic.stats().action_handoffs, 1)

		local sibling = provenance.classify(first_down, "keylogger")
		helpers.assert_true(sibling.stale and sibling.effect == "action")
		helpers.assert_true(synthetic.current_action_epoch() == first_epoch,
			"a sibling consumer must not publish the same stale tag twice")
		helpers.assert_eq(synthetic.stats().action_handoffs, 1)

		provenance.classify(first_up, "keylogger")
		helpers.assert_eq(synthetic.stats().action_handoffs, 2,
			"a distinct stale phase tag must publish its own conservative boundary")
		provenance.classify(second_down, "keymap")
		helpers.assert_eq(synthetic.stats().action_handoffs, 3)
		helpers.assert_eq(synthetic.stats().stale_context_tags, 2,
			"stale-context dedupe memory must stay at its configured bound")

		local before_revisit = synthetic.current_action_epoch()
		provenance.classify(first_down, "third-consumer")
		helpers.assert_true(synthetic.current_action_epoch() ~= before_revisit,
			"an evicted dedupe entry must fail safe if its tag appears again")
		helpers.assert_eq(synthetic.stats().stale_context_tags, 2)
	end)

	helpers.it("wraps the persisted sequence ring without bricking a reload", function()
		local sequence_limit = 1 << 38
		local reservation_key = "ergopti_plus.synthetic_input.next_tag_sequence_v2"
		local fixture = make_fixture({
			settings_store = { [reservation_key] = sequence_limit - 2 },
		})
		local synthetic, provenance = fixture.load()
		synthetic.RECORD_LIMIT = 2
		local initial_epoch = synthetic.current_action_epoch()
		local tx = synthetic.begin("unit.wrap", "action")
		local batch = synthetic.begin_callback(tx)
		synthetic.keyStrokes(batch, "ab") -- four tags cross limit - 1 -> 0
		local _, events = synthetic.finish_callback(batch, true)
		helpers.assert_eq(synthetic.decode_tag(events[1]:getProperty(USER_DATA)).sequence,
			sequence_limit - 2)
		helpers.assert_eq(synthetic.decode_tag(events[3]:getProperty(USER_DATA)).sequence, 0)
		helpers.assert_true(synthetic.current_action_epoch() ~= initial_epoch)
		helpers.assert_eq(synthetic.stats().action_handoffs, 1)
		local wrapped_stale = provenance.classify(events[1], "keymap")
		helpers.assert_true(wrapped_stale.stale)
		helpers.assert_eq(synthetic.stats().action_handoffs, 1,
			"a wrapped current-session block must not look like pre-reload output")
		helpers.assert_eq(synthetic.stats().stale_context_tags, 0)

		fixture.timers = {}
		local reloaded = fixture.load()
		local reloaded_tx = reloaded.begin("unit.wrap-reload", "replacement")
		local reloaded_batch = reloaded.begin_callback(reloaded_tx)
		reloaded.keyStroke(reloaded_batch, {}, "c")
		helpers.assert_eq(reloaded.decode_tag(
			reloaded_batch.events[1]:getProperty(USER_DATA)).sequence,
			(1 << 20) - 2,
			"reload must continue from the persisted modular reservation")
	end)
end)


helpers.describe("synthetic input: callback and deferred dispatch", function()
	helpers.it("starts the pump lazily and hands one unposted payload batch back", function()
		local fixture = make_fixture()
		local synthetic, provenance = fixture.load()
		local epoch_before = synthetic.current_action_epoch()
		local tx = synthetic.begin("unit.deferred", "action")
		local batch = synthetic.begin_batch(tx)
		synthetic.keyStroke(batch, { "cmd" }, "v")
		local completed = false
		synthetic.on_complete(tx, function(_, status) completed = status == "complete" end)
		helpers.assert_true(synthetic.dispatch(batch))
		synthetic.seal(tx)
		helpers.assert_eq(#fixture.taps, 0)
		helpers.assert_eq(fixture.post_count, 0)
		helpers.assert_eq(#fixture.timers, 1,
			"dispatch itself may only enqueue timer-zero work")

		helpers.assert_eq(fixture.fire_next_timer(), 0)
		helpers.assert_eq(#fixture.taps, 1)
		helpers.assert_eq(fixture.taps[1].types[1], OTHER_MOUSE_UP)
		helpers.assert_eq(fixture.trigger_posts, 1)
		helpers.assert_eq(fixture.last_trigger.position.x, 321)
		helpers.assert_eq(fixture.last_trigger.position.y, 654)
		helpers.assert_eq(fixture.last_trigger:getProperty(MOUSE_BUTTON),
			synthetic.PUMP_MOUSE_BUTTON)
		helpers.assert_true(fixture.last_trigger:getProperty(USER_DATA) ~= 0)
		helpers.assert_eq(fixture.key_posts, 0,
			"payload events must be callback-returned, never individually posted")
		helpers.assert_eq(#fixture.pump_deliveries, 1)
		helpers.assert_true(fixture.pump_deliveries[1].consume)
		helpers.assert_eq(#fixture.pump_deliveries[1].events, 2)
		helpers.assert_true(synthetic.current_action_epoch() ~= epoch_before)
		local echo = provenance.classify(fixture.pump_deliveries[1].events[1], "keymap")
		helpers.assert_true(echo.owned)
		helpers.assert_true(not completed)
		fixture.fire_next_timer() -- post-return confirmation
		helpers.assert_true(not completed)
		fixture.fire_next_timer() -- retained lifecycle dispatcher
		helpers.assert_true(completed)
	end)

	helpers.it("recreates a pump disabled between two batches", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local function send_one(owner)
			local tx = synthetic.begin(owner, "action")
			local batch = synthetic.begin_batch(tx)
			synthetic.keyStroke(batch, {}, "x")
			synthetic.dispatch(batch)
			synthetic.seal(tx)
			fixture.fire_next_timer()
			fixture.fire_next_timer()
		end
		send_one("unit.first")
		helpers.assert_eq(#fixture.taps, 1)
		local old_tap = fixture.active_tap
		old_tap.enabled = false
		send_one("unit.second")
		helpers.assert_eq(#fixture.taps, 2)
		helpers.assert_true(old_tap.stop_count > 0)
	end)

	helpers.it("delivers with the runtime-faithful event-type surface", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		helpers.assert_nil(fixture.eventtap.event.types.tapDisabledByTimeout,
			"the pump fixture must not manufacture a native-only callback event")
		helpers.assert_nil(fixture.eventtap.event.types.tapDisabledByUserInput)

		local tx = synthetic.begin("unit.native-contract", "action")
		local batch = synthetic.begin_batch(tx)
		synthetic.keyStroke(batch, {}, "x")
		synthetic.dispatch(batch)
		synthetic.seal(tx)
		fixture.fire_next_timer()

		helpers.assert_eq(#fixture.pump_deliveries, 1)
		helpers.assert_true(fixture.pump_deliveries[1].consume)
		helpers.assert_eq(#fixture.pump_deliveries[1].events, 2,
			"ordinary tagged payload delivery must not depend on an unreachable disable branch")
	end)

	helpers.it("serializes deferred batches through one FIFO timer under reverse scheduling", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local function enqueue(owner, key)
			local tx = synthetic.begin(owner, "action")
			local batch = synthetic.begin_batch(tx)
			synthetic.keyStroke(batch, {}, key)
			synthetic.dispatch(batch)
			synthetic.seal(tx)
		end
		enqueue("unit.fifo-a", "a")
		enqueue("unit.fifo-b", "b")
		helpers.assert_eq(#fixture.timers, 1,
			"N queued batches must have only one broker timer in flight")

		-- A scheduler that chooses the newest equal-deadline timer cannot reverse
		-- output because the broker never exposes two trigger timers at once.
		fixture.fire_last_timer()
		helpers.assert_eq(fixture.pump_deliveries[1].events[1].key, "a")
		helpers.assert_eq(#fixture.timers, 1,
			"only A's post-return confirmation may exist before B is eligible")
		fixture.fire_last_timer() -- confirms A and schedules B's sole broker timer
		helpers.assert_eq(#fixture.timers, 1)
		fixture.fire_last_timer()
		helpers.assert_eq(fixture.pump_deliveries[2].events[1].key, "b")
	end)

	helpers.it("prepends older deferred output to a later callback handoff", function()
		local fixture = make_fixture({ deliver_trigger = false })
		local synthetic = fixture.load()

		local older_tx = synthetic.begin("unit.mixed-a", "action")
		local older_batch = synthetic.begin_batch(older_tx)
		synthetic.keyStroke(older_batch, {}, "a")
		synthetic.dispatch(older_batch)
		synthetic.seal(older_tx)
		helpers.assert_eq(#fixture.timers, 1,
			"the older deferred action is waiting for its broker turn")

		synthetic.enter_callback()
		local newer_tx = synthetic.begin("unit.mixed-b", "action")
		synthetic.with_transaction(newer_tx, function()
			synthetic.emit_key_stroke({}, "b", 0)
		end)
		synthetic.seal(newer_tx)
		local consume, events = synthetic.leave_callback(true)

		helpers.assert_true(consume)
		helpers.assert_eq(#events, 4)
		helpers.assert_eq(events[1].key, "a",
			"an earlier deferred action must not be overtaken by callback output")
		helpers.assert_eq(events[3].key, "b")
		helpers.assert_eq(synthetic.stats().pending, 0)
		helpers.assert_eq(#fixture.pump_deliveries, 0,
			"adoption must return one ordered batch, not also pump the older payload")
	end)

	helpers.it("hands older deferred output off before an ordinary physical event", function()
		local fixture = make_fixture({ deliver_trigger = false })
		local synthetic = fixture.load()
		local initial_epoch = synthetic.current_action_epoch()
		local tx = synthetic.begin("unit.physical-fence", "action")
		local batch = synthetic.begin_batch(tx)
		synthetic.keyStroke(batch, {}, "a")
		synthetic.dispatch(batch)
		synthetic.seal(tx)

		local fence = synthetic.claim_physical_fence()
		helpers.assert_not_nil(fence)
		helpers.assert_eq(#fence.events, 2)
		helpers.assert_eq(fence.events[1].key, "a",
			"Hammerspoon posts the returned table before propagating the original event")
		helpers.assert_true(synthetic.current_action_epoch() ~= initial_epoch,
			"the first tap must reconcile consumers before mutating the physical event")
		helpers.assert_eq(synthetic.stats().pending, 0)
		helpers.assert_nil(synthetic.claim_physical_fence(),
			"a downstream tap must not claim the same deferred action twice")
	end)

	helpers.it("keeps action and physical state ordered in both head-insert tap orders", function()
		local function exercise(order_names)
			local fixture = make_fixture({ deliver_trigger = false })
			local synthetic, provenance = fixture.load()
			local initial_epoch = synthetic.current_action_epoch()
			local tx = synthetic.begin("unit.tap-chain", "action")
			local batch = synthetic.begin_batch(tx)
			synthetic.keyStroke(batch, {}, "a")
			synthetic.dispatch(batch)
			synthetic.seal(tx)

			local state = {
				keymap = { epoch = initial_epoch, buffer = { "pre" } },
				keylogger = { epoch = initial_epoch, buffer = { "pre" }, snapshots = {} },
			}
			local function reconcile(name)
				local epoch = synthetic.current_action_epoch()
				local consumer = state[name]
				if epoch == consumer.epoch then return end
				if name == "keylogger" then
					consumer.snapshots[#consumer.snapshots + 1] = table.concat(consumer.buffer)
				end
				consumer.buffer = {}
				consumer.epoch = epoch
			end
			local callbacks = {}
			for _, name in ipairs({ "keymap", "keylogger" }) do
				callbacks[name] = function(event)
					local owned = provenance.classify(event, name)
					local fence = nil
					if not owned then fence = synthetic.claim_physical_fence() end
					reconcile(name)
					if not owned and event.isDown then
						state[name].buffer[#state[name].buffer + 1] = event.key
					end
					return false, fence and fence.events or nil
				end
			end

			local app_keys = {}
			local function deliver(index, event)
				if index > #order_names then
					if event.isDown then app_keys[#app_keys + 1] = event.key end
					return
				end
				local consume, returned = callbacks[order_names[index]](event)
				-- Mirrors libeventtap.m: returned events enter only downstream taps
				-- before the physical original continues through that same proxy.
				for _, returned_event in ipairs(returned or {}) do
					deliver(index + 1, returned_event)
				end
				if not consume then deliver(index + 1, event) end
			end

			deliver(1, fixture.external_event(nil, CURRENT_PID))
			helpers.assert_eq(table.concat(app_keys, ","), "a,x")
			helpers.assert_eq(state.keylogger.snapshots[1], "pre",
				"the overtaking physical key belongs to the post-action run")
			helpers.assert_eq(table.concat(state.keylogger.buffer), "x")
			helpers.assert_eq(table.concat(state.keymap.buffer), "x")
			helpers.assert_true(synthetic.current_action_epoch() ~= initial_epoch)
			helpers.assert_eq(synthetic.stats().pending, 0)
		end

		exercise({ "keylogger", "keymap" })
		exercise({ "keymap", "keylogger" })
	end)

	helpers.it("strongly retains broker, listener, and confirmation timers across GC", function()
		local fixture = make_fixture({ gc_cancels_unretained_timers = true })
		local synthetic = fixture.load()
		local listener_calls, status = 0, nil
		synthetic.register_action_listener("unit", function()
			listener_calls = listener_calls + 1
		end)
		local tx = synthetic.begin("unit.gc", "action")
		local batch = synthetic.begin_batch(tx)
		synthetic.keyStroke(batch, {}, "x")
		synthetic.on_complete(tx, function(_, value) status = value end)
		synthetic.dispatch(batch)
		synthetic.seal(tx)
		collectgarbage("collect")
		fixture.fire_next_timer() -- retained broker hands off payload
		helpers.assert_eq(#fixture.pump_deliveries, 1)
		collectgarbage("collect")
		fixture.fire_next_timer() -- retained async listener
		helpers.assert_eq(listener_calls, 1)
		collectgarbage("collect")
		fixture.fire_next_timer() -- retained post-return confirmation
		helpers.assert_nil(status,
			"completion callbacks are isolated from the confirmation timer")
		fixture.fire_next_timer() -- retained lifecycle dispatcher
		helpers.assert_eq(status, "complete")
	end)

	helpers.it("returns pump payload even when its confirmation timer cannot allocate", function()
		local fixture = make_fixture({ fail_on_do_after_call = 2 })
		local synthetic = fixture.load()
		local tx = synthetic.begin("unit.pump-confirm-fail", "action")
		local batch = synthetic.begin_batch(tx)
		synthetic.keyStroke(batch, {}, "x")
		local status
		synthetic.on_complete(tx, function(_, value) status = value end)
		synthetic.dispatch(batch)
		synthetic.seal(tx)
		fixture.fire_next_timer()
		helpers.assert_eq(#fixture.pump_deliveries, 1)
		helpers.assert_true(fixture.pump_deliveries[1].consume)
		helpers.assert_eq(#fixture.pump_deliveries[1].events, 2,
			"confirmation diagnostics cannot erase an irrevocably handed-off payload")
		helpers.assert_nil(status)
		while #fixture.timers > 0 and status == nil do fixture.fire_next_timer() end
		helpers.assert_eq(status, "failed")
	end)

	helpers.it("uses the retained backup dispatcher without running feature work inline", function()
		local fixture = make_fixture({ delayed_start_failures = 1 })
		local synthetic = fixture.load()
		local calls = 0
		helpers.assert_true(synthetic.defer_after_callback(
			"unit backup dispatcher", function() calls = calls + 1 end))
		helpers.assert_eq(calls, 0,
			"post-eventtap feature work must never run on the caller's stack")
		helpers.assert_eq(fixture.delayed_start_calls, 2,
			"one failed primary start must fall through to the pre-created backup")
		helpers.assert_eq(synthetic.stats().pending_post_callback_actions, 1)
		fixture.fire_next_timer()
		helpers.assert_eq(calls, 1)
		helpers.assert_eq(synthetic.stats().pending_post_callback_actions, 0)
	end)

	helpers.it("fails a feature action closed when every dispatcher start fails", function()
		local fixture = make_fixture({ delayed_start_failures = 2 })
		local synthetic = fixture.load()
		local calls = 0
		fixture.fail_next_do_after = true -- independent retained doAfter fallback
		helpers.assert_true(not synthetic.defer_after_callback(
			"unit unavailable dispatcher", function() calls = calls + 1 end))
		helpers.assert_eq(calls, 0)
		helpers.assert_eq(synthetic.stats().pending_post_callback_actions, 0,
			"a rejected feature action must be removed instead of firing later")
		helpers.assert_eq(synthetic.stats().pending_lifecycle_callbacks, 0)
		while #fixture.timers > 0 do fixture.fire_next_timer() end
		helpers.assert_eq(calls, 0,
			"a caller that passed its physical event through must not get a duplicate action")
	end)

	helpers.it("keeps an already-idle drain owned when every fast dispatcher start fails", function()
		local fixture = make_fixture({ delayed_start_failures = 2 })
		local synthetic = fixture.load()
		local calls = 0
		fixture.fail_next_do_after = true -- independent retained doAfter fallback
		helpers.assert_true(synthetic.when_idle(function() calls = calls + 1 end),
			"the pre-acquired periodic owner must survive every fast-dispatch refusal")
		helpers.assert_eq(calls, 0,
			"an unavailable dispatcher must not run lifecycle work inline")
		helpers.assert_not_nil(fixture.fire_timer_matching(synthetic.IDLE_WAITER_TICK_SEC),
			"an accepted drain must retain an autonomous wake")
		helpers.assert_eq(calls, 1,
			"the periodic owner must deliver the accepted drain exactly once")
	end)

	helpers.it("fails terminally when CGEventTapCreate returns a disabled tap", function()
		local fixture = make_fixture({ tap_should_enable = false })
		local synthetic = fixture.load()
		local tx = synthetic.begin("unit.disabled", "action")
		local batch = synthetic.begin_batch(tx)
		synthetic.keyStroke(batch, {}, "x")
		local status
		synthetic.on_complete(tx, function(_, value) status = value end)
		synthetic.dispatch(batch)
		synthetic.seal(tx)
		fixture.fire_next_timer()
		helpers.assert_nil(status)
		fixture.fire_next_timer()
		helpers.assert_eq(status, "failed")
		helpers.assert_eq(synthetic.stats().pending, 0)
		helpers.assert_eq(fixture.trigger_posts, 0)
	end)

	helpers.it("watchdog retries without dropping output and sinks the late old trigger", function()
		local fixture = make_fixture({ deliver_trigger = false })
		local synthetic = fixture.load()
		local initial_epoch = synthetic.current_action_epoch()
		local tx = synthetic.begin("unit.timeout", "action")
		local batch = synthetic.begin_batch(tx)
		synthetic.keyStroke(batch, {}, "x")
		local status
		synthetic.on_complete(tx, function(_, value) status = value end)
		synthetic.dispatch(batch)
		synthetic.seal(tx)
		fixture.fire_next_timer()
		helpers.assert_eq(fixture.trigger_posts, 1)
		helpers.assert_eq(synthetic.stats().pending, 1)
		helpers.assert_eq(fixture.fire_next_timer(), synthetic.PUMP_DELIVERY_TIMEOUT_SEC)
		helpers.assert_nil(status,
			"an overdue run loop must not convert queued user output into failure")
		helpers.assert_eq(fixture.trigger_posts, 2)
		helpers.assert_eq(synthetic.stats().pending, 1)
		helpers.assert_true(fixture.active_tap.enabled,
			"an enabled pump remains the sink for late tombstoned triggers")
		local consume, events = fixture.deliver_posted_trigger(fixture.triggers[2])
		helpers.assert_true(consume,
			"the retry trigger must hand off the original payload")
		helpers.assert_eq(#events, 2)
		helpers.assert_true(synthetic.current_action_epoch() ~= initial_epoch)
		local old_consume, old_events = fixture.deliver_posted_trigger(fixture.triggers[1])
		helpers.assert_true(old_consume,
			"the late first trigger must be consumed as a tombstone")
		helpers.assert_nil(old_events)
		while #fixture.timers > 0 and status == nil do fixture.fire_next_timer() end
		helpers.assert_eq(status, "complete")
		helpers.assert_eq(synthetic.stats().pending, 0)
	end)

	helpers.it("terminates a permanently undelivered pump trigger after a bounded retry budget", function()
		local fixture = make_fixture({ deliver_trigger = false })
		local synthetic = fixture.load()
		local tx = synthetic.begin("unit.timeout-budget", "action")
		local batch = synthetic.begin_batch(tx)
		synthetic.keyStroke(batch, {}, "x")
		local status
		synthetic.on_complete(tx, function(_, value) status = value end)
		synthetic.dispatch(batch)
		synthetic.seal(tx)

		fixture.fire_next_timer() -- FIFO broker posts attempt one
		for _ = 1, synthetic.PUMP_WATCHDOG_MAX_FAILURES do
			helpers.assert_eq(fixture.fire_next_timer(),
				synthetic.PUMP_DELIVERY_TIMEOUT_SEC)
		end
		helpers.assert_eq(fixture.trigger_posts, synthetic.PUMP_WATCHDOG_MAX_FAILURES,
			"the normal timeout path must consume the same bounded budget as callback errors")
		helpers.assert_eq(synthetic.stats().pending, 0,
			"persistent run-loop loss must not leave an immortal queued transaction")
		helpers.assert_true(tx.completed)
		helpers.assert_eq(tx.completion_status, "failed")

		local consume, events = fixture.deliver_posted_trigger(fixture.triggers[#fixture.triggers])
		helpers.assert_true(consume,
			"the replacement pump must sink a trigger delivered after terminal timeout")
		helpers.assert_nil(events)
		while #fixture.timers > 0 do fixture.fire_next_timer() end
		helpers.assert_eq(status, "failed")
		helpers.assert_eq(#fixture.timers, 0,
			"terminal timeout must not leave a self-rearming watchdog")
	end)

	helpers.it("arms the retained watchdog before posting a deferred trigger", function()
		local fixture = make_fixture({ deliver_trigger = false })
		local synthetic = fixture.load()
		local tx = synthetic.begin("unit.watchdog-prearm", "action")
		local batch = synthetic.begin_batch(tx)
		synthetic.keyStroke(batch, {}, "x")
		local status
		synthetic.on_complete(tx, function(_, value) status = value end)
		synthetic.dispatch(batch)
		synthetic.seal(tx)

		fixture.fire_next_timer()
		helpers.assert_true(fixture.watchdog_armed_at_post,
			"watchdog startup must succeed before user intent is handed to Quartz")
		helpers.assert_nil(status)
		helpers.assert_true(fixture.active_tap.enabled,
			"a posted trigger still needs an enabled payload/tombstone sink")
		local consume, events = fixture.deliver_posted_trigger()
		helpers.assert_true(consume,
			"the reserved button-31 trigger must not reach the front application")
		helpers.assert_eq(#events, 2,
			"watchdog bookkeeping must never revoke already-posted user intent")
		while #fixture.timers > 0 and status == nil do fixture.fire_next_timer() end
		helpers.assert_eq(status, "complete")
	end)

	helpers.it("rejects a watchdog start that returns no retained handle", function()
		local fixture = make_fixture({
			deliver_trigger = false,
			watchdog_start_returns_nil = true,
		})
		local synthetic = fixture.load()
		local tx = synthetic.begin("unit.watchdog-start-nil", "action")
		local batch = synthetic.begin_batch(tx)
		synthetic.keyStroke(batch, {}, "x")
		local status
		synthetic.on_complete(tx, function(_, value) status = value end)
		synthetic.dispatch(batch)
		synthetic.seal(tx)

		fixture.fire_next_timer()
		helpers.assert_nil(status)
		fixture.fire_next_timer()
		helpers.assert_eq(status, "failed",
			"a watchdog with no live timer cannot authorize an unmonitored post")
		helpers.assert_eq(fixture.trigger_posts, 0,
			"the broker trigger must not post after watchdog startup failed")
		helpers.assert_eq(synthetic.stats().pending, 0)
	end)

	helpers.it("contains watchdog callback errors without stranding output", function()
		local fixture = make_fixture({ deliver_trigger = false })
		local original_warn = fixture.logger.warn
		local warn_calls = 0
		fixture.logger.warn = function(...)
			warn_calls = warn_calls + 1
			if warn_calls == 1 then error("watchdog logger unavailable") end
			return original_warn(...)
		end
		local synthetic = fixture.load()
		local tx = synthetic.begin("unit.watchdog-callback-error", "action")
		local batch = synthetic.begin_batch(tx)
		synthetic.keyStroke(batch, {}, "x")
		local status
		synthetic.on_complete(tx, function(_, value) status = value end)
		synthetic.dispatch(batch)
		synthetic.seal(tx)

		fixture.fire_next_timer() -- FIFO broker and first trigger post
		-- Let any escaped watchdog exception fail the test directly. The state
		-- assertions below prove that containment also preserves forward progress.
		fixture.fire_next_timer()
		fixture.deliver_trigger = true
		local fired = 0
		while #fixture.timers > 0 and status == nil and fired < 20 do
			fixture.fire_next_timer()
			fired = fired + 1
		end
		helpers.assert_eq(status, "complete",
			"a diagnostic failure cannot strand or revoke queued user output")
		helpers.assert_eq(synthetic.stats().pending, 0)
	end)

	helpers.it("sinks a delayed trigger after cancellation", function()
		local fixture = make_fixture({ deliver_trigger = false })
		local synthetic = fixture.load()
		local tx = synthetic.begin("unit.cancel-trigger", "action")
		local batch = synthetic.begin_batch(tx)
		synthetic.keyStroke(batch, {}, "x")
		synthetic.dispatch(batch)
		synthetic.seal(tx)
		fixture.fire_next_timer()
		helpers.assert_true(synthetic.cancel(tx))
		local consume, events = fixture.deliver_posted_trigger()
		helpers.assert_true(consume,
			"a cancelled broker trigger must never leak as a phantom mouse-up")
		helpers.assert_nil(events)
	end)

	helpers.it("rolls back trigger and payload records when trigger tagging throws", function()
		local fixture = make_fixture({ trigger_set_property_fail = true })
		local synthetic = fixture.load()
		local tx = synthetic.begin("unit.trigger-fail", "action")
		local batch = synthetic.begin_batch(tx)
		synthetic.keyStroke(batch, {}, "x")
		synthetic.dispatch(batch)
		synthetic.seal(tx)
		fixture.fire_next_timer()
		helpers.assert_eq(synthetic.stats().records, 0)
		helpers.assert_eq(synthetic.stats().pending, 0)
	end)

	helpers.it("contains pump callback failure and consumes its exact trigger", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local decode_tag = synthetic.decode_tag
		local fail_once = true
		synthetic.decode_tag = function(...)
			if fail_once then
				fail_once = false
				error("callback processing exploded")
			end
			return decode_tag(...)
		end
		local tx = synthetic.begin("unit.callback-failure", "action")
		local batch = synthetic.begin_batch(tx)
		synthetic.keyStroke(batch, {}, "x")
		synthetic.dispatch(batch)
		synthetic.seal(tx)

		fixture.fire_next_timer()
		helpers.assert_eq(#fixture.pump_deliveries, 1)
		helpers.assert_true(fixture.pump_deliveries[1].consume,
			"a proven broker trigger must never leak when callback processing throws")
		helpers.assert_nil(fixture.pump_deliveries[1].events)
		helpers.assert_eq(synthetic.stats().pending, 0,
			"the matched batch must fail terminally instead of retrying forever")
		helpers.assert_eq(synthetic.stats().records, 0)
	end)

	helpers.it("does not depend on a second mouse-button property read", function()
		local fixture = make_fixture({ throw_on_mouse_button_read = true })
		local synthetic = fixture.load()
		local tx = synthetic.begin("unit.mouse-property", "action")
		local batch = synthetic.begin_batch(tx)
		synthetic.keyStroke(batch, {}, "x")
		synthetic.dispatch(batch)
		synthetic.seal(tx)
		fixture.fire_next_timer()
		helpers.assert_true(fixture.pump_deliveries[1].consume)
		helpers.assert_eq(#fixture.pump_deliveries[1].events, 2,
			"the unique reserved tag is sufficient broker authority")
	end)
end)


helpers.describe("synthetic input: ambient transactions and loopback", function()
	helpers.it("revalidates idle state when the deferred callback actually executes", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local idle_calls = 0
		local active_seen
		local tx1 = synthetic.begin("unit.idle-first", "action")
		local batch1 = synthetic.begin_callback(tx1)
		synthetic.keyStroke(batch1, {}, "x")
		synthetic.when_idle(function()
			idle_calls = idle_calls + 1
			active_seen = synthetic.stats().active_transactions
		end)
		synthetic.finish_callback(batch1, true)
		synthetic.seal(tx1)

		fixture.fire_next_timer() -- confirms tx1 and queues the idle lifecycle call
		local tx2 = synthetic.begin("unit.idle-racer", "replacement")
		fixture.fire_next_timer() -- stale idle observation executes while tx2 is active
		helpers.assert_eq(idle_calls, 0,
			"an idle callback must not fire after a newer transaction has started")
		helpers.assert_eq(synthetic.stats().active_transactions, 1)

		synthetic.seal(tx2)
		fixture.fire_next_timer()
		helpers.assert_eq(idle_calls, 1)
		helpers.assert_eq(active_seen, 0,
			"the callback must observe the execution-time idle state")

		local immediate_calls = 0
		synthetic.when_idle(function() immediate_calls = immediate_calls + 1 end)
		local tx3 = synthetic.begin("unit.idle-immediate-racer", "replacement")
		fixture.fire_next_timer()
		helpers.assert_eq(immediate_calls, 0,
			"the already-idle fast path needs the same execution-time fence")
		synthetic.seal(tx3)
		fixture.fire_next_timer()
		helpers.assert_eq(immediate_calls, 1)
	end)

	helpers.it("gives an accepted active idle waiter an autonomous wake", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local tx = synthetic.begin("unit.autonomous-idle-waiter", "replacement")
		local token = synthetic.retain(tx)
		helpers.assert_true(synthetic.seal(tx))
		local calls = 0
		helpers.assert_true(synthetic.when_idle(function() calls = calls + 1 end),
			"acceptance must mean an independently owned terminal path exists")

		fixture.options.delayed_start_failures = 2
		fixture.fail_next_do_after = true
		helpers.assert_true(synthetic.release(tx, token))
		helpers.assert_eq(calls, 0,
			"the caller stack may not become a lifecycle dispatcher")
		local guard = 0
		while calls == 0 and #fixture.timers > 0 do
			fixture.fire_next_timer()
			guard = guard + 1
			helpers.assert_true(guard < 20, "owned idle waiter did not settle")
		end
		helpers.assert_eq(calls, 1,
			"all one-shot dispatch refusals must not strand an accepted drain")
	end)

	helpers.it("keeps an accepted stale idle callback owned across false nil and throw rearm traps", function()
		for _, case in ipairs({ "false", "nil", "throw" }) do
			local fixture = make_fixture()
			local synthetic = fixture.load()
			local calls = 0
			helpers.assert_true(synthetic.when_idle(function() calls = calls + 1 end))
			helpers.assert_eq(fixture.timer_new_calls, 1,
				"initial acceptance must acquire exactly one autonomous periodic owner")

			-- Production now owns the autonomous waiter before accepting. The old
			-- implementation first accepted only a lifecycle entry, then attempted a
			-- fresh periodic acquisition from its stale recheck and discarded false.
			local refused_call = fixture.timer_new_calls + 1
			if case == "false" then
				fixture.options.false_on_timer_new_call = refused_call
			elseif case == "nil" then
				fixture.options.fail_on_timer_new_call = refused_call
			else
				fixture.options.throw_on_timer_new_call = refused_call
			end
			local racer = synthetic.begin("unit.idle-recheck-" .. case, "replacement")
			fixture.fire_timer_matching(0)
			helpers.assert_eq(calls, 0,
				"the accepted callback must revalidate rather than cross an active tx")
			helpers.assert_true(synthetic.seal(racer))
			local guard = 0
			while calls == 0 and #fixture.timers > 0 do
				fixture.fire_next_timer()
				guard = guard + 1
				helpers.assert_true(guard < 20, case .. " stranded an accepted idle owner")
			end
			helpers.assert_eq(calls, 1,
				case .. " may not lose a callback whose initial acceptance was true")
			helpers.assert_eq(fixture.timer_new_calls, 1,
				case .. " stale recheck must reuse its initial owner, never hit a rearm trap")
		end
	end)

	helpers.it("removes a refused idle FIFO entry before any unrelated enqueue", function()
		for _, case in ipairs({ "false", "nil", "throw" }) do
			local options = { delayed_start_failures = 2 }
			options[case == "false" and "false_on_timer_new_call"
				or (case == "nil" and "fail_on_timer_new_call"
					or "throw_on_timer_new_call")] = 1
			local fixture = make_fixture(options)
			fixture.fail_next_do_after = true
			local synthetic = fixture.load()
			local stale_calls = 0
			helpers.assert_true(synthetic.when_idle(function()
				stale_calls = stale_calls + 1
			end) ~= true, case .. " acquisition refusal must reject the idle request")
			helpers.assert_eq(fixture.timer_new_calls, 1,
				case .. " must exercise exactly one initial periodic acquisition")

			fixture.options.delayed_start_failures = 0
			fixture.options.false_on_timer_new_call = nil
			fixture.options.fail_on_timer_new_call = nil
			fixture.options.throw_on_timer_new_call = nil
			fixture.fail_next_do_after = false
			local unrelated_calls = 0
			helpers.assert_true(synthetic.defer_after_callback("unit unrelated enqueue", function()
				unrelated_calls = unrelated_calls + 1
			end))
			local guard = 0
			while #fixture.timers > 0 do
				fixture.fire_next_timer()
				guard = guard + 1
				helpers.assert_true(guard < 20,
					case .. " unrelated lifecycle enqueue did not settle")
			end
			helpers.assert_eq(unrelated_calls, 1)
			helpers.assert_eq(stale_calls, 0,
				case .. " refused idle request must never revive from a later FIFO start")
		end
	end)

	helpers.it("keeps accepted post-eventtap work inside idle recheck and admission", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local idle_calls = 0
		local deferred_tx = nil
		local deferred_token = nil

		-- Queue the idle observation first, then accept user work behind it. The
		-- lifecycle FIFO will execute the stale idle recheck before that work, so
		-- only the accepted post-callback debt can prevent a false drain.
		helpers.assert_true(synthetic.when_idle(function() idle_calls = idle_calls + 1 end))
		helpers.assert_true(synthetic.defer_after_callback("unit accepted producer", function()
			deferred_tx = synthetic.begin("unit.accepted-post-callback", "replacement")
			deferred_token = synthetic.retain(deferred_tx)
			synthetic.seal(deferred_tx)
		end))
		helpers.assert_nil(synthetic.acquire_admission_fence("pause"),
			"accepted user work must close the same idle-to-PAUSED admission boundary")

		helpers.assert_not_nil(fixture.fire_timer_matching(0),
			"the accepted post-eventtap producer must run at its zero-delay deadline")
		helpers.assert_eq(idle_calls, 0,
			"a stale idle callback must requeue behind accepted post-eventtap work")
		helpers.assert_not_nil(deferred_tx)
		helpers.assert_eq(synthetic.stats().active_transactions, 1)
		helpers.assert_true(synthetic.release(deferred_tx, deferred_token))
		local guard = 0
		while idle_calls == 0 and #fixture.timers > 0 do
			fixture.fire_next_timer()
			guard = guard + 1
			helpers.assert_true(guard < 20, "accepted post-eventtap debt stranded idle")
		end
		helpers.assert_eq(idle_calls, 1)
	end)

	helpers.it("accepts idle ownership only after transactional construction and start", function()
		local cases = {
			{ name = "constructor false", options = { false_on_timer_new_call = 1 }, starts = 0 },
			{ name = "constructor nil", options = { fail_on_timer_new_call = 1 }, starts = 0 },
			{ name = "constructor throw", options = { throw_on_timer_new_call = 1 }, starts = 0 },
			{ name = "start false", options = { timer_start_mode = "false" }, starts = 1 },
			{ name = "start nil", options = { timer_start_mode = "nil" }, starts = 1 },
			{ name = "start throw", options = { timer_start_mode = "throw" }, starts = 1 },
			{ name = "start state mismatch", options = { timer_start_mode = "stopped" }, starts = 1 },
			{ name = "start callback reentry", options = { timer_start_inline = true }, starts = 1 },
			{
				name = "start callback rollback debt",
				options = {
					timer_start_inline = true,
					timer_stop_failures_by_call = { [1] = 1 },
				},
				starts = 1,
				cleanup = 1,
			},
		}
		for _, case in ipairs(cases) do
			local fixture = make_fixture(case.options)
			local synthetic = fixture.load()
			local tx = synthetic.begin("unit.idle-constructor-" .. case.name, "replacement")
			local token = synthetic.retain(tx)
			synthetic.seal(tx)
			local callback_calls = 0
			local call_ok, accepted = pcall(synthetic.when_idle, function()
				callback_calls = callback_calls + 1
			end)
			helpers.assert_true(call_ok,
				case.name .. " is a native refusal, not a Lua error boundary")
			helpers.assert_true(accepted ~= true,
				case.name .. " cannot authorize a drain with no autonomous owner")
			helpers.assert_eq(callback_calls, 0)
			helpers.assert_eq(fixture.timer_new_calls, 1,
				case.name .. " must construct at most one exact native candidate")
			helpers.assert_eq(fixture.timer_start_calls, case.starts,
				case.name .. " must not hide a successor start")
			helpers.assert_eq(fixture.raw_do_every_calls, 0,
				case.name .. " must stay behind TimerScheduler")
			local expected_cleanup = case.cleanup or 0
			helpers.assert_eq(synthetic.stats().pending_periodic_cleanup, expected_cleanup,
				case.name .. " must publish exact rollback debt before refusing admission")
			if expected_cleanup > 0 then
				local periodic = fixture.fire_timer_matching(synthetic.IDLE_WAITER_TICK_SEC)
				helpers.assert_not_nil(periodic)
				helpers.assert_eq(periodic.stop_calls, 2,
					"queued reentry must retry the exact uncommitted candidate")
				helpers.assert_true(periodic.stopped)
				helpers.assert_eq(fixture.timer_new_calls, 1)
				helpers.assert_eq(callback_calls, 0)
				helpers.assert_eq(synthetic.stats().pending_periodic_cleanup, 0)
			end
			synthetic.release(tx, token)
		end
	end)

	helpers.it("settles an idle waiter only after its exact periodic handle stops", function()
		local cases = {
			{
				name = "false",
				options = { timer_stop_failures_by_call = { [1] = 1 } },
			},
			{
				name = "nil",
				options = { timer_stop_nils_by_call = { [1] = 1 } },
			},
			{
				name = "throw",
				options = { timer_stop_throws_by_call = { [1] = 1 } },
			},
		}
		for _, case in ipairs(cases) do
			local fixture = make_fixture(case.options)
			local synthetic = fixture.load()
			local tx = synthetic.begin("unit.idle-stop-debt-" .. case.name, "replacement")
			local token = synthetic.retain(tx)
			synthetic.seal(tx)
			local idle_calls = 0
			helpers.assert_true(synthetic.when_idle(function()
				idle_calls = idle_calls + 1
			end))
			helpers.assert_eq(fixture.timer_new_calls, 1)
			helpers.assert_eq(fixture.timer_start_calls, 1)
			helpers.assert_true(synthetic.release(tx, token))

			local periodic = fixture.fire_timer_matching(synthetic.IDLE_WAITER_TICK_SEC)
			helpers.assert_not_nil(periodic)
			helpers.assert_not_nil(periodic.handle)
			helpers.assert_eq(periodic.stop_calls, 1)
			helpers.assert_eq(idle_calls, 0,
				case.name .. " stop refusal must keep when_idle behind native cleanup")
			helpers.assert_true(not periodic.stopped,
				case.name .. " stop refusal must retain the recurring handle")
			helpers.assert_eq(synthetic.stats().pending_periodic_cleanup, 1,
				case.name .. " stop refusal must remain observable lifecycle debt")
			helpers.assert_eq(fixture.timer_new_calls, 1,
				case.name .. " cancel refusal must retain rather than reacquire")

			local retried = fixture.fire_timer_matching(synthetic.IDLE_WAITER_TICK_SEC)
			helpers.assert_true(retried == periodic,
				case.name .. " cleanup must retry the exact same native timer entry")
			helpers.assert_true(retried.handle == periodic.handle,
				case.name .. " cleanup must not substitute a new native handle")
			helpers.assert_eq(periodic.stop_calls, 2,
				case.name .. " retained handle must retry autonomously on its next tick")
			helpers.assert_true(periodic.stopped)
			helpers.assert_eq(fixture.timer_new_calls, 1,
				case.name .. " callback reentry must settle the original construction")
			helpers.assert_eq(fixture.timer_start_calls, 1)
			helpers.assert_eq(fixture.raw_do_every_calls, 0)
			helpers.assert_eq(synthetic.stats().pending_periodic_cleanup, 0)
			helpers.assert_eq(idle_calls, 1,
				case.name .. " accepted drain must settle once after exact stop")

			local guard = 0
			while #fixture.timers > 0 do
				fixture.fire_next_timer()
				guard = guard + 1
				helpers.assert_true(guard < 20,
					case.name .. " stop settlement left a recurring wake")
			end
			helpers.assert_eq(idle_calls, 1,
				case.name .. " stale lifecycle wakes must not redeliver when_idle")
		end
	end)

	helpers.it("atomically fences new admission only at an exact idle boundary", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local active = synthetic.begin("unit.admission-active", "replacement")
		helpers.assert_nil(synthetic.acquire_admission_fence("pause"),
			"a fence may not falsely acknowledge idle while output is active")
		helpers.assert_true(synthetic.seal(active))

		local fence = synthetic.acquire_admission_fence("pause")
		helpers.assert_not_nil(fence)
		helpers.assert_true(not synthetic.admission_open())
		local admitted = pcall(synthetic.begin, "unit.admission-racer", "replacement")
		helpers.assert_true(not admitted,
			"no producer may enter between the idle observation and PAUSED acknowledgement")
		helpers.assert_true(not synthetic.release_admission_fence({}),
			"only the exact lifecycle owner can reopen admission")
		helpers.assert_true(synthetic.release_admission_fence(fence))
		helpers.assert_true(synthetic.admission_open())
		local resumed = synthetic.begin("unit.admission-resumed", "replacement")
		helpers.assert_true(synthetic.seal(resumed))
	end)

	helpers.it("advances one opaque epoch only at the first successful action handoff", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local initial = synthetic.current_action_epoch()
		local tx = synthetic.begin("unit.epoch", "action")
		local first = synthetic.begin_callback(tx)
		synthetic.keyStroke(first, {}, "a")
		helpers.assert_true(synthetic.current_action_epoch() == initial,
			"build remains abortable and must not publish")
		synthetic.finish_callback(first, true)
		local handed_off = synthetic.current_action_epoch()
		helpers.assert_true(handed_off ~= initial)
		helpers.assert_eq(synthetic.stats().action_handoffs, 1)

		local token = synthetic.retain(tx)
		synthetic.seal(tx)
		local second = synthetic.begin_callback(tx, token)
		synthetic.keyStroke(second, {}, "b")
		synthetic.finish_callback(second, true)
		helpers.assert_true(synthetic.current_action_epoch() == handed_off,
			"a retained sibling batch is still the same logical action")
		helpers.assert_eq(synthetic.stats().action_handoffs, 1)
		synthetic.release(tx, token)
	end)

	helpers.it("notifies stable listeners asynchronously without vetoing handed-off output", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local calls, transient_calls = 0, 0
		local seen_token, seen_time
		synthetic.register_action_listener("broken", function()
			transient_calls = transient_calls + 1
			if transient_calls == 1 then error("listener boom") end
		end)
		synthetic.register_action_listener("keymap", function(token, handoff_time_ms)
			calls = calls + 1
			seen_token = token
			seen_time = handoff_time_ms
		end)

		local tx = synthetic.begin("unit.listener", "action")
		local batch = synthetic.begin_callback(tx)
		synthetic.keyStroke(batch, {}, "a")
		local _, events = synthetic.finish_callback(batch, true)
		helpers.assert_eq(#events, 2,
			"listener failure cannot veto output after irrevocable handoff")
		helpers.assert_eq(calls, 0,
			"listeners must never run inside the originating eventtap callback")
		local epoch, handoff_time = synthetic.current_action_epoch()
		helpers.assert_true(epoch ~= nil)
		helpers.assert_eq(type(handoff_time), "number")
		collectgarbage("collect")
		fixture.fire_next_timer()
		helpers.assert_eq(calls, 1,
			"listener reconciles even when no synthetic echo or later human key arrives")
		helpers.assert_true(seen_token == epoch)
		helpers.assert_eq(seen_time, handoff_time)
		while #fixture.timers > 0 and transient_calls < 2 do fixture.fire_next_timer() end
		helpers.assert_eq(transient_calls, 2,
			"a transient listener failure must be retried without another user event")
	end)

	helpers.it("reconciles an action handed off while a consumer was unregistered", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local last_safe_epoch = synthetic.current_action_epoch()

		local tx = synthetic.begin("unit.stopped-consumer", "action")
		local batch = synthetic.begin_callback(tx)
		synthetic.keyStroke(batch, {}, "x")
		local _, events = synthetic.finish_callback(batch, true)
		helpers.assert_eq(#events, 2)
		synthetic.seal(tx)
		local live_epoch = synthetic.current_action_epoch()
		helpers.assert_true(live_epoch ~= last_safe_epoch)

		local calls, observed = 0, nil
		synthetic.register_action_listener("restarted", function(epoch)
			calls = calls + 1
			observed = epoch
		end, last_safe_epoch)
		local fired = 0
		while calls == 0 and #fixture.timers > 0 and fired < 10 do
			fixture.fire_next_timer()
			fired = fired + 1
		end

		helpers.assert_eq(calls, 1,
			"registration with an older safe token must schedule reconciliation")
		helpers.assert_true(observed == live_epoch)
	end)

	helpers.it("bounds retries for a permanently failing listener", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local attempts = 0
		synthetic.register_action_listener("permanent", function()
			attempts = attempts + 1
			error("deterministic listener failure")
		end)

		local tx = synthetic.begin("unit.listener-quarantine", "action")
		local batch = synthetic.begin_callback(tx)
		synthetic.keyStroke(batch, {}, "x")
		synthetic.finish_callback(batch, true)
		synthetic.seal(tx)

		local fired = 0
		while #fixture.timers > 0 and fired < 100 do
			fixture.fire_next_timer()
			fired = fired + 1
		end
		helpers.assert_eq(attempts, synthetic.ACTION_LISTENER_MAX_ATTEMPTS,
			"a deterministic consumer error must be quarantined for this epoch")
		helpers.assert_true(fired < 100,
			"the listener dispatcher must not spin forever at a fixed cadence")
		helpers.assert_eq(#fixture.timers, 0)
	end)

	helpers.it("bounds retries for a persistent dispatcher-internal failure", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		synthetic.register_action_listener("keymap", function() end)
		local tx = synthetic.begin("unit.dispatcher-internal-failure", "action")
		local batch = synthetic.begin_callback(tx)
		synthetic.keyStroke(batch, {}, "x")
		synthetic.finish_callback(batch, true)
		synthetic.seal(tx)

		local original_sort = table.sort
		table.sort = function() error("dispatcher bookkeeping unavailable") end
		local ok, err = xpcall(function()
			local fired = 0
			while #fixture.timers > 0 and fired < 100 do
				fixture.fire_next_timer()
				fired = fired + 1
			end
			helpers.assert_true(fired < 100,
				"an adapter-internal error must not create an immortal retry timer")
			helpers.assert_eq(#fixture.timers, 0)
		end, debug.traceback)
		table.sort = original_sort
		if not ok then error(err, 0) end
	end)

	helpers.it("retries a one-shot listener timer failure from confirmation without a later key", function()
		local fixture = make_fixture({ do_after_failures = 1 })
		local synthetic = fixture.load()
		local calls = 0
		synthetic.register_action_listener("keymap", function() calls = calls + 1 end)
		local tx = synthetic.begin("unit.listener-retry", "action")
		local batch = synthetic.begin_callback(tx)
		synthetic.keyStroke(batch, {}, "x")
		local _, events = synthetic.finish_callback(batch, true)
		helpers.assert_eq(#events, 2)
		helpers.assert_eq(calls, 0)
		fixture.fire_next_timer() -- independent confirmation timer performs retry
		helpers.assert_eq(calls, 1,
			"one timer allocation failure must not leave the tooltip stale forever")
	end)

	helpers.it("does not advance epoch for aborted, cancelled, failed, empty, or replacement output", function()
		local fixture = make_fixture({ tap_should_enable = false })
		local synthetic = fixture.load()
		local initial = synthetic.current_action_epoch()

		synthetic.enter_callback()
		local aborted = synthetic.begin("unit.abort", "action")
		synthetic.with_transaction(aborted, function()
			synthetic.emit_key_stroke({}, "a", 0)
		end)
		synthetic.abort_callback()
		helpers.assert_true(synthetic.current_action_epoch() == initial)

		local cancelled = synthetic.begin("unit.cancel", "action")
		local cancelled_batch = synthetic.begin_callback(cancelled)
		synthetic.keyStroke(cancelled_batch, {}, "b")
		synthetic.cancel(cancelled)
		helpers.assert_true(synthetic.current_action_epoch() == initial)

		local failed = synthetic.begin("unit.failed", "action")
		local failed_batch = synthetic.begin_batch(failed)
		synthetic.keyStroke(failed_batch, {}, "c")
		synthetic.dispatch(failed_batch)
		synthetic.seal(failed)
		fixture.fire_next_timer()
		helpers.assert_true(synthetic.current_action_epoch() == initial,
			"pump creation failure is not an output handoff")

		local empty = synthetic.begin("unit.empty", "action")
		local empty_batch = synthetic.begin_callback(empty)
		local _, empty_events = synthetic.finish_callback(empty_batch, false)
		helpers.assert_nil(empty_events)
		helpers.assert_true(synthetic.current_action_epoch() == initial)

		local replacement = synthetic.begin("unit.replacement", "replacement")
		local replacement_batch = synthetic.begin_callback(replacement)
		synthetic.keyStroke(replacement_batch, {}, "d")
		synthetic.finish_callback(replacement_batch, true)
		helpers.assert_true(synthetic.current_action_epoch() == initial)
	end)

	helpers.it("rolls observable-action metadata back with malformed UTF-8", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local initial = synthetic.current_action_epoch()
		local tx = synthetic.begin("unit.malformed-action", "action")
		local batch = synthetic.begin_callback(tx)
		local ok = synthetic.keyStrokes(batch, "a\255")
		helpers.assert_true(not ok)
		helpers.assert_eq(#batch.events, 0)
		local consume, events = synthetic.finish_callback(batch, false)
		helpers.assert_true(not consume)
		helpers.assert_nil(events)
		helpers.assert_true(synthetic.current_action_epoch() == initial,
			"a rolled-back prefix must not leave an observable-action marker")
	end)

	helpers.it("cancels explicit siblings atomically when any high-level emitter fails", function()
		local cases = {
			{
				name = "single-key argument error",
				throws = true,
				invoke = function(synthetic, tx)
					return synthetic.emit_key_stroke({}, "y", 1, tx)
				end,
			},
			{
				name = "single-key constructor error",
				options = { new_key_event_throw_at = 3 },
				throws = true,
				invoke = function(synthetic, tx)
					return synthetic.emit_key_stroke({}, "y", 0, tx)
				end,
			},
			{
				name = "text argument error",
				throws = true,
				invoke = function(synthetic, tx)
					return synthetic.emit_key_strokes({}, tx)
				end,
			},
			{
				name = "malformed UTF-8 text",
				invoke = function(synthetic, tx)
					return synthetic.emit_key_strokes("a\255", tx)
				end,
			},
			{
				name = "loopback transaction effect error",
				effect = "replacement",
				throws = true,
				invoke = function(synthetic, tx)
					return synthetic.emit_loopback_key_stroke({}, "f16", 0, tx)
				end,
			},
			{
				name = "loopback constructor error",
				options = { new_key_event_throw_at = 3 },
				throws = true,
				invoke = function(synthetic, tx)
					return synthetic.emit_loopback_key_stroke({}, "f16", 0, tx)
				end,
			},
			{
				name = "loopback timer allocation failure",
				options = { fail_on_do_after_call = 2 },
				invoke = function(synthetic, tx)
					return synthetic.emit_loopback_key_stroke({}, "f16", 0, tx)
				end,
			},
		}

		for _, case in ipairs(cases) do
			local fixture = make_fixture(case.options)
			local synthetic = fixture.load()
			local tx = synthetic.begin("unit.atomic-emitter-" .. case.name,
				case.effect or "action")
			local sibling = synthetic.begin_batch(tx)
			synthetic.keyStroke(sibling, {}, "x")
			local completion
			synthetic.on_complete(tx, function(_, status) completion = status end)
			helpers.assert_true(synthetic.dispatch(sibling))

			local ok, result = pcall(case.invoke, synthetic, tx)
			if case.throws then
				helpers.assert_true(not ok, case.name .. " must propagate its root error")
			else
				helpers.assert_true(ok, case.name .. " must report failure without throwing")
				helpers.assert_eq(result, false)
			end
			helpers.assert_true(tx.cancelled, case.name .. " must cancel the explicit transaction")
			helpers.assert_true(tx.completed, case.name .. " must leave no live transaction")
			helpers.assert_eq(tx.completion_status, "cancelled")
			helpers.assert_eq(sibling.status, "cancelled",
				case.name .. " must cancel an older queued sibling")
			helpers.assert_eq(synthetic.stats().pending, 0)
			helpers.assert_eq(synthetic.stats().records, 0)
			helpers.assert_eq(synthetic.stats().active_transactions, 0)

			while #fixture.timers > 0 do fixture.fire_next_timer() end
			helpers.assert_eq(completion, "cancelled")
			helpers.assert_eq(fixture.trigger_posts, 0)
			helpers.assert_eq(fixture.key_posts, 0)
		end
	end)

	helpers.it("advances once for an action larger than the enrichment ledger", function()
		local fixture = make_fixture()
		local synthetic, provenance = fixture.load()
		local initial = synthetic.current_action_epoch()
		local tx = synthetic.begin("unit.large-action", "action")
		local batch = synthetic.begin_callback(tx)
		synthetic.keyStroke(batch, {}, "a")
		local evicted = batch.events[1]
		for _ = 2, 2050 do synthetic.keyStroke(batch, {}, "a") end
		synthetic.finish_callback(batch, true)
		helpers.assert_true(synthetic.current_action_epoch() ~= initial)
		helpers.assert_eq(synthetic.stats().action_handoffs, 1)
		local stale = provenance.classify(evicted, "unregistered-consumer")
		helpers.assert_true(stale.owned)
		helpers.assert_eq(synthetic.stats().action_handoffs, 1,
			"current-session ledger eviction must not republish one action per old phase")
		helpers.assert_eq(synthetic.stats().stale_context_tags, 0)
	end)

	helpers.it("validates direct and ambient handoff atomically before epoch publication", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local initial = synthetic.current_action_epoch()

		local direct_tx = synthetic.begin("unit.invalid-direct", "action")
		local direct_batch = synthetic.begin_callback(direct_tx)
		synthetic.keyStroke(direct_batch, {}, "a")
		helpers.assert_throws(function()
			synthetic.finish_callback(direct_batch, "not-a-boolean")
		end)
		helpers.assert_eq(direct_batch.status, "building")
		helpers.assert_true(synthetic.current_action_epoch() == initial)
		synthetic.cancel(direct_tx)

		local collector = synthetic.enter_callback()
		local first_tx = synthetic.begin("unit.atomic-first", "action")
		synthetic.with_transaction(first_tx, function()
			synthetic.emit_key_stroke({}, "b", 0)
		end)
		local second_tx = synthetic.begin("unit.atomic-second", "action")
		synthetic.with_transaction(second_tx, function()
			synthetic.emit_key_stroke({}, "c", 0)
		end)
		collector.batches[2].status = "queued" -- invalid for a callback collector
		helpers.assert_throws(function() synthetic.leave_callback(true) end)
		helpers.assert_eq(collector.batches[1].status, "building",
			"validation of a later batch must not hand off an earlier prefix")
		helpers.assert_true(synthetic.current_action_epoch() == initial)
		helpers.assert_true(synthetic.abort_callback(),
			"failed validation must leave the collector available for rollback")
		helpers.assert_eq(synthetic.stats().records, 0)
	end)

	helpers.it("hands off ambient output when the diagnostic clock throws", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local initial = synthetic.current_action_epoch()
		synthetic.enter_callback()
		local tx = synthetic.begin("unit.clock-failure", "action")
		synthetic.with_transaction(tx, function()
			synthetic.emit_key_stroke({}, "x", 0)
		end)
		fixture.absolute_time_throws = true
		local ok, consume, events = pcall(synthetic.leave_callback, true)
		helpers.assert_true(ok,
			"diagnostic timestamp failure must not strand a popped collector")
		helpers.assert_true(consume)
		helpers.assert_eq(#events, 2)
		local epoch, handoff_time = synthetic.current_action_epoch()
		helpers.assert_true(epoch ~= initial)
		helpers.assert_nil(handoff_time)
	end)

	helpers.it("returns direct and ambient events when confirmation scheduling fails", function()
		local direct_fixture = make_fixture({ do_after_failures = 1 })
		local direct = direct_fixture.load()
		local direct_tx = direct.begin("unit.direct-confirm-fail", "action")
		local direct_batch = direct.begin_callback(direct_tx)
		direct.keyStroke(direct_batch, {}, "x")
		local consume, events = direct.finish_callback(direct_batch, true)
		helpers.assert_true(consume)
		helpers.assert_eq(#events, 2)
		direct.seal(direct_tx)
		helpers.assert_eq(direct_tx.completion_status, "failed")

		local ambient_fixture = make_fixture({ do_after_failures = 1 })
		local ambient = ambient_fixture.load()
		ambient.enter_callback()
		ambient.emit_key_stroke({}, "y", 0)
		local left_ok, ambient_consume, ambient_events = pcall(ambient.leave_callback, true)
		helpers.assert_true(left_ok)
		helpers.assert_true(ambient_consume)
		helpers.assert_eq(#ambient_events, 2)
		helpers.assert_true(not ambient.abort_callback(),
			"successful leave must remove the collector even on timer failure")
	end)

	helpers.it("keeps adopted output and defers terminal lifecycle on confirmation failure", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local tx = synthetic.begin("unit.adopt-confirm-fail", "action")
		local batch = synthetic.begin_batch(tx)
		synthetic.keyStroke(batch, {}, "x")
		local completion
		synthetic.on_complete(tx, function(_, status) completion = status end)
		helpers.assert_true(synthetic.dispatch(batch))
		synthetic.seal(tx)

		fixture.fail_next_do_after = true
		local fence = synthetic.claim_physical_fence()
		helpers.assert_not_nil(fence)
		helpers.assert_eq(#fence.events, 2,
			"irrevocably queued output must still be returned before physical input")
		helpers.assert_nil(completion,
			"failure lifecycle must not run inside the physical event callback")
		while #fixture.timers > 0 do fixture.fire_next_timer() end
		helpers.assert_eq(completion, "failed")
	end)

	helpers.it("preserves ambient scope, timer retain, delay compatibility, and cancellation", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		synthetic.enter_callback()
		local tx = synthetic.begin("unit.ambient", "action")
		synthetic.with_transaction(tx, function()
			helpers.assert_true(synthetic.current_transaction() == tx)
			synthetic.emit_key_stroke({}, "x", 0.02)
			synthetic.emit_key_strokes("y")
		end)
		helpers.assert_nil(synthetic.current_transaction())
		synthetic.seal(tx)
		local consume, events = synthetic.leave_callback(true)
		helpers.assert_true(consume)
		helpers.assert_eq(#events, 4)
		helpers.assert_eq(fixture.post_count, 0)
		fixture.fire_next_timer()

		local retained = synthetic.begin("unit.retained", "action")
		local token = synthetic.retain(retained)
		synthetic.seal(retained)
		synthetic.with_transaction(retained, function()
			synthetic.emit_key_stroke({}, "z", 0)
		end)
		helpers.assert_true(synthetic.release(retained, token))
		helpers.assert_true(not synthetic.release(retained, token),
			"release must be idempotent")
		fixture.fire_next_timer()
		fixture.fire_next_timer()

		synthetic.enter_callback()
		local cancelled = synthetic.begin("unit.cancelled", "action")
		synthetic.with_transaction(cancelled, function()
			synthetic.emit_key_stroke({}, "q", 0)
		end)
		synthetic.cancel(cancelled)
		local _, cancelled_events = synthetic.leave_callback(false)
		helpers.assert_nil(cancelled_events,
			"cancelled ambient events must not survive into the callback return")

		local timers_before = #fixture.timers
		helpers.assert_true(synthetic.emit_key_strokes(""))
		helpers.assert_eq(#fixture.timers, timers_before,
			"empty ambient/deferred emissions are true no-ops")
		helpers.assert_throws(function()
			synthetic.emit_key_stroke({}, "x", 1)
		end, "delay >= 1 microsecond must fail fast")
	end)

	helpers.it("serializes terminal deletion pairs after callback return with timed render turns", function()
		local fixture = make_fixture({ gc_cancels_unretained_timers = true })
		local synthetic = fixture.load()
		local target = { id = "terminal-app" }
		local observed_tags = {}
		fixture.key_observer = function(event)
			local property = fixture.eventtap.event.properties.eventSourceUserData
			local metadata = synthetic.lookup_tag(event:getProperty(property))
			observed_tags[#observed_tags + 1] = string.format("%d:%s",
				metadata.ordinal, metadata.phase)
		end
		fixture.callback_active = true
		synthetic.enter_callback()
		local tx = synthetic.begin("unit.terminal", "replacement")
		synthetic.with_transaction(tx, function()
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_strokes("X")
		end)

		local owner = synthetic.prepare_collected_paced(tx, 2, 12000, target)
		helpers.assert_not_nil(owner)
		helpers.assert_eq(fixture.key_posts, 0,
			"paced delivery must not post from the active eventtap callback")
		helpers.assert_true(synthetic.seal(tx))
		helpers.assert_true(synthetic.authorize_collected_paced(owner))
		helpers.assert_true(synthetic.commit_collected_paced(owner))
		local consume, returned = synthetic.leave_callback(true)
		helpers.assert_true(consume)
		helpers.assert_nil(returned,
			"target-posted events must not be returned to Quartz a second time")
		helpers.assert_eq(fixture.key_posts, 0)
		fixture.callback_active = false
		local paced_delays = 0
		local guard = 0
		while fixture.key_posts < 6 and #fixture.timers > 0 do
			collectgarbage("collect")
			local delay = fixture.fire_next_timer()
			if delay == 0.012 then paced_delays = paced_delays + 1 end
			guard = guard + 1
			helpers.assert_true(guard < 40, "paced serializer must terminate")
		end
		helpers.assert_eq(fixture.key_posts, 6)
		helpers.assert_eq(table.concat(observed_tags, ","),
			"1:down,1:up,2:down,2:up,3:down,3:up",
			"paced output must preserve the exact immutable tag order")
		helpers.assert_eq(paced_delays, 3,
			"both Backspace pairs and the contiguous replacement suffix need their own paced turn")
		helpers.assert_eq(#fixture.paced_sleeps, 0,
			"paced delivery must never block with hs.timer.usleep")
		for _, app in ipairs(fixture.posted_targets) do helpers.assert_true(app == target) end
	end)

	helpers.it("has one paced wake authority in both zero-before-periodic orders", function()
		for _, zero_first in ipairs({ true, false }) do
			local fixture = make_fixture()
			local synthetic = fixture.load()
			synthetic.enter_callback()
			local tx = synthetic.begin(
				zero_first and "unit.cadence.zero-first" or "unit.cadence.periodic-first",
				"replacement")
			synthetic.with_transaction(tx, function()
				synthetic.emit_key_stroke({}, "delete", 0)
				synthetic.emit_key_stroke({}, "delete", 0)
				synthetic.emit_key_strokes("X")
			end)
			local owner = synthetic.prepare_collected_paced(tx, 2, 20000,
				{ id = "terminal-app" })
			helpers.assert_not_nil(owner)
			helpers.assert_true(synthetic.seal(tx))
			helpers.assert_true(synthetic.authorize_collected_paced(owner))
			helpers.assert_true(synthetic.commit_collected_paced(owner))
			synthetic.leave_callback(true)

			local zero = nil
			local periodic = nil
			if zero_first then
				zero = fixture.fire_timer_matching(0)
				helpers.assert_eq(fixture.key_posts, 0,
					"a late zero wake must not post a pair before the cadence owner")
				periodic = fixture.fire_timer_matching(0.02)
			else
				periodic = fixture.fire_timer_matching(0.02)
				helpers.assert_eq(fixture.key_posts, 2,
					"one periodic turn posts exactly one delete pair")
				zero = fixture.fire_timer_matching(0)
				helpers.assert_eq(fixture.key_posts, 2,
					"a queued zero wake after a long callback may not collapse the next pair")
			end
			helpers.assert_not_nil(periodic,
				"the prepared 20 ms periodic cadence must be the sole output authority")
			helpers.assert_nil(zero,
				"paced preparation must not own a competing zero-delay wake")
			if zero_first then helpers.assert_eq(fixture.key_posts, 2) end
		end
	end)

	helpers.it("never lends a deferred tail broker turn to a paced FIFO head", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		synthetic.enter_callback()
		local paced_tx = synthetic.begin("unit.foreign-broker-paced", "replacement")
		synthetic.with_transaction(paced_tx, function()
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_strokes("X")
		end)
		local paced_owner = synthetic.prepare_collected_paced(paced_tx, 2, 20000,
			{ id = "terminal-app" })
		helpers.assert_not_nil(paced_owner)
		helpers.assert_true(synthetic.seal(paced_tx))
		helpers.assert_true(synthetic.authorize_collected_paced(paced_owner))
		helpers.assert_true(synthetic.commit_collected_paced(paced_owner))
		synthetic.leave_callback(true)

		local deferred_tx = synthetic.begin("unit.foreign-broker-tail", "replacement")
		local deferred_batch = synthetic.begin_batch(deferred_tx)
		synthetic.keyStroke(deferred_batch, {}, "q")
		helpers.assert_true(synthetic.dispatch(deferred_batch))
		helpers.assert_true(synthetic.seal(deferred_tx))

		helpers.assert_not_nil(fixture.fire_timer_matching(0),
			"the ordinary deferred tail must exercise its generic zero-delay broker")
		helpers.assert_eq(fixture.key_posts, 0,
			"a foreign broker turn must not post the paced head before its 20 ms owner")
		helpers.assert_not_nil(fixture.fire_timer_matching(0.02))
		helpers.assert_eq(fixture.key_posts, 2,
			"the paced owner must post exactly one complete delete pair on its own turn")
	end)

	helpers.it("fails an exact predecessor sibling when its broker timer is refused behind a reservation", function()
		local cases = {
			{ name = "false", option = "false_on_do_after_call" },
			{ name = "nil", option = "fail_on_do_after_call" },
			{ name = "throw", option = "throw_on_do_after_call" },
		}
		for _, case in ipairs(cases) do
			local fixture = make_fixture()
			local synthetic = fixture.load()
			local predecessor = synthetic.begin(
				"unit.reserved-broker-refusal-" .. case.name, "replacement")
			local retain = synthetic.retain(predecessor)
			helpers.assert_true(synthetic.seal(predecessor))

			local reserved = synthetic.prepare_reserved_successor(predecessor, function()
				return synthetic.emit_key_stroke({}, "return", 0)
			end)
			helpers.assert_not_nil(reserved)
			helpers.assert_true(synthetic.authorize_reserved_successor(reserved))
			helpers.assert_true(synthetic.commit_reserved_successor(reserved))
			helpers.assert_true(reserved.ready ~= true,
				"the reserved FIFO head must remain a non-ready barrier")

			local sibling = synthetic.begin_batch(predecessor, retain)
			synthetic.keyStroke(sibling, {}, "x")
			local dispatched_status = nil
			synthetic.on_dispatched(predecessor, function(_, observed, status)
				if observed == sibling then dispatched_status = status end
			end)
			fixture.options[case.option] = fixture.do_after_calls + 1
			local call_ok, scheduled = pcall(synthetic.dispatch, sibling)
			helpers.assert_true(call_ok,
				case.name .. " broker refusal must be a reported result, not a throw")
			helpers.assert_eq(scheduled, false,
				case.name .. " broker refusal must reject the exact sibling dispatch")
			helpers.assert_eq(sibling.status, "failed",
				case.name .. " must terminally remove the refused predecessor sibling")
			helpers.assert_eq(synthetic.stats().pending_deferred, 1,
				case.name .. " must leave only the separately-owned reservation pending")
			helpers.assert_eq(fixture.trigger_posts, 0)
			helpers.assert_eq(fixture.key_posts, 0)

			helpers.assert_true(synthetic.cancel_reserved_successor(reserved))
			helpers.assert_true(synthetic.release(predecessor, retain))
			local guard = 0
			while #fixture.timers > 0 do
				fixture.fire_next_timer()
				guard = guard + 1
				helpers.assert_true(guard < 20,
					case.name .. " broker refusal left immortal timer debt")
			end
			helpers.assert_eq(dispatched_status, "failed")
			helpers.assert_eq(synthetic.stats().pending, 0)
			helpers.assert_eq(synthetic.stats().active_transactions, 0)
			helpers.assert_eq(fixture.trigger_posts, 0,
				case.name .. " refused sibling must never revive from a later wake")
			helpers.assert_eq(fixture.key_posts, 0)
		end
	end)

	helpers.it("never lends a 5ms physical or reserved wake to a 20ms paced head", function()
		for _, kind in ipairs({ "physical", "reserved" }) do
			local fixture = make_fixture()
			local synthetic = fixture.load()
			synthetic.enter_callback()
			local tx = synthetic.begin("unit.cross-owner-" .. kind, "replacement")
			synthetic.with_transaction(tx, function()
				synthetic.emit_key_stroke({}, "delete", 0)
				synthetic.emit_key_strokes("X")
			end)
			local paced = synthetic.prepare_collected_paced(tx, 1, 20000,
				{ id = "terminal-app" })
			helpers.assert_not_nil(paced)
			helpers.assert_true(synthetic.seal(tx))
			helpers.assert_true(synthetic.authorize_collected_paced(paced))
			helpers.assert_true(synthetic.commit_collected_paced(paced))
			synthetic.leave_callback(true)

			if kind == "physical" then
				local fence = synthetic.claim_physical_fence(fixture.external_event(nil, 42))
				helpers.assert_not_nil(fence)
				helpers.assert_true(fence.consume_original)
			else
				local reserved = synthetic.prepare_reserved_successor(tx, function()
					return synthetic.emit_key_stroke({}, "return", 0)
				end)
				helpers.assert_not_nil(reserved)
				helpers.assert_true(synthetic.authorize_reserved_successor(reserved))
				helpers.assert_true(synthetic.commit_reserved_successor(reserved))
				helpers.assert_true(synthetic.activate_reserved_successor(reserved))
			end

			helpers.assert_not_nil(
				fixture.fire_timer_matching(synthetic.PERIODIC_OWNER_TICK_SEC))
			helpers.assert_eq(fixture.key_posts, 0,
				kind .. " wake must not start the foreign paced ordinal 15ms early")
			helpers.assert_not_nil(fixture.fire_timer_matching(0.02))
			helpers.assert_eq(fixture.key_posts, 2,
				"the paced head begins only from its own 20ms authority")
		end
	end)

	helpers.it("retains paced timer cleanup debt until the exact stop retry succeeds", function()
		local cases = {
			{ name = "false", option = "timer_stop_failures_by_call" },
			{ name = "nil", option = "timer_stop_nils_by_call" },
			{ name = "throw", option = "timer_stop_throws_by_call" },
		}
		for _, case in ipairs(cases) do
			local options = { [case.option] = { [1] = 1 } }
			local fixture = make_fixture(options)
			local synthetic = fixture.load()
			synthetic.enter_callback()
			local tx = synthetic.begin("unit.paced-stop-debt-" .. case.name, "replacement")
			synthetic.with_transaction(tx, function()
				synthetic.emit_key_stroke({}, "delete", 0)
				synthetic.emit_key_strokes("X")
			end)
			local owner = synthetic.prepare_collected_paced(tx, 1, 20000,
				{ id = "terminal-app" })
			helpers.assert_not_nil(owner)
			helpers.assert_true(synthetic.seal(tx))
			helpers.assert_true(synthetic.authorize_collected_paced(owner))
			helpers.assert_true(synthetic.commit_collected_paced(owner))
			synthetic.leave_callback(true)
			local drained = 0
			helpers.assert_true(synthetic.when_idle(function() drained = drained + 1 end))
			local timer_new_before = fixture.timer_new_calls

			local periodic = fixture.fire_timer_matching(0.02)
			helpers.assert_eq(fixture.key_posts, 2)
			fixture.fire_timer_matching(0.02)
			helpers.assert_eq(fixture.key_posts, 4)
			fixture.fire_timer_matching(0.02)
			helpers.assert_eq(periodic.stop_calls, 1)
			helpers.assert_true(not periodic.stopped)
			helpers.assert_eq(drained, 0,
				case.name .. " completion may not hide an unstopped periodic handle")
			helpers.assert_eq(fixture.timer_new_calls, timer_new_before,
				case.name .. " cancel refusal must retain the exact construction")

			local retried = fixture.fire_timer_matching(0.02)
			helpers.assert_true(retried == periodic,
				case.name .. " callback reentry must target the retained native timer")
			helpers.assert_true(retried.handle == periodic.handle)
			helpers.assert_eq(periodic.stop_calls, 2)
			helpers.assert_true(periodic.stopped)
			helpers.assert_eq(fixture.timer_new_calls, timer_new_before)
			helpers.assert_eq(fixture.raw_do_every_calls, 0)
			local guard = 0
			while drained == 0 and #fixture.timers > 0 do
				fixture.fire_next_timer()
				guard = guard + 1
				helpers.assert_true(guard < 20,
					case.name .. " paced cleanup debt stranded global idle")
			end
			helpers.assert_eq(drained, 1)
		end
	end)

	helpers.it("retries the exact terminal ordinal after a refused paced post", function()
		local fixture = make_fixture({ key_post_throw_at = 3 })
		local synthetic = fixture.load()
		local target = { id = "terminal-app" }
		local completion
		synthetic.enter_callback()
		local tx = synthetic.begin("unit.terminal.retry", "replacement")
		synthetic.on_complete(tx, function(_, status) completion = status end)
		synthetic.with_transaction(tx, function()
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_strokes("X")
		end)
		local owner = synthetic.prepare_collected_paced(tx, 2, 12000, target)
		helpers.assert_not_nil(owner)
		helpers.assert_true(synthetic.seal(tx))
		helpers.assert_true(synthetic.authorize_collected_paced(owner))
		helpers.assert_true(synthetic.commit_collected_paced(owner))
		local consume, returned = synthetic.leave_callback(true)
		helpers.assert_true(consume)
		helpers.assert_nil(returned)

		fixture.fire_next_timer() -- timer-zero wake: first pair succeeds
		helpers.assert_eq(#fixture.key_attempts, 2)
		fixture.fire_next_timer() -- next paced turn: ordinal three is refused
		helpers.assert_eq(#fixture.key_attempts, 3,
			"a refused post must end the current render turn without bursting its retry")
		fixture.fire_next_timer() -- a later paced turn retries the exact event
		helpers.assert_eq(#fixture.key_attempts, 5,
			"the retry may finish only its original delete pair on the next turn")
		local guard = 0
		while (#fixture.timers > 0 or completion == nil) and guard < 60 do
			if #fixture.timers > 0 then fixture.fire_next_timer() end
			guard = guard + 1
		end
		helpers.assert_eq(fixture.key_posts, 6,
			"all six unique events must eventually post exactly once")
		helpers.assert_eq(#fixture.key_attempts, 7,
			"one refused ordinal must add exactly one retry attempt")
		helpers.assert_true(fixture.key_attempts[3] == fixture.key_attempts[4],
			"retry must retain the exact event object and ordinal")
		helpers.assert_eq(completion, "complete")
	end)

	helpers.it("preflights physical replay before adopting any queued prefix", function()
		local cases = {
			{ name = "copy throw", options = { physical_copy_throw = true } },
			{ name = "copy nil", options = { physical_copy_nil = true } },
			{ name = "tagging throw", options = { physical_set_property_throw = true } },
			{ name = "periodic owner refusal", options = {}, refuse_owner = true },
			{ name = "periodic owner false", options = { false_on_timer_new_call = 2 } },
			{ name = "periodic owner throw", options = { throw_on_timer_new_call = 2 } },
		}
		for _, case in ipairs(cases) do
			local fixture = make_fixture(case.options)
			local synthetic = fixture.load()
			local older = synthetic.begin("unit.physical-preflight-prefix", "replacement")
			local older_batch = synthetic.begin_batch(older)
			synthetic.keyStroke(older_batch, {}, "a")
			helpers.assert_true(synthetic.dispatch(older_batch))
			helpers.assert_true(synthetic.seal(older))

			synthetic.enter_paced_collection()
			local paced = synthetic.begin("unit.physical-preflight-paced", "replacement")
			synthetic.with_transaction(paced, function()
				synthetic.emit_key_stroke({}, "delete", 0)
				synthetic.emit_key_strokes("X")
			end)
			local target = { id = "terminal-app" }
			local paced_owner = synthetic.prepare_collected_paced(paced, 1, 12000, target)
			helpers.assert_not_nil(paced_owner)
			helpers.assert_true(synthetic.seal(paced))
			helpers.assert_true(synthetic.authorize_collected_paced(paced_owner))
			helpers.assert_true(synthetic.commit_collected_paced(paced_owner))
			helpers.assert_true(synthetic.leave_paced_collection())
			helpers.assert_eq(synthetic.stats().pending, 2)

			if case.refuse_owner then fixture.fail_next_timer_new = true end
			local fence = synthetic.claim_physical_fence(fixture.external_event(nil, 42))
			helpers.assert_nil(fence, case.name .. " must pass the untouched original through")
			helpers.assert_eq(synthetic.stats().pending, 2,
				case.name .. " must not detach or acknowledge the older prefix")

			local guard = 0
			while #fixture.pump_deliveries == 0 and #fixture.timers > 0 do
				fixture.fire_next_timer()
				guard = guard + 1
				helpers.assert_true(guard < 30, case.name .. " stranded the older prefix")
			end
			helpers.assert_eq(#fixture.pump_deliveries, 1,
				case.name .. " must leave the exact older batch deliverable")
			helpers.assert_eq(fixture.pump_deliveries[1].events[1].key, "a")
		end
	end)

	helpers.it("fences a physical key behind paced output without collapsing cadence or target", function()
		local terminal_target = { id = "terminal-app" }
		local physical_target = { id = "editor-app" }
		local later_target = { id = "browser-app" }
		local fixture = make_fixture({ frontmost_app = terminal_target })
		local synthetic, provenance = fixture.load()
		synthetic.enter_callback()
		local tx = synthetic.begin("unit.terminal.physical-fence", "replacement")
		synthetic.with_transaction(tx, function()
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_strokes("X")
		end)
		local owner = synthetic.prepare_collected_paced(tx, 2, 12000, terminal_target)
		helpers.assert_not_nil(owner)
		helpers.assert_true(synthetic.seal(tx))
		helpers.assert_true(synthetic.authorize_collected_paced(owner))
		helpers.assert_true(synthetic.commit_collected_paced(owner))
		local consume, returned = synthetic.leave_callback(true)
		helpers.assert_true(consume)
		helpers.assert_nil(returned)

		-- The timer-zero wake may post only the first complete delete pair. A human
		-- key arriving now is consumed and copied behind the still-paced suffix.
		while fixture.key_posts < 2 do fixture.fire_next_timer() end
		fixture.frontmost_app = physical_target
		local physical = fixture.external_event(nil, 42)
		physical.key = "tab"
		physical.modifiers = { "cmd" }
		local fence = synthetic.claim_physical_fence(physical)
		helpers.assert_not_nil(fence)
		helpers.assert_true(fence.consume_original,
			"the physical event must be owned before its original can be consumed")
		helpers.assert_nil(fence.events,
			"paced output must never be flattened into an immediate callback return")
		fixture.frontmost_app = later_target

		local replay_seen = 0
		local physical_replay = nil
		fixture.global_key_observer = function(event)
			local tag = event:getProperty(USER_DATA)
			local metadata = synthetic.lookup_tag(tag)
			if metadata and metadata.physical_replay then
				physical_replay = event
				replay_seen = replay_seen + 1
				for _, consumer in ipairs({ "keymap", "keylogger", "shortcuts" }) do
					local owned, status, replay_fence = provenance.classify_with_fence(event, consumer)
					helpers.assert_nil(owned)
					helpers.assert_eq(status, provenance.STATUS_FOREIGN)
					helpers.assert_nil(replay_fence,
						"a tagged physical replay must not recursively fence itself")
				end
			end
		end
		local periodic_pace_turns = 0
		local guard = 0
		while fixture.key_posts < 7 and #fixture.timers > 0 do
			local delay = fixture.fire_next_timer()
			if delay == 0.012 then periodic_pace_turns = periodic_pace_turns + 1 end
			guard = guard + 1
			helpers.assert_true(guard < 80, "paced physical fence must terminate")
		end
		helpers.assert_eq(fixture.key_posts, 7)
		helpers.assert_eq(periodic_pace_turns, 3,
			"the remaining delete pair, suffix, and lifecycle settlement need distinct paced turns")
		helpers.assert_eq(replay_seen, 1,
			"every tap may observe the replay, but Quartz must post it exactly once")
		for index = 1, 6 do
			helpers.assert_true(fixture.posted_targets[index] == terminal_target,
				"the complete replacement must retain its original terminal target")
		end
		helpers.assert_nil(fixture.posted_targets[7],
			"the delayed physical key must use global Quartz routing")
		helpers.assert_not_nil(physical_replay)
		helpers.assert_true(physical_replay ~= physical,
			"the consumed native event must be replayed from its owned copy")
		helpers.assert_eq(physical_replay.key, "tab")
		helpers.assert_eq(physical_replay.source_pid, 42)
		helpers.assert_eq(physical_replay.modifiers[1], "cmd",
			"Cmd-Tab modifier fidelity is required for global shortcut semantics")
	end)

	helpers.it("preserves Cmd-Space modifier flags on the global physical route", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		synthetic.enter_callback()
		local tx = synthetic.begin("unit.cmd-space-fidelity", "replacement")
		synthetic.with_transaction(tx, function()
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_strokes("X")
		end)
		local target = { id = "terminal-app" }
		local owner = synthetic.prepare_collected_paced(tx, 1, 12000, target)
		helpers.assert_not_nil(owner)
		helpers.assert_true(synthetic.seal(tx))
		helpers.assert_true(synthetic.authorize_collected_paced(owner))
		helpers.assert_true(synthetic.commit_collected_paced(owner))
		synthetic.leave_callback(true)

		local physical = fixture.external_event(nil, 42)
		physical.key = "space"
		physical.modifiers = { "cmd", "shift" }
		local fence = synthetic.claim_physical_fence(physical)
		helpers.assert_not_nil(fence)
		helpers.assert_true(fence.consume_original)
		local guard = 0
		while fixture.key_posts < 5 and #fixture.timers > 0 do
			fixture.fire_next_timer()
			guard = guard + 1
			helpers.assert_true(guard < 60, "Cmd-Space replay did not settle")
		end

		local replay = nil
		local replay_index = nil
		for index, event in ipairs(fixture.key_attempts) do
			local metadata = synthetic.lookup_tag(event:getProperty(USER_DATA))
			if metadata and metadata.physical_replay then
				replay = event
				replay_index = index
			end
		end
		helpers.assert_eq(fixture.key_posts, 5,
			"the global physical replay must settle after the four target events")
		helpers.assert_not_nil(replay)
		helpers.assert_eq(replay_index, #fixture.key_attempts,
			"Cmd-Space must not overtake any paced target suffix")
		helpers.assert_eq(replay.key, "space")
		helpers.assert_eq(replay.modifiers[1], "cmd")
		helpers.assert_eq(replay.modifiers[2], "shift")
		helpers.assert_nil(replay.posted_app,
			"Cmd-Space must re-enter Quartz globally, never through post(app)")
	end)

	helpers.it("retains physical replay timer debt until its exact stop succeeds", function()
		local fixture = make_fixture({ timer_stop_failures_by_call = { [2] = 1 } })
		local synthetic = fixture.load()
		synthetic.enter_callback()
		local tx = synthetic.begin("unit.physical-stop-debt", "replacement")
		synthetic.with_transaction(tx, function()
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_strokes("X")
		end)
		local owner = synthetic.prepare_collected_paced(tx, 1, 20000,
			{ id = "terminal-app" })
		helpers.assert_not_nil(owner)
		helpers.assert_true(synthetic.seal(tx))
		helpers.assert_true(synthetic.authorize_collected_paced(owner))
		helpers.assert_true(synthetic.commit_collected_paced(owner))
		synthetic.leave_callback(true)
		local fence = synthetic.claim_physical_fence(fixture.external_event(nil, 42))
		helpers.assert_true(fence.consume_original)
		local drained = 0
		helpers.assert_true(synthetic.when_idle(function() drained = drained + 1 end))

		for _ = 1, 3 do fixture.fire_timer_matching(0.02) end
		local physical = fixture.fire_timer_matching(synthetic.PERIODIC_OWNER_TICK_SEC)
		helpers.assert_not_nil(physical)
		helpers.assert_eq(fixture.global_key_posts, 1)
		fixture.fire_timer_matching(synthetic.PERIODIC_OWNER_TICK_SEC)
		helpers.assert_eq(physical.stop_calls, 1)
		helpers.assert_true(not physical.stopped)
		helpers.assert_eq(drained, 0,
			"global idle must retain a physical replay handle after stop refusal")
		fixture.fire_timer_matching(synthetic.PERIODIC_OWNER_TICK_SEC)
		helpers.assert_eq(physical.stop_calls, 2)
		helpers.assert_true(physical.stopped)
		local guard = 0
		while drained == 0 and #fixture.timers > 0 do
			fixture.fire_next_timer()
			guard = guard + 1
			helpers.assert_true(guard < 20, "physical cleanup debt stranded global idle")
		end
		helpers.assert_eq(drained, 1)
	end)

	helpers.it("fails a paced transaction when its exact target process is gone", function()
		local fixture = make_fixture()
		local target = { id = "terminal-app" }
		function target:pid() return 8801 end
		fixture.live_applications = { [8801] = target }
		local synthetic = fixture.load()
		synthetic.enter_callback()
		local tx = synthetic.begin("unit.dead-terminal-target", "replacement")
		local completion = nil
		synthetic.on_complete(tx, function(_, status) completion = status end)
		synthetic.with_transaction(tx, function()
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_strokes("X")
		end)
		local owner = synthetic.prepare_collected_paced(tx, 1, 12000, target)
		helpers.assert_not_nil(owner)
		helpers.assert_true(synthetic.seal(tx))
		helpers.assert_true(synthetic.authorize_collected_paced(owner))
		helpers.assert_true(synthetic.commit_collected_paced(owner))
		synthetic.leave_callback(true)

		while fixture.key_posts < 2 do fixture.fire_next_timer() end
		fixture.live_applications[8801] = nil
		local guard = 0
		while completion == nil and #fixture.timers > 0 do
			fixture.fire_next_timer()
			guard = guard + 1
			helpers.assert_true(guard < 30, "dead target left the serializer non-terminal")
		end
		helpers.assert_eq(completion, "failed",
			"a non-delivery proof may never be published as complete")
		helpers.assert_eq(fixture.key_posts, 2,
			"the remaining suffix must not be redirected to another application")
	end)

	helpers.it("bounds permanent paced post refusal and releases the global drain", function()
		local fixture = make_fixture({ key_post_always_throws = true })
		local synthetic = fixture.load()
		synthetic.enter_callback()
		local tx = synthetic.begin("unit.permanent-paced-refusal", "replacement")
		local completion = nil
		synthetic.on_complete(tx, function(_, status) completion = status end)
		synthetic.with_transaction(tx, function()
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_strokes("X")
		end)
		local owner = synthetic.prepare_collected_paced(tx, 1, 12000, { id = "terminal-app" })
		helpers.assert_not_nil(owner)
		helpers.assert_true(synthetic.seal(tx))
		helpers.assert_true(synthetic.authorize_collected_paced(owner))
		helpers.assert_true(synthetic.commit_collected_paced(owner))
		synthetic.leave_callback(true)
		local drained = 0
		helpers.assert_true(synthetic.when_idle(function() drained = drained + 1 end))

		for _ = 1, 12 do
			if completion ~= nil or #fixture.timers == 0 then break end
			fixture.fire_next_timer()
		end
		helpers.assert_eq(completion, "failed",
			"permanent refusal needs one observable terminal result")
		helpers.assert_true(#fixture.key_attempts <= 8,
			"native post retries must have a finite budget")
		local post_logs = 0
		for _, line in ipairs(fixture.logs) do
			if line:find("Paced terminal post", 1, true) then post_logs = post_logs + 1 end
		end
		helpers.assert_true(post_logs <= 3,
			"a permanent refusal must not create an unbounded error stream")
		for _ = 1, 8 do
			if drained == 1 or #fixture.timers == 0 then break end
			fixture.fire_next_timer()
		end
		helpers.assert_eq(synthetic.stats().active_transactions, 0)
		helpers.assert_eq(drained, 1,
			"terminal failure must open the process-wide drain exactly once")
	end)

	helpers.it("fences a physical mouse event globally and replays it once to provenance consumers", function()
		local fixture = make_fixture()
		local synthetic, provenance = fixture.load()
		local target = { id = "terminal-app" }
		synthetic.enter_callback()
		local tx = synthetic.begin("unit.terminal.mouse-fence", "replacement")
		synthetic.with_transaction(tx, function()
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_strokes("X")
		end)
		local owner = synthetic.prepare_collected_paced(tx, 1, 12000, target)
		helpers.assert_not_nil(owner)
		helpers.assert_true(synthetic.seal(tx))
		helpers.assert_true(synthetic.authorize_collected_paced(owner))
		helpers.assert_true(synthetic.commit_collected_paced(owner))
		local consume, returned = synthetic.leave_callback(true)
		helpers.assert_true(consume)
		helpers.assert_nil(returned)

		local fence = synthetic.claim_physical_fence(fixture.mouse_event(LEFT_MOUSE_DOWN))
		helpers.assert_true(fence.consume_original)
		local replay_seen = 0
		fixture.key_observer = function(event)
			local metadata = synthetic.lookup_tag(event:getProperty(USER_DATA))
			if metadata and metadata.physical_replay then
				replay_seen = replay_seen + 1
				for _, consumer in ipairs({ "tooltip.mouse", "keylogger.nonkeyboard" }) do
					local owned, status, replay_fence = provenance.classify_with_fence(event, consumer)
					helpers.assert_nil(owned)
					helpers.assert_eq(status, provenance.STATUS_FOREIGN)
					helpers.assert_nil(replay_fence)
				end
			end
		end
		local guard = 0
		while fixture.key_posts < 5 and #fixture.timers > 0 do
			fixture.fire_next_timer()
			guard = guard + 1
			helpers.assert_true(guard < 80, "mouse fence must terminate")
		end
		helpers.assert_eq(replay_seen, 1)
		helpers.assert_nil(fixture.posted_targets[5],
			"a mouse replay must remain global instead of inheriting a later app")
	end)

	helpers.it("refuses cancellation after paced ownership commits", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local target = { id = "terminal-app" }
		local completion
		synthetic.enter_callback()
		local tx = synthetic.begin("unit.terminal.cancel-fence", "replacement")
		synthetic.on_complete(tx, function(_, status) completion = status end)
		synthetic.with_transaction(tx, function()
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_strokes("X")
		end)
		local owner = synthetic.prepare_collected_paced(tx, 1, 12000, target)
		helpers.assert_not_nil(owner)
		helpers.assert_true(synthetic.seal(tx))
		helpers.assert_true(synthetic.authorize_collected_paced(owner))
		helpers.assert_true(synthetic.commit_collected_paced(owner))
		local consume, returned = synthetic.leave_callback(true)
		helpers.assert_true(consume)
		helpers.assert_nil(returned)
		helpers.assert_true(not synthetic.cancel(tx),
			"pause/reload cancellation must not revoke an already-consumed user action")

		local guard = 0
		while (#fixture.timers > 0 or completion == nil) and guard < 40 do
			if #fixture.timers > 0 then fixture.fire_next_timer() end
			guard = guard + 1
		end
		helpers.assert_eq(fixture.key_posts, 4)
		helpers.assert_eq(completion, "complete")
	end)

	helpers.it("makes callback abort report committed paced ownership", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local target = { id = "terminal-app" }
		synthetic.enter_callback()
		local tx = synthetic.begin("unit.terminal.abort-fence", "replacement")
		synthetic.with_transaction(tx, function()
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_strokes("X")
		end)
		local owner = synthetic.prepare_collected_paced(tx, 1, 12000, target)
		helpers.assert_not_nil(owner)
		helpers.assert_true(synthetic.seal(tx))
		helpers.assert_true(synthetic.authorize_collected_paced(owner))
		helpers.assert_true(synthetic.commit_collected_paced(owner))

		local removed, consume_original = synthetic.abort_callback()
		helpers.assert_true(removed)
		helpers.assert_true(consume_original,
			"an enclosing callback failure cannot pass through the already-owned magic key")
		helpers.assert_eq(synthetic.stats().pending, 1,
			"abort must preserve the committed output batch for post-return delivery")
	end)

	helpers.it("keeps callback output reversible until periodic construction commits", function()
		local cases = {
			{ name = "constructor false", options = { false_on_timer_new_call = 1 }, starts = 0 },
			{ name = "constructor nil", options = { fail_on_timer_new_call = 1 }, starts = 0 },
			{ name = "constructor throw", options = { throw_on_timer_new_call = 1 }, starts = 0 },
			{ name = "start false", options = { timer_start_mode = "false" }, starts = 1 },
			{ name = "start nil", options = { timer_start_mode = "nil" }, starts = 1 },
			{ name = "start throw", options = { timer_start_mode = "throw" }, starts = 1 },
			{ name = "start state mismatch", options = { timer_start_mode = "stopped" }, starts = 1 },
			{ name = "start callback reentry", options = { timer_start_inline = true }, starts = 1 },
			{
				name = "start callback rollback debt",
				options = {
					timer_start_inline = true,
					timer_stop_failures_by_call = { [1] = 2 },
				},
				starts = 1,
				cleanup = 1,
			},
		}
		for _, case in ipairs(cases) do
			local fixture = make_fixture(case.options)
			local synthetic = fixture.load()
			local target = { id = "terminal-app" }
			synthetic.enter_callback()
			local tx = synthetic.begin("unit.terminal.wake-" .. case.name, "replacement")
			synthetic.with_transaction(tx, function()
				synthetic.emit_key_stroke({}, "delete", 0)
				synthetic.emit_key_strokes("X")
			end)
			local owner = synthetic.prepare_collected_paced(tx, 1, 12000, target)
			helpers.assert_nil(owner,
				case.name .. " must refuse periodic ownership during reversible preparation")
			helpers.assert_true(synthetic.seal(tx))
			local consume, returned = synthetic.leave_callback(true)
			helpers.assert_true(consume)
			helpers.assert_eq(#returned, 4,
				case.name .. " must fall back to the complete callback batch")
			helpers.assert_eq(fixture.key_posts, 0)
			helpers.assert_eq(synthetic.stats().pending, 0)
			local expected_cleanup = case.cleanup or 0
			helpers.assert_eq(synthetic.stats().pending_periodic_cleanup, expected_cleanup)
			helpers.assert_eq(fixture.timer_new_calls, 1,
				case.name .. " must not construct a hidden successor")
			helpers.assert_eq(fixture.timer_start_calls, case.starts)
			helpers.assert_eq(fixture.raw_do_every_calls, 0)
			if expected_cleanup > 0 then
				local periodic = fixture.fire_timer_matching(0.012)
				helpers.assert_not_nil(periodic)
				helpers.assert_eq(periodic.stop_calls, 3,
					"queued reentry must settle the twice-refused acquisition")
				helpers.assert_true(periodic.stopped)
				helpers.assert_eq(fixture.timer_new_calls, 1)
				helpers.assert_eq(fixture.key_posts, 0)
				helpers.assert_eq(synthetic.stats().pending_periodic_cleanup, 0)
			end
		end
	end)

	helpers.it("uses only its pre-acquired owner after paced commit, across wake and post refusals", function()
		local fixture = make_fixture({ key_post_throw_at = 3 })
		local synthetic = fixture.load()
		local target = { id = "terminal-app" }
		synthetic.enter_callback()
		local tx = synthetic.begin("unit.terminal.infallible-commit", "replacement")
		synthetic.with_transaction(tx, function()
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_strokes("X")
		end)
		local owner = synthetic.prepare_collected_paced(tx, 1, 12000, target)
		helpers.assert_not_nil(owner)
		helpers.assert_true(synthetic.seal(tx))
		helpers.assert_true(synthetic.authorize_collected_paced(owner))
		local do_after_before = fixture.do_after_calls
		local timer_new_before = fixture.timer_new_calls
		synthetic.defer_after_callback = function()
			error("late dispatcher acquisition")
		end

		local commit_ok, committed = pcall(synthetic.commit_collected_paced, owner)
		helpers.assert_true(commit_ok,
			"commit after engine-state mutation must invoke no fallible scheduler")
		helpers.assert_true(committed)
		local consume, returned = synthetic.leave_callback(true)
		helpers.assert_true(consume)
		helpers.assert_nil(returned)
		fixture.fail_next_do_after = true
		fixture.fail_next_timer_new = true
		fixture.fire_next_timer() -- first pair succeeds through the prepared wake
		fixture.fire_next_timer() -- suffix post is refused; this turn must stop
		helpers.assert_eq(#fixture.key_attempts, 3)
		fixture.fire_next_timer() -- recurring owner retries without reacquisition
		local guard = 0
		while #fixture.timers > 0 and fixture.key_posts < 4 and guard < 40 do
			fixture.fire_next_timer()
			guard = guard + 1
		end
		helpers.assert_eq(fixture.key_posts, 4)
		helpers.assert_eq(fixture.do_after_calls, do_after_before,
			"post-commit recovery must never acquire a one-shot dispatcher")
		helpers.assert_eq(fixture.timer_new_calls, timer_new_before,
			"post-commit recovery must never acquire another periodic owner")
	end)

	helpers.it("finishes with no next input when immediate wake and first post are both refused", function()
		local fixture = make_fixture({ do_after_failures = 1, key_post_throw_at = 1 })
		local synthetic = fixture.load()
		local target = { id = "terminal-app" }
		local completion
		synthetic.enter_callback()
		local tx = synthetic.begin("unit.terminal.double-refusal", "replacement")
		synthetic.on_complete(tx, function(_, status) completion = status end)
		synthetic.with_transaction(tx, function()
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_strokes("X")
		end)
		local owner = synthetic.prepare_collected_paced(tx, 1, 12000, target)
		helpers.assert_not_nil(owner,
			"the recurring owner must survive refusal of the optional immediate wake")
		helpers.assert_true(synthetic.seal(tx))
		helpers.assert_true(synthetic.authorize_collected_paced(owner))
		helpers.assert_true(synthetic.commit_collected_paced(owner))
		local consume, returned = synthetic.leave_callback(true)
		helpers.assert_true(consume)
		helpers.assert_nil(returned)

		fixture.fire_next_timer() -- periodic owner: first post refused
		helpers.assert_eq(#fixture.key_attempts, 1)
		helpers.assert_nil(completion)
		local guard = 0
		while (#fixture.timers > 0 or completion == nil) and guard < 40 do
			if #fixture.timers > 0 then fixture.fire_next_timer() end
			guard = guard + 1
		end
		helpers.assert_eq(fixture.key_posts, 4,
			"pre-acquired recurring ownership must finish without another physical event")
		helpers.assert_eq(completion, "complete")
	end)

	helpers.it("serializes overlapping terminal replacements through one FIFO owner", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local target = { id = "terminal-app" }
		synthetic.enter_callback()
		local function queue(owner, text)
			local tx = synthetic.begin(owner, "replacement")
			synthetic.with_transaction(tx, function()
				synthetic.emit_key_stroke({}, "delete", 0)
				synthetic.emit_key_strokes(text)
			end)
			local paced_owner = synthetic.prepare_collected_paced(tx, 1, 12000, target)
			helpers.assert_not_nil(paced_owner)
			helpers.assert_true(synthetic.seal(tx))
			helpers.assert_true(synthetic.authorize_collected_paced(paced_owner))
			helpers.assert_true(synthetic.commit_collected_paced(paced_owner))
		end

		queue("unit.terminal.first", "A")
		queue("unit.terminal.second", "B")
		local consume, returned = synthetic.leave_callback(true)
		helpers.assert_true(consume)
		helpers.assert_nil(returned)
		local observed_owners = {}
		fixture.key_observer = function(event)
			local property = fixture.eventtap.event.properties.eventSourceUserData
			local metadata = synthetic.lookup_tag(event:getProperty(property))
			observed_owners[#observed_owners + 1] = metadata.owner
		end
		local guard = 0
		while #fixture.timers > 0 and guard < 80 do
			fixture.fire_next_timer()
			guard = guard + 1
		end
		helpers.assert_eq(#observed_owners, 8)
		for index = 1, 4 do helpers.assert_eq(observed_owners[index], "unit.terminal.first") end
		for index = 5, 8 do helpers.assert_eq(observed_owners[index], "unit.terminal.second") end
	end)

	helpers.it("globally posts loopback after the origin callback so keymap receives it", function()
		local fixture = make_fixture({ gc_cancels_unretained_timers = true })
		local synthetic, provenance = fixture.load()
		local epoch_before = synthetic.current_action_epoch()
		local received
		local order = {}
		fixture.key_observer = function(event)
			if event.isDown then
				received = provenance.classify(event, "keymap")
				order[#order + 1] = "keymap"
			end
		end

		synthetic.enter_callback() -- simulate the originating keymap callback
		local tx = synthetic.begin("unit.llm-loopback", "action")
		synthetic.on_complete(tx, function(_, status)
			if status == "complete" then order[#order + 1] = "complete" end
		end)
		synthetic.with_transaction(tx, function()
			synthetic.emit_loopback_key_stroke({}, "f16", 0)
		end)
		synthetic.seal(tx)
		local _, returned = synthetic.leave_callback(false)
		helpers.assert_nil(returned,
			"loopback cannot use a return table that bypasses its originating tap")
		helpers.assert_nil(received)
		helpers.assert_eq(fixture.post_count, 0)

		collectgarbage("collect")
		fixture.fire_next_timer()
		helpers.assert_eq(fixture.key_posts, 2)
		helpers.assert_not_nil(received,
			"global Quartz post must re-enter the simulated keymap callback")
		helpers.assert_true(received.owned)
		helpers.assert_true(received.loopback)
		helpers.assert_eq(received.effect, "action")
		helpers.assert_true(synthetic.current_action_epoch() == epoch_before,
			"loopback control alone must not invalidate action context")
		helpers.assert_eq(order[1], "keymap")
		helpers.assert_nil(order[2],
			"completion must be isolated from the global post callback")
		fixture.fire_next_timer()
		helpers.assert_eq(order[2], "complete",
			"transaction completion must follow both global posts")
	end)

	helpers.it("pins live loopback provenance until both keymap phases claim it", function()
		local fixture = make_fixture()
		local synthetic, provenance = fixture.load()
		synthetic.RECORD_LIMIT = 4
		helpers.assert_true(synthetic.emit_loopback_key_stroke({}, "f16", 0))

		local churn_tx = synthetic.begin("unit.loopback-ledger-churn", "replacement")
		local churn_batch = synthetic.begin_callback(churn_tx)
		for _ = 1, 3 do synthetic.keyStroke(churn_batch, {}, "x") end
		helpers.assert_eq(synthetic.stats().records, synthetic.RECORD_LIMIT)

		local observed = {}
		local posted = {}
		fixture.key_observer = function(event)
			posted[#posted + 1] = event
			local consumer = event.isDown and "keymap" or "keymap.loopback_keyup"
			observed[#observed + 1] = provenance.classify(event, consumer)
		end
		fixture.fire_next_timer()

		helpers.assert_eq(fixture.key_posts, 2)
		for phase = 1, 2 do
			helpers.assert_true(observed[phase].enriched,
				"live loopback phase " .. phase .. " must survive unrelated ledger churn")
			helpers.assert_true(observed[phase].loopback)
			helpers.assert_true(not observed[phase].stale_loopback)
		end

		-- Both authoritative consumers have now claimed their phases. One newer pair
		-- must be able to evict those pins while preserving the configured bound.
		synthetic.keyStroke(churn_batch, {}, "y")
		helpers.assert_eq(synthetic.stats().records, synthetic.RECORD_LIMIT)
		for phase = 1, 2 do
			local tag = posted[phase]:getProperty(USER_DATA)
			local retired = synthetic.lookup_tag(tag)
			helpers.assert_true(retired.stale_loopback,
				"claimed loopback phase " .. phase .. " must become eviction-eligible")
			helpers.assert_true(not retired.loopback)
		end
		synthetic.cancel(churn_tx)
	end)

	helpers.it("rolls back every loopback phase when construction throws", function()
		local fixture = make_fixture({ new_key_event_throw_at = 2 })
		local synthetic = fixture.load()
		helpers.assert_throws(function()
			synthetic.emit_loopback_key_stroke({}, "f16", 0)
		end)
		local stats = synthetic.stats()
		helpers.assert_eq(stats.records, 0,
			"the successfully built down phase must not survive a key-up constructor failure")
		helpers.assert_eq(stats.pending_loopbacks, 0)
		helpers.assert_eq(stats.active_transactions, 0)
		helpers.assert_eq(fixture.key_posts, 0)
	end)

	helpers.it("cancels a pending global loopback at the physical ordering fence", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		helpers.assert_true(synthetic.emit_loopback_key_stroke({}, "f16", 0))
		helpers.assert_eq(synthetic.stats().pending_loopbacks, 1)
		local fence = synthetic.claim_physical_fence()
		helpers.assert_not_nil(fence)
		helpers.assert_nil(fence.events)
		helpers.assert_eq(fence.cancelled_loopbacks, 1)
		helpers.assert_eq(synthetic.stats().pending_loopbacks, 0)
		while #fixture.timers > 0 do fixture.fire_next_timer() end
		helpers.assert_eq(fixture.key_posts, 0,
			"a delayed control signal must never overtake the physical event")
		helpers.assert_eq(synthetic.stats().records, 0)
	end)
end)
