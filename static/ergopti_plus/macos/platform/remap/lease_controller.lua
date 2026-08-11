--- platform/remap/lease_controller.lua

--- ==============================================================================
--- MODULE: Karabiner Lease Controller
--- DESCRIPTION:
--- Owns the short-lived capability that authorizes only Ergopti-managed
--- Karabiner rules. A retained native worker writes one generation-specific
--- atomic mode, acknowledges ACTIVE/PAUSED transitions, and fences that exact
--- generation OFF when Hammerspoon closes its stdin after quit, reload, Force
--- Quit or a crash.
---
--- FEATURES & RATIONALE:
--- 1. Exact identity: every generation receives distinct 32-hex mode and
---    tombstone names, so stale callbacks cannot affect a replacement generation.
--- 2. Fail-closed protocol: READY, PAUSED, RESUMED and STOPPED are mandatory;
---    missing or malformed acknowledgements trigger an exact CLI revocation.
--- 3. Shared-process safety: this module never enumerates, signals or unloads a
---    Karabiner process. The only terminable object is Ergopti's watchdog task.
--- 4. Bounded recovery: a retained Hammerspoon timer sends one sequenced ping at
---    a time. The native outer never manufactures liveness after Lua disappears.
--- 5. Per-spawn identity: every worker and fallback task re-resolves the exact
---    bundle path plus launcher device/inode instead of trusting init-time state.
--- ==============================================================================

local M = {}

local hs             = hs
local Logger         = require("infra.logger")
local ShellRunner    = require("adapters.shell_runner")
local TimerScheduler = require("adapters.timer_scheduler")
local KePaths        = require("platform.remap.ke_paths")
local LeaseContract  = require("platform.remap.lease_contract")
local LeaseHelper    = require("platform.remap.lease_helper")

local LOG = "karabiner.lease"

local READY_ACK_TIMEOUT_SEC = 4.0
local COMMAND_ACK_TIMEOUT_SEC = 2.0
local STOP_ACK_TIMEOUT_SEC = 7.0
local HEARTBEAT_INTERVAL_SEC = 5 -- Bounds Core Service reset recovery without a 1 Hz CLI loop.
local HEARTBEAT_RETRY_SEC = 1.0
local MAX_CONSECUTIVE_HEARTBEAT_FAILURES = 2
local FALLBACK_RETRY_SEC = 1.0
local TOKEN_ALLOCATION_ATTEMPTS = 8
local MAX_PROTOCOL_BUFFER_BYTES = 64
local MAX_PING_SEQUENCE = 2147483647
local TOKEN_LEDGER_KEY = "ergopti.karabiner.used_tokens.v1"
local WORKER_FLAG = "--karabiner-lease-worker"
local REVOKE_FLAG = "--karabiner-lease-revoke"

local _state = nil





-- =======================================
-- =======================================
-- ======= 1/ Internal State Model =======
-- =======================================
-- =======================================

--- Reports a public call made before initialization.
--- @param func_name string Public function name.
--- @return boolean True when the module is initialized.
local function require_state(func_name)
	if not _state then
		Logger.error(LOG, "'%s' called before M.init() — lease controller unavailable.", func_name)
		return false
	end
	return true
end

--- Invokes an optional client callback without letting it abort async cleanup.
--- @param label string Callback label for diagnostics.
--- @param callback function|nil Callback to invoke.
--- @param ... any Callback arguments.
local function invoke_callback(label, callback, ...)
	if type(callback) ~= "function" then return end
	local args = table.pack(...)
	local ok, err = xpcall(function()
		callback(table.unpack(args, 1, args.n))
	end, debug.traceback)
	if not ok then
		Logger.error(LOG, "%s callback threw: %s", label, tostring(err))
	end
end

--- Invokes and clears a callback array exactly once.
--- @param label string Callback label for diagnostics.
--- @param callbacks table|nil Callback array.
--- @param ok boolean Operation result.
--- @param reason string Result detail.
local function settle_callbacks(label, callbacks, ok, reason)
	if type(callbacks) ~= "table" then return end
	local snapshot = {}
	for index = 1, #callbacks do snapshot[index] = callbacks[index] end
	-- Clear first: a re-entrant callback may register another operation on the
	-- same lifecycle object and must not be erased by this settlement pass.
	for index = #callbacks, 1, -1 do callbacks[index] = nil end
	for index = 1, #snapshot do
		invoke_callback(label, snapshot[index], ok, reason)
	end
end

--- Loads and strictly validates the persistent one-shot capability ledger.
--- nil means first use. Any read failure or malformed table is ambiguous: it
--- may hide tokens published by a previous Lua state, so allocation must remain
--- disabled rather than risking reuse of an already-revoked capability.
--- @return table|nil used_tokens Canonical token lookup.
--- @return table|nil used_token_order Dense canonical token array.
--- @return string|nil error_message Validation or host failure.
local function load_used_token_ledger()
	if not hs or type(hs.settings) ~= "table" or type(hs.settings.get) ~= "function" then
		return nil, nil, "hs.settings.get is unavailable"
	end
	local call_ok, ledger = pcall(hs.settings.get, TOKEN_LEDGER_KEY)
	if not call_ok then return nil, nil, "settings read raised: " .. tostring(ledger) end
	if ledger == nil then return {}, {} end
	if type(ledger) ~= "table" then return nil, nil, "persisted token ledger is not a table" end

	local count = 0
	for index in pairs(ledger) do
		if type(index) ~= "number" or index < 1 or index % 1 ~= 0 then
			return nil, nil, "persisted token ledger is not a dense array"
		end
		count = count + 1
	end
	local used_tokens = {}
	local used_token_order = {}
	for index = 1, count do
		local token = ledger[index]
		if not LeaseContract.is_valid_token(token) then
			return nil, nil, "persisted token ledger contains an invalid token"
		end
		if used_tokens[token] then
			return nil, nil, "persisted token ledger contains a duplicate token"
		end
		used_tokens[token] = true
		used_token_order[index] = token
	end
	return used_tokens, used_token_order
end

