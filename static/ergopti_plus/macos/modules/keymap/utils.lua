--- modules/keymap/utils.lua

--- ==============================================================================
--- MODULE: Keymap Utilities (Hammerspoon adapter)
--- DESCRIPTION:
--- Hammerspoon-specific keymap helpers layered on top of the shared pure-Lua
--- core from _shared/lua/keymap/utils.lua. Adds OS-level text emission
--- (simulated keystrokes and clipboard paste) and ignored-window detection,
--- which depend on hs.eventtap, hs.pasteboard, hs.timer, and hs.window.
---
--- FEATURES & RATIONALE:
--- 1. Safe Emission: Chooses between direct keystrokes or fast clipboard-paste
---    based on text length and unicode complexity, to handle any content reliably.
--- 2. Seamless LLM Integration: The overlap solver (re-exported from shared)
---    aligns the in-flight buffer with the AI completion to prevent ghost-text
---    duplication.
--- 3. Window Caching: Focus watchers invalidate a cached classification and an
---    off-eventtap refresh performs the expensive AX query.
--- ==============================================================================

local hs = hs
local M  = {}

local text_utils  = require("infra.text_utils")
local shared_utils = require("keymap.utils")
local Logger      = require("infra.logger")
local Timings     = require("infra.timings")
local TimerScheduler = require("adapters.timer_scheduler")
local SyntheticInput = require("adapters.synthetic_input")
local SecureFieldDetector = require("adapters.secure_field_detector")

local LOG = "keymap.utils"

-- Re-export pure-Lua functions from the shared module so callers that require
-- this HS adapter keep working unchanged without needing to know about the split.
M.tokens_from_repl          = shared_utils.tokens_from_repl
M.plain_text                = shared_utils.plain_text
M.resolve_prediction_overlap = shared_utils.resolve_prediction_overlap





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

-- Threshold (in UTF-8 characters) above which clipboard-paste is used instead of
-- simulated keystrokes. Pasting is faster and avoids issues with long strings.
local PASTE_THRESHOLD = 50

-- How long the clipboard is left with the pasted value before restoring the
-- user's previous contents. Large enough to let the target app receive the paste.
-- Shared cross-driver value ([debounce] clipboard_restore_ms).
local CLIPBOARD_RESTORE_SEC = Timings.sec("debounce", "clipboard_restore_ms")

-- Minimum gap enforced between two consecutive clipboard pastes emitted from the
-- same emit_tokens() call. CGEventPost is asynchronous, so issuing a second
-- setContents+Cmd+V pair back-to-back can overwrite the clipboard before the OS
-- has delivered the first paste to the target app, corrupting that first segment
-- (multi-segment-paste-race). Reuses the existing paste-settle value rather than
-- introducing a new duplicate constant ([debounce] clipboard_paste_settle_ms).
local CLIPBOARD_PASTE_GAP_SEC = Timings.sec("debounce", "clipboard_paste_settle_ms")

-- Safety TTL (seconds) for the ignored-window cache. The cache is normally
-- invalidated on focus-change events (hs.application.watcher + hs.window.filter),
-- so this long TTL only acts as a net in the unlikely case the watcher misses an
-- event. Keeping it large means near-zero syscalls per keystroke in steady state.
local IGNORED_WIN_TTL_SEC = 5.0

-- True while a deferred TTL refresh is already queued, so a burst of keystrokes
-- arms exactly one. Declared above the closure that clears it — a local declared
-- after a closure binds the nil global instead.
local _ignored_win_refresh_armed = false
local _ignored_win_refresh_handle = nil
local _ignored_win_ttl_handle = nil
local _ignored_win_refresh_generation = 0

-- Key tokens whose keydown carries a character through getCharacters()
-- ("return" -> CR, "tab" -> HT). The legacy physical_echo return value keeps
-- those characters for extension/telemetry compatibility; immutable event tags,
-- not this string, identify the OS callbacks. Nav/escape tokens ({Left},
-- {Delete}, {Esc}) have no character representation and remain absent.
local KEY_ECHO_CHARS = { ["return"] = "\r", ["tab"] = "\t" }





-- ==========================================
-- ==========================================
-- ======= 2/ Text Emission Utilities =======
-- ==========================================
-- ==========================================

-- Clipboard serialisation state for the paste path. Ownership is retained until
-- the exact all-type snapshot has been restored; a native false/nil result never
-- releases it. That matters after a failed restore: a later expansion must not
-- snapshot Ergopti's payload as if it were the user's clipboard.
local _paste_saved_original = nil
local _paste_pending_timer = nil
local _paste_timer_cleanup = nil
local _paste_owns_clipboard = false
local _paste_recovery_only = false
local _paste_generation = 0
-- A sealed retained synthetic transaction makes clipboard restoration part of
-- the same process-wide drain used by pause/reload/quit. It owns no Quartz
-- events; its sole terminal condition is restoration of the exact all-type
-- snapshot (or an explicit lifecycle refusal while that debt remains visible).
local _paste_debt_transaction = nil
local _paste_debt_token = nil


--- Acquires drain-visible ownership before the first clipboard mutation.
--- @return boolean acquired
--- @return any error_detail
local function acquire_paste_debt()
	if _paste_debt_transaction and _paste_debt_token
		and _paste_debt_token.active == true then return true, nil end
	local tx = nil
	local token = nil
	local ok, err = xpcall(function()
		tx = SyntheticInput.begin("clipboard_restore", "replacement")
		token = SyntheticInput.retain(tx)
		assert(SyntheticInput.seal(tx) == true,
			"clipboard debt transaction could not be sealed")
	end, debug.traceback)
	if not ok then
		if tx then pcall(SyntheticInput.cancel, tx) end
		return false, err
	end
	_paste_debt_transaction = tx
	_paste_debt_token = token
	return true, nil
end


--- Releases the exact drain debt only after the user's snapshot is restored.
--- @return boolean released
local function release_paste_debt()
	local tx = _paste_debt_transaction
	local token = _paste_debt_token
	if tx == nil or token == nil then return true end
	local ok, released_or_error = pcall(SyntheticInput.release, tx, token)
	if not ok or released_or_error ~= true then
		Logger.error(LOG, "Clipboard drain debt release failed: %s.",
			tostring(released_or_error))
		return false
	end
	_paste_debt_transaction = nil
	_paste_debt_token = nil
	return true
end

--- Cancels one exact scheduler handle without discarding stop-failure debt.
--- @param timer table TimerScheduler handle.
--- @return boolean settled
local function cancel_paste_timer(timer)
	local ok_cancel, settled_or_error = pcall(TimerScheduler.cancel, timer)
	if ok_cancel and settled_or_error == true then return true end
	if _paste_timer_cleanup == nil or _paste_timer_cleanup == timer then
		_paste_timer_cleanup = timer
	end
	Logger.error(LOG, "Clipboard timer cleanup remains pending: %s.",
		tostring(ok_cancel and settled_or_error or settled_or_error))
	return false
