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
		is_terminator = function(value) return value == " " end,
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


local function load_fixture()
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
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.timings"] = {
		sec = function(_, key)
			return key == "clipboard_restore_ms" and 0.15 or 0.08
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
				timer = {},
			}
			scheduled[#scheduled + 1] = handle
			return handle
		end,
		cancel = function(handle)
			if type(handle) == "table" then
				handle.cancelled = true
				handle.timer = nil
			end
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
	}
	package.loaded["adapters.tooltip_renderer"] = {
		hide = function() end,
	}

	local clipboard_writes = {}
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
	}
end


local function expand(fixture, entry)
	local state = make_state("btw ")
	fixture.expander.init(state, make_registry(), make_llm())
	fixture.synthetic.enter_callback()
	local fired = fixture.expander.try_terminator_expand(entry, " ", 1, false)
	local consume, events = fixture.synthetic.leave_callback(fired)
	helpers.assert_true(fired, "the integration path must actually expand")
	helpers.assert_true(consume)
	helpers.assert_not_nil(events)
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


local function fire_scheduled_delay(fixture, delay)
	local initial_count = #fixture.scheduled
	local fired = 0
	for index = 1, initial_count do
		local handle = fixture.scheduled[index]
		if not handle.cancelled and handle.delay == delay then
			handle.cancelled = true
			handle.timer = nil
			handle.callback()
			fired = fired + 1
		end
	end
	return fired
end


local function metadata(fixture, event)
	local property = fixture.hs.eventtap.event.properties.eventSourceUserData
	return fixture.synthetic.lookup_tag(event:getProperty(property))
end


local function claim_pending(fixture)
	local fence = fixture.synthetic.claim_physical_fence()
	helpers.assert_not_nil(fence, "tagged output must be waiting at the physical fence")
	return fence.events
end


helpers.describe("terminator replay lands after its tagged replacement", function()
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
		helpers.assert_eq(fixture.synthetic.stats().pending, 0,
			"deferred token timers have not fired yet")

		local token_delay = fixture.scheduled[1].delay
		helpers.assert_eq(fire_scheduled_delay(fixture, token_delay), 2,
			"the deferred key and second paste must both run at the first deadline")
		helpers.assert_eq(#fixture.clipboard_writes, 2)
		helpers.assert_eq(fixture.clipboard_writes[2], LONG_B)
		helpers.assert_eq(fixture.synthetic.stats().pending, 2)

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

		helpers.assert_eq(fixture.synthetic.stats().pending, 0)
		helpers.assert_true(fixture.replay.is_pending(),
			"handoff alone cannot prove that the target consumed the second paste")
		local settle_delay = fixture.scheduled[#fixture.scheduled].delay
		helpers.assert_true(settle_delay > token_delay)
		helpers.assert_eq(fire_scheduled_delay(fixture, settle_delay), 1)

		local terminator = claim_pending(fixture)
		helpers.assert_eq(#terminator, 2)
		local term_tag = metadata(fixture, terminator[1])
		helpers.assert_eq(term_tag.owner, "terminator_replay")
		helpers.assert_eq(term_tag.effect, "replacement")
		helpers.assert_true(term_tag.generation > inline_first.generation)
		helpers.assert_eq(term_tag.ordinal, 1)
		helpers.assert_eq(terminator[1].unicode, " ")
	end)

	helpers.it("holds a single-paste terminator until the target-settle deadline", function()
		local fixture = load_fixture()
		local inline = expand(fixture, mapping(LONG_A))
		local replacement = metadata(fixture, inline[1])
		helpers.assert_eq(#fixture.clipboard_writes, 1)
		fire_hs_lifecycle(fixture)

		helpers.assert_true(fixture.replay.is_pending())
		helpers.assert_eq(fixture.synthetic.stats().pending, 0,
			"transaction completion must not bypass the clipboard settle fence")
		local settle_delay = fixture.scheduled[#fixture.scheduled].delay
		helpers.assert_eq(fire_scheduled_delay(fixture, settle_delay), 1)

		local terminator = claim_pending(fixture)
		local term_tag = metadata(fixture, terminator[1])
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
		helpers.assert_eq(fixture.synthetic.stats().pending, 0)

		fire_hs_lifecycle(fixture)
		helpers.assert_eq(fixture.replay.is_pending(), false)
		helpers.assert_eq(fixture.synthetic.stats().pending, 1,
			"the replay is now an independently tagged deferred batch")
		local terminator = claim_pending(fixture)
		local term_tag = metadata(fixture, terminator[1])
		helpers.assert_true(term_tag.generation > replacement.generation)
		helpers.assert_eq(term_tag.owner, "terminator_replay")
		helpers.assert_eq(terminator[1].unicode, " ")
	end)
end)
