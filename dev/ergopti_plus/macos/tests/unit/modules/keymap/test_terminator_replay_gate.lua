--- tests/unit/modules/keymap/test_terminator_replay_gate.lua

--- ==============================================================================
--- MODULE: Regression — Enter must not fire before the autocorrection lands
---         (terminator-before-expansion)
--- DESCRIPTION:
--- Typing "ui" then Enter sent Enter to the application FIRST. In a chat client
--- or a search field that submits the line; the user saw their message go out as
--- "ui", or — when the trigger had already been erased — as an empty line, with
--- the expansion appearing afterwards in the freshly emptied box.
---
--- ROOT CAUSE ENCODED: the expander consumes the physical terminator (so trigger
--- and terminator can be erased together) and re-emits it after the replacement.
--- The re-emission was posted inline, immediately after the replacement, on the
--- assumption that a raw key event posted after a text injection is delivered
--- after that text. It is not. The replacement travels through the text-input
--- pipeline — a unicode-string key event, or a clipboard read the target
--- schedules itself — while Enter and Tab travel as raw key events many hosts
--- action on arrival. Nothing ordered the two.
---
--- The terminator is now HELD until the replacement has provably landed: the
--- driver already logs every synthetic event it injects so it can ignore its own
--- echo, and that bookkeeping is the proof. Once the deletes, the pastes and the
--- replacement's own echo have all come back through the keyboard tap, whatever
--- we post next is strictly behind them.
---
--- WHY IT MUST NEVER BE "FIXED" BY DROPPING THE KEY: Enter and Tab are the
--- terminators with irreversible side effects. Late is recoverable; lost is not.
--- The watchdog case below is what guarantees that.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =============================================
-- =============================================
-- ======= 1/ Harness ==========================
-- =============================================
-- =============================================