end

--- Retries the exact native timer retained after a stop refusal.
--- @return boolean settled
local function retry_paste_timer_cleanup()
	local cleanup = _paste_timer_cleanup
	if cleanup == nil then return true end
	if cancel_paste_timer(cleanup) ~= true then return false end
	if _paste_timer_cleanup == cleanup then _paste_timer_cleanup = nil end
	return true
end

--- Stops the active clipboard timer and retains any exact cleanup debt.
--- @return boolean settled
local function stop_paste_restore_timer()
	local pending = _paste_pending_timer
	_paste_pending_timer = nil
	if pending and cancel_paste_timer(pending) ~= true then return false end
	return retry_paste_timer_cleanup()
end

local function release_paste_ownership()
	stop_paste_restore_timer()
	_paste_saved_original = nil
	_paste_owns_clipboard = false
	_paste_recovery_only = false
	_paste_generation = _paste_generation + 1
	release_paste_debt()
end

--- Restores the retained all-type snapshot without releasing it on refusal.
--- `clearContents()` has no success return in Hammerspoon, so a non-throw is its
--- complete contract; `writeAllData()` must return the literal boolean true.
--- @return boolean restored
--- @return any error_detail
local function restore_owned_clipboard()
	if not _paste_owns_clipboard then return true, nil end
	local saved = _paste_saved_original
	local ok_restore, restore_result
	if type(saved) == "table" and next(saved) ~= nil then
		ok_restore, restore_result = pcall(hs.pasteboard.writeAllData, saved)
		if not ok_restore or restore_result ~= true then
			return false, ok_restore and "writeAllData returned " .. tostring(restore_result)
				or restore_result
		end
	else
		ok_restore, restore_result = pcall(hs.pasteboard.clearContents)
		if not ok_restore then return false, restore_result end
	end
	release_paste_ownership()
	return true, nil
end

local queue_paste_restore_retry

--- Arms one retained restore timer for the current ownership generation.
--- @param delay number Seconds before the attempt.
--- @return boolean scheduled
--- @return any error_detail
local function schedule_paste_restore(delay)
	if _paste_pending_timer then return true, nil end
	if retry_paste_timer_cleanup() ~= true then
		return false, "prior clipboard timer cleanup remains unsettled"
	end
	local generation = _paste_generation
	local callback_ran = false
	local timer_handle = nil
	local installing = true
	local ok_timer, timer_or_error, timer_committed = pcall(TimerScheduler.after, delay, function()
			callback_ran = true
			if installing then return end
			if timer_handle and timer_handle.timer ~= nil then
				-- TimerScheduler already fenced repeat delivery before invoking us.
				-- Retain its exact native stop debt so no successor can be armed.
				_paste_timer_cleanup = timer_handle
			end
			_paste_pending_timer = nil
			if generation ~= _paste_generation or not _paste_owns_clipboard then return end
			local restored, restore_error = restore_owned_clipboard()
			if restored then return end
			_paste_recovery_only = true
			Logger.error(LOG, "Clipboard restore failed; ownership retained for retry: %s.",
				tostring(restore_error))
			queue_paste_restore_retry("native restore refusal")
	end)
	timer_handle = timer_or_error
	installing = false
	if not ok_timer or timer_committed ~= true
		or type(timer_or_error) ~= "table" or timer_or_error.timer == nil or callback_ran then
		if type(timer_or_error) == "table" then cancel_paste_timer(timer_or_error) end
		return false, ok_timer and (callback_ran and "timer fired before commit"
			or "TimerScheduler.after returned no committed handle") or timer_or_error
	end
	_paste_pending_timer = timer_or_error
	return true, nil
end

--- Retains autonomous recovery after a restore failure. If native timer
--- allocation is unavailable, the synthetic-input lifecycle queue is an
--- independent fallback. When both refuse, ownership still remains closed and
--- the next paste fails closed until the original clipboard can be restored.
--- @param reason string Diagnostic context.
--- @return boolean scheduled
queue_paste_restore_retry = function(reason)
	if not _paste_owns_clipboard then return true end
	local scheduled, timer_error = schedule_paste_restore(CLIPBOARD_RESTORE_SEC)
	if scheduled then return true end
	if type(SyntheticInput.defer_after_callback) == "function" then
		local generation = _paste_generation
		local callback_ran = false
		local installing = true
		local ok_defer, deferred = pcall(SyntheticInput.defer_after_callback,
			"clipboard restore recovery", function()
				callback_ran = true
				if installing then return end
				if generation ~= _paste_generation or not _paste_owns_clipboard then return end
				local restored, restore_error = restore_owned_clipboard()
				if restored then return end
				_paste_recovery_only = true
				Logger.error(LOG, "Deferred clipboard restore failed; ownership retained: %s.",
					tostring(restore_error))
				queue_paste_restore_retry("deferred restore refusal")
			end)
		installing = false
		if ok_defer and deferred == true and not callback_ran then return true end
	end
	Logger.error(LOG, "Clipboard restore retry could not be armed after %s: %s.",
		tostring(reason), tostring(timer_error))
	return false
end

--- Returns true when the text is long enough or unicode-heavy enough that
--- clipboard-paste should be preferred over simulated keystrokes.
--- @param text string The text to evaluate.
--- @return boolean
function M.should_paste(text)
	if type(text) ~= "string" then return false end

	local ok_len, len = pcall(text_utils.utf8_len, text)
	if ok_len and len > PASTE_THRESHOLD then return true end

	local ok_high, has_high = pcall(text_utils.contains_high_unicode, text)
	if ok_high and has_high then return true end

	return false
end

