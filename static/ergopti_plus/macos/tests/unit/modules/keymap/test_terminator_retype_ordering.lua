--- tests/unit/modules/keymap/test_terminator_retype_ordering.lua

--- ==============================================================================
--- MODULE: Terminator replay ordering across tagged replacement batches
--- DESCRIPTION:
--- A non-consumed terminator is held until every replacement batch has been
--- handed to Quartz and any clipboard settle fence has opened. The proof uses
--- real SyntheticInput generations and batches, including deferred token output.
--- ==============================================================================

local helpers = require("tests.helpers")

local LONG_A = string.rep("a", 80)
local LONG_B = string.rep("b", 80)


local function make_state(buffer)
	local state = {
		buffer = buffer or "",
		start_is_word_boundary = true,
		magic_key = "*",
	}
	function state.suppress_rescan() end
	function state.is_repeat_feature_enabled() return false end
	return state
end


local function make_registry()
	return {
		is_terminator = function(value) return value == " " or value == "\r" end,
		terminator_is_consumed = function() return false end,
		mappings_for_tail = function() return {} end,
	}
end


local function make_llm()
	return {
		update_preview = function() end,
		get_llm_enabled = function() return false end,
		start_timer = function() end,
	}
end


local function mapping(replacement, plain)
	return {
		trigger = "btw",
		trigger_bytes = 3,
		tlen = 3,
		repl = replacement,
		plain_repl = plain or replacement,
		is_word = false,
		match_mode = "exact",
		final_result = false,
	}
end


