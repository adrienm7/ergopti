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
--- 2. Watchdog: a terminal transaction whose completion callback never arrives
---    must not cost the user their Enter. A plan-aware timer repairs that lost
---    callback, but cannot overtake a transaction that is still delivering.
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

--- Canonical margin added after the replacement's immutable dispatch plan and
--- target-settle delay. The watchdog repairs a lost completion callback only;
--- it never authorizes a terminator to overtake an unfinished transaction.
local REPLAY_WATCHDOG_MARGIN_SEC = 0.25

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
---          min_delay = number, dispatch_budget = number,
---          fence_delay = number, watchdog_delay = number,
---          watchdog = handle|nil }
local _pending = nil

--- Exact TimerScheduler handles whose native stop refused. Identity fences make
--- their queued callbacks inert, but ownership remains here until a later
--- lifecycle boundary successfully retries the same capability.
local _timer_cleanup = {}
local PREPARED_MARKER = {}


local function retain_timer_cleanup(handle)
	if type(handle) ~= "table" or handle.timer == nil then return end
	for _, existing in ipairs(_timer_cleanup) do
		if existing == handle then return end
	end
	_timer_cleanup[#_timer_cleanup + 1] = handle
end


local function cancel_owned_timer(handle)
	if type(handle) ~= "table" or handle.timer == nil then return true end
	local ok_cancel, settled_or_error = pcall(TimerScheduler.cancel, handle)
	if ok_cancel and settled_or_error == true then return true end
	retain_timer_cleanup(handle)
	Logger.error(LOG, "Terminator timer cleanup remains pending: %s.",
		tostring(settled_or_error))
	return false
end


local function retry_timer_cleanup()
	if #_timer_cleanup == 0 then return true end
	local remaining = {}
	for _, handle in ipairs(_timer_cleanup) do
		local ok_cancel, settled = pcall(TimerScheduler.cancel, handle)
		if not ok_cancel or settled ~= true then remaining[#remaining + 1] = handle end
	end
	_timer_cleanup = remaining
	return #remaining == 0
end


local function acquire_timer(delay, callback, label)
	retry_timer_cleanup()
	local ok_schedule, handle_or_error, committed = pcall(TimerScheduler.after, delay, callback)
	if ok_schedule and committed == true
		and type(handle_or_error) == "table" and handle_or_error.timer ~= nil then
		return handle_or_error, true
	end
	if type(handle_or_error) == "table" then cancel_owned_timer(handle_or_error) end
	Logger.error(LOG, "Cannot arm %s timer: %s.", label,
		tostring(ok_schedule and "scheduler returned no committed handle" or handle_or_error))
	return nil, false
end


--- Acquires one recurring liveness owner. Unlike a chain of one-shot timers,
--- the already-committed native handle remains autonomous after an early tick;
--- no later lifecycle callback is required to rearm it.
--- @param interval number Seconds between liveness checks.
--- @param callback function Zero-argument callback.
--- @param label string Diagnostic timer label.
--- @return table|nil handle
--- @return boolean committed
local function acquire_recurring_timer(interval, callback, label)
	retry_timer_cleanup()
	local ok_schedule, handle_or_error, committed = pcall(
		TimerScheduler.every, interval, callback)
	if ok_schedule and committed == true
		and type(handle_or_error) == "table" and handle_or_error.timer ~= nil then
		return handle_or_error, true
	end
	if type(handle_or_error) == "table" then cancel_owned_timer(handle_or_error) end
	Logger.error(LOG, "Cannot arm %s timer: %s.", label,
		tostring(ok_schedule and "scheduler returned no committed handle" or handle_or_error))
	return nil, false
end


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
	local handle, committed = acquire_timer(delay, function()
		if _pending ~= pending then return end
		pending.retry = nil
		emit_pending("retry after " .. reason, false)
	end, "terminator replay retry")
	if committed then
		pending.retry = handle
		return
	end
	pending.retry = nil
	if not quiet then
		Logger.error(LOG, "Cannot schedule terminator replay retry after %s.", tostring(reason))
	end
end


--- Builds the pending terminator atomically and clears it only after commit.
--- @param reason string Why the replay fired (log context).
--- @param quiet boolean|nil Suppress synchronous diagnostics on an eventtap path.
--- @return boolean True only when the replay transaction was sealed.
emit_pending = function(reason, quiet)
	local pending = _pending
	if not pending then return false end
	if pending.reservation then
		if pending.activated == true then return true end
		local activated_ok, activated_or_error = pcall(
			SyntheticInput.activate_reserved_successor, pending.reservation)
		if not activated_ok or activated_or_error ~= true then
			if not quiet then
				Logger.error(LOG, "Reserved terminator activation failed (%s): %s.",
					reason, tostring(activated_or_error))
			end
			return false
		end
		pending.activated = true
		if pending.watchdog then
			cancel_owned_timer(pending.watchdog)
			pending.watchdog = nil
		end
		if pending.fence then
			cancel_owned_timer(pending.fence)
			pending.fence = nil
		end
		if pending.retry then
			cancel_owned_timer(pending.retry)
			pending.retry = nil
		end
		if not quiet then Logger.done(LOG, "Terminator replay activated (%s).", reason) end
		return true
	end

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
		cancel_owned_timer(pending.watchdog)
		pending.watchdog = nil
	end
	if pending.fence then
		cancel_owned_timer(pending.fence)
		pending.fence = nil
	end
	if pending.retry then
		cancel_owned_timer(pending.retry)
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
--- @return boolean committed True only when replay state is ready.
function M.init(core_state)
	Logger.start(LOG, "Initializing terminator replay…")
	if type(core_state) ~= "table" then
		Logger.error(LOG, "M.init(): core_state must be a table (got %s) — module non-functional.",
			type(core_state))
		return false
	end
	if _state then
		if _state == core_state then
			Logger.warn(LOG, "M.init() called more than once with the active state — ignoring duplicate call.")
			return true
		end
		Logger.error(LOG, "M.init(): a different state is already active — replacement refused.")
		return false
	end
	_state = core_state
	Logger.success(LOG, "Terminator replay initialized.")
	return true
end


--- Queues a terminator to be replayed once the replacement has landed.
---
--- @param spec table { kind = "key"|"text", key?: string, chars: string,
---   transaction: table, min_delay?: number, dispatch_budget?: number }
--- @return table|nil Prepared replay owner, or nil on refusal.
function M.prepare(spec)
	if not require_state("prepare") then return nil end
	if type(spec) ~= "table" or type(spec.chars) ~= "string" or spec.chars == "" then
		Logger.error(LOG, "arm(): invalid spec — terminator NOT queued, it would be lost.")
		return nil
	end
	if spec.kind ~= "key" and spec.kind ~= "text" then
		Logger.error(LOG, "arm(): unknown kind '%s' — terminator NOT queued.", tostring(spec.kind))
		return nil
	end
	if spec.kind == "key" and type(spec.key) ~= "string" then
		Logger.error(LOG, "arm(): kind='key' requires a key name — terminator NOT queued.")
		return nil
	end

	-- A second expansion must never sink an earlier terminator behind its own
	-- replacement: flush what is already waiting before taking ownership.
	if _pending then
		emit_pending("superseded by a new expansion")
		if _pending then
			Logger.error(LOG, "arm(): prior terminator is still pending — refusing to overwrite it.")
			return nil
		end
	end

	if type(spec.transaction) ~= "table" then
		-- Returning false tells the raw callback to pass its physical terminator
		-- through. Synthesizing here as well would create a delayed duplicate.
		Logger.error(LOG, "arm(): replacement transaction missing — terminator ownership refused.")
		return nil
	end

	local min_delay = tonumber(spec.min_delay) or 0
	local dispatch_budget = tonumber(spec.dispatch_budget) or 0
	if min_delay < 0 or min_delay ~= min_delay
		or dispatch_budget < 0 or dispatch_budget ~= dispatch_budget then
		Logger.error(LOG, "arm(): delay plan is invalid — terminator NOT queued.")
		return nil
	end
	local fence_delay = min_delay > 0 and (dispatch_budget + min_delay) or 0
	local watchdog_delay = dispatch_budget + min_delay + REPLAY_WATCHDOG_MARGIN_SEC
	local pending = {
		_marker     = PREPARED_MARKER,
		kind       = spec.kind,
		key        = spec.key,
		chars      = spec.chars,
		transaction = spec.transaction,
		transaction_complete = false,
		min_delay  = min_delay,
		dispatch_budget = dispatch_budget,
		fence_delay = fence_delay,
		watchdog_delay = watchdog_delay,
		-- Declared here rather than left implicit: replacement_has_landed() reads
		-- fence_open, and a field that only ever exists on one code path is how a
		-- predicate ends up depending on nil-versus-false by accident.
		fence_open = false,
		fence      = nil,
	}

	-- Acquire every timer before publishing the pending record or consuming the
	-- physical terminator. A refused watchdog/fence is therefore a complete
	-- rollback: the caller can pass the original key through with no hidden owner.
	local watchdog, watchdog_committed = acquire_recurring_timer(watchdog_delay, function()
		if _pending ~= pending then return end
		-- A fixed timeout cannot prove ordering: paced target posts may legitimately
		-- retry beyond their nominal plan. The recurring owner remains live after an
		-- early tick and polls only the transaction's exact terminal truth.
		if pending.transaction.completed == true then
			if pending.transaction.completion_status == "complete" then
				pending.transaction_complete = true
				M.flush_if_delivered()
			else
				M.cancel_prepared(pending)
			end
			return
		end
		if pending.watchdog_warned ~= true then
			pending.watchdog_warned = true
			Logger.warn(LOG,
			"Replacement remains non-terminal after %.2fs — terminator stays owned.",
				watchdog_delay)
		end
	end, "terminator replay watchdog")
	if not watchdog_committed then return nil end
	pending.watchdog = watchdog

	if pending.fence_delay > 0 then
		local fence, fence_committed = acquire_timer(pending.fence_delay, function()
			if _pending ~= pending then return end
			pending.fence_open = true
			pending.fence      = nil
			M.flush_if_delivered()
		end, "terminator replay settle fence")
		if not fence_committed then
			cancel_owned_timer(pending.watchdog)
			pending.watchdog = nil
			return nil
		end
		pending.fence = fence
	end

	local reservation_ok, reservation_or_error = pcall(
		SyntheticInput.prepare_reserved_successor,
		pending.transaction,
		function()
			if pending.kind == "key" then
				return TextSender.pressKey(pending.key, nil, REPLAY_KEY_DELAY)
			end
			return TextSender.send(pending.chars, { mode = "direct" })
		end,
		spec.target_app)
	if not reservation_ok or type(reservation_or_error) ~= "table" then
		cancel_owned_timer(pending.watchdog)
		if pending.fence then cancel_owned_timer(pending.fence) end
		Logger.error(LOG, "arm(): terminator reservation failed: %s.",
			tostring(reservation_or_error))
		return nil
	end
	pending.reservation = reservation_or_error

	local reserved_registered, reserved_registration_error = pcall(
		SyntheticInput.on_reserved_complete, pending.reservation,
		function(_transaction, status)
			if _pending ~= pending then return end
			_pending = nil
			pending._marker = nil
			if pending.watchdog then cancel_owned_timer(pending.watchdog) end
			if pending.fence then cancel_owned_timer(pending.fence) end
			if pending.retry then cancel_owned_timer(pending.retry) end
			if status == "complete" then
				Logger.done(LOG, "Terminator replay completed.")
			else
				Logger.error(LOG, "Terminator replay ended with status '%s'.", tostring(status))
			end
		end)
	if not reserved_registered then
		pcall(SyntheticInput.cancel_reserved_successor, pending.reservation)
		cancel_owned_timer(pending.watchdog)
		if pending.fence then cancel_owned_timer(pending.fence) end
		Logger.error(LOG, "arm(): reserved completion registration failed: %s.",
			tostring(reserved_registration_error))
		return nil
	end

	-- Completion is generation-bound. A delayed callback from an older
	-- replacement can only update its own pending object and is ignored after a
	-- superseding arm/forced flush.
	local registered, registration_error = pcall(SyntheticInput.on_complete,
		pending.transaction, function(_transaction, status)
		if _pending ~= pending then return end
		if status ~= "complete" then
			M.cancel_prepared(pending)
			return
		end
		pending.transaction_complete = true
		M.flush_if_delivered()
	end)
	if not registered then
		pcall(SyntheticInput.cancel_reserved_successor, pending.reservation)
		cancel_owned_timer(pending.watchdog)
		if pending.fence then cancel_owned_timer(pending.fence) end
		Logger.error(LOG, "arm(): replacement completion registration failed: %s.",
			tostring(registration_error))
		return nil
	end

	-- A paste-backed expansion has no target-delivery callback: the target
	-- reads the clipboard on its own schedule, so the settle delay the emitter
	-- reported is added after the paced dispatch budget. Opening a FENCE rather
	-- than emitting directly means transaction completion and the target timer
	-- agree on when the replacement has landed: whichever arrives second releases
	-- the terminator instead of a long delete prefix consuming the settle window.
	if pending.min_delay > 0 then
		return pending
	end

	-- on_complete() always dispatches after the originating eventtap has returned,
	-- including for an already-complete transaction. It performs the only release
	-- attempt; an eager flush here would either run too early or duplicate failure.
	return pending
end


--- Publishes a fully prepared terminator owner using memory-only operations.
--- @param pending table Owner returned by prepare().
--- @return boolean authorized
function M.authorize_prepared(pending)
	assert(type(pending) == "table" and pending._marker == PREPARED_MARKER,
		"terminator_replay.authorize_prepared(): invalid owner")
	assert(_pending == nil,
		"terminator_replay.authorize_prepared(): another terminator is pending")
	assert(SyntheticInput.authorize_reserved_successor(pending.reservation) == true,
		"terminator_replay.authorize_prepared(): reservation authorization failed")
	pending.authorized = true
	return true
end


--- Publishes an authorized terminator owner using memory-only operations.
--- @param pending table Owner authorized by authorize_prepared().
--- @return boolean committed
function M.commit_prepared(pending)
	SyntheticInput.commit_reserved_successor(pending.reservation)
	_pending = pending
	pending.committed = true
	return true
end


--- Revokes an uncommitted/committed prepared owner without replaying it.
--- @param pending table Owner returned by prepare().
--- @return boolean cancelled
function M.cancel_prepared(pending)
	if type(pending) ~= "table" or pending._marker ~= PREPARED_MARKER then return false end
	if _pending == pending then _pending = nil end
	if pending.reservation then
		pcall(SyntheticInput.cancel_reserved_successor, pending.reservation)
	end
	pending._marker = nil
	if pending.watchdog then cancel_owned_timer(pending.watchdog); pending.watchdog = nil end
	if pending.fence then cancel_owned_timer(pending.fence); pending.fence = nil end
	if pending.retry then cancel_owned_timer(pending.retry); pending.retry = nil end
	return true
end


--- Compatibility one-shot API for non-transactional callers and existing tests.
--- @param spec table Terminator descriptor.
--- @return boolean queued
function M.arm(spec)
	local pending = M.prepare(spec)
	if not pending then return false end
	if M.authorize_prepared(pending) ~= true then
		M.cancel_prepared(pending)
		return false
	end
	return M.commit_prepared(pending)
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
	if _pending.reservation then
		_pending.transaction_complete = true
		_pending.fence_open = true
	end
	return emit_pending(reason or "forced", quiet == true)
end


--- Revokes a pending terminator without replaying it.
---
--- A focus/title ownership change makes the original target unknowable. Sending
--- the key late is worse than dropping it because it can submit or mutate data in
--- a different application. The pending identity is cleared before touching any
--- timer; every watchdog/fence/completion callback already compares that exact
--- object and therefore becomes inert even when native cancellation fails.
--- @param reason string|nil Log context.
--- @param quiet boolean|nil When true, perform only O(1) Lua state work (eventtap).
--- @return boolean True when a pending replay was revoked.
function M.discard_pending(reason, quiet)
	local pending = _pending
	if not pending then return false end
	if pending.reservation then
		local cancel_ok, cancelled = pcall(
			SyntheticInput.cancel_reserved_successor, pending.reservation)
		if not cancel_ok or cancelled ~= true then
			if quiet ~= true then
				Logger.warn(LOG, "Pending terminator already crossed its replay boundary (%s).",
					reason or "ownership changed")
			end
			return false
		end
	end
	_pending = nil
	if quiet ~= true then
		if pending.watchdog then cancel_owned_timer(pending.watchdog) end
		if pending.fence then cancel_owned_timer(pending.fence) end
		if pending.retry then cancel_owned_timer(pending.retry) end
		Logger.debug(LOG, "Pending terminator discarded (%s).", reason or "ownership changed")
	else
		retain_timer_cleanup(pending.watchdog)
		retain_timer_cleanup(pending.fence)
		retain_timer_cleanup(pending.retry)
	end
	return true
end


--- Returns true while a terminator is waiting to be replayed.
--- @return boolean
function M.is_pending()
	return _pending ~= nil
end



return M