--- Mutates the clipboard with `value` and issues the Cmd+V keystroke, then arms
--- restoration from the exact synthetic transaction completion. Extracted so both
--- emit_tokens (which may need to defer this call — see the serialisation
--- comment in emit_tokens) share the exact same paste + restore contract.
--- @param value string The text to paste.
--- @return boolean True only after the payload and Cmd+V were both accepted.
local function perform_paste(value)
	local transaction = SyntheticInput.current_transaction()
	-- A previous failed restore owns the clipboard but has no valid user output
	-- to extend. Recover it first; if the native pasteboard still refuses, fail
	-- closed and preserve the original snapshot for the autonomous retry.
	if _paste_recovery_only then
		local recovered, recovery_error = restore_owned_clipboard()
		if not recovered then
			queue_paste_restore_retry("new paste while recovery is pending")
			Logger.error(LOG, "Clipboard paste refused while recovery is pending: %s.",
				tostring(recovery_error))
			return false
		end
	end

	-- Serialise clipboard ownership: if a restore is already pending,
	-- cancel it but keep _paste_saved_original (the user's real
	-- clipboard) — reading readAllData() now would return the first
	-- expansion's data rather than what the user had copied.
	if _paste_owns_clipboard then
		if stop_paste_restore_timer() ~= true then
			local restored, restore_error = restore_owned_clipboard()
			if not restored then queue_paste_restore_retry("prior paste timer cleanup refusal") end
			Logger.error(LOG, "Clipboard paste refused while prior timer cleanup remains pending: %s.",
				tostring(restore_error))
			return false
		end
	else
		-- Preserve all clipboard types (images, RTF, etc.), not just plain text.
		local ok_snapshot, snapshot_or_error = pcall(function()
			return hs.pasteboard.readAllData()
		end)
		if not ok_snapshot or (snapshot_or_error ~= nil and type(snapshot_or_error) ~= "table") then
			Logger.error(LOG, "Clipboard paste snapshot failed: %s.", tostring(snapshot_or_error))
			return false
		end
		_paste_saved_original = snapshot_or_error
		local debt_acquired, debt_error = acquire_paste_debt()
		if not debt_acquired then
			_paste_saved_original = nil
			Logger.error(LOG, "Clipboard paste drain ownership was refused: %s.",
				tostring(debt_error))
			return false
		end
	end

	_paste_generation = _paste_generation + 1
	-- Conservative ordering: a native method may mutate the pasteboard and only
	-- then return false or throw. Ownership must exist before entering it.
	_paste_owns_clipboard = true
	_paste_recovery_only = true
	local ok_write, write_result = pcall(hs.pasteboard.setContents, value)
	if not ok_write or write_result ~= true then
		local restored, restore_error = restore_owned_clipboard()
		if not restored then queue_paste_restore_retry("payload write refusal") end
		Logger.error(LOG, "Clipboard paste payload was rejected — %s (restore=%s).",
			tostring(write_result), tostring(restore_error))
		return false
	end

	local ownership_generation = _paste_generation
	local restore_armed = false
	if transaction then
		-- Cmd+V may sit behind many Terminal delete turns. Starting a wall-clock
		-- restore now lets 8 × 20 ms restore the old clipboard before Cmd+V posts.
		-- Completion is the exact handoff boundary for both callback and paced FIFO.
		local registered, registration_error = pcall(SyntheticInput.on_complete,
			transaction, function(_transaction, status)
				if ownership_generation ~= _paste_generation or not _paste_owns_clipboard then return end
				if status ~= "complete" then
					local restored, restore_error = restore_owned_clipboard()
					if not restored then queue_paste_restore_retry("cancelled paste transaction") end
					if not restored then
						Logger.error(LOG, "Clipboard rollback after %s transaction failed: %s.",
							tostring(status), tostring(restore_error))
					end
					return
				end
				local scheduled, timer_error = schedule_paste_restore(CLIPBOARD_RESTORE_SEC)
				if not scheduled then
					_paste_recovery_only = true
					queue_paste_restore_retry("post-handoff restore timer refusal")
					Logger.error(LOG, "Clipboard restore could not be armed after Cmd+V handoff: %s.",
						tostring(timer_error))
				end
			end)
		if not registered then
			local restored, restore_error = restore_owned_clipboard()
			if not restored then queue_paste_restore_retry("completion registration refusal") end
			Logger.error(LOG, "Clipboard completion ownership was refused — %s (restore=%s).",
				tostring(registration_error), tostring(restore_error))
			return false
		end
	else
		-- Standalone adapter callers have no enclosing transaction; retain the
		-- historical pre-armed timer contract for that explicit boundary.
		local timer_error
		restore_armed, timer_error = schedule_paste_restore(CLIPBOARD_RESTORE_SEC)
		if not restore_armed then
			local restored, restore_error = restore_owned_clipboard()
			if not restored then queue_paste_restore_retry("restore timer refusal") end
			Logger.error(LOG, "Clipboard paste restore timer was refused — %s (restore=%s).",
				tostring(timer_error), tostring(restore_error))
			return false
		end
	end

	local ok_emit, emitted_or_error = pcall(function()
		return SyntheticInput.emit_key_stroke({ "cmd" }, "v", 0)
	end)
	if not ok_emit or emitted_or_error ~= true then
		if restore_armed then stop_paste_restore_timer() end
		local restored, restore_error = restore_owned_clipboard()
		if not restored then queue_paste_restore_retry("paste dispatch refusal") end
		Logger.error(LOG, "Clipboard paste shortcut was refused — %s (restore=%s).",
			tostring(emitted_or_error), tostring(restore_error))
		return false
	end
	_paste_recovery_only = false
	return true
end

