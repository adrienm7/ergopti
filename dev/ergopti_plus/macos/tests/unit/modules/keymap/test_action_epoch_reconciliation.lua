--- tests/unit/modules/keymap/test_action_epoch_reconciliation.lua

--- ==============================================================================
--- MODULE: Keymap action-epoch reconciliation
--- DESCRIPTION:
--- Drives the real keymap eventtap wrapper and its registered SyntheticInput
--- listener. The fixture varies listener/event order and injects a transient LLM
--- teardown failure to prove an epoch is acknowledged only after the stale UI,
--- typing buffer, and word-boundary state have all been reconciled.
--- ==============================================================================

local helpers = require("tests.helpers")

local RESET_MODULES = {
	"modules.keymap", "modules.keymap.init", "modules.keymap.registry",
	"modules.keymap.expander", "modules.keymap.llm_bridge", "modules.keymap.state",
	"modules.keymap.terminator_replay", "modules.keymap.utils",
	"adapters.synthetic_input", "adapters.event_provenance",
	"infra.logger", "infra.perf",
	"infra.hotpath_profiler", "infra.manifest_reader", "infra.keycodes",
}


local function noop() end

local function api(overrides)
	return setmetatable(overrides or {}, {
		__index = function(t, key)
			local value = noop
			rawset(t, key, value)
			return value
		end,
	})
end