--- Persists one newly allocated capability before it can be published.
--- A settings failure is fail-closed: without cross-reload memory, a repeated
--- UUID could inherit old Karabiner variables and make READY dishonest.
--- @param token string Fresh canonical token.
--- @return boolean persisted Whether read-after-write proves durability.
local function persist_used_token(token)
	if not _state.token_ledger_ready then return false end
	if not hs or type(hs.settings) ~= "table"
		or type(hs.settings.set) ~= "function"
		or type(hs.settings.get) ~= "function" then
		return false
	end
	local ledger = {}
	for index, value in ipairs(_state.used_token_order) do ledger[index] = value end
	ledger[#ledger + 1] = token
	local ok_set = pcall(hs.settings.set, TOKEN_LEDGER_KEY, ledger)
	if not ok_set then return false end
	local ok_get, stored = pcall(hs.settings.get, TOKEN_LEDGER_KEY)
	if not ok_get or type(stored) ~= "table" then return false end
	for _, value in ipairs(stored) do
		if value == token then
			_state.used_token_order = ledger
			_state.used_tokens[token] = true
			return true
		end
	end
	return false
end

--- Creates an inert generation descriptor without touching Karabiner.
--- @return table|nil generation Newly allocated generation.
local function create_generation()
	if not hs or type(hs.host) ~= "table" or type(hs.host.uuid) ~= "function" then
		Logger.error(LOG, "Cannot allocate lease token — host UUID API is unavailable.")
		return nil
	end
	local last_error = "host UUID API returned only reused tokens"
	for _ = 1, TOKEN_ALLOCATION_ATTEMPTS do
		local ok, raw = pcall(hs.host.uuid)
		local token, token_err
		if ok then
			token, token_err = LeaseContract.normalize_token(raw)
		else
			token_err = raw
		end
		if not token then
			last_error = tostring(token_err or raw)
		elseif _state.used_tokens[token] then
			last_error = "host UUID API repeated an already published token"
		else
			local generation, variables_err = LeaseContract.variables(token)
			if not generation then
				last_error = tostring(variables_err)
			else
				-- A token is a one-shot capability. Reusing it could activate stale
				-- variables before READY or inherit revoked=1 from an old generation.
				if not persist_used_token(token) then
					Logger.error(LOG, "Cannot persist one-shot lease token %s.", token)
					return nil
				end
				generation.phase = "prepared"
				generation.stdout_buffer = ""
				generation.start_callbacks = {}
				return generation
			end
		end
	end
	Logger.error(LOG, "Cannot allocate a fresh lease token after %d attempts — %s",
		TOKEN_ALLOCATION_ATTEMPTS, last_error)
	return nil
end

--- Returns any generation whose exact revocation has not yet been proven.
--- @return table|nil generation Retiring generation, when one exists.
local function any_retiring()
	if not _state or type(_state.retiring) ~= "table" then return nil end
	local selected_token = nil
	for token in pairs(_state.retiring) do
		if not selected_token or token < selected_token then selected_token = token end
	end
	return selected_token and _state.retiring[selected_token] or nil
end

--- Returns whether an unresolved protocol failure must block replacement
--- generation allocation until its exact native fence completes.
--- @return boolean True while any failed writer remains ambiguous.
local function has_fencing_failure()
	if not _state or type(_state.retiring) ~= "table" then return false end
	for _, generation in pairs(_state.retiring) do
		if generation.failure_reason and not generation.safe then return true end
	end
	return false
end

--- Derives one deterministic public phase from the whole retiring set.
--- @return string|nil phase `fencing`, `stopping`, or nil when empty.
local function retiring_phase()
	local saw_retiring = false
	for _, generation in pairs(_state.retiring) do
		saw_retiring = true
		if generation.failure_reason then return "fencing" end
	end
	return saw_retiring and "stopping" or nil
end

--- Removes one generation only after STOPPED or a successful native revoker
--- has completed the generation-specific fence transports. Callers must use
--- mark_generation_safe() so every overlapping stop barrier is updated too.
--- @param generation table Generation whose fence transports completed.
local function forget_retiring(generation)
	if not _state or type(_state.retiring) ~= "table" then return end
	if _state.retiring[generation.token] == generation then
		_state.retiring[generation.token] = nil
	end
end

--- Settles and removes one completed aggregate stop barrier.
--- @param barrier table Stop barrier whose pending set is empty.
local function settle_stop_barrier(barrier)
	if barrier.settled then return end
	barrier.settled = true
	for index = #_state.stop_barriers, 1, -1 do
		if _state.stop_barriers[index] == barrier then
			table.remove(_state.stop_barriers, index)
			break
		end
	end
	settle_callbacks("lease.stop", barrier.callbacks, barrier.ok, barrier.reason)
end

--- Creates a barrier over every generation that is still capable of writing
--- managed variables. A stop caller cannot report completion while an older
--- retiring generation is still waiting for its own fence.
--- @param on_done function|nil Callback fn(ok, reason).
--- @return table|nil barrier Nil when no fence transport is outstanding.
local function create_stop_barrier(on_done)
	local pending = {}
	local remaining = 0
	for token, generation in pairs(_state.retiring) do
		if not generation.safe then
			pending[token] = true
			remaining = remaining + 1
		end
	end
	if remaining == 0 then
		invoke_callback("lease.stop", on_done, true, "already-stopped")
		return nil
	end
	local callbacks = {}
	if type(on_done) == "function" then callbacks[1] = on_done end
	local barrier = {
		pending = pending,
		remaining = remaining,
		ok = true,
		reason = "stopped",
		callbacks = callbacks,
	}
	_state.stop_barriers[#_state.stop_barriers + 1] = barrier
	return barrier
end

--- Applies one aggregate Stop intent to every generation the resulting barrier
--- will wait for. A failure fence that began before Stop must settle IDLE, not
--- publish FAILED immediately before reporting the requested stopped state.
--- @return boolean unsafe_retiring True while any captured fence is outstanding.
local function mark_retiring_stop_requested()
	local unsafe_retiring = false
	for _, generation in pairs(_state.retiring) do
		generation.stop_requested = true
		if not generation.safe then unsafe_retiring = true end
	end
	return unsafe_retiring
end

local cancel_heartbeat_timer
local cancel_heartbeat_retry_timer

--- Cancels one exact timer without throwing across a lifecycle boundary.
--- @param timer table Exact TimerScheduler handle.
--- @param label string Diagnostic owner.
--- @return boolean cancelled Strict cancellation result.
local function cancel_timer_handle(timer, label)
	local call_ok, cancelled_or_err = pcall(TimerScheduler.cancel, timer)
	if call_ok and cancelled_or_err == true then return true end
	Logger.error(LOG, "%s cancellation failed; retaining the exact timer for retry: %s.",
		label, tostring(cancelled_or_err))
	return false
end

--- Retries every timer whose native cancellation was not previously proven.
--- The callbacks are already fenced by clearing their active generation slots.
--- @return boolean complete Whether the cleanup backlog is empty.
local function retry_timer_cleanup()
	if not _state or type(_state.timer_cleanup_backlog) ~= "table" then return true end
	for index = #_state.timer_cleanup_backlog, 1, -1 do
		local entry = _state.timer_cleanup_backlog[index]
		if cancel_timer_handle(entry.timer, entry.label) then
			table.remove(_state.timer_cleanup_backlog, index)
		end
	end
	return #_state.timer_cleanup_backlog == 0
end

--- Fences one active timer slot first, then cancels or retains its exact handle.
--- @param generation table Timer owner.
--- @param slot string Generation field holding the active handle.
--- @param label string Diagnostic owner.
local function release_generation_timer(generation, slot, label)
	local timer = generation[slot]
	if not timer then return end
	-- Invalidate before crossing the native boundary: a queued callback must be
	-- logically inert even when stop() throws or reports failure.
	generation[slot] = nil
	if not cancel_timer_handle(timer, label) then
		_state.timer_cleanup_backlog[#_state.timer_cleanup_backlog + 1] = {
			timer = timer,
			label = label,
		}
	end
end

--- Resolves the bundle-owned executable at the final task-construction boundary.
--- The launcher path is mutable across an app update, so a value cached by
--- M.init() cannot authorize a later worker or fallback process.
--- @param arguments string[] Exact native helper arguments.
--- @param on_done function Task completion callback.
--- @param on_chunk function|nil Streaming callback.
--- @return table|nil handle Unstarted task handle.
--- @return string|nil error_message Current identity failure.
local function spawn_current_helper(arguments, on_done, on_chunk)
	local helper_path, helper_error = LeaseHelper.resolve()
	_state.helper_path = helper_path
	_state.helper_error = helper_error
	if not helper_path then return nil, helper_error end
	return ShellRunner.spawn(helper_path, arguments, on_done, on_chunk), nil
end

--- Publishes one exact-generation fence completion to every overlapping stop
--- operation. A successful fallback is degraded but satisfies the caller's
--- desired stopped state, so aggregate stop callbacks report true only after
--- every captured generation completed its clean local fence transports.
--- This does not claim a receiver-side Karabiner application acknowledgement.
--- @param generation table Generation whose fence transports completed.
--- @param protocol_ok boolean True only when the retained worker reported STOPPED.
--- @param reason string Stable settlement reason.
local function mark_generation_safe(generation, protocol_ok, reason)
	if generation.safe then return end
	cancel_heartbeat_timer(generation)
	release_generation_timer(generation, "fallback_retry_timer", "Lease fallback retry timer")
	generation.fallback_started = false
	generation.safe = true
	generation.safe_reason = reason
	forget_retiring(generation)
	local ready_barriers = {}
	for index = #_state.stop_barriers, 1, -1 do
		local barrier = _state.stop_barriers[index]
		if barrier.pending[generation.token] then
			barrier.pending[generation.token] = nil
			barrier.remaining = barrier.remaining - 1
			if not protocol_ok then barrier.reason = reason end
			if barrier.remaining == 0 then ready_barriers[#ready_barriers + 1] = barrier end
		end
	end
	-- Publish the settled aggregate phase before any callback can re-enter and
	-- observe stale `stopping`/`fencing` state or allocate a replacement token.
	if not _state.current then
		local phase = retiring_phase()
		if not phase then
			phase = generation.failure_reason and not generation.stop_requested and "failed" or "idle"
		end
		_state.last_phase = phase
		invoke_callback("lease.phase", _state.phase_listener, phase,
			phase == "idle" and nil or generation.token)
	end
	if generation.failure_reason then
		settle_callbacks("lease.start", generation.start_callbacks, false, generation.failure_reason)
		if generation.command then
			settle_callbacks("lease.command", generation.command.callbacks,
				false, generation.failure_reason)
			generation.command = nil
		end
		if generation.queued_command then
			settle_callbacks("lease.command", generation.queued_command.callbacks,
				false, generation.failure_reason)
			generation.queued_command = nil
		end
	end
	for index = 1, #ready_barriers do settle_stop_barrier(ready_barriers[index]) end
end

--- Returns the current generation, allocating an inert one when needed.
--- @return table|nil generation Prepared or live generation.
local function current_or_prepare()
	if not _state.token_ledger_ready then
		Logger.error(LOG, "Cannot allocate a Karabiner lease while token history is unavailable: %s",
			tostring(_state.token_ledger_error))
		return nil
	end
	local current = _state.current
	if current and current.phase ~= "failed" then return current end
	if has_fencing_failure() then
		Logger.error(LOG, "Cannot allocate a replacement lease while failed variables remain unfenced.")
		return nil
	end
	local generation = create_generation()
	if not generation then
		_state.current = nil
		_state.last_phase = "failed"
		return nil
	end
	_state.current = generation
	_state.last_phase = "prepared"
	invoke_callback("lease.phase", _state.phase_listener, "prepared", generation.token)
	Logger.debug(LOG, "Prepared Karabiner lease generation %s.", generation.token)
	return generation
end

--- Updates a generation phase without letting an old generation own status or
--- publish destructive lifecycle events over a live replacement.
--- @param generation table Generation being updated.
--- @param phase string New phase.
--- @param publish_detached boolean|nil True only for M.stop's intentional stopping event.
local function set_phase(generation, phase, publish_detached)
	generation.phase = phase
	local owns_public_state = _state.current == generation
	if owns_public_state then _state.last_phase = phase end
	if owns_public_state or publish_detached == true then
		invoke_callback("lease.phase", _state.phase_listener, phase, generation.token)
	end
end

--- Cancels the generation's current acknowledgement watchdog.
--- @param generation table Generation whose timer should be cancelled.
local function cancel_ack_timer(generation)
	retry_timer_cleanup()
	release_generation_timer(generation, "ack_timer", "Lease ACK timer")
end

--- Cancels the sole recurring heartbeat owned by one exact generation.
--- @param generation table Generation whose timer must become inert.
cancel_heartbeat_timer = function(generation)
	retry_timer_cleanup()
	release_generation_timer(generation, "heartbeat_timer", "Lease heartbeat timer")
	release_generation_timer(generation, "heartbeat_retry_timer", "Lease heartbeat retry timer")
	generation.ping_sequence = nil
end

--- Cancels a pending bounded retry without touching the recurring liveness source.
--- @param generation table Generation whose one-shot retry must become inert.
cancel_heartbeat_retry_timer = function(generation)
	retry_timer_cleanup()
	release_generation_timer(generation, "heartbeat_retry_timer", "Lease heartbeat retry timer")
end





-- ============================================
-- ============================================
-- ======= 2/ Exact Fallback Revocation =======
-- ============================================
-- ============================================

local fallback_revoke

--- Retries a failed helper launch without a synchronous spin on the HS runloop.
--- Once the detached helper launches, it owns all per-attempt timeouts and
--- retries independently of Hammerspoon's lifetime.
--- @param generation table Generation whose exact variables remain suspect.
--- @param reason string Diagnostic reason retained across launch attempts.
local function schedule_fallback_retry(generation, reason)
	if generation.fallback_retry_timer then return end
	local timer = nil
	local armed = false
	local fired_before_arm = false
	local schedule_ok, timer_or_err = pcall(TimerScheduler.after, FALLBACK_RETRY_SEC, function()
		if not armed then
			fired_before_arm = true
			return
		end
		if generation.fallback_retry_timer ~= timer then return end
		generation.fallback_retry_timer = nil
		generation.fallback_started = false
		fallback_revoke(generation, reason)
	end)
	if schedule_ok then timer = timer_or_err end
	generation.fallback_retry_timer = timer
	if type(timer) ~= "table" or timer.fired == true or fired_before_arm then
		generation.fallback_retry_timer = nil
		generation.fallback_started = false
		Logger.error(LOG, "Could not schedule fallback helper retry for lease %s: %s.",
			generation.token, tostring(schedule_ok and "invalid handle" or timer_or_err))
		-- Do not settle any stop caller: without a successful fence, reporting a
		-- result would permit teardown to outrun a late generation writer.
		return false
	end
	armed = true
	return true
end

--- Revokes one captured generation through a detached retrying helper.
---
--- This is intentionally redundant with the retained native guardian. It covers
--- an outer helper killed by SIGKILL while Hammerspoon remains alive. Each
--- native CLI writer is bounded, while the helper retries
--- transient failures until exact revocation succeeds even if HS then exits.
--- Captured variable names make it harmless to any newer generation.
--- @param generation table Generation to revoke.
--- @param reason string Diagnostic reason.
--- @param on_done function|nil Callback receiving the CLI result.
fallback_revoke = function(generation, reason, on_done)
	generation.fallback_callbacks = generation.fallback_callbacks or {}
	if type(on_done) == "function" then
		generation.fallback_callbacks[#generation.fallback_callbacks + 1] = on_done
	end
	if generation.safe or generation.fallback_revoked then
		settle_callbacks("fallback_revoke", generation.fallback_callbacks, true, "fallback-revoked")
		return
	end
	if generation.fallback_started then return end
	generation.fallback_started = true
	Logger.warn(LOG, "Starting detached fallback revoker for lease %s (%s).",
		generation.token, tostring(reason))
	local handle, helper_error = spawn_current_helper(
		{ REVOKE_FLAG, KePaths.CLI, generation.mode, generation.revoked },
		function(exit_code, _stdout, stderr)
			local revoked = exit_code == 0
			if revoked then
				generation.fallback_revoked = true
				Logger.info(LOG, "Detached fallback revoked Karabiner lease %s.", generation.token)
				mark_generation_safe(generation, false, "fallback-revoked")
				settle_callbacks("fallback_revoke", generation.fallback_callbacks,
					true, "fallback-revoked")
			else
				Logger.error(LOG, "Detached fallback exited before revoking lease %s (exit %s): %s",
					generation.token, tostring(exit_code), tostring(stderr))
				schedule_fallback_retry(generation, reason)
			end
		end
	)
	if not handle then
		Logger.error(LOG, "Cannot launch native fallback revoker for lease %s: %s",
			generation.token, tostring(helper_error or "task construction failed"))
		schedule_fallback_retry(generation, reason)
		return
	end
	local start_ok, started = false, false
	if handle and type(handle.start) == "function" then
		start_ok, started = pcall(handle.start)
	end
	if not start_ok or not started then
		Logger.error(LOG, "Could not launch detached fallback revoker for lease %s; retrying.",
			generation.token)
		schedule_fallback_retry(generation, reason)
	end
end

--- Fails one generation closed and settles all outstanding operations once.
--- @param generation table Generation that can no longer be trusted.
--- @param reason string Failure detail.
local function fail_generation(generation, reason)
	if generation.failed then return end
	generation.failed = true
	generation.failure_reason = reason
	cancel_ack_timer(generation)
	cancel_heartbeat_timer(generation)
	set_phase(generation, "fencing")
	Logger.error(LOG, "Karabiner lease %s failed; fencing before publishing failure: %s",
		generation.token, tostring(reason))
	if _state.current == generation then
		_state.current = nil
		_state.retiring[generation.token] = generation
	end

	fallback_revoke(generation, reason)
	if generation.handle then
		local close_ok, closed_or_err = pcall(generation.handle.close_input)
		if not close_ok or not closed_or_err then
			Logger.error(LOG, "Could not close failed watchdog input for lease %s: %s",
				generation.token, tostring(closed_or_err))
		end
	end
end

--- Rejects a task launch that proved no native worker ever started.
--- No Karabiner variable could have been written, so manufacturing an
--- asynchronous revocation dependency would strand an otherwise inert system.
--- @param generation table Prepared generation whose start returned false.
--- @param reason string Stable failure detail.
local function reject_unlaunched_generation(generation, reason)
	if generation.failed then return end
	generation.failed = true
	generation.safe = true
	generation.failure_reason = reason
	cancel_ack_timer(generation)
	cancel_heartbeat_timer(generation)
	set_phase(generation, "failed")
	if _state.current == generation then _state.current = nil end
	settle_callbacks("lease.start", generation.start_callbacks, false, reason)
	if generation.command then
		settle_callbacks("lease.command", generation.command.callbacks, false, reason)
		generation.command = nil
	end
	if generation.queued_command then
		settle_callbacks("lease.command", generation.queued_command.callbacks, false, reason)
		generation.queued_command = nil
	end
	Logger.error(LOG, "Karabiner lease %s worker did not launch: %s",
		generation.token, tostring(reason))
end

--- Arms a bounded timeout for one expected protocol acknowledgement.
--- @param generation table Generation awaiting the ACK.
--- @param expected string Expected protocol line.
local function arm_ack_timer(generation, expected)
	cancel_ack_timer(generation)
	generation.awaiting = expected
	local timeout = COMMAND_ACK_TIMEOUT_SEC
	if expected == "READY" then timeout = READY_ACK_TIMEOUT_SEC end
	if expected == "STOPPED" then timeout = STOP_ACK_TIMEOUT_SEC end
	local timer = nil
	local armed = false
	local fired_before_arm = false
	local schedule_ok, timer_or_err = pcall(TimerScheduler.after, timeout, function()
		if not armed then
			fired_before_arm = true
			return
		end
		-- A cancelled callback may already be queued. ACK text is not unique across
		-- transitions (PAUSE → RESUME → PAUSE), so only the currently retained timer
		-- may fence the generation.
		if generation.ack_timer ~= timer
			or generation.awaiting ~= expected or generation.failed then return end
		generation.ack_timer = nil
		fail_generation(generation, "timeout waiting for " .. expected)
	end)
	if schedule_ok then timer = timer_or_err end
	generation.ack_timer = timer
	if type(timer) ~= "table" or timer.fired == true or fired_before_arm then
		generation.ack_timer = nil
		fail_generation(generation, "could not arm timeout for " .. expected .. ": "
			.. tostring(schedule_ok and "invalid handle" or timer_or_err))
		return
	end
	armed = true
end





-- =========================================
-- =========================================
-- ======= 3/ Watchdog Line Protocol =======
-- =========================================
-- =========================================

local send_command
local send_ping

--- Moves callbacks from an older queued intent onto the live command that now
--- represents the same desired state. The queued callbacks come first because
--- their requests were accepted before the re-entrant command.
--- @param command table Live command descriptor.
--- @param queued table Detached older command descriptor.
local function prepend_queued_callbacks(command, queued)
	local merged = {}
	for _, callback in ipairs(queued.callbacks or {}) do merged[#merged + 1] = callback end
	for _, callback in ipairs(command.callbacks or {}) do merged[#merged + 1] = callback end
	command.callbacks = merged
end

--- Reconciles a queued command detached before lifecycle callbacks run.
--- A callback may synchronously publish newer pause/resume intent. Dispatching
--- the old queue unconditionally afterwards would let that older command
--- overtake the latest user action on the native stdin stream.
--- @param generation table Generation whose callback just ran.
--- @param queued table|nil Command detached before callback publication.
--- @param observed_revision integer Latest intent revision before callbacks.
local function reconcile_detached_command(generation, queued, observed_revision)
	if not queued then return end
	if generation.failed or generation.stop_requested then
		settle_callbacks("lease.command", queued.callbacks, false, "generation-stopping")
		return
	end

	local current_revision = generation.intent_revision or 0
	if current_revision == observed_revision and generation.command == nil then
		send_command(generation, queued)
		return
	end

	-- A newer request may already have sent the same native state transition.
	-- Join it instead of issuing a duplicate write or rejecting an older caller
	-- whose desired final state still matches.
	if generation.command and generation.command.kind == queued.kind then
		prepend_queued_callbacks(generation.command, queued)
		return
	end

	local settled_phase = queued.kind == "pause" and "paused" or "active"
	if generation.command == nil
		and generation.phase == settled_phase
		and generation.latest_intent_kind == queued.kind then
		settle_callbacks("lease.command", queued.callbacks, true, "already-" .. settled_phase)
		return
	end

	settle_callbacks(
		"lease.command",
		queued.callbacks,
		false,
		"superseded-by-" .. tostring(generation.latest_intent_kind or "reentrant-command")
	)
end

--- Parses one exact sequenced heartbeat result from the native worker.
--- @param line string Complete public protocol line.
--- @return string|nil result `pong` or `failed`.
--- @return integer|nil sequence Canonical positive sequence.
local function parse_ping_result(line)
	local result = "pong"
	local raw_sequence = line:match("^PONG ([1-9]%d*)$")
	if not raw_sequence then
		result = "failed"
		raw_sequence = line:match("^PING_FAILED ([1-9]%d*)$")
	end
	if not raw_sequence then return nil, nil end
	local sequence = tonumber(raw_sequence)
	if type(sequence) ~= "number" or sequence % 1 ~= 0
		or sequence < 1 or sequence > MAX_PING_SEQUENCE
		or string.format("%d", sequence) ~= raw_sequence then
		return nil, nil
	end
	return result, sequence
end

--- Dispatches the latest pause/resume intent after a ping transport settles.
--- @param generation table Generation whose ping no longer owns task input.
local function dispatch_after_ping(generation)
	local queued = generation.queued_command
	generation.queued_command = nil
	local observed_revision = generation.intent_revision or 0
	reconcile_detached_command(generation, queued, observed_revision)
end

--- Retains the sole timer allowed to originate native lease heartbeats.
--- @param generation table READY generation receiving the timer.
--- @return boolean True only when a live recurring timer was retained.
local function arm_heartbeat_timer(generation)
	if generation.heartbeat_timer then return true end
	local timer
	local schedule_ok, timer_or_err = pcall(TimerScheduler.every, HEARTBEAT_INTERVAL_SEC, function()
		if not _state or _state.current ~= generation
			or generation.heartbeat_timer ~= timer
			or generation.failed or generation.stop_requested then
			return
		end
		send_ping(generation, "timer")
	end)
	if schedule_ok then timer = timer_or_err end
	generation.heartbeat_timer = timer
	if type(timer) ~= "table" or timer.fired == true then
		generation.heartbeat_timer = nil
		fail_generation(generation, "could not arm sequenced heartbeat timer: "
			.. tostring(schedule_ok and "invalid handle" or timer_or_err))
		return false
	end
	return true
end

--- Schedules the sole bounded retry after one negative heartbeat transport.
--- The recurring timer and wake hook are suppressed while this handle is live,
--- preventing an instant CLI failure from turning into a subprocess spin.
--- @param generation table Recovering generation.
--- @return boolean True only when a live one-shot retry was retained.
local function schedule_heartbeat_retry(generation)
	if generation.heartbeat_retry_timer then return true end
	local timer
	local armed = false
	local fired_before_arm = false
	local schedule_ok, timer_or_err = pcall(TimerScheduler.after, HEARTBEAT_RETRY_SEC, function()
		if not armed then
			fired_before_arm = true
			return
		end
		if not _state or _state.current ~= generation
			or generation.heartbeat_retry_timer ~= timer
			or generation.failed or generation.stop_requested then
			return
		end
		generation.heartbeat_retry_timer = nil
		if not send_ping(generation, "retry") and not generation.failed then
			fail_generation(generation, "could not send bounded heartbeat retry")
		end
	end)
	if schedule_ok then timer = timer_or_err end
	generation.heartbeat_retry_timer = timer
	if type(timer) ~= "table" or timer.fired == true or fired_before_arm then
		generation.heartbeat_retry_timer = nil
		fail_generation(generation, "could not arm bounded heartbeat retry: "
			.. tostring(schedule_ok and "invalid handle" or timer_or_err))
		return false
	end
	armed = true
	return true
end

--- Completes the currently pending pause or resume command.
--- @param generation table Generation receiving the ACK.
--- @param ack string PAUSED or RESUMED.
local function complete_command(generation, ack)
	local command = generation.command
	if not command or command.ack ~= ack or generation.awaiting ~= ack then
		fail_generation(generation, "unexpected " .. ack .. " acknowledgement")
		return
	end
	cancel_ack_timer(generation)
	generation.awaiting = nil
	generation.command = nil
	cancel_heartbeat_retry_timer(generation)
	generation.heartbeat_transport_failures = 0
	generation.recovery_phase = nil
	-- Detach before set_phase(): both the phase listener and the completed
	-- command's callbacks may re-enter pause()/resume(). They must observe no
	-- hidden older queue and their newer intent must win deterministically.
	local queued = generation.queued_command
	generation.queued_command = nil
	local observed_revision = generation.intent_revision or 0
	set_phase(generation, command.kind == "pause" and "paused" or "active")
	settle_callbacks("lease." .. command.kind, command.callbacks, true, ack:lower())
	reconcile_detached_command(generation, queued, observed_revision)
end

--- Processes one complete stdout protocol line.
--- @param generation table Generation that emitted the line.
--- @param line string Line without its terminator.
local function process_line(generation, line)
	if generation.failed or line == "" then return end
	if line == "READY" then
		if generation.ready then return end
		if generation.stop_requested then
			-- STOP can be queued while the helper is still activating. READY then
			-- describes the superseded activation, not a protocol violation
			generation.ready = true
			return
		end
		if generation.awaiting ~= "READY" then
			fail_generation(generation, "unexpected READY acknowledgement")
			return
		end
		generation.ready = true
		cancel_ack_timer(generation)
		generation.awaiting = nil
		generation.heartbeat_transport_failures = 0
		generation.recovery_phase = nil
		if generation.stop_requested then return end
		if not arm_heartbeat_timer(generation) then return end
		-- The just-completed ACTIVATE is the HS-originated bootstrap pulse. Retain
		-- the first-fire-after-5s timer before publishing the live phase; the inner
		-- allows 1.75s additional command slack, so a pre-first-tick hang still
		-- reaches exact fencing rather than creating an unbounded bootstrap gap.
		local ready_phase = generation.initial_paused and "paused" or "active"
		local ready_reason = generation.initial_paused and "ready-paused" or "ready"
		-- As with command completion, hide the older queue before any lifecycle or
		-- start callback can publish a newer pause/resume request.
		local queued = generation.queued_command
		generation.queued_command = nil
		-- Keep the detached intent observable while start callbacks prepare local
		-- consumers. A cold-start callback must not overwrite an older user PAUSE
		-- merely because the queue is temporarily held in this stack frame.
		generation.reconciling_command = queued
		local observed_revision = generation.intent_revision or 0
		set_phase(generation, ready_phase)
		Logger.info(LOG, "Karabiner lease %s activated %s by watchdog READY.",
			generation.token, generation.initial_paused and "paused" or "active")
		settle_callbacks("lease.start", generation.start_callbacks, true, ready_reason)
		generation.reconciling_command = nil
		if queued and queued.kind == (ready_phase == "paused" and "pause" or "resume")
			and (generation.intent_revision or 0) == observed_revision then
			settle_callbacks("lease.command", queued.callbacks, true, "already-" .. ready_phase)
		else
			reconcile_detached_command(generation, queued, observed_revision)
		end
		return
	end
	local ping_result, ping_sequence = parse_ping_result(line)
	if ping_result then
		if generation.stop_requested then return end
		local expected = "PONG " .. tostring(ping_sequence)
		if generation.ping_sequence ~= ping_sequence or generation.awaiting ~= expected then
			fail_generation(generation, "unexpected or stale " .. line)
			return
		end
		cancel_ack_timer(generation)
		generation.awaiting = nil
		generation.ping_sequence = nil
		if ping_result == "failed" then
			generation.heartbeat_transport_failures =
				(generation.heartbeat_transport_failures or 0) + 1
			Logger.warn(LOG, "Karabiner lease %s heartbeat %d had no clean local CLI transport.",
				generation.token, ping_sequence)
			if generation.heartbeat_transport_failures
				>= MAX_CONSECUTIVE_HEARTBEAT_FAILURES then
				fail_generation(generation, "repeated heartbeat transport failure")
				return
			end
			if generation.phase == "active" or generation.phase == "paused" then
				generation.recovery_phase = generation.phase
			elseif generation.phase ~= "recovering" or not generation.recovery_phase then
				fail_generation(generation, "heartbeat failed outside a settled live phase")
				return
			end
			set_phase(generation, "recovering")
			if not schedule_heartbeat_retry(generation) then return end
			dispatch_after_ping(generation)
			return
		end
		generation.heartbeat_transport_failures = 0
		cancel_heartbeat_retry_timer(generation)
		dispatch_after_ping(generation)
		if not generation.failed and generation.phase == "recovering"
			and not generation.command and not generation.ping_sequence then
			local recovered_phase = generation.recovery_phase
			generation.recovery_phase = nil
			if recovered_phase ~= "active" and recovered_phase ~= "paused" then
				fail_generation(generation, "heartbeat recovery lost its settled phase")
				return
			end
			set_phase(generation, recovered_phase)
		end
		return
	end
	if line == "PAUSED" or line == "RESUMED" then
		if generation.stop_requested then
			-- The helper may have consumed the superseded command just before STOP
			-- replaced pending stdin; its stale ACK cannot outrank the stop request
			return
		end
		complete_command(generation, line)
		return
	end
	if line == "STOPPED" then
		if not generation.stop_requested then
			fail_generation(generation, "unexpected STOPPED acknowledgement")
			return
		end
		generation.stop_ack = true
		generation.awaiting = nil
		cancel_ack_timer(generation)
		-- STOPPED is emitted only after the native engine's repeated clean local
		-- fence transports. A later hs.task stdin-close failure cannot invalidate
		-- that protocol completion; STOPPED is not a Karabiner receiver ACK.
		if generation.handle and not generation.completed then
			local close_ok, closed = pcall(generation.handle.close_input)
			if not close_ok or not closed then
				Logger.warn(LOG, "Could not close completed watchdog input for lease %s.", generation.token)
			end
		end
		mark_generation_safe(generation, true, "stopped")
		return
	end
	fail_generation(generation, "unknown watchdog protocol line: " .. line)
end

--- Feeds arbitrarily chunked stdout into the line parser.
--- @param generation table Generation emitting bytes.
--- @param chunk string|nil New stdout bytes.
local function consume_stdout(generation, chunk)
	if generation.failed or type(chunk) ~= "string" or chunk == "" then return end
	if #generation.stdout_buffer + #chunk > MAX_PROTOCOL_BUFFER_BYTES then
		generation.stdout_buffer = ""
		fail_generation(generation, string.format(
			"watchdog protocol line exceeded %d bytes",
			MAX_PROTOCOL_BUFFER_BYTES
		))
		return
	end
	generation.stdout_buffer = generation.stdout_buffer .. chunk
	while true do
		local newline = generation.stdout_buffer:find("\n", 1, true)
		if not newline then break end
		local line = generation.stdout_buffer:sub(1, newline - 1):gsub("\r$", "")
		generation.stdout_buffer = generation.stdout_buffer:sub(newline + 1)
		process_line(generation, line)
	end
end

--- Sends one framed command only after the previous command was acknowledged.
--- @param generation table Target generation.
--- @param command table Command descriptor.
send_command = function(generation, command)
	if generation.failed or generation.stop_requested then
		settle_callbacks("lease.command", command.callbacks, false, "generation-stopping")
		return false
	end
	cancel_heartbeat_retry_timer(generation)
	generation.command = command
	-- Publish the expected ACK before writing. The current hs.task implementation
	-- delivers child output on a later main-runloop turn, but the adapter contract
	-- does not promise non-reentrance and a future transport may acknowledge from
	-- inside set_input().
	generation.awaiting = command.ack
	set_phase(generation, command.kind == "pause" and "pausing" or "resuming")
	local write_ok, wrote = pcall(generation.handle.set_input, command.wire .. "\n")
	if not write_ok or not wrote then
		fail_generation(generation, "could not send " .. command.wire)
		-- The request remains accepted for asynchronous settlement: fail_generation
		-- retains its callbacks until an exact fallback fence is proven.
		return true
	end
	if generation.awaiting == command.ack and not generation.failed then
		arm_ack_timer(generation, command.ack)
	end
	return true
end

--- Sends one sequenced ping only when no task input remains unacknowledged.
--- @param generation table Live READY generation.
--- @param origin string Diagnostic origin such as timer or wake.
--- @return boolean True when sent or an existing write already renews liveness.
send_ping = function(generation, origin)
	if generation.failed or generation.stop_requested then return false end
	if generation.heartbeat_retry_timer then return true end
	if generation.command or generation.ping_sequence then return true end
	if generation.phase ~= "active" and generation.phase ~= "paused"
		and generation.phase ~= "recovering" then return false end
	local previous = generation.last_ping_sequence or 0
	local sequence = previous >= MAX_PING_SEQUENCE and 1 or previous + 1
	generation.last_ping_sequence = sequence
	generation.ping_sequence = sequence
	local expected = "PONG " .. tostring(sequence)
	generation.awaiting = expected
	local wire = "PING " .. tostring(sequence)
	local write_ok, wrote = pcall(generation.handle.set_input, wire .. "\n")
	if not write_ok or not wrote then
		fail_generation(generation, "could not send " .. wire)
		return false
	end
	Logger.debug(LOG, "Karabiner lease %s heartbeat %d sent by %s.",
		generation.token, sequence, tostring(origin))
	if generation.awaiting == expected and not generation.failed then
		arm_ack_timer(generation, expected)
	end
	return not generation.failed
end

--- Requests a pause-state transition while serializing native task input.
--- @param target_paused boolean Desired pause state.
--- @param on_done function|nil Result callback.
--- @return boolean True when accepted or already satisfied.
local function request_pause_state(target_paused, on_done)
	local generation = _state.current
	if not generation or generation.failed or generation.stop_requested then
		Logger.error(LOG, "Cannot change pause state — no live Karabiner generation exists.")
		invoke_callback("lease.command", on_done, false, "no-live-lease")
		return false
	end
	local kind = target_paused and "pause" or "resume"
	local settled_phase = target_paused and "paused" or "active"
	if generation.phase == "prepared" then
		Logger.error(LOG, "Cannot %s lease %s before its watchdog starts.", kind, generation.token)
		invoke_callback("lease." .. kind, on_done, false, "watchdog-not-started")
		return false
	end
	generation.intent_revision = (generation.intent_revision or 0) + 1
	local request_revision = generation.intent_revision
	generation.latest_intent_kind = kind
	if generation.phase == settled_phase and not generation.command then
		-- A heartbeat can hold the task input slot while an opposite transition is
		-- queued.  The settled phase still describes the pre-queue state, so a
		-- latest request for that state must explicitly supersede the stale queue;
		-- otherwise PONG would dispatch the older user intent afterwards.
		local superseded = generation.queued_command
		generation.queued_command = nil
		if superseded then
			settle_callbacks("lease.command", superseded.callbacks,
				false, "superseded-by-" .. kind)
		end
		invoke_callback("lease." .. kind, on_done, true, "already-" .. settled_phase)
		return true
	end

	if generation.command and generation.command.kind == kind then
		local active_command = generation.command
		local superseded = generation.queued_command
		if superseded and superseded.kind ~= kind then
			-- Detach before user code runs. A rejected callback may synchronously
			-- publish a newer opposite intent, which must remain in the live slot.
			generation.queued_command = nil
			settle_callbacks("lease.command", superseded.callbacks,
				false, "superseded-by-" .. kind)
		end
		if _state.current ~= generation or generation.failed
			or generation.stop_requested or generation.command ~= active_command then
			invoke_callback("lease." .. kind, on_done, false, "generation-stopping")
			return true
		end
		if type(on_done) == "function" then
			active_command.callbacks[#active_command.callbacks + 1] = on_done
		end
		active_command.revision = math.max(active_command.revision or 0, request_revision)
		return true
	end

	local command = {
		kind = kind,
		wire = target_paused and "PAUSE" or "RESUME",
		ack = target_paused and "PAUSED" or "RESUMED",
		revision = request_revision,
		callbacks = {},
	}
	if type(on_done) == "function" then command.callbacks[1] = on_done end

	if generation.command or generation.ping_sequence or generation.phase == "starting" then
		if generation.queued_command and generation.queued_command.kind == kind then
			if type(on_done) == "function" then
				generation.queued_command.callbacks[#generation.queued_command.callbacks + 1] = on_done
			end
			generation.queued_command.revision = request_revision
			return true
		end
		local superseded = generation.queued_command
		-- Publish the replacement before invoking rejected callbacks. Re-entrant
		-- user intent can then supersede this request instead of being appended to
		-- the detached command and silently discarded on return.
		generation.queued_command = command
		if superseded then
			settle_callbacks("lease.command", superseded.callbacks,
				false, "superseded-by-" .. kind)
		end
		return true
	end
	return send_command(generation, command)
end





-- ===================================
-- ===================================
-- ======= 4/ Public Lifecycle =======
-- ===================================
-- ===================================

--- Reports whether the controller already owns initialized state.
--- @return boolean initialized True after the first M.init() call.
function M.is_initialized()
	return _state ~= nil
end

--- Initializes the controller without touching Karabiner or starting a task.
--- @param phase_listener function|nil Guarded callback fn(phase, token) invoked
---   for lifecycle changes so dependent consumers can release claimed state.
--- @return boolean True when initialized.
function M.init(phase_listener)
	Logger.start(LOG, "Initializing Karabiner lease controller…")
	if _state then
		Logger.warn(LOG, "M.init() called more than once — keeping the existing controller.")
		return _state.token_ledger_ready == true
	end
	local helper_path, helper_err = LeaseHelper.resolve()
	local used_tokens, used_token_order, token_ledger_error = load_used_token_ledger()
	local token_ledger_ready = used_tokens ~= nil and used_token_order ~= nil
	_state = {
		current = nil,
		retiring = {},
		stop_barriers = {},
		timer_cleanup_backlog = {},
		used_tokens = used_tokens or {},
		used_token_order = used_token_order or {},
		token_ledger_ready = token_ledger_ready,
		token_ledger_error = token_ledger_error,
		helper_path = helper_path,
		helper_error = helper_err,
		last_phase = token_ledger_ready and "idle" or "failed",
		phase_listener = type(phase_listener) == "function" and phase_listener or nil,
	}
	invoke_callback("lease.phase", _state.phase_listener, _state.last_phase, nil)
	if not token_ledger_ready then
		Logger.error(LOG, "Karabiner lease token history unavailable — %s. Rules remain inert.",
			tostring(token_ledger_error))
		return false
	end
	if not helper_path then
		Logger.error(LOG, "Native Karabiner lease helper unavailable — %s", tostring(helper_err))
	end
	Logger.success(LOG, "Karabiner lease controller initialized.")
	return true
end

--- Returns or allocates the current generation token without external effects.
--- @return string|nil token Lowercase 32-hex token.
function M.token()
	if not require_state("token") then return nil end
	local generation = current_or_prepare()
	return generation and generation.token or nil
end

--- Returns the variable names that the generator must gate into every rule.
--- @return table|nil variables Token, atomic mode, and tombstone names.
function M.variables()
	if not require_state("variables") then return nil end
	local generation = current_or_prepare()
	if not generation then return nil end
	return LeaseContract.variables(generation.token)
end

--- Starts one retained watchdog in its exact initial pause state.
--- @param initial_paused boolean True only for a fail-closed transaction while paused.
--- @param on_done function|nil Callback fn(ok, reason) after READY or failure.
--- @return boolean True when launch succeeded or activation is already pending.
local function start_generation(initial_paused, on_done)
	if not require_state("start") then return false end
	initial_paused = initial_paused == true
	local generation = current_or_prepare()
	if not generation then
		invoke_callback("lease.start", on_done, false, "token-allocation-failed")
		return false
	end
	if generation.phase == "active" or generation.phase == "paused" then
		local matches = (generation.phase == "paused") == initial_paused
		invoke_callback("lease.start", on_done, matches,
			matches and "already-" .. generation.phase or "initial-state-mismatch")
		return matches
	end
	if generation.phase == "starting" then
		if generation.initial_paused ~= initial_paused then
			Logger.error(LOG, "Cannot join generation %s start with a different initial mode.", generation.token)
			invoke_callback("lease.start", on_done, false, "initial-state-mismatch")
			return false
		end
		if type(on_done) == "function" then
			generation.start_callbacks[#generation.start_callbacks + 1] = on_done
		end
		return true
	end
	if generation.phase ~= "prepared" then
		Logger.error(LOG, "Cannot start lease %s from phase %s.", generation.token, generation.phase)
		invoke_callback("lease.start", on_done, false, "invalid-phase")
		return false
	end
	if type(on_done) == "function" then
		generation.start_callbacks[#generation.start_callbacks + 1] = on_done
	end
	generation.initial_paused = initial_paused

	Logger.start(LOG, "Starting Karabiner lease watchdog %s…", generation.token)
	set_phase(generation, "starting")
	local handle, helper_error = spawn_current_helper(
		{
			WORKER_FLAG,
			KePaths.CLI,
			generation.mode,
			generation.revoked,
			initial_paused and tostring(LeaseContract.MODE_PAUSED)
				or tostring(LeaseContract.MODE_ACTIVE),
			tostring(HEARTBEAT_INTERVAL_SEC),
		},
		function(exit_code, stdout, stderr)
			generation.completed = true
			if not generation.stop_requested then
				-- Completion status is authoritative. A final buffered READY from a
				-- process that exited non-zero must never settle activation true.
				local detail = string.format("watchdog exited unexpectedly (exit %s): %s",
					tostring(exit_code), tostring(stderr))
				fail_generation(generation, detail)
				return
			end
			consume_stdout(generation, stdout)

			-- hs.task may deliver one final streaming callback after completion and
			-- documents no next-runloop bound. Revoke redundantly now, but leave the
			-- existing STOPPED ACK timeout authoritative: a late final chunk can still
			-- complete the retained-worker protocol until that bounded deadline expires.
			fallback_revoke(generation, "watchdog completion")
			Logger.info(LOG, "Karabiner lease watchdog %s stopped (exit %s); %s.",
				generation.token,
				tostring(exit_code),
				generation.stop_ack and "STOPPED acknowledged" or "awaiting final STOPPED chunk")
		end,
		function(_task, stdout_chunk, stderr_chunk)
			consume_stdout(generation, stdout_chunk)
			if type(stderr_chunk) == "string" and stderr_chunk ~= "" then
				Logger.warn(LOG, "Lease watchdog %s stderr: %s",
					generation.token, stderr_chunk:gsub("%s+$", ""))
			end
			return true
		end
	)
	if not handle then
		reject_unlaunched_generation(generation,
			"native helper identity unavailable: " .. tostring(helper_error or "task construction failed"))
		return false
	end
	generation.handle = handle
	-- Publish the expected ACK before start(): real task callbacks are deferred,
	-- but a faithful adapter or future implementation may report immediate output
	generation.awaiting = "READY"
	local start_ok, started = false, false
	if handle and type(handle.start) == "function" then
		start_ok, started = pcall(handle.start)
	end
	if not start_ok then
		fail_generation(generation, "watchdog start raised")
		return false
	end
	if not started then
		reject_unlaunched_generation(generation, "watchdog launch refused")
		return false
	end
	if not generation.ready then arm_ack_timer(generation, "READY") end
	if generation.failed then return false end
	if generation.ready then
		Logger.success(LOG, "Karabiner lease watchdog %s launched and acknowledged READY.", generation.token)
	else
		Logger.success(LOG, "Karabiner lease watchdog %s launched; awaiting READY.", generation.token)
	end
	return true
end

--- Low-level ACTIVE transport retained for protocol tests and diagnostics.
--- Production remap orchestration never calls this for a fresh generation; it
--- must use start_paused() and mount every local consumer before RESUME.
--- @param on_done function|nil Callback fn(ok, reason) after READY or failure.
--- @return boolean True when launch succeeded or activation is already pending.
function M.start(on_done)
	return start_generation(false, on_done)
end

--- Starts a fresh fail-closed generation with atomic mode=2 before READY.
--- Normal boot, enable, resume recovery, and failed-disable recovery all use
--- this path; the remap orchestrator decides dynamically whether to remain
--- paused or send RESUME after local preparation.
--- @param on_done function|nil Callback fn(ok, reason) after paused READY or failure.
--- @return boolean True when launch succeeded or activation is already pending.
function M.start_paused(on_done)
	return start_generation(true, on_done)
end

--- Pauses Ergopti rules through an acknowledged token-scoped command.
--- @param on_done function|nil Callback fn(ok, reason).
--- @return boolean True when accepted.
function M.pause(on_done)
	if not require_state("pause") then return false end
	return request_pause_state(true, on_done)
end

--- Resumes Ergopti rules through an acknowledged token-scoped command.
--- @param on_done function|nil Callback fn(ok, reason).
--- @return boolean True when accepted.
function M.resume(on_done)
	if not require_state("resume") then return false end
	return request_pause_state(false, on_done)
end

--- Activates a freshly prepared PAUSED generation only when no older PAUSE
--- intent is current or temporarily detached by READY reconciliation. The exact
--- token prevents a stale local mount from resuming a replacement generation.
--- Explicit user resume uses M.resume(); this stricter API is for cold-start and
--- enable transactions that must never overtake a user pause.
--- @param token string Exact generation capability captured before local mount.
--- @param on_done function|nil Callback fn(ok, reason).
--- @return boolean True when RESUME was accepted.
function M.resume_prepared(token, on_done)
	if not require_state("resume_prepared") then return false end
	local generation = _state.current
	if not generation or generation.token ~= token or generation.phase ~= "paused"
		or generation.failed or generation.stop_requested then
		invoke_callback("lease.resume_prepared", on_done, false, "prepared-generation-changed")
		return false
	end
	local pending = generation.reconciling_command or generation.command
		or generation.queued_command
	if generation.latest_intent_kind == "pause"
		or (pending and pending.kind == "pause") then
		invoke_callback("lease.resume_prepared", on_done, false, "pause-intent-pending")
		return false
	end
	return request_pause_state(false, on_done)
end

--- Requests immediate serialized liveness recovery after wake or unlock.
--- @return boolean True when a ping was sent or another write is already in flight.
function M.refresh_liveness()
	if not require_state("refresh_liveness") then return false end
	local generation = _state.current
	if not generation or generation.failed or generation.stop_requested then
		Logger.warn(LOG, "Cannot refresh Karabiner lease liveness — no live generation exists.")
		return false
	end
	return send_ping(generation, "wake")
end

--- Stops the current generation without touching any stock Karabiner process.
---
--- The generation is detached before asynchronous cleanup so an immediate
--- re-enable receives a different token. STOPPED must arrive before the
--- controller closes stdin; if the ACK is lost, the bounded timeout and
--- completion callback both revoke the captured old names.
--- @param reason string|nil Diagnostic reason.
--- @param on_done function|nil Callback fn(ok, reason).
--- @return boolean True when stop was accepted or no generation was live.
function M.stop(reason, on_done)
	if not require_state("stop") then return false end
	retry_timer_cleanup()
	if type(reason) == "function" and on_done == nil then
		on_done = reason
		reason = nil
	end
	local generation = _state.current
	if not generation then
		if not mark_retiring_stop_requested() then
			local phase_changed = _state.last_phase ~= "idle"
			_state.last_phase = "idle"
			if phase_changed then
				invoke_callback("lease.phase", _state.phase_listener, "idle", nil)
			end
		end
		create_stop_barrier(on_done)
		return true
	end
	cancel_heartbeat_timer(generation)
	_state.current = nil
	_state.retiring[generation.token] = generation
	_state.last_phase = "stopping"
	set_phase(generation, "stopping", true)
	mark_retiring_stop_requested()
	-- Snapshot every older retiring generation before any call below can settle
	-- synchronously. The caller observes a system-wide Ergopti fence, not merely
	-- the newest token's STOPPED line.
	create_stop_barrier(on_done)
	Logger.info(LOG, "Stopping Karabiner lease %s (%s).", generation.token, tostring(reason or "unspecified"))

	cancel_ack_timer(generation)
	settle_callbacks("lease.start", generation.start_callbacks, false, "stopped-before-ready")
	if generation.command then
		settle_callbacks("lease.command", generation.command.callbacks, false, "lease-stopping")
		generation.command = nil
	end
	if generation.queued_command then
		settle_callbacks("lease.command", generation.queued_command.callbacks, false, "lease-stopping")
		generation.queued_command = nil
	end

	if not generation.handle then
		mark_generation_safe(generation, true, "prepared-only")
		return true
	end
	-- As with pause/resume, publish the expected ACK before the transport call so
	-- a re-entrant STOPPED cannot be followed by a phantom timeout.
	generation.awaiting = "STOPPED"
	local ok_send, sent = pcall(generation.handle.set_input, "STOP\n")
	if not ok_send or not sent then
		fail_generation(generation, "stop channel failure")
		-- The stop request remains accepted: its aggregate callback settles only
		-- after the detached native revoker completes its clean fence transports.
		return true
	end
	if generation.awaiting == "STOPPED" and not generation.safe and not generation.failed then
		arm_ack_timer(generation, "STOPPED")
	end
	-- A timer-setup failure also enters exact fallback fencing. It must not make
	-- the caller roll back while that accepted stop operation is still pending.
	return true
end

--- Stops only the named generation. A stale caller must never revoke the live
--- replacement merely because its local mount failed after ownership changed.
--- A generation already in the retiring set is already being fenced, so this
--- method joins the aggregate safety barrier without touching `_state.current`.
--- @param token string Exact generation capability.
--- @param reason string|nil Diagnostic reason.
--- @param on_done function|nil Callback fn(ok, reason).
--- @return boolean True when the exact generation is stopped, retiring, or gone.
function M.stop_exact(token, reason, on_done)
	if not require_state("stop_exact") then return false end
	retry_timer_cleanup()
	if not LeaseContract.is_valid_token(token) then
		invoke_callback("lease.stop_exact", on_done, false, "invalid-token")
		return false
	end
	local current = _state.current
	if current and current.token == token then return M.stop(reason, on_done) end
	if _state.retiring[token] then
		create_stop_barrier(on_done)
		return true
	end
	invoke_callback("lease.stop_exact", on_done, true, "generation-gone")
	return true
end

--- Returns the current public phase and a diagnostic snapshot.
--- @return string phase Current lifecycle phase.
--- @return table snapshot Token-scoped state safe for status UIs.
function M.status()
	if not require_state("status") then return "uninitialized", { phase = "uninitialized" } end
	retry_timer_cleanup()
	local generation = _state.current
	local phase
	if generation then
		phase = generation.phase
	else
		generation = any_retiring()
		phase = generation and retiring_phase() or _state.last_phase
	end
	return phase, {
		phase = phase,
		token = generation and generation.token or nil,
		mode = generation and generation.mode or nil,
		revoked = generation and generation.revoked or nil,
		activation_blocked = generation ~= nil and (
			generation.latest_intent_kind == "pause"
			or (generation.reconciling_command
				and generation.reconciling_command.kind == "pause")
			or (generation.command and generation.command.kind == "pause")
			or (generation.queued_command and generation.queued_command.kind == "pause")
		) or false,
	}
end

return M
