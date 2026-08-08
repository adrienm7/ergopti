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
--- 1. Transaction-gated replay: every replacement event belongs to one tagged
---    transaction. Completion runs only after each callback-return batch has
---    been handed to Quartz, so a subsequently dispatched terminator is ordered
---    behind it without matching mutable character queues.
--- 2. Watchdog: a batch whose completion callback never arrives must never cost
---    the user their Enter. A bounded timer replays it anyway and says so in the
---    log.
--- 3. Ordering across expansions: arming a second replay flushes the first, so
---    a chained autocorrection can never sink an earlier terminator behind its
---    own replacement.
--- ==============================================================================

local M = {}

local Logger         = require("infra.logger")
local TextSender     = require("adapters.text_sender")
local TimerScheduler = require("adapters.timer_scheduler")
local SyntheticInput = require("adapters.synthetic_input")

local LOG = "keymap.terminator_replay"




-- =========================================
-- =========================================
-- ======= 1/ Constants & State ============
-- =========================================
-- =========================================

--- Upper bound on how long a pending terminator waits for replacement transaction
--- completion before it is replayed regardless. This is a lost-callback escape
--- hatch, not a pacing delay, and it is deliberately short: the user pressed
--- Enter and is waiting for it.
local REPLAY_WATCHDOG_SEC = 0.25

--- Inter-key delay handed to the send adapters. Zero mirrors every other
--- injection site in the driver; the adapter default is a BLOCKING sleep on the
--- run loop that services the typing tap, so it is never left implicit.
local REPLAY_KEY_DELAY = 0

-- A failed event construction is retried off the input callback until the
-- adapter recovers. The delay backs off to avoid a tight loop while preserving
-- the pending terminator instead of silently declaring it delivered.
local REPLAY_RETRY_BASE_SEC = 0.05
local REPLAY_RETRY_MAX_SEC  = 1.0

--- Shared CoreState injected via M.init(); nil until then.
local _state = nil

--- The terminator waiting to be replayed, or nil when nothing is pending.
--- Shape: { kind = "key"|"text", key = string|nil, chars = string,
---          transaction = table, transaction_complete = boolean,
---          min_delay = number, watchdog = handle|nil }
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

--- Reports whether every tagged batch in the replacement transaction has been
--- handed to Quartz before the pending terminator is emitted.
---
--- The settle fence is part of this predicate, not an alternative to it. On the
--- paste path, dispatch proves the tagged Cmd+V was posted, never that the target
--- read the pasteboard. The emitter's settle delay therefore remains mandatory.
--- @return boolean True when replay is ordered behind the replacement dispatch.
local function replacement_is_ordered()
	if not _pending.transaction_complete then return false end
	if _pending.min_delay > 0 and not _pending.fence_open then return false end
	return true
end


local emit_pending


--- Arms one bounded-backoff retry without replacing an existing retry.
--- @param pending table Pending replay record.
--- @param reason string Original delivery reason.
--- @param quiet boolean|nil Suppress synchronous diagnostics on an eventtap path.
local function schedule_retry(pending, reason, quiet)
	if pending.retry and pending.retry.timer then return end
	pending.retry_attempt = (pending.retry_attempt or 0) + 1
	local delay = math.min(REPLAY_RETRY_BASE_SEC * (2 ^ (pending.retry_attempt - 1)),
		REPLAY_RETRY_MAX_SEC)
	local ok, handle_or_err = pcall(TimerScheduler.after, delay, function()
		if _pending ~= pending then return end
		pending.retry = nil
		emit_pending("retry after " .. reason, false)
	end)
	if ok and type(handle_or_err) == "table" and handle_or_err.timer ~= nil then
		pending.retry = handle_or_err
		return
	end
	pending.retry = nil
	if not quiet then
		Logger.error(LOG, "Cannot schedule terminator replay retry: %s.",
			tostring(ok and "timer unavailable" or handle_or_err))
	end
end