local function load_fixture()
	for _, name in ipairs(RESET_MODULES) do package.loaded[name] = nil end

	package.loaded["tests.stubs.hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	local taps = {}
	local base_new = hs_stub.eventtap.new
	hs_stub.eventtap.new = function(types, callback)
		local tap = base_new(types, callback)
		tap.callback = callback
		taps[#taps + 1] = tap
		return tap
	end
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub

	local epoch = {}
	local pending_fence = nil
	local listener = nil
	local register_calls = 0
	local unregister_calls = 0
	local registered_epoch = nil
	local deferred = {}
	local abort_requires_consumption = false
	local raw_failure = false
	local admission_is_open = true
	local key_provenance_status = "foreign"
	local synthetic_stub = {
		current_action_epoch = function() return epoch, 125 end,
		claim_physical_fence = function()
			if pending_fence == nil then return nil end
			local fence = pending_fence
			pending_fence = nil
			epoch = {}
			return fence
		end,
		register_action_listener = function(id, callback, acknowledged_epoch)
			helpers.assert_eq(id, "modules.keymap.action_epoch")
			register_calls = register_calls + 1
			listener = callback
			registered_epoch = acknowledged_epoch
			return true
		end,
		unregister_action_listener = function(id)
			helpers.assert_eq(id, "modules.keymap.action_epoch")
			unregister_calls = unregister_calls + 1
			listener = nil
			return true
		end,
		enter_callback = function() end,
		leave_callback = function(consume) return consume == true, {} end,
		abort_callback = function() return true, abort_requires_consumption end,
		admission_open = function() return admission_is_open end,
		defer_after_callback = function(_label, callback)
			deferred[#deferred + 1] = callback
			return true
		end,
	}
	package.loaded["adapters.synthetic_input"] = synthetic_stub
	package.loaded["adapters.event_provenance"] = {
		STATUS_OWNED = "owned",
		STATUS_FOREIGN = "foreign",
		STATUS_UNREADABLE = "unreadable",
		classify_with_fence = function()
			return nil, key_provenance_status, synthetic_stub.claim_physical_fence()
		end,
	}

	local state = {
		buffer = "typed",
		start_is_word_boundary = true,
		processing_paused = false,
		ignored_window_titles = {},
		ignored_window_patterns = {},
		last_key_time = 0,
		WORD_TIMEOUT_SEC = 0,
		no_rescan_until = 0,
		last_key_was_complex = false,
		magic_key = "★",
		DELAYS = { STAR_TRIGGER = 0 },
		groups = {},
		interceptors = {},
		preview_providers = {},
		shift_side = nil,
	}
	package.loaded["modules.keymap.state"] = {
		new = function() return state end,
	}
	package.loaded["modules.keymap.registry"] = api({
		init = function() return true end,
		is_terminator = function()
			if raw_failure then error("forced post-commit callback failure") end
			return false
		end,
		is_repeat_feature_enabled = function() return false end,
		set_repeat_feature_enabled = noop,
	})
	package.loaded["modules.keymap.expander"] = api({
		init = function() return true end,
	})

	local calls = {}
	local callback_errors = {}
	local reset_should_fail = false
	local record_nav_reset = false
	local llm_quarantined = false
	local safe_epoch = epoch
	package.loaded["modules.keymap.llm_bridge"] = api({
		init = function() return true end,
		reset_predictions = function()
			calls[#calls + 1] = "ordinary-reset"
			return not llm_quarantined
		end,
		reset_for_teardown = function()
			calls[#calls + 1] = "teardown-reset"
			return true
		end,
		stop = function()
			calls[#calls + 1] = "bridge-stop"
			return true
		end,
		check_nav_reset = function()
			if record_nav_reset then calls[#calls + 1] = "ordinary-reset" end
		end,
		observe_action_epoch = function(observed)
			calls[#calls + 1] = "observe"
			if observed ~= safe_epoch then llm_quarantined = true end
			return observed == epoch
		end,
		reset_for_action_epoch = function(observed)
			calls[#calls + 1] = "observe"
			if observed ~= safe_epoch then llm_quarantined = true end
			calls[#calls + 1] = "reset"
			if reset_should_fail then error("transient prediction reset") end
			if observed ~= epoch then return false end
			safe_epoch = observed
			llm_quarantined = false
			return true
		end,
		is_runtime_available = function()
			return not llm_quarantined and safe_epoch == epoch
		end,
		handle_llm_keys = function()
			if llm_quarantined or safe_epoch ~= epoch then return false end
			calls[#calls + 1] = "handle"
			return true
		end,
		update_preview = function(buf)
			if llm_quarantined then return end
			calls[#calls + 1] = "preview:" .. tostring(buf)
		end,
	})
	package.loaded["modules.keymap.terminator_replay"] = api({
		flush_now = function() return true end,
		is_pending = function() return false end,
	})
	package.loaded["modules.keymap.utils"] = api({
		start_ignored_win_tracking = function() return 1 end,
		prewarm_ignored_win_watchers = function() return true end,
		stop = function() return true end,
		is_ignored_window = function() return false, 1 end,
	})
	local mailbox_running = false
	package.loaded["modules.diagnostics.hid_diagnostic_mailbox"] = {
		start = function() mailbox_running = true; return true end,
		stop = function() mailbox_running = false; return true end,
		is_running = function() return mailbox_running end,
	}
	package.loaded["infra.logger"] = api({
		LEVELS = { DEBUG = 10 },
		is_enabled = function() return false end,
		error = function(_, fmt, ...)
			local ok, message = pcall(string.format, tostring(fmt), ...)
			callback_errors[#callback_errors + 1] = ok and message or tostring(fmt)
		end,
	})
	package.loaded["infra.perf"] = api({ is_enabled = function() return false end })
	package.loaded["infra.hotpath_profiler"] = api({ now = function() return 0 end })
	package.loaded["infra.manifest_reader"] = {
		default_for = function(key)
			if key == "hotstrings.expansion_delay" then return 0 end
			if key == "hotstrings.trigger_char" then return "★" end
			return false
		end,
	}
	package.loaded["infra.keycodes"] = { ESCAPE = 53, BACKSPACE = 51, RETURN = 36 }

	local keymap = require("modules.keymap.init")
	keymap.start()
	-- Startup observes the already-safe token. Individual cases below assert only
	-- work caused by the action they create, not that one-time registration step.
	for i = #calls, 1, -1 do calls[i] = nil end

	local function physical_key(key_code, chars)
		local before = #callback_errors
		local results = table.pack(taps[1].callback({
			getKeyCode = function() return key_code end,
			getFlags = function() return {} end,
			getCharacters = function() return chars end,
			getProperty = function() return 0 end,
		}))
		helpers.assert_eq(#callback_errors, before,
			"the keymap wrapper must not hide a fixture/runtime error as physical pass-through")
		return table.unpack(results, 1, results.n)
	end
	local function failing_physical_key(key_code, chars)
		local before = #callback_errors
		local results = table.pack(taps[1].callback({
			getKeyCode = function() return key_code end,
			getFlags = function() return {} end,
			getCharacters = function() return chars end,
			getProperty = function() return 0 end,
		}))
		helpers.assert_eq(#callback_errors, before + 1,
			"the forced raw failure must reach the wrapper's diagnostic path")
		return table.unpack(results, 1, results.n)
	end
	local function tap_for(event_type)
		for _, candidate in ipairs(taps) do
			for _, watched in ipairs(candidate.types or {}) do
				if watched == event_type then return candidate end
			end
		end
		return nil
	end

	return {
		keymap = keymap,
		state = state,
		calls = calls,
		advance = function() epoch = {} end,
		dispatch = function()
			helpers.assert_type(listener, "function")
			return listener(epoch, 125)
		end,
		physical_enter = function() return physical_key(36, "\r") end,
		physical_letter = function(chars) return physical_key(0, chars or "x") end,
		fail_after_paced_commit = function()
			abort_requires_consumption = true
			raw_failure = true
			return failing_physical_key(0, "x")
		end,
		physical_click = function()
			local mouse_tap = tap_for(hs_stub.eventtap.event.types.leftMouseDown)
			helpers.assert_type(mouse_tap and mouse_tap.callback, "function")
			local before = #callback_errors
			record_nav_reset = true
			local results = table.pack(mouse_tap.callback({}))
			helpers.assert_eq(#callback_errors, before,
				"the mouse wrapper must not hide a fixture/runtime error as pass-through")
			local pending = deferred
			deferred = {}
			for _, callback in ipairs(pending) do callback() end
			record_nav_reset = false
			return table.unpack(results, 1, results.n)
		end,
		shift_failure = function()
			local shift_tap = tap_for(hs_stub.eventtap.event.types.flagsChanged)
			helpers.assert_type(shift_tap and shift_tap.callback, "function")
			return shift_tap.callback({
				getKeyCode = function() error("SHIFT_KEYCODE_THROW") end,
				getFlags = function() return { shift = true } end,
			})
		end,
		deferred_count = function() return #deferred end,
		queue_fence = function(events) pending_fence = { events = events } end,
		set_admission = function(value) admission_is_open = value == true end,
		set_key_provenance_status = function(value) key_provenance_status = value end,
		set_reset_failure = function(value) reset_should_fail = value end,
		llm_quarantined = function() return llm_quarantined end,
		registered_epoch = function() return registered_epoch end,
		register_calls = function() return register_calls end,
		unregister_calls = function() return unregister_calls end,
	}
end


helpers.describe("keymap action epochs", function()
	helpers.it("passes physical input without engine mutation while pause owns admission", function()
		local fixture = load_fixture()
		fixture.set_admission(false)
		local consumed = fixture.physical_letter("x")

		helpers.assert_true(not consumed)
		helpers.assert_eq(fixture.state.buffer, "typed",
			"the idle-to-PAUSED fence must not start a new logical replacement")
		helpers.assert_eq(#fixture.calls, 0)
		fixture.keymap.stop()
	end)

	helpers.it("passes unreadable keyDown without context invalidation while PAUSED", function()
		local fixture = load_fixture()
		helpers.assert_eq(fixture.keymap.pause_processing(), true)
		fixture.state.buffer = "pause-owned"
		fixture.state.start_is_word_boundary = true
		fixture.set_key_provenance_status("unreadable")

		local consumed = fixture.physical_letter("x")

		helpers.assert_true(not consumed,
			"an unreadable physical event must still pass through under PAUSED")
		helpers.assert_eq(fixture.state.buffer, "pause-owned",
			"unreadable delivery may not invalidate the paused text snapshot")
		helpers.assert_eq(fixture.state.start_is_word_boundary, true)
		helpers.assert_eq(#fixture.calls, 0,
			"PAUSED unreadable delivery may not observe epochs or reset predictions")
		fixture.keymap.stop()
	end)

	helpers.it("does not defer shift diagnostics after PAUSED is published", function()
		local fixture = load_fixture()
		helpers.assert_eq(fixture.keymap.pause_processing(), true)
		helpers.assert_eq(fixture.deferred_count(), 0)

		local consumed = fixture.shift_failure()

		helpers.assert_true(not consumed)
		helpers.assert_eq(fixture.deferred_count(), 0,
			"a paused flagsChanged failure may not acquire a deferred logger callback")
		fixture.keymap.stop()
	end)

	helpers.it("an action with no following key clears the buffer and hides predictions", function()
		local fixture = load_fixture()
		fixture.advance()
		fixture.dispatch()

		helpers.assert_eq(fixture.state.buffer, "")
		helpers.assert_true(not fixture.state.start_is_word_boundary)
		helpers.assert_eq(table.concat(fixture.calls, ","), "observe,reset")
		fixture.keymap.stop()
	end)

	helpers.it("the per-event backstop reconciles before reversed-order physical input", function()
		local fixture = load_fixture()
		fixture.advance()
		local consumed = fixture.physical_enter()

		helpers.assert_true(not consumed,
			"the physical Enter must pass through while stale LLM state is quarantined")
		helpers.assert_eq(table.concat(fixture.calls, ","), "observe",
			"the eventtap backstop must perform no full reset or external work")
		helpers.assert_eq(fixture.state.buffer, "\r")
		fixture.dispatch()
		fixture.physical_enter()
		helpers.assert_eq(table.concat(fixture.calls, ","), "observe,observe,reset,handle")
		fixture.keymap.stop()
	end)

	helpers.it("claims older output before processing the overtaking physical key", function()
		local fixture = load_fixture()
		local older_events = { { key = "older-action" } }
		fixture.queue_fence(older_events)
		local consumed, returned_events = fixture.physical_enter()

		helpers.assert_true(not consumed)
		helpers.assert_eq(#returned_events, 1)
		helpers.assert_true(returned_events[1] == older_events[1],
			"the keymap tap must return older output before the physical original")
		helpers.assert_eq(table.concat(fixture.calls, ","), "observe",
			"the fence epoch must close stale LLM state without resetting on the HID path")
		fixture.keymap.stop()
	end)

	helpers.it("consumes a physical key already owned by paced output when the wrapper aborts", function()
		local fixture = load_fixture()
		fixture.advance()
		local consumed = fixture.fail_after_paced_commit()

		helpers.assert_true(consumed,
			"post-commit callback failure must not pass the owned magic key through")
		fixture.keymap.stop()
	end)

	helpers.it("claims older output before a focus-changing click without keylogger", function()
		local fixture = load_fixture()
		local older_events = { { key = "before-focus-change" } }
		fixture.queue_fence(older_events)
		local consumed, returned_events = fixture.physical_click()

		helpers.assert_true(not consumed)
		helpers.assert_eq(#returned_events, 1)
		helpers.assert_true(returned_events[1] == older_events[1],
			"the always-on keymap mouse tap must return queued output before the original click")
		helpers.assert_true(not fixture.state.start_is_word_boundary,
			"a focus-changing click must close the stale word-boundary state synchronously")
		fixture.keymap.stop()
	end)

	helpers.it("passes clicks without context mutation or deferred reset while PAUSED", function()
		local fixture = load_fixture()
		helpers.assert_eq(fixture.keymap.pause_processing(), true)
		fixture.state.buffer = "pause-owned"
		fixture.state.start_is_word_boundary = true

		local consumed = fixture.physical_click()

		helpers.assert_true(not consumed)
		helpers.assert_eq(fixture.state.buffer, "pause-owned",
			"the installed mouse tap must not mutate keymap context under PAUSED")
		helpers.assert_eq(fixture.state.start_is_word_boundary, true)
		helpers.assert_eq(#fixture.calls, 0,
			"the paused click must not enqueue nav-reset or reconciliation work")
		fixture.keymap.stop()
	end)

	helpers.it("a click cancels pre-click preview recovery even when buffer reset is disabled", function()
		local fixture = load_fixture()
		fixture.advance()
		fixture.set_reset_failure(true)
		helpers.assert_true(not pcall(fixture.dispatch))
		fixture.physical_letter("x")
		fixture.physical_click()

		fixture.set_reset_failure(false)
		fixture.dispatch()
		helpers.assert_eq(table.concat(fixture.calls, ","),
			"observe,reset,ordinary-reset,observe,reset",
			"recovery must not arm a timer for text typed at the cursor position before the click")
		fixture.keymap.stop()
	end)

	helpers.it("a permanent reset failure quarantines only LLM while ordinary typing accumulates", function()
		local fixture = load_fixture()
		fixture.advance()
		fixture.set_reset_failure(true)

		local first_listener_ok = pcall(fixture.dispatch)
		helpers.assert_true(not first_listener_ok,
			"the listener must raise so SyntheticInput does not acknowledge the epoch")
		local first_consumed = fixture.physical_letter("x")
		local second_consumed = fixture.physical_letter("y")
		helpers.assert_true(not first_consumed and not second_consumed,
			"quarantine must never consume physical text")
		helpers.assert_eq(fixture.state.buffer, "xy",
			"context must reset once; repeated LLM retries cannot erase later typing")
		helpers.assert_true(fixture.llm_quarantined())
		helpers.assert_eq(table.concat(fixture.calls, ","),
			"observe,reset",
			"physical keys must not retry the throwing reset on the HID path")

		fixture.set_reset_failure(false)
		fixture.dispatch()
		helpers.assert_true(not fixture.llm_quarantined())
		helpers.assert_eq(fixture.state.buffer, "xy",
			"successful LLM recovery must not repeat the already-completed context reset")
		helpers.assert_eq(table.concat(fixture.calls, ","),
			"observe,reset,observe,reset,preview:xy",
			"recovery must rebuild the preview and re-arm LLM from every key typed during quarantine")
		fixture.physical_enter()
		helpers.assert_eq(table.concat(fixture.calls, ","),
			"observe,reset,observe,reset,preview:xy,handle")
		fixture.keymap.stop()
	end)

	helpers.it("pause cancels a preview catch-up recorded before reconciliation", function()
		local fixture = load_fixture()
		fixture.advance()
		fixture.set_reset_failure(true)
		helpers.assert_true(not pcall(fixture.dispatch))
		fixture.physical_letter("x")

		fixture.keymap.pause_processing()
		fixture.set_reset_failure(false)
		fixture.dispatch()
		helpers.assert_eq(table.concat(fixture.calls, ","),
			"observe,reset,observe,reset",
			"a listener recovering during pause must not re-arm predictions from pre-pause text")
		fixture.keymap.resume_processing()
		fixture.keymap.stop()
	end)

	helpers.it("resume starts from fresh text after unobserved paused typing", function()
		local fixture = load_fixture()
		fixture.state.buffer = "ae"
		fixture.state.start_is_word_boundary = true

		fixture.keymap.pause_processing()
		local paused_consumed = fixture.physical_letter("x")
		helpers.assert_true(not paused_consumed,
			"typing while paused must continue to reach the frontmost application")
		fixture.keymap.resume_processing()

		helpers.assert_eq(fixture.state.buffer, "",
			"resume must discard text that predates unobserved paused edits")
		helpers.assert_true(not fixture.state.start_is_word_boundary,
			"an unknown cursor context must not be advertised as a proven word boundary")
		fixture.physical_letter("u")
		helpers.assert_true(not fixture.state.buffer:find("ae", 1, true),
			"the post-resume key must not join text from before the pause boundary")
		fixture.keymap.stop()
	end)

	helpers.it("start and stop register the stable listener exactly once", function()
		local fixture = load_fixture()
		fixture.keymap.start()
		helpers.assert_eq(fixture.register_calls(), 1)
		helpers.assert_type(fixture.registered_epoch(), "table")
		fixture.keymap.stop()
		fixture.keymap.stop()
		helpers.assert_eq(fixture.unregister_calls(), 1)
	end)

	helpers.it("stop uses the teardown reset even while the ordinary runtime is quarantined", function()
		local fixture = load_fixture()
		fixture.advance()
		fixture.physical_letter("x")
		helpers.assert_true(fixture.llm_quarantined())

		local generation_before_stop = fixture.state.lifecycle_generation or 0
		helpers.assert_eq(fixture.keymap.stop(), true,
			"teardown must not wait for a listener that stop has already unregistered")
		helpers.assert_eq(fixture.state.lifecycle_generation, generation_before_stop + 1,
			"stop must invalidate every pending replacement completion callback")
		helpers.assert_eq(table.concat(fixture.calls, ","),
			"observe,teardown-reset,bridge-stop",
			"keymap.stop must bypass the ordinary quarantine gate and still stop the sibling trap")
	end)
end)

for _, name in ipairs(RESET_MODULES) do package.loaded[name] = nil end
