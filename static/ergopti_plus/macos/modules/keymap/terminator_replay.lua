--- modules/keymap/terminator_replay.lua

--- ==============================================================================
--- MODULE: Keymap Terminator Replay
--- DESCRIPTION:
--- Holds the terminator keystroke that ended a hotstring (Enter, Tab, or a
--- printable character such as space or a comma) until the replacement text it
--- terminates has provably reached the target application, then replays it.
---
--- WHY THIS EXISTS:
--- The expander consumes the physical terminator so the trigger and the
--- terminator can be erased together, then re-emits it after the replacement.
--- Re-emitting it inline assumed that a raw key event posted immediately after
--- a text injection is delivered after that text. It is not: the replacement
--- travels through the text-input pipeline (a unicode-string key event, or a
--- clipboard paste the target reads back asynchronously) while Enter and Tab
--- travel as raw key events that many hosts action immediately. The window
--- between the two is where the driver lost "ui" + Enter: the Enter submitted
--- the pre-expansion content — sometimes after the trigger had already been
--- erased, so the host received an empty line.
---
--- Enter and Tab are also the two terminators whose side effects are
--- irreversible: they send the message, submit the form, or move focus away.
--- Getting their ORDER wrong is not a cosmetic defect, it is data loss.
---
--- FEATURES & RATIONALE:
--- 1. Delivery-gated replay: the driver already tracks every synthetic event it
---    injects so it can ignore its own echo. That same bookkeeping is the proof
---    we need — once the deletes, the pasted payload and the replacement's own
---    echo have all come back through the keyboard tap, the replacement is
---    ahead of anything we post next, and the terminator is safe to send.
--- 2. Watchdog: an echo that never arrives (a host that swallows it, a tap the
---    OS disabled, a window the driver does not observe) must never cost the
---    user their Enter. A bounded timer replays it anyway and says so in the log.
--- 3. Ordering across expansions: arming a second replay flushes the first, so
---    a chained autocorrection can never sink an earlier terminator behind its
---    own replacement.
--- ==============================================================================

local M = {}

local Logger         = require("lib.logger")
local TextSender     = require("adapters.text_sender")
local TimerScheduler = require("adapters.timer_scheduler")

local LOG = "keymap.terminator_replay"




-- =========================================
-- =========================================
-- ======= 1/ Constants & State ============
-- =========================================
-- =========================================

--- Upper bound on how long a pending terminator waits for the replacement's
--- echo before it is replayed regardless. Echoes normally return within a few
--- milliseconds — this is a lost-echo escape hatch, not a pacing delay, and it
--- is deliberately short: the user pressed Enter and is waiting for it.
local REPLAY_WATCHDOG_SEC = 0.25

--- Inter-key delay handed to the send adapters. Zero mirrors every other
--- injection site in the driver; the adapter default is a BLOCKING sleep on the
--- run loop that services the typing tap, so it is never left implicit.
local REPLAY_KEY_DELAY = 0

--- Shared CoreState injected via M.init(); nil until then.
local _state = nil

--- The terminator waiting to be replayed, or nil when nothing is pending.
--- Shape: { kind = "key"|"text", key = string|nil, chars = string,
---          echo_bytes = number, min_delay = number, watchdog = handle|nil }
local _pending = nil


--- Guard: verifies M.init() ran before any public function that needs state.
--- @param func_name string Name of the calling function (for error messages).
--- @return boolean True when the dependencies are ready.
local function require_state(func_name)
	if not _state then
		Logger.error(LOG, "'%s' called before M.init() — shared state not initialized.", func_name)
		return false
	end
	return true
end




-- =========================================
-- =========================================
-- ======= 2/ Delivery Accounting ==========
-- =========================================
-- =========================================

--- Reports whether every synthetic event injected BEFORE the pending
--- terminator has echoed back through the keyboard tap.
---
--- The terminator's own echo is already armed in expected_synthetic_chars by
--- the expansion that queued it (the keylogger's synthetic accounting is fed
--- once, up front, for the whole expansion). It has not been sent yet, so it is
--- still outstanding — which is why the test is "nothing but my own echo is
--- left", not "the expectation is empty".
--- @return boolean True when the replacement has provably landed.
local function replacement_has_landed()
	if (_state.expected_synthetic_deletes or 0) > 0 then return false end
	if (_state.expected_synthetic_pastes  or 0) > 0 then return false end
	return #(_state.expected_synthetic_chars or "") <= _pending.echo_bytes
end


--- Posts the pending terminator and clears the pending slot.
--- @param reason string Why the replay fired (log context).
local function emit_pending(reason)
	local pending = _pending
	_pending = nil
	if not pending then return end

	if pending.watchdog then
		TimerScheduler.cancel(pending.watchdog)
		pending.watchdog = nil
	end

	if pending.kind == "key" then
		TextSender.pressKey(pending.key, nil, REPLAY_KEY_DELAY)
	else
		TextSender.send(pending.chars, { mode = "direct" })
	end
	Logger.done(LOG, "Terminator replayed (%s).", reason)