--- Emits a sequence of tokens by simulating keystrokes or pasting via the clipboard.
---
--- Consecutive paste-worthy tokens (e.g. two long segments separated by a
--- literal newline, as in a signature/address block) are serialised via a
--- named inter-token delay: CGEventPost is asynchronous, so mutating the
--- clipboard again before the OS has delivered the previous Cmd+V would
--- overwrite it mid-flight and corrupt the earlier segment
--- (multi-segment-paste-race). Only the FIRST paste in the loop fires
--- synchronously; every later token is owned by one pre-acquired recurring
--- cursor, so equal deadlines cannot race and each Cmd+V has
--- CLIPBOARD_PASTE_GAP_SEC before the next setContents() call.
--- @param tokens table The token list produced by tokens_from_repl().
--- @return number, string, string Total characters, the legacy physical_echo
---   metadata, and the logical text inserted. Clipboard text is absent from the
---   compatibility echo; immutable tags carry actual event provenance.
function M.emit_tokens(tokens)
	if type(tokens) ~= "table" then
		Logger.error(LOG, "emit_tokens: tokens must be a table (got %s).", type(tokens))
		return 0, "", "", 0
	end

	Logger.trace(LOG, "Emitting %d token(s)…", #tokens)
	local count        = 0
	local emitted_str  = ""
	local logical_text = ""
	-- Chain cursor: seconds from now at which the NEXT paste in this call is
	-- allowed to mutate the clipboard. 0 means "fire immediately" (no prior
	-- paste queued yet in this emit_tokens call).
	local next_paste_delay = 0
	local planned_emissions = {}

	-- When the next token of ANY kind may be emitted. Every clipboard paste moves
	-- this cursor: Cmd+V is only our last posted event; the target produces the
	-- pasted text later, so a following key must wait for that settle boundary.
	local order_delay = 0

	--- Emits inline when nothing is queued ahead, otherwise chains behind it.
	--- Declared above the loop so the closures below capture it rather than a nil
	--- global. Keys and short text reach the OS synchronously, so without this a
	--- token following a deferred paste overtakes it and the replacement arrives
	--- scrambled on screen.
	--- @param delay number Seconds to wait, or <= 0 to fire inline.
	--- @param fn function The emission to perform.
	local function emit_in_order(delay, fn)
		planned_emissions[#planned_emissions + 1] = { delay = delay, run = fn }
	end

	for _, tok in ipairs(tokens) do
		if type(tok) ~= "table" then goto continue end

		if tok.kind == "key" then
			local key_value = tok.value  -- Bound per iteration for the deferred closure
			emit_in_order(order_delay, function()
				assert(SyntheticInput.emit_key_stroke({}, key_value, 0),
					"synthetic key token could not be dispatched")
			end)
			count = count + 1

			-- Preserve character-producing key tokens in the historical physical_echo
			-- result. Their OS events are classified by immutable transaction tags.
			local echo = KEY_ECHO_CHARS[key_value]
			if echo then
				emitted_str  = emitted_str .. echo
				logical_text = logical_text .. echo
			end

		elseif tok.kind == "text" then
			-- Clipboard text has no per-character OS echo but is still part of
			-- the logical replacement consumed by synthetic telemetry.
			logical_text = logical_text .. tok.value
			if M.should_paste(tok.value) then
				local ok_l, tok_len = pcall(text_utils.utf8_len, tok.value)
				count              = count + (ok_l and tok_len or 1)

				local paste_at    = next_paste_delay
				local paste_value = tok.value  -- Bound per iteration for the deferred closure
				if paste_at > 0 then
					Logger.debug(LOG, "Deferring paste of %d char(s) by %.2fs to avoid clipboard race.",
						ok_l and tok_len or 1, paste_at)
				end
				emit_in_order(paste_at, function()
					assert(perform_paste(paste_value) == true,
						paste_at > 0 and "deferred clipboard token paste could not be dispatched"
							or "clipboard token paste could not be dispatched")
				end)
				-- Every following paste-worthy token must wait at least one more
				-- gap so two deferred pastes never collapse onto the same tick.
				next_paste_delay = paste_at + CLIPBOARD_PASTE_GAP_SEC
				-- Every later token queues behind a paste, deferred or not. The
				-- fence used to be skipped for an inline paste on the grounds that
				-- its Cmd+V had already been posted and post order is preserved.
				-- Post order is — but the pasted TEXT is not one of our events: the
				-- target produces it later, on its own schedule, after reading the
				-- pasteboard. A keystroke posted immediately behind the Cmd+V
				-- therefore reaches the host ahead of the text it is meant to
				-- follow, which is how an Enter terminator landed on an unpasted
				-- line and submitted it empty.
				order_delay = next_paste_delay
			else
				local text_value = tok.value  -- Bound per iteration for the deferred closure
				emit_in_order(order_delay, function()
					assert(SyntheticInput.emit_key_strokes(text_value),
						"synthetic token text could not be dispatched")
				end)
				local ok, len = pcall(text_utils.utf8_len, tok.value)
				count       = count + (ok and len or 1)
				emitted_str = emitted_str .. tok.value
			end
		end

		::continue::
	end

	-- One pre-acquired recurring owner serializes every delayed token. Independent
	-- absolute timers at the same deadline have no ordering contract in
	-- Hammerspoon; a single cursor makes insertion order the runtime authority and
	-- gives the whole continuation one retain/failure boundary.
	local first_delayed = nil
	for index, emission in ipairs(planned_emissions) do
		if emission.delay > 0 then first_delayed = index; break end
	end
	local ordered_owner = nil
	if first_delayed then
		local tx = SyntheticInput.current_transaction()
		local retain_token = tx and SyntheticInput.retain(tx) or nil
		local owner = {
			tx = tx,
			retain_token = retain_token,
			cursor = first_delayed,
			tick = 0,
			released = false,
			finished = false,
			handle = nil,
		}

		local function release_retain()
			if owner.released then return true end
			owner.released = true
			if not tx then return true end
			local ok_release, released_or_error = pcall(
				SyntheticInput.release, tx, retain_token)
			if not ok_release or released_or_error ~= true then
				Logger.error(LOG, "Ordered synthetic transaction release failed: %s.",
					tostring(released_or_error))
				return false
			end
			return true
		end

		local function stop_owner()
			owner.finished = true
			local handle = owner.handle
			owner.handle = nil
			if handle then
				local ok_cancel, settled_or_error = pcall(TimerScheduler.cancel, handle)
				if not ok_cancel or settled_or_error ~= true then
					Logger.error(LOG, "Ordered emission timer cleanup remains pending: %s.",
						tostring(settled_or_error))
				end
			end
			release_retain()
		end

		local function fail_owner(detail)
			if tx then
				local ok_fail, failed_or_error = pcall(SyntheticInput.fail, tx, detail)
				if not ok_fail or failed_or_error ~= true then
					Logger.error(LOG, "Deferred transaction failure publication failed: %s.",
						tostring(failed_or_error))
				end
			end
			stop_owner()
			Logger.error(LOG, "Deferred synthetic emission failed: %s.", tostring(detail))
		end

		local installing = true
		local callback_ran = false
		local ok_timer, timer_or_error, timer_committed = pcall(
			TimerScheduler.every, CLIPBOARD_PASTE_GAP_SEC, function()
				callback_ran = true
				if installing or owner.finished then return end
				owner.tick = owner.tick + 1
				local deadline = owner.tick * CLIPBOARD_PASTE_GAP_SEC
				while owner.cursor <= #planned_emissions do
					local emission = planned_emissions[owner.cursor]
					if emission.delay > deadline + 0.0000001 then break end
					local run_ok, run_error = xpcall(function()
						if tx then
							SyntheticInput.with_transaction(tx, emission.run)
						else
							emission.run()
						end
					end, debug.traceback)
					if not run_ok then
						fail_owner(run_error)
						return
					end
					owner.cursor = owner.cursor + 1
				end
				if owner.cursor > #planned_emissions then
					Logger.done(LOG, "%d token(s) emitted (%d char(s)).", #tokens, count)
					stop_owner()
				end
			end)
		installing = false
		if not ok_timer or timer_committed ~= true
			or type(timer_or_error) ~= "table" or timer_or_error.timer == nil
			or callback_ran then
			if type(timer_or_error) == "table" then
				pcall(TimerScheduler.cancel, timer_or_error)
			end
			release_retain()
			error(ok_timer and (callback_ran and "ordered timer fired before commit"
				or "timer scheduler returned no live ordered synthetic timer")
				or timer_or_error, 0)
		end
		owner.handle = timer_or_error
		ordered_owner = owner
	end

	local ok_inline, inline_error = xpcall(function()
		for _, emission in ipairs(planned_emissions) do
			if emission.delay <= 0 then emission.run() end
		end
	end, debug.traceback)
	if not ok_inline then
		if ordered_owner and not ordered_owner.finished then
			ordered_owner.finished = true
			if ordered_owner.handle then pcall(TimerScheduler.cancel, ordered_owner.handle) end
			if ordered_owner.tx and not ordered_owner.released then
				ordered_owner.released = true
				pcall(SyntheticInput.release, ordered_owner.tx, ordered_owner.retain_token)
			end
		end
		error(inline_error, 0)
	end

	if ordered_owner == nil then
		Logger.done(LOG, "%d token(s) emitted (%d char(s)).", #tokens, count)
	end
	-- The fence is returned, not just applied internally. A caller that emits
	-- anything MORE after this call — the terminator re-type does — has the same
	-- ordering hazard as the tokens themselves, and no way to know about it
	-- otherwise: everything here already looks finished from the outside while a
	-- paste is still queued on a timer.
	return count, emitted_str, logical_text, order_delay
end

--- Emits a raw string directly, choosing between keystrokes and clipboard-paste.
--- @param text string The text to emit.
--- @return number, string, string Characters emitted, legacy physical_echo
---   metadata (empty on paste), and the logical text inserted.
function M.emit_text(text)
	if type(text) ~= "string" then
		Logger.error(LOG, "emit_text: text must be a string (got %s).", type(text))
		return 0, "", "", 0
	end

	-- Log the payload's SIZE, never the payload. Every expansion funnels through
	-- here — including personal_info's SSN / IBAN / phone expansions and LLM
	-- completions — and DEBUG is the driver's default level, so echoing `text`
	-- copied user secrets into a log retained 14 days. #text is a byte count
	-- (free); a codepoint count would cost a utf8 scan on the hot path
	Logger.trace(LOG, "Emitting text (%d byte(s))…", #text)

	if M.should_paste(text) then
		assert(perform_paste(text) == true,
			"clipboard text paste could not be dispatched")
		Logger.done(LOG, "Text pasted via clipboard.")
		-- physical_echo stays empty: Cmd+V emits one tagged key pair, not one
		-- keydown per pasted character. Immutable transaction provenance owns its
		-- classification, so no mutable compatibility counter is maintained.
		local ok_l, l = pcall(text_utils.utf8_len, text)
		-- The fence is NOT zero just because this paste fired inline. Cmd+V is our
		-- last event; the text itself is produced by the target when it gets around
		-- to reading the pasteboard. Anything the caller emits after this — the
		-- terminator re-type above all — must wait out that settle window or it
		-- arrives ahead of the replacement it terminates.
		return (ok_l and l or 1), "", text, CLIPBOARD_PASTE_GAP_SEC
	end

	assert(SyntheticInput.emit_key_strokes(text),
		"synthetic text could not be dispatched")
	local ok, len = pcall(text_utils.utf8_len, text)
	Logger.done(LOG, "Text emitted as keystrokes (%d char(s)).", ok and len or 1)
	return (ok and len or 1), text, text, 0
end





-- =================================
-- =================================
-- ======= 3/ Window Ignorer =======
-- =================================
-- =================================

local _ignored_win_cache_time  = 0
local _ignored_win_cache_value = nil
-- Cache dirty flag: true when the cached value can no longer be trusted
-- (focus change, first call, or TTL elapsed). Watchers set this to true
-- synchronously whenever the focused window/app is known to have changed.
local _ignored_win_cache_dirty = true
-- One cheap NSWorkspace watcher plus three narrowly scoped AX watchers. Never use
-- hs.window.filter here: its first access enumerates every application's windows
-- and has already stalled the Hammerspoon runloop for multiple seconds.
local _ignored_win_app_watcher = nil
local _ignored_win_focus_watcher = nil
local _ignored_win_title_watcher = nil
local _secure_field_focus_watcher = nil
local _ignored_win_app_watcher_committed = false
local _ignored_win_focus_watcher_committed = false
local _ignored_win_title_watcher_committed = false
local _ignored_win_focus_owner = nil
local _ignored_win_title_owner = nil
local _secure_field_focus_owner = nil
local _ignored_win_titles_ref   = nil
local _ignored_win_patterns_ref = nil
local _ignored_win_context_generation = 0
-- Tracking is opened explicitly by keymap.start(). Keeping the module closed
-- before that lifecycle edge prevents a stray caller from arming AX callbacks
-- before the owning event taps exist.
local _ignored_win_stopped = true
local _ignored_win_last_identity = nil
local _secure_field_cache_value = nil
local schedule_ignored_win_refresh
local arm_ignored_win_ttl_refresh

--- Stops one exact native watcher without treating an explicit refusal as success.
--- @param watcher any Exact watcher capability.
--- @param label string Diagnostic label.
--- @return boolean settled
local function stop_exact_native_watcher(watcher, label)
	local stopped, stop_result = xpcall(function() return watcher:stop() end, debug.traceback)
	if not stopped or stop_result == false then
		Logger.error(LOG, "Ignored-window %s watcher stop failed: %s.", label, tostring(stop_result))
		return false
	end
	return true
end

--- Logically revokes and then releases the application watcher.
--- @param label string Diagnostic label.
--- @return boolean settled
local function stop_application_watcher(label)
	local watcher = _ignored_win_app_watcher
	_ignored_win_app_watcher_committed = false
	if not watcher then return true end
	if not stop_exact_native_watcher(watcher, label) then return false end
	if _ignored_win_app_watcher == watcher then _ignored_win_app_watcher = nil end
	return true
end

--- Invalidates the ignored-window cache. Called from focus-change watchers;
--- also safe to call from anywhere else (tests, manual overrides).
local function invalidate_ignored_win_cache()
	if _ignored_win_stopped then return end
	_ignored_win_cache_dirty = true
	_ignored_win_cache_value = nil
	_secure_field_cache_value = nil
	_ignored_win_context_generation = _ignored_win_context_generation + 1
	-- Every scheduled refresh carries this epoch. If native timer cancellation
	-- fails, the old callback can still run but may not publish its stale probe.
	_ignored_win_refresh_generation = _ignored_win_refresh_generation + 1
	if _ignored_win_ttl_handle then
		if TimerScheduler.cancel(_ignored_win_ttl_handle) == true then
			_ignored_win_ttl_handle = nil
		end
	end
	if schedule_ignored_win_refresh and _ignored_win_titles_ref then
		schedule_ignored_win_refresh()
	end
end

--- Starts the cheap global application watcher. Context-specific AX watchers
--- are bound by probe_ignored_window(), which already runs outside CGEventTap.
local function ensure_ignored_win_watchers()
	if _ignored_win_app_watcher then return _ignored_win_app_watcher_committed == true end

	-- Application-level: fires when a different app becomes/leaves frontmost.
	if not _ignored_win_app_watcher then
		local candidate = nil
		local ok, watcher = xpcall(function()
			candidate = hs.application.watcher.new(function(_name, event, _app)
				if _ignored_win_app_watcher ~= candidate
					or _ignored_win_app_watcher_committed ~= true then return end
				if event == hs.application.watcher.activated
					or event == hs.application.watcher.deactivated then
					invalidate_ignored_win_cache()
				end
			end)
			if not candidate then error("application watcher construction returned nil", 0) end
			_ignored_win_app_watcher = candidate
			_ignored_win_app_watcher_committed = false
			if candidate:start() == false then error("application watcher start refused", 0) end
			return candidate
		end, debug.traceback)
		if ok and watcher then
			_ignored_win_app_watcher_committed = true
			Logger.debug(LOG, "Ignored-window cache: application watcher started.")
		else
			if candidate and _ignored_win_app_watcher == candidate then
				stop_application_watcher("application setup rollback")
			end
			Logger.warn(LOG, "Ignored-window cache: application watcher setup failed — relying on TTL.")
		end
	end

	return _ignored_win_app_watcher ~= nil and _ignored_win_app_watcher_committed == true
end


local function ui_watcher_event(name, fallback)
	local watcher = hs.uielement and hs.uielement.watcher
	return type(watcher) == "table" and watcher[name] or fallback
end


--- Stops one retained contextual watcher without dropping a failed capability.
--- @param field string Module-local watcher selector.
--- @param label string Diagnostic label.
--- @return boolean settled
local function stop_context_watcher(field, label)
	local watcher
	if field == "focus" then
		watcher = _ignored_win_focus_watcher
		_ignored_win_focus_watcher_committed = false
	elseif field == "title" then
		watcher = _ignored_win_title_watcher
		_ignored_win_title_watcher_committed = false
	else watcher = _secure_field_focus_watcher end
	if not watcher then return true end
	if not stop_exact_native_watcher(watcher, label) then return false end
	if field == "focus" then
		_ignored_win_focus_watcher = nil
		_ignored_win_focus_owner = nil
	elseif field == "title" then
		_ignored_win_title_watcher = nil
		_ignored_win_title_owner = nil
	else
		_secure_field_focus_watcher = nil
		_secure_field_focus_owner = nil
	end
	return true
end


local function app_owner_key(app)
	local ok, pid = pcall(function() return app:pid() end)
	return ok and pid ~= nil and tostring(pid) or tostring(app)
end


local function window_owner_key(win)
	local ok, window_id = pcall(function() return win:id() end)
	return ok and window_id ~= nil and tostring(window_id) or tostring(win)
end


--- Binds AX watchers only to the current app/window; no global enumeration.
--- @param app table Current focused-window application.
--- @param win table Current focused window.
--- @param watch_title boolean False only when every title is ignored (HS console).
--- @return boolean ready True only when every required invalidation edge is live.
local function ensure_ignored_win_context_watchers(app, win, watch_title)
	local app_key = app_owner_key(app)
	local win_key = window_owner_key(win)
	if _secure_field_focus_owner ~= app_key
		and not stop_context_watcher("secure", "secure-field focus")
	then
		return false
	end
	if _ignored_win_title_owner ~= win_key and not stop_context_watcher("title", "title") then
		return false
	end
	if _ignored_win_focus_owner ~= app_key and not stop_context_watcher("focus", "focus") then
		return false
	end
	if _ignored_win_focus_watcher and _ignored_win_focus_watcher_committed ~= true then
		return false
	end

	if not _ignored_win_focus_watcher then
		local candidate = nil
		local ok, watcher = xpcall(function()
			candidate = app:newWatcher(function()
				if _ignored_win_focus_watcher ~= candidate
					or _ignored_win_focus_watcher_committed ~= true then return end
				invalidate_ignored_win_cache()
			end)
			if not candidate then error("focused-window watcher construction returned nil", 0) end
			_ignored_win_focus_watcher = candidate
			_ignored_win_focus_owner = app_key
			_ignored_win_focus_watcher_committed = false
			if candidate:start({ ui_watcher_event("focusedWindowChanged", "AXFocusedWindowChanged") })
				== false then error("focused-window watcher start refused", 0) end
			return candidate
		end, debug.traceback)
		if not ok or not watcher then
			if candidate and _ignored_win_focus_watcher == candidate then
				stop_context_watcher("focus", "focus setup rollback")
			end
			Logger.warn(LOG, "Ignored-window focused-window watcher setup failed.")
			return false
		end
		_ignored_win_focus_watcher_committed = true
	end

	if not _secure_field_focus_watcher then
		local watcher, detail = SecureFieldDetector.watchFocusedElementChanges(
			app, invalidate_ignored_win_cache)
		if not watcher then
			Logger.warn(LOG, "Secure-field focus watcher setup failed: %s.", tostring(detail))
			return false
		end
		_secure_field_focus_watcher = watcher
		_secure_field_focus_owner = app_key
	end

	if watch_title ~= true then
		if _ignored_win_title_watcher and not stop_context_watcher("title", "title") then
			return false
		end
		return true
	end
	if _ignored_win_title_watcher and _ignored_win_title_watcher_committed ~= true then
		return false
	end
	if not _ignored_win_title_watcher then
		local candidate = nil
		local ok, watcher = xpcall(function()
			candidate = win:newWatcher(function()
				if _ignored_win_title_watcher ~= candidate
					or _ignored_win_title_watcher_committed ~= true then return end
				invalidate_ignored_win_cache()
			end)
			if not candidate then error("title watcher construction returned nil", 0) end
			_ignored_win_title_watcher = candidate
			_ignored_win_title_owner = win_key
			_ignored_win_title_watcher_committed = false
			if candidate:start({ ui_watcher_event("titleChanged", "AXTitleChanged") })
				== false then error("title watcher start refused", 0) end
			return candidate
		end, debug.traceback)
		if not ok or not watcher then
			if candidate and _ignored_win_title_watcher == candidate then
				stop_context_watcher("title", "title setup rollback")
			end
			Logger.warn(LOG, "Ignored-window title watcher setup failed.")
			return false
		end
		_ignored_win_title_watcher_committed = true
	end
	return true
end

--- Marks the cached classification unknown after an AX read failure.
--- @return nil
local function mark_ignored_win_unknown()
	_ignored_win_cache_dirty = true
	_ignored_win_cache_value = nil
	_secure_field_cache_value = nil
	_ignored_win_context_generation = _ignored_win_context_generation + 1
	_ignored_win_last_identity = nil
	return nil
end

--- Advances the text-context generation when an off-tap probe observes a
--- different focused window even if the native watcher missed the transition.
local function observe_ignored_win_identity(win, app_name, title)
	local ok_id, window_id = pcall(function() return win:id() end)
	-- A browser/editor can reuse one native window while its title crosses an
	-- ignored rule. Window id alone therefore is not text-context identity.
	local identity = tostring(ok_id and window_id or "<no-id>")
		.. "\0" .. tostring(app_name) .. "\0" .. tostring(title)
	if _ignored_win_last_identity ~= nil and identity ~= _ignored_win_last_identity then
		_ignored_win_context_generation = _ignored_win_context_generation + 1
	end
	_ignored_win_last_identity = identity
end

--- Performs the expensive focused-window AX probe. Never call from CGEventTap.
--- @param ignored_titles table Hash map of exact window titles to ignore.
--- @param ignored_patterns table Array of Lua patterns matched against window titles.
--- @param now number|nil Current epoch timestamp.
--- @return boolean|nil ignored Nil means the classification could not be read.
local function probe_ignored_window(ignored_titles, ignored_patterns, now)
	if not now then now = hs.timer.secondsSinceEpoch() end
	_ignored_win_cache_time  = now
	_ignored_win_cache_dirty = false
	_ignored_win_cache_value = false
	_secure_field_cache_value = nil
	if not ensure_ignored_win_watchers() then return mark_ignored_win_unknown() end

	-- Use the focused window directly rather than frontmostApplication() so that
	-- floating-panel apps (e.g. Raycast) that accept keystrokes without becoming
	-- the NSWorkspace frontmost app are evaluated against their own window title,
	-- not the title of the previously active app.
	local ok_win, win = pcall(hs.window.focusedWindow)
	if not ok_win or not win then return mark_ignored_win_unknown() end

	local ok_app, app = pcall(function() return win:application() end)
	if not ok_app or not app then return mark_ignored_win_unknown() end

	-- Always ignore the Hammerspoon console to prevent feedback loops;
	-- folded here so it benefits from the event-driven cache as the rest.
	local ok_app_name, app_name = pcall(function() return app:name() end)
	if not ok_app_name or type(app_name) ~= "string" then
		return mark_ignored_win_unknown()
	end
	if app_name == "Hammerspoon" then
		if not ensure_ignored_win_context_watchers(app, win, false) then
			return mark_ignored_win_unknown()
		end
		observe_ignored_win_identity(win, app_name, "<hammerspoon>")
		_ignored_win_cache_value = true
		_secure_field_cache_value = false
		return true
	end

	local ok_title, title = pcall(function() return win:title() end)
	if not ok_title or type(title) ~= "string" then return mark_ignored_win_unknown() end
	if not ensure_ignored_win_context_watchers(app, win, true) then
		return mark_ignored_win_unknown()
	end
	observe_ignored_win_identity(win, app_name, title)
	local secure = SecureFieldDetector.isSecureApp(app_name) == true and true
		or SecureFieldDetector.inspectFocusedElement(app)
	if type(secure) ~= "boolean" then return mark_ignored_win_unknown() end
	_secure_field_cache_value = secure

	-- Exact-title match.
	if type(ignored_titles) == "table" and ignored_titles[title] then
		Logger.debug(LOG, "Window '%s' ignored (exact match).", title)
		_ignored_win_cache_value = true
		return true
	end

	-- Pattern match.
	if type(ignored_patterns) == "table" then
		for _, pat in ipairs(ignored_patterns) do
			local ok_match, matched = pcall(string.match, title, pat)
			if type(pat) == "string" and ok_match and matched then
				Logger.debug(LOG, "Window '%s' ignored (pattern '%s').", title, pat)
				_ignored_win_cache_value = true
				return true
			end
			if type(pat) == "string" and not ok_match then
				Logger.warn(LOG, "Invalid ignored-window pattern '%s' — skipped.", pat)
			end
		end
	end

	return false
end

--- Arms one off-eventtap AX refresh. The callback probes directly instead of
--- recursively re-entering the cache state machine; recursive refreshes could
--- alternate dirty/clean flags forever without ever reading the focused window.
--- @return boolean committed True when a refresh is armed or already pending.
schedule_ignored_win_refresh = function()
	if _ignored_win_stopped then return false end
	if _ignored_win_refresh_armed then return true end
	_ignored_win_refresh_armed = true
	local generation = _ignored_win_refresh_generation
	local callback_ran = false
	local handle, committed = TimerScheduler.after(0, function()
		callback_ran = true
		_ignored_win_refresh_armed = false
		_ignored_win_refresh_handle = nil
		if _ignored_win_stopped then return end
		if generation ~= _ignored_win_refresh_generation then
			-- An invalidation overtook this callback. Re-arm the newest epoch now
			-- that the one-slot scheduler is free rather than leaving dirty state
			-- permanently fail-closed.
			if _ignored_win_cache_dirty then schedule_ignored_win_refresh() end
			return
		end
		local ok, result = xpcall(function()
			return probe_ignored_window(
				_ignored_win_titles_ref or {},
				_ignored_win_patterns_ref or {},
				hs.timer.secondsSinceEpoch())
		end, debug.traceback)
		if not ok then
			mark_ignored_win_unknown()
			Logger.error(LOG, "Ignored-window refresh failed: %s.", tostring(result))
		end
		arm_ignored_win_ttl_refresh()
	end)
	if committed ~= true then
		_ignored_win_refresh_armed = false
		_ignored_win_refresh_handle = nil
		return false
	end
	if not callback_ran then _ignored_win_refresh_handle = handle end
	return true
end


--- Keeps the cache fresh while no watcher event arrives. The timer itself does
--- the AX probe off CGEventTap; a normal key therefore consumes a fresh boolean
--- instead of paying one deliberately dropped classification every TTL period.
--- @return boolean committed True when the next refresh is armed/already live.
arm_ignored_win_ttl_refresh = function()
	if _ignored_win_stopped then return false end
	if _ignored_win_ttl_handle then
		if _ignored_win_ttl_handle.fired ~= true then return true end
		_ignored_win_ttl_handle = nil
	end
	local generation = _ignored_win_refresh_generation
	local callback_ran = false
	local handle, committed = TimerScheduler.after(IGNORED_WIN_TTL_SEC, function()
		callback_ran = true
		_ignored_win_ttl_handle = nil
		if _ignored_win_stopped then return end
		if generation ~= _ignored_win_refresh_generation then
			if _ignored_win_cache_dirty then schedule_ignored_win_refresh()
			else arm_ignored_win_ttl_refresh() end
			return
		end
		local ok, result = xpcall(function()
			return probe_ignored_window(
				_ignored_win_titles_ref or {},
				_ignored_win_patterns_ref or {},
				hs.timer.secondsSinceEpoch())
		end, debug.traceback)
		if not ok then
			mark_ignored_win_unknown()
			Logger.error(LOG, "Ignored-window TTL probe failed: %s.", tostring(result))
		end
		arm_ignored_win_ttl_refresh()
	end)
	if committed ~= true then
		_ignored_win_ttl_handle = nil
		return false
	end
	if not callback_ran then _ignored_win_ttl_handle = handle end
	return true
end

--- Returns the cached ignored-window classification without performing AX work.
--- A dirty cache is unknown, not the previous window's answer: callers must pass
--- the physical key through without transforming it until the timer refreshes.
--- @param ignored_titles table Hash map of exact window titles to ignore.
--- @param ignored_patterns table Array of Lua patterns matched against window titles.
--- @param now number|nil Current epoch timestamp (seconds) from the caller.
--- @return boolean|nil ignored Nil means the focused window is not yet classified.
--- @return integer context_generation Increments on every focus/title invalidation.
function M.is_ignored_window(ignored_titles, ignored_patterns, now)
	if not now then now = hs.timer.secondsSinceEpoch() end
	_ignored_win_titles_ref = type(ignored_titles) == "table" and ignored_titles or {}
	_ignored_win_patterns_ref = type(ignored_patterns) == "table" and ignored_patterns or {}
	if _ignored_win_stopped then return nil, _ignored_win_context_generation end

	if _ignored_win_cache_dirty or _ignored_win_cache_value == nil then
		schedule_ignored_win_refresh()
		return nil, _ignored_win_context_generation
	end

	if (now - _ignored_win_cache_time) >= IGNORED_WIN_TTL_SEC then
		-- The periodic timer should normally have refreshed first. If the main
		-- runloop delayed it, never authorize the previous window's answer.
		invalidate_ignored_win_cache()
		return nil, _ignored_win_context_generation
	end
	return _ignored_win_cache_value, _ignored_win_context_generation
end


--- Returns the cached secure-field classification without performing AX work.
--- The cache shares focus identity, TTL, invalidation, and refresh ownership with
--- is_ignored_window(); nil means the current field is not yet classified.
--- @param now number|nil Current epoch timestamp (seconds) from the caller.
--- @return boolean|nil secure
--- @return integer context_generation
function M.is_secure_field(now)
	if not now then now = hs.timer.secondsSinceEpoch() end
	if _ignored_win_stopped then return nil, _ignored_win_context_generation end
	if _ignored_win_cache_dirty or _secure_field_cache_value == nil then
		schedule_ignored_win_refresh()
		return nil, _ignored_win_context_generation
	end
	if (now - _ignored_win_cache_time) >= IGNORED_WIN_TTL_SEC then
		invalidate_ignored_win_cache()
		return nil, _ignored_win_context_generation
	end
	return _secure_field_cache_value, _ignored_win_context_generation
end

--- Reopens ignored-window tracking before the keymap taps start.
--- Watchers and AX reads remain deferred; this method only publishes live refs.
--- @param ignored_titles table Exact ignored-window titles.
--- @param ignored_patterns table Ignored-window title patterns.
function M.start_ignored_win_tracking(ignored_titles, ignored_patterns)
	local next_titles = type(ignored_titles) == "table" and ignored_titles or {}
	local next_patterns = type(ignored_patterns) == "table" and ignored_patterns or {}
	if not _ignored_win_stopped then
		_ignored_win_titles_ref = next_titles
		_ignored_win_patterns_ref = next_patterns
		return _ignored_win_context_generation
	end
	-- A failed native cancellation deliberately retains the exact capability for
	-- retry. Do not reopen while such a callback can still publish old lifecycle
	-- state; a second stop/start may settle the same handle.
	if _ignored_win_refresh_handle then
		if TimerScheduler.cancel(_ignored_win_refresh_handle) ~= true then return nil end
		_ignored_win_refresh_handle = nil
	end
	if _ignored_win_ttl_handle then
		if TimerScheduler.cancel(_ignored_win_ttl_handle) ~= true then return nil end
		_ignored_win_ttl_handle = nil
	end
	if _ignored_win_app_watcher or _ignored_win_focus_watcher or _ignored_win_title_watcher
		or _secure_field_focus_watcher
	then
		-- A previous teardown retained an exact watcher capability because its
		-- stop/unsubscribe raised. Reopening would mistake a half-dead object for
		-- valid coverage; require the caller to retry stop() first.
		return nil
	end
	_ignored_win_refresh_armed = false
	_ignored_win_stopped = false
	_ignored_win_context_generation = _ignored_win_context_generation + 1
	_ignored_win_titles_ref = next_titles
	_ignored_win_patterns_ref = next_patterns
	_ignored_win_cache_dirty = true
	_ignored_win_cache_value = nil
	_secure_field_cache_value = nil
	return _ignored_win_context_generation
end

--- Invalidates a clean classification after the runtime ignore rules mutate.
function M.ignored_window_rules_changed()
	invalidate_ignored_win_cache()
end

--- Prepares the narrow app/window AX watchers before the keyDown tap is armed.
--- This intentionally avoids hs.window.filter.default: its cold global-window
--- enumeration blocks the shared Hammerspoon runloop even when moved to a timer.
--- Safe to call repeatedly: unchanged current owners reuse their exact watchers.
--- @param ignored_titles table|nil Exact ignored-window titles.
--- @param ignored_patterns table|nil Ignored-window title patterns.
function M.prewarm_ignored_win_watchers(ignored_titles, ignored_patterns)
	if _ignored_win_stopped then return false end
	Logger.start(LOG, "Preparing ignored-window watchers before key capture…")
	local t0 = hs.timer.absoluteTime()
	if type(ignored_titles) == "table" then _ignored_win_titles_ref = ignored_titles end
	if type(ignored_patterns) == "table" then _ignored_win_patterns_ref = ignored_patterns end
	local classification = probe_ignored_window(
		_ignored_win_titles_ref or {},
		_ignored_win_patterns_ref or {},
		hs.timer.secondsSinceEpoch())
	local ttl_ready = arm_ignored_win_ttl_refresh()
	if classification == nil or not ttl_ready then
		Logger.warn(LOG, "Ignored-window prewarm incomplete; tracking remains fail-closed.")
		return false
	end
	Logger.success(LOG, "Ignored-window watchers ready (%.1f ms).",
		(hs.timer.absoluteTime() - t0) / 1e6)
	return true
end

--- Stops every ignored-window watcher.
--- Must be called from keymap/init.lua M.stop() to prevent callbacks from firing
--- after the module is unloaded (watcher-leak-on-reload).
function M.stop()
	_ignored_win_stopped = true
	_ignored_win_refresh_generation = _ignored_win_refresh_generation + 1
	local settled = true
	if _ignored_win_refresh_handle then
		local cancelled = TimerScheduler.cancel(_ignored_win_refresh_handle)
		if cancelled ~= true then
			Logger.error(LOG, "Ignored-window refresh timer could not be cancelled during stop.")
			settled = false
		else
			_ignored_win_refresh_handle = nil
		end
	end
	_ignored_win_refresh_armed = _ignored_win_refresh_handle ~= nil
	if _ignored_win_ttl_handle then
		local cancelled = TimerScheduler.cancel(_ignored_win_ttl_handle)
		if cancelled ~= true then
			Logger.error(LOG, "Ignored-window TTL timer could not be cancelled during stop.")
			settled = false
		else
			_ignored_win_ttl_handle = nil
		end
	end
	if not stop_application_watcher("application") then settled = false end
	if not stop_context_watcher("title", "title") then settled = false end
	if not stop_context_watcher("focus", "focus") then settled = false end
	if not stop_context_watcher("secure", "secure-field focus") then settled = false end
	_ignored_win_cache_dirty = true
	_ignored_win_cache_value = nil
	_secure_field_cache_value = nil
	_ignored_win_last_identity = nil
	_ignored_win_titles_ref = nil
	_ignored_win_patterns_ref = nil
	return settled
end

return M