--- Loads a cold copy of the replay gate with recording adapters.
---
--- Both adapters are evicted first: each binds its dependencies at load time, so
--- a cached copy would post into a previous test case's recorder and every
--- assertion here would read an empty log.
--- @return table replay, table sent, table timers, table state
local function load_gate()
	local sent   = {}
	local timers = {}

	package.loaded["adapters.text_sender"] = {
		pressKey   = function(key, _mods, delay)
			sent[#sent + 1] = { kind = "key", key = key, delay = delay }
		end,
		send       = function(text, opts)
			sent[#sent + 1] = { kind = "text", text = text, mode = opts and opts.mode }
		end,
		eraseChars = function() end,
	}
	package.loaded["adapters.timer_scheduler"] = {
		after = function(delay, fn)
			local handle = { delay = delay, fn = fn, cancelled = false }
			timers[#timers + 1] = handle
			return handle
		end,
		cancel = function(handle)
			if type(handle) == "table" then handle.cancelled = true end
		end,
	}

	package.loaded["modules.keymap.terminator_replay"] = nil
	local Replay = require("modules.keymap.terminator_replay")

	local state = {
		expected_synthetic_deletes = 0,
		expected_synthetic_chars   = "",
		expected_synthetic_pastes  = 0,
	}
	Replay.init(state)

	return Replay, sent, timers, state
end

--- Fires the first live timer whose delay matches, mimicking the run loop.
--- @param timers table
--- @param delay number|nil Only fire timers at this delay when given.
local function fire_timers(timers, delay)
	for _, t in ipairs(timers) do
		if not t.cancelled and (delay == nil or t.delay == delay) then
			t.cancelled = true
			t.fn()
		end
	end
end

--- The state an expansion of "ui" → "UI" terminated by Enter leaves behind:
--- two deletes in flight, and an echo expectation holding the replacement plus
--- the terminator's own CR (armed up front for the keylogger's accounting).
--- @param state table
local function arm_ui_expansion(state)
	state.expected_synthetic_deletes = 2
	state.expected_synthetic_chars   = "UI\r"
	state.expected_synthetic_pastes  = 0
end




-- ======================================================
-- ======================================================
-- ======= 2/ The Terminator Waits For The Text =========
-- ======================================================
-- ======================================================

helpers.describe("terminator replay: Enter is held until the replacement lands", function()

	helpers.it("is not sent while the replacement's deletes are still in flight", function()
		local Replay, sent, _timers, state = load_gate()
		arm_ui_expansion(state)

		Replay.arm({ kind = "key", key = "return", chars = "\r", echo_bytes = 1 })

		helpers.assert_eq(#sent, 0,
			"Enter must NOT reach the host while our own backspaces are still travelling — "
				.. "this is exactly the moment the trigger is erased and the line is empty, "
				.. "so an Enter landing here submits nothing at all")
		helpers.assert_true(Replay.is_pending(), "and it must still be queued, not discarded")
	end)

	helpers.it("is not sent while the replacement text has not echoed back", function()
		local Replay, sent, _timers, state = load_gate()
		arm_ui_expansion(state)
		Replay.arm({ kind = "key", key = "return", chars = "\r", echo_bytes = 1 })

		-- The backspace echoes have come back; the replacement's have not.
		state.expected_synthetic_deletes = 0
		Replay.flush_if_delivered()

		helpers.assert_eq(#sent, 0,
			"Enter must wait for the replacement itself — releasing it once the deletes are "
				.. "done is precisely the 'ui' erased, Enter sent, UI typed afterwards case")
	end)

	helpers.it("is sent the moment the replacement's echo has drained", function()
		local Replay, sent, _timers, state = load_gate()
		arm_ui_expansion(state)
		Replay.arm({ kind = "key", key = "return", chars = "\r", echo_bytes = 1 })

		state.expected_synthetic_deletes = 0
		-- The tap has consumed "U" and "I"; only the terminator's own CR is left,
		-- and that one is ours to send.
		state.expected_synthetic_chars = "\r"
		Replay.flush_if_delivered()

		helpers.assert_eq(#sent, 1, "Enter must be released as soon as the text has landed")
		helpers.assert_eq(sent[1].kind, "key", "it must go out as a real key event")
		helpers.assert_eq(sent[1].key, "return", "and it must be Return")
		helpers.assert_true(not Replay.is_pending(), "the slot must be clear afterwards")
	end)

	helpers.it("is sent exactly once, not once per drained echo", function()
		local Replay, sent, _timers, state = load_gate()
		arm_ui_expansion(state)
		Replay.arm({ kind = "key", key = "return", chars = "\r", echo_bytes = 1 })

		state.expected_synthetic_deletes = 0
		state.expected_synthetic_chars   = "\r"
		Replay.flush_if_delivered()
		Replay.flush_if_delivered()
		Replay.flush_if_delivered()

		helpers.assert_eq(#sent, 1,
			"the gate is consulted on every synthetic echo, so a non-idempotent release "
				.. "would submit the message once per character of the replacement")
	end)

	helpers.it("applies the same hold to Tab", function()
		local Replay, sent, _timers, state = load_gate()
		state.expected_synthetic_deletes = 1
		state.expected_synthetic_chars   = "X\t"

		Replay.arm({ kind = "key", key = "tab", chars = "\t", echo_bytes = 1 })
		helpers.assert_eq(#sent, 0, "Tab moves focus away — it must not overtake the text either")

		state.expected_synthetic_deletes = 0
		state.expected_synthetic_chars   = "\t"
		Replay.flush_if_delivered()

		helpers.assert_eq(#sent, 1, "and it must still be delivered")
		helpers.assert_eq(sent[1].key, "tab")
	end)

	helpers.it("sends a printable terminator as text, not as a key", function()
		local Replay, sent, _timers, state = load_gate()
		state.expected_synthetic_deletes = 0
		state.expected_synthetic_chars   = " "

		Replay.arm({ kind = "text", chars = " ", echo_bytes = 1 })

		helpers.assert_eq(#sent, 1, "a space has no side effect to fear and is releasable at once")
		helpers.assert_eq(sent[1].kind, "text")
		helpers.assert_eq(sent[1].text, " ")
		helpers.assert_eq(sent[1].mode, "direct",
			"printable terminators keep the direct-injection contract they had before")
	end)

end)




-- ==========================================================
-- ==========================================================
-- ======= 3/ The Terminator Is Never Lost ==================
-- ==========================================================
-- ==========================================================

helpers.describe("terminator replay: the key is never silently dropped", function()

	helpers.it("is replayed by the watchdog when the echo never comes back", function()
		local Replay, sent, timers, state = load_gate()
		arm_ui_expansion(state)
		Replay.arm({ kind = "key", key = "return", chars = "\r", echo_bytes = 1 })
		helpers.assert_eq(#sent, 0, "still waiting, as it should be")

		-- The host swallowed our echo, or the OS disabled the tap: nothing will
		-- ever drain those counters.
		fire_timers(timers)

		helpers.assert_eq(#sent, 1,
			"a lost echo must cost the user a few milliseconds, never their Enter — "
				.. "waiting forever on evidence that will never arrive is a worse failure "
				.. "than the ordering bug this gate exists to fix")
		helpers.assert_eq(sent[1].key, "return")
	end)

	helpers.it("does not double-send when the echo arrives after the watchdog", function()
		local Replay, sent, timers, state = load_gate()
		arm_ui_expansion(state)
		Replay.arm({ kind = "key", key = "return", chars = "\r", echo_bytes = 1 })

		fire_timers(timers)
		state.expected_synthetic_deletes = 0
		state.expected_synthetic_chars   = "\r"
		Replay.flush_if_delivered()

		helpers.assert_eq(#sent, 1, "a late echo must not send a second Enter")
	end)

	helpers.it("cancels its watchdog once released, so nothing fires into an empty slot", function()
		local Replay, sent, timers, state = load_gate()
		arm_ui_expansion(state)
		Replay.arm({ kind = "key", key = "return", chars = "\r", echo_bytes = 1 })

		state.expected_synthetic_deletes = 0
		state.expected_synthetic_chars   = "\r"
		Replay.flush_if_delivered()
		helpers.assert_eq(#sent, 1)

		fire_timers(timers)
		helpers.assert_eq(#sent, 1,
			"an orphaned watchdog would replay a terminator the user already got, inserting "
				.. "a stray newline into whatever they typed next")
	end)

	helpers.it("flush_now releases it where echoes are unobservable", function()
		local Replay, sent, _timers, state = load_gate()
		arm_ui_expansion(state)
		Replay.arm({ kind = "key", key = "return", chars = "\r", echo_bytes = 1 })

		helpers.assert_true(Replay.flush_now("window not observed"),
			"flush_now must report that it released something")
		helpers.assert_eq(#sent, 1,
			"in a window the driver does not track, no echo will ever arrive — holding the "
				.. "Enter there would stall every single one until the watchdog expired")
	end)

	helpers.it("a second expansion flushes the first terminator before taking the slot", function()
		local Replay, sent, _timers, state = load_gate()
		arm_ui_expansion(state)
		Replay.arm({ kind = "key", key = "return", chars = "\r", echo_bytes = 1 })
		helpers.assert_eq(#sent, 0)

		-- A chained autocorrection fires while the first terminator is still held.
		Replay.arm({ kind = "text", chars = " ", echo_bytes = 1 })

		helpers.assert_true(#sent >= 1, "the first terminator must be released, not overwritten")
		helpers.assert_eq(sent[1].key, "return",
			"and it must be released FIRST — a single pending slot that simply replaced its "
				.. "occupant would drop the earlier Enter on the floor")
	end)

end)




-- ==========================================================
-- ==========================================================
-- ======= 4/ The Paste Path ================================
-- ==========================================================
-- ==========================================================

helpers.describe("terminator replay: clipboard-backed replacements", function()

	helpers.it("waits for the Cmd+V echo before releasing the terminator", function()
		local Replay, sent, _timers, state = load_gate()
		-- A paste emits no per-character echo: the pending Cmd+V is the only
		-- evidence the replacement is on its way.
		state.expected_synthetic_deletes = 0
		state.expected_synthetic_chars   = "\r"
		state.expected_synthetic_pastes  = 1

		Replay.arm({ kind = "key", key = "return", chars = "\r", echo_bytes = 1 })
		helpers.assert_eq(#sent, 0,
			"Enter posted straight after Cmd+V reaches the host before the target has even "
				.. "read the pasteboard")

		state.expected_synthetic_pastes = 0
		Replay.flush_if_delivered()
		helpers.assert_eq(#sent, 1, "and it is released once that echo is seen")
	end)

	helpers.it("honours a settle floor reported by the emitter", function()
		local Replay, sent, timers, state = load_gate()
		state.expected_synthetic_deletes = 0
		state.expected_synthetic_chars   = "\r"

		-- Everything already drained, but the emitter reported a paste fence: the
		-- pasted text is produced by the TARGET, on its own schedule, so our own
		-- bookkeeping cannot prove it has landed.
		Replay.arm({ kind = "key", key = "return", chars = "\r", echo_bytes = 1, min_delay = 0.08 })

		helpers.assert_eq(#sent, 0,
			"an empty echo ledger is not proof the paste arrived — the fence must win")

		fire_timers(timers, 0.08)
		helpers.assert_eq(#sent, 1, "and the terminator follows once the settle window elapses")
	end)

	helpers.it("does not let our own Cmd+V echo open the settle fence", function()
		local Replay, sent, timers, state = load_gate()
		-- The state production ACTUALLY produces, which neither case above builds:
		-- a paste-backed replacement whose non-consumed terminator is re-typed arms
		-- the paste counter AND reports a settle floor, at the same time.
		state.expected_synthetic_deletes = 0
		state.expected_synthetic_chars   = "\r"
		state.expected_synthetic_pastes  = 1

		Replay.arm({ kind = "key", key = "return", chars = "\r", echo_bytes = 1, min_delay = 0.08 })
		helpers.assert_eq(#sent, 0, "nothing may go out while the Cmd+V is still outstanding")

		-- The OS returns our own Cmd+V through the tap within a millisecond and the
		-- keyboard handler drains the counter. That proves the Cmd+V was POSTED. It
		-- says nothing about whether the target has read the pasteboard yet.
		state.expected_synthetic_pastes = 0
		Replay.flush_if_delivered()
		helpers.assert_eq(#sent, 0,
			"our own echo is not evidence the paste landed: releasing on it puts Enter ahead of "
				.. "the text by the whole settle window, which is the race this gate exists to close")

		fire_timers(timers, 0.08)
		helpers.assert_eq(#sent, 1,
			"the terminator goes out when the SECOND of the two conditions is met, not the first")
	end)

	helpers.it("still bounds the wait: the watchdog releases a terminator whose fence never opens", function()
		local Replay, sent, timers, state = load_gate()
		state.expected_synthetic_deletes = 0
		state.expected_synthetic_chars   = "\r"
		state.expected_synthetic_pastes  = 0

		Replay.arm({ kind = "key", key = "return", chars = "\r", echo_bytes = 1, min_delay = 0.08 })
		-- Fire ONLY the watchdog, never the fence: late is recoverable, lost is not,
		-- so adding a second condition must not create a way to hold Enter forever.
		fire_timers(timers, 0.25)
		helpers.assert_eq(#sent, 1, "the watchdog must still be able to release the terminator")
	end)

end)




-- ==========================================================
-- ==========================================================
-- ======= 5/ Fail Fast On A Malformed Queue ================
-- ==========================================================
-- ==========================================================

helpers.describe("terminator replay: invalid arm requests are refused loudly", function()

	helpers.it("refuses a spec with no characters", function()
		local Replay, sent = load_gate()
		helpers.assert_eq(Replay.arm({ kind = "key", key = "return", chars = "" }), false,
			"an empty terminator is a caller bug and must be reported, not queued")
		helpers.assert_eq(#sent, 0)
		helpers.assert_true(not Replay.is_pending())
	end)

	helpers.it("refuses a key spec with no key name", function()
		local Replay = load_gate()
		helpers.assert_eq(Replay.arm({ kind = "key", chars = "\r" }), false,
			"there is no sane default key to guess here")
	end)

	helpers.it("refuses an unknown kind", function()
		local Replay = load_gate()
		helpers.assert_eq(Replay.arm({ kind = "chord", chars = "\r" }), false)
	end)

end)


-- Restore the real adapters for the files that run after this one.
package.loaded["adapters.text_sender"]        = nil
package.loaded["adapters.timer_scheduler"]    = nil
package.loaded["modules.keymap.terminator_replay"] = nil