--- Builds the pending terminator atomically and clears it only after commit.
--- @param reason string Why the replay fired (log context).
--- @param quiet boolean|nil Suppress synchronous diagnostics on an eventtap path.
--- @return boolean True only when the replay transaction was sealed.
emit_pending = function(reason, quiet)
	local pending = _pending
	if not pending then return false end

	local transaction = SyntheticInput.begin("terminator_replay", "replacement")
	local built, build_err = pcall(SyntheticInput.with_transaction, transaction, function()
		if pending.kind == "key" then
			assert(TextSender.pressKey(pending.key, nil, REPLAY_KEY_DELAY) ~= false,
				"terminator key could not be constructed")
		else
			assert(TextSender.send(pending.chars, { mode = "direct" }) ~= false,
				"terminator text could not be constructed")
		end
	end)
	if not built then
		pcall(SyntheticInput.cancel, transaction)
		if not quiet then
			Logger.error(LOG, "Terminator replay construction failed (%s): %s.",
				reason, tostring(build_err))
		end
		schedule_retry(pending, reason, quiet)
		return false
	end
	local sealed, seal_err = pcall(SyntheticInput.seal, transaction)
	if not sealed then
		pcall(SyntheticInput.cancel, transaction)
		if not quiet then
			Logger.error(LOG, "Terminator replay commit failed (%s): %s.",
				reason, tostring(seal_err))
		end
		schedule_retry(pending, reason, quiet)
		return false
	end

	_pending = nil
	if pending.watchdog then
		TimerScheduler.cancel(pending.watchdog)
		pending.watchdog = nil
	end
	if pending.fence then
		TimerScheduler.cancel(pending.fence)
		pending.fence = nil
	end
	if pending.retry then
		TimerScheduler.cancel(pending.retry)
		pending.retry = nil
	end
	if not quiet then Logger.done(LOG, "Terminator replayed (%s).", reason) end
	return true
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
--- @param spec table { kind = "key"|"text", key?: string, chars: string,
---   transaction: table, min_delay?: number }
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
	if _pending and not emit_pending("superseded by a new expansion") then
		Logger.error(LOG, "arm(): prior terminator is still pending — refusing to overwrite it.")
		return false
	end

	if type(spec.transaction) ~= "table" then
		Logger.error(LOG, "arm(): replacement transaction missing — replaying immediately for safety.")
		_pending = {
			kind = spec.kind, key = spec.key, chars = spec.chars,
			transaction_complete = true, min_delay = 0, fence_open = true,
		}
		emit_pending("missing replacement transaction")
		return false
	end

	_pending = {
		kind       = spec.kind,
		key        = spec.key,
		chars      = spec.chars,
		transaction = spec.transaction,
		transaction_complete = false,
		min_delay  = tonumber(spec.min_delay) or 0,
		-- Declared here rather than left implicit: replacement_has_landed() reads
		-- fence_open, and a field that only ever exists on one code path is how a
		-- predicate ends up depending on nil-versus-false by accident.
		fence_open = false,
		fence      = nil,
	}
	Logger.trace(LOG, "Terminator held pending delivery of the replacement…")

	-- Armed FIRST so a synchronous flush below still finds the handle and
	-- cancels it; arming it afterwards would leave an orphan timer that fires
	-- into an empty slot.
	local pending = _pending
	pending.watchdog = TimerScheduler.after(REPLAY_WATCHDOG_SEC, function()
		if _pending ~= pending then return end
		Logger.warn(LOG,
			"Replacement transaction did not complete within %.2fs — replaying the terminator anyway.",
			REPLAY_WATCHDOG_SEC)
		pending.watchdog = nil
		emit_pending("watchdog")
	end)

	-- Completion is generation-bound. A delayed callback from an older
	-- replacement can only update its own pending object and is ignored after a
	-- superseding arm/forced flush.
	SyntheticInput.on_complete(pending.transaction, function()
		if _pending ~= pending then return end
		pending.transaction_complete = true
		M.flush_if_delivered()
	end)

	-- A paste-backed expansion has no target-delivery callback: the target
	-- reads the clipboard on its own schedule, so the settle delay the emitter
	-- reported is the only honest lower bound. Opening a FENCE rather than
	-- emitting directly means the echo path and the timer path agree on when the
	-- replacement has landed: whichever arrives second releases the terminator,
	-- instead of the echo racing past a fence it could not see.
	if pending.min_delay > 0 then
		pending.fence_open = false
		pending.fence = TimerScheduler.after(pending.min_delay, function()
			if _pending ~= pending then return end
			pending.fence_open = true
			pending.fence      = nil
			-- Dispatch may already be complete, in which case this is the
			-- second of the two conditions and the terminator goes now.
			M.flush_if_delivered()
		end)
		return true
	end

	-- on_complete() always dispatches after the originating eventtap has returned,
	-- including for an already-complete transaction. It performs the only release
	-- attempt; an eager flush here would either run too early or duplicate failure.
	return true
end


--- Replays the pending terminator when its replacement transaction and optional
--- clipboard settle fence have both completed.
--- @return boolean True when a terminator was replayed by this call.
function M.flush_if_delivered()
	if not _pending then return false end
	if not require_state("flush_if_delivered") then return false end
	if not replacement_is_ordered() then return false end
	return emit_pending("replacement transaction complete")
end


--- Replays the pending terminator immediately, without waiting for any echo.
--- Used where echoes are structurally unobservable (a window the driver does
--- not track) and before teardown, so a held Enter is never simply dropped.
--- @param reason string|nil Log context.
--- @param quiet boolean|nil Suppress logger sinks when called from CGEventTap.
--- @return boolean True when a terminator was replayed by this call.
function M.flush_now(reason, quiet)
	if not _pending then return false end
	return emit_pending(reason or "forced", quiet == true)
end


--- Returns true while a terminator is waiting to be replayed.
--- @return boolean
function M.is_pending()
	return _pending ~= nil
end



return M