end




-- =========================================
-- =========================================
-- ======= 3/ Public API ===================
-- =========================================
-- =========================================

--- Initializes the module with the shared CoreState.
--- @param core_state table The shared state object from keymap/init.lua.
function M.init(core_state)
	Logger.start(LOG, "Initializing terminator replay…")
	if type(core_state) ~= "table" then
		Logger.error(LOG, "M.init(): core_state must be a table (got %s) — module non-functional.",
			type(core_state))
		return
	end
	if _state then
		Logger.warn(LOG, "M.init() called more than once — ignoring duplicate call.")
		return
	end
	_state = core_state
	Logger.success(LOG, "Terminator replay initialized.")
end


--- Queues a terminator to be replayed once the replacement has landed.
---
--- `echo_bytes` is the byte length this terminator will contribute to
--- expected_synthetic_chars when it finally fires. Key terminators that carry a
--- character back through the tap (Enter echoes CR, Tab echoes HT) contribute
--- their echo; a terminator whose expansion pasted its replacement contributes
--- nothing extra beyond what the caller already armed.
---
--- @param spec table { kind = "key"|"text", key?: string, chars: string,
---   echo_bytes?: number, min_delay?: number }
--- @return boolean True when the replay was queued.
function M.arm(spec)
	if not require_state("arm") then return false end
	if type(spec) ~= "table" or type(spec.chars) ~= "string" or spec.chars == "" then
		Logger.error(LOG, "arm(): invalid spec — terminator NOT queued, it would be lost.")
		return false
	end
	if spec.kind ~= "key" and spec.kind ~= "text" then
		Logger.error(LOG, "arm(): unknown kind '%s' — terminator NOT queued.", tostring(spec.kind))
		return false
	end
	if spec.kind == "key" and type(spec.key) ~= "string" then
		Logger.error(LOG, "arm(): kind='key' requires a key name — terminator NOT queued.")
		return false
	end

	-- A second expansion must never sink an earlier terminator behind its own
	-- replacement: flush what is already waiting before taking ownership.
	if _pending then emit_pending("superseded by a new expansion") end

	_pending = {
		kind       = spec.kind,
		key        = spec.key,
		chars      = spec.chars,
		echo_bytes = tonumber(spec.echo_bytes) or #spec.chars,
		min_delay  = tonumber(spec.min_delay) or 0,
	}
	Logger.trace(LOG, "Terminator held pending delivery of the replacement…")

	-- Armed FIRST so a synchronous flush below still finds the handle and
	-- cancels it; arming it afterwards would leave an orphan timer that fires
	-- into an empty slot.
	local pending = _pending
	pending.watchdog = TimerScheduler.after(REPLAY_WATCHDOG_SEC, function()
		if _pending ~= pending then return end
		Logger.warn(LOG,
			"Replacement echo never returned within %.2fs — replaying the terminator anyway.",
			REPLAY_WATCHDOG_SEC)
		pending.watchdog = nil
		emit_pending("watchdog")
	end)

	-- A paste-backed expansion has no per-character echo to wait on: the target
	-- reads the clipboard on its own schedule, so the only honest gate is the
	-- settle delay the emitter reported.
	if pending.min_delay > 0 then
		TimerScheduler.after(pending.min_delay, function()
			if _pending == pending then emit_pending("paste settled") end
		end)
		return true
	end

	-- Deletes and text are posted before arm() is reached, so an expansion whose
	-- echoes were already accounted for (or that emitted nothing at all) is
	-- ready immediately and must not wait for a keystroke that may never come.
	M.flush_if_delivered()
	return true
end


--- Replays the pending terminator when the replacement has provably landed.
--- Called from the keyboard handler at each point where a synthetic echo is
--- consumed, which is the only moment the answer can change.
--- @return boolean True when a terminator was replayed by this call.
function M.flush_if_delivered()
	if not _pending then return false end
	if not require_state("flush_if_delivered") then return false end
	if not replacement_has_landed() then return false end
	emit_pending("replacement echo complete")
	return true
end


--- Replays the pending terminator immediately, without waiting for any echo.
--- Used where echoes are structurally unobservable (a window the driver does
--- not track) and before teardown, so a held Enter is never simply dropped.
--- @param reason string|nil Log context.
--- @return boolean True when a terminator was replayed by this call.
function M.flush_now(reason)
	if not _pending then return false end
	emit_pending(reason or "forced")
	return true
end


--- Returns true while a terminator is waiting to be replayed.
--- @return boolean
function M.is_pending()
	return _pending ~= nil
end


--- Drops the pending terminator WITHOUT replaying it. Reserved for teardown
--- paths where injecting a keystroke would be worse than losing it; every
--- other caller wants flush_now().
function M.cancel()
	if not _pending then return end
	if _pending.watchdog then TimerScheduler.cancel(_pending.watchdog) end
	_pending = nil
	Logger.debug(LOG, "Pending terminator cancelled.")
end


return M