local function load_fixture(options)
	options = options or {}
	for name in pairs(package.loaded) do
		if type(name) == "string" and (
			name:match("^modules%.keymap")
			or name == "modules.keylogger"
			or name:match("^adapters%.")
			or name == "infra.logger"
			or name == "infra.timings"
		) then
			package.loaded[name] = nil
		end
	end

	package.loaded["tests.stubs.hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	local posted = {}
	local posted_mouse = {}
	local native_new_key_event = hs_stub.eventtap.event.newKeyEvent
	hs_stub.eventtap.event.newKeyEvent = function(modifiers, key, is_down)
		local event = native_new_key_event(modifiers, key, is_down)
		local native_post = event.post
		event.post = function(self, app)
			if self.isDown then
				posted[#posted + 1] = {
					key = self.key,
					text = self.unicode,
					event = self,
					app = app,
				}
			end
			return native_post(self, app)
		end
		return event
	end
	local native_new_mouse_event = hs_stub.eventtap.event.newMouseEvent
	hs_stub.eventtap.event.newMouseEvent = function(...)
		local event = native_new_mouse_event(...)
		local native_post = event.post
		event.post = function(self, ...)
			posted_mouse[#posted_mouse + 1] = self
			return native_post(self, ...)
		end
		return event
	end
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.timings"] = {
		sec = function(_, key)
			return key == "clipboard_restore_ms" and 0.15 or 0.08
		end,
		ms = function(_, key)
			return key == "terminal_hotstring_key_delay_ms" and 20 or 20
		end,
	}
	package.loaded["modules.keylogger"] = {
		notify_synthetic = function() end,
		set_buffer = function() end,
		log_hotstring = function() end,
	}

	local synthetic = require("adapters.synthetic_input")
	local scheduled = {}
	package.loaded["adapters.timer_scheduler"] = {
		after = function(delay, callback)
			local handle = {
				delay = delay,
				callback = callback,
				cancelled = false,
				recurring = false,
				timer = {},
			}
			scheduled[#scheduled + 1] = handle
			return handle, true
		end,
		every = function(delay, callback)
			local handle = {
				delay = delay,
				callback = callback,
				cancelled = false,
				recurring = true,
				timer = {},
			}
			scheduled[#scheduled + 1] = handle
			return handle, true
		end,
		cancel = function(handle)
			if type(handle) == "table" then
				handle.cancelled = true
				handle.timer = nil
			end
			return true
		end,
	}
	package.loaded["adapters.text_sender"] = {
		eraseChars = function(count, delay)
			for _ = 1, count do
				if not synthetic.emit_key_stroke({}, "delete", delay or 0) then return false end
			end
			return true
		end,
		pressKey = function(key, modifiers, delay)
			return synthetic.emit_key_stroke(modifiers or {}, key, delay or 0)
		end,
		send = function(value)
			return synthetic.emit_key_strokes(value)
		end,
		terminalInputTarget = function()
			return options.terminal_target
		end,
	}
	package.loaded["adapters.tooltip_renderer"] = {
		hide = function() end,
	}

	local clipboard_writes = {}
	hs_stub.pasteboard.readAllData = function() return { original = "snapshot" } end
	hs_stub.pasteboard.writeAllData = function() return true end
	hs_stub.pasteboard.setContents = function(value)
		if value ~= "" then clipboard_writes[#clipboard_writes + 1] = value end
		return true
	end

	local expander = require("modules.keymap.expander")
	local replay = require("modules.keymap.terminator_replay")
	return {
		hs = hs_stub,
		synthetic = synthetic,
		expander = expander,
		replay = replay,
		scheduled = scheduled,
		clipboard_writes = clipboard_writes,
		posted = posted,
		posted_mouse = posted_mouse,
	}
end


local function expand(fixture, entry, terminator, expect_paced)
	terminator = terminator or " "
	local state = make_state("btw" .. terminator)
	fixture.expander.init(state, make_registry(), make_llm())
	fixture.synthetic.enter_callback()
	local fired = fixture.expander.try_terminator_expand(entry, terminator, 1, false)
	local consume, events = fixture.synthetic.leave_callback(fired)
	helpers.assert_true(fired, "the integration path must actually expand")
	helpers.assert_true(consume)
	if expect_paced then
		helpers.assert_nil(events,
			"terminal replacement must remain under its target-paced owner")
	else
		helpers.assert_not_nil(events)
	end
	return events
end


local function fire_hs_zero(fixture)
	local initial_count = #fixture.hs.timer.__timers
	local fired = 0
	for index = 1, initial_count do
		local timer = fixture.hs.timer.__timers[index]
		if timer.running and timer.delay == 0 then
			timer:fire()
			fired = fired + 1
		end
	end
	return fired
end


--- Advances a callback handoff through confirmation and the retained lifecycle
--- dispatcher without firing broker work allocated by that lifecycle callback.
local function fire_hs_lifecycle(fixture)
	fire_hs_zero(fixture)
	fire_hs_zero(fixture)
end


local function fire_one_hs_delay(fixture, delay)
	for _, timer in ipairs(fixture.hs.timer.__timers) do
		if timer.running and math.abs(timer.delay - delay) < 0.000001 then
			timer:fire()
			return timer
		end
	end
	return nil
end


local function fire_serialized(fixture, turns)
	for _ = 1, turns or 6 do fixture.hs.timer.__fire_all() end
end


local function fire_scheduled_delay(fixture, delay)
	local initial_count = #fixture.scheduled
	local fired = 0
	for index = 1, initial_count do
		local handle = fixture.scheduled[index]
		if not handle.cancelled and handle.delay == delay then
			if not handle.recurring then
				handle.cancelled = true
				handle.timer = nil
			end
			handle.callback()
			fired = fired + 1
		end
	end
	return fired
end


local function deliver_latest_pump(fixture)
	local trigger = fixture.posted_mouse[#fixture.posted_mouse]
	helpers.assert_not_nil(trigger, "an ordinary predecessor sibling must post a pump trigger")
	for index = #fixture.hs.eventtap.__taps, 1, -1 do
		local tap = fixture.hs.eventtap.__taps[index]
		if tap.enabled then
			local consume, events = tap.fn(trigger)
			helpers.assert_true(consume, "the tagged pump trigger must be consumed")
			helpers.assert_not_nil(events, "the predecessor sibling must reach Quartz")
			return events
		end
	end
	error("no enabled synthetic pump tap", 0)
end


local function metadata(fixture, event)
	local property = fixture.hs.eventtap.event.properties.eventSourceUserData
	return fixture.synthetic.lookup_tag(event:getProperty(property))
end


local function claim_pending(fixture)
	local physical_x = fixture.hs.eventtap.event.newKeyEvent({}, "x", true)
	physical_x.copy = function(self)
		return fixture.hs.eventtap.event.newKeyEvent(self.mods, self.key, self.isDown)
	end
	local fence = fixture.synthetic.claim_physical_fence(physical_x)
	helpers.assert_not_nil(fence, "tagged output must be waiting at the physical fence")
	helpers.assert_true(fence.consume_original,
		"physical x must be retained behind the reserved terminator")
	return fence.events
end


helpers.describe("terminator replay lands after its tagged replacement", function()
	helpers.it("lets terminal multi-paste siblings complete before reserved Enter", function()
		local target = { id = "terminal-app" }
		local fixture = load_fixture({ terminal_target = target })
		expand(fixture, mapping(
			LONG_A .. "{Left}" .. LONG_B,
			LONG_A .. LONG_B
		), "\r", true)

		-- Three delete pairs, the inline Cmd+V suffix, then lifecycle settlement:
		-- each belongs to its own 20 ms paced turn.
		for _ = 1, 5 do
			helpers.assert_not_nil(fire_one_hs_delay(fixture, 0.02))
		end
		helpers.assert_eq(#fixture.posted, 4)
		helpers.assert_eq(fixture.posted[4].key, "v",
			"the first paste shortcut must finish under the paced target owner")
		helpers.assert_true(fixture.replay.is_pending())

		local token_delay = fixture.scheduled[1].delay
		helpers.assert_eq(fire_scheduled_delay(fixture, token_delay), 1,
			"one ordered owner must enqueue Left and the second paste")
		helpers.assert_eq(#fixture.clipboard_writes, 2)

		-- Exercise the adversarial order: reserved 5 ms tick first, then the
		-- ordinary zero broker. The reserved owner must not pop its predecessor's
		-- deferred sibling and assert before that sibling can reach Quartz.
		helpers.assert_not_nil(fire_one_hs_delay(fixture,
			fixture.synthetic.PERIODIC_OWNER_TICK_SEC))
		local delivered = {}
		for sibling_index = 1, 2 do
			if #fixture.posted_mouse < sibling_index then
				helpers.assert_not_nil(fire_one_hs_delay(fixture, 0))
			end
			local events = deliver_latest_pump(fixture)
			for _, event in ipairs(events) do
				if event.isDown then delivered[#delivered + 1] = event.key end
			end
			fire_hs_lifecycle(fixture)
		end
		helpers.assert_eq(table.concat(delivered, ","), "left,v",
			"both deferred predecessor siblings must overtake only their own reservation")

		local settle_delay = 0.10 + token_delay * 2
		helpers.assert_eq(fire_scheduled_delay(fixture, settle_delay), 1,
			"the exact terminal settle fence must open after all predecessor output")
		fire_hs_lifecycle(fixture)
		helpers.assert_not_nil(fire_one_hs_delay(fixture,
			fixture.synthetic.PERIODIC_OWNER_TICK_SEC))
		helpers.assert_eq(fixture.posted[#fixture.posted].key, "return",
			"reserved Enter must post only after both predecessor siblings")
		helpers.assert_not_nil(fire_one_hs_delay(fixture,
			fixture.synthetic.PERIODIC_OWNER_TICK_SEC))
		fire_hs_lifecycle(fixture)
		helpers.assert_eq(fixture.replay.is_pending(), false)
		helpers.assert_eq(fixture.synthetic.stats().pending, 0,
			"paced, predecessor siblings, and reserved Enter must drain exactly")
	end)

	helpers.it("waits for every deferred replacement batch and the final settle fence", function()
		local fixture = load_fixture()
		local inline = expand(fixture, mapping(
			LONG_A .. "{Left}" .. LONG_B,
			LONG_A .. LONG_B
		))
		local inline_first = metadata(fixture, inline[1])
		local inline_paste = metadata(fixture, inline[7])
		helpers.assert_eq(inline_first.owner, "hotstring")
		helpers.assert_eq(inline_first.effect, "replacement")
		helpers.assert_eq(inline_first.generation, inline_paste.generation)
		helpers.assert_eq(inline_paste.ordinal, 4)
		helpers.assert_eq(inline[7].key, "v")
		helpers.assert_eq(#fixture.clipboard_writes, 1)

		fire_hs_lifecycle(fixture)
		helpers.assert_true(fixture.replay.is_pending())
		helpers.assert_eq(fixture.synthetic.stats().pending, 1,
			"the terminator ordinal is already reserved before deferred tokens fire")

		local token_delay = fixture.scheduled[1].delay
		helpers.assert_eq(fire_scheduled_delay(fixture, token_delay), 1,
			"one ordered cursor must run the deferred key and second paste in sequence")
		helpers.assert_eq(#fixture.clipboard_writes, 2)
		helpers.assert_eq(fixture.clipboard_writes[2], LONG_B)
		helpers.assert_eq(fixture.synthetic.stats().pending, 3,
			"two predecessor batches may overtake the reserved terminator, nothing else")

		local deferred = claim_pending(fixture)
		helpers.assert_eq(#deferred, 4)
		local deferred_key = metadata(fixture, deferred[1])
		local deferred_paste = metadata(fixture, deferred[3])
		helpers.assert_eq(deferred_key.generation, inline_first.generation)
		helpers.assert_eq(deferred_paste.generation, inline_first.generation)
		helpers.assert_eq(deferred_key.ordinal, 5)
		helpers.assert_eq(deferred_paste.ordinal, 6)
		helpers.assert_eq(deferred[1].key, "left")
		helpers.assert_eq(deferred[3].key, "v")
		fire_hs_lifecycle(fixture)

		helpers.assert_eq(fixture.synthetic.stats().pending, 2,
			"the reserved terminator and physical x remain while predecessor output settles")
		helpers.assert_true(fixture.replay.is_pending(),
			"handoff alone cannot prove that the target consumed the second paste")
		-- Two paste-worthy segments advance the target-settle cursor twice.  A
		-- clipboard-restore timer is appended when the second paste runs, so "last
		-- scheduled" is no longer the ordering fence and would exercise the wrong
		-- capability.
		local settle_delay = token_delay * 2
		helpers.assert_true(settle_delay > token_delay)
		helpers.assert_eq(fire_scheduled_delay(fixture, settle_delay), 1)

		fire_serialized(fixture)
		helpers.assert_eq(#fixture.posted, 2,
			"reserved terminator and retained physical x must both settle")
		local term_tag = metadata(fixture, fixture.posted[1].event)
		helpers.assert_eq(term_tag.owner, "terminator_replay")
		helpers.assert_eq(term_tag.effect, "replacement")
		helpers.assert_true(term_tag.generation > inline_first.generation)
		helpers.assert_eq(term_tag.ordinal, 1)
		helpers.assert_eq(fixture.posted[1].text, " ")
		helpers.assert_eq(fixture.posted[2].key, "x",
			"a physical key typed while the successor was reserved cannot overtake it")
	end)

	helpers.it("holds a single-paste terminator until the target-settle deadline", function()
		local fixture = load_fixture()
		local inline = expand(fixture, mapping(LONG_A))
		local replacement = metadata(fixture, inline[1])
		helpers.assert_eq(#fixture.clipboard_writes, 1)
		fire_hs_lifecycle(fixture)

		helpers.assert_true(fixture.replay.is_pending())
		helpers.assert_eq(fixture.synthetic.stats().pending, 1,
			"the reserved terminator must remain blocked by the clipboard settle fence")
		-- Completion now arms clipboard restoration after Cmd+V handoff. That timer
		-- is intentionally later than the target-settle owner and must never be
		-- mistaken for the terminator fence merely because it was appended last.
		helpers.assert_eq(fire_scheduled_delay(fixture, 0.15), 1)
		helpers.assert_true(fixture.replay.is_pending(),
			"clipboard ownership release is not proof that the target consumed the paste")
		helpers.assert_eq(fixture.synthetic.stats().pending, 1,
			"the unopened reserved terminator still owns its FIFO ordinal")
		helpers.assert_eq(fire_scheduled_delay(fixture, 0.08), 1)

		fire_serialized(fixture)
		helpers.assert_eq(#fixture.posted, 1)
		local term_tag = metadata(fixture, fixture.posted[1].event)
		helpers.assert_true(term_tag.generation > replacement.generation)
		helpers.assert_eq(term_tag.owner, "terminator_replay")
	end)

	helpers.it("releases a typed replacement on callback handoff without a settle timer", function()
		local fixture = load_fixture()
		local inline = expand(fixture, mapping("by the way"))
		local replacement = metadata(fixture, inline[1])
		helpers.assert_true(fixture.replay.is_pending())
		helpers.assert_eq(#fixture.scheduled, 1,
			"only the lost-completion watchdog may exist for direct text")
		helpers.assert_eq(fixture.synthetic.stats().pending, 1,
			"direct text already owns the following terminator ordinal")

		fire_hs_lifecycle(fixture)
		fire_serialized(fixture)
		helpers.assert_eq(fixture.replay.is_pending(), false)
		helpers.assert_eq(fixture.synthetic.stats().pending, 0,
			"the autonomously posted replay is fully settled")
		helpers.assert_eq(#fixture.posted, 1)
		local term_tag = metadata(fixture, fixture.posted[1].event)
		helpers.assert_true(term_tag.generation > replacement.generation)
		helpers.assert_eq(term_tag.owner, "terminator_replay")
		helpers.assert_eq(fixture.posted[1].text, " ")
	end)
end)
