--- platform/remap/ke_variables.lua

--- ==============================================================================
--- MODULE: Karabiner Variable Bridge
--- DESCRIPTION:
--- Serializes Karabiner-Elements engine-variable state from Hammerspoon, which
--- is how the driver reaches state that lives inside Karabiner rather than macOS.
---
--- FEATURES & RATIONALE:
--- 1. One Write Boundary: `karabiner_cli --set-variables` receives each submitted
---    variable, or the latest coalesced pending values, through one child. The
---    upstream CLI may enqueue object members separately, so this module makes no
---    multi-variable transaction guarantee.
--- 2. Async, always. `hs.execute` blocks the Hammerspoon runloop, and these calls
---    are made from a gesture callback — the one place a blocking subprocess is
---    felt as the pointer stuttering under the user's fingers.
--- 3. Serialized Latest-Wins: one CLI child runs at a time. Pending variable
---    values coalesce by name, retaining the newest value without discarding an
---    unrelated pending write such as CapsWord.
--- 4. Lease Isolation: every accepted logical name is rewritten to the current
---    exact generation before JSON encoding. A writer orphaned by reload or
---    Force Quit can therefore mutate only its already-revoked generation.
--- 5. Shared-Process Safety: this bridge controls no Karabiner process. Its only
---    external operation is an exact, token-scoped CLI variable write; bare
---    personal variables and the stock Karabiner process family stay untouched.
--- 6. Bounded Liveness: every writer has a watchdog. A new exact generation
---    preempts an unresponsive old child immediately, and late completion from
---    that detached child cannot release the successor's serializer slot.
--- ==============================================================================

local M = {}

local Logger        = require("infra.logger")
local JsonCodec     = require("adapters.json_codec")
local ShellRunner   = require("adapters.shell_runner")
local TimerScheduler = require("adapters.timer_scheduler")
local KePaths       = require("platform.remap.ke_paths")
local LeaseContract = require("platform.remap.lease_contract")
local LeaseController = require("platform.remap.lease_controller")

local LOG = "karabiner.variables"

-- The plural operation accepts the coalesced variable map as one CLI payload.
local SET_VARIABLES_FLAG = "--set-variables"

-- karabiner_cli variable writes normally complete in milliseconds. Five seconds
-- tolerates severe scheduler pressure while keeping a started-but-never-completing
-- child from wedging every later gesture for the lifetime of Hammerspoon.
local VARIABLE_WRITER_TIMEOUT_SEC = 5.0

-- A refused transient launch or nonzero child exit is retried twice after the
-- initial attempt. The delay prevents fork-pressure failures from recursing on
-- the Hammerspoon callback stack while keeping gesture recovery sub-second.
local VARIABLE_WRITER_RETRY_DELAY_SEC = 0.25
local VARIABLE_WRITER_MAX_ATTEMPTS = 3

local CAPSWORD_LOGICAL_NAME = "capsword"

local _active_batch = nil
local _active_handle = nil
local _active_timeout = nil
local _pending_batch = nil
local _retry_timer = nil
local _retry_token = nil
local _recovery_in_progress = false
local _poisoned_tokens = {}
local _fence_retries = {}
local _poison_settlements = {}
local _timer_cleanup_backlog = {}
local _child_cleanup_backlog = {}
local _fence_requested_tokens = {}
local _recovery_observer = nil

-- Revisions describe logical user intent, not subprocess completion. They stay
-- monotonic across lease generations so an old asynchronous probe can never
-- clear a newer generation that happens to have the same desired value.
local _logical_token = nil
local _logical_values = {}
local _logical_revisions = { [CAPSWORD_LOGICAL_NAME] = 0 }





-- ===================================
-- ===================================
-- ======= 1/ Write Validation =======
-- ===================================
-- ===================================

--- Invokes one optional settlement callback without letting it abort serializer cleanup.
--- @param callback function|nil Callback fn(ok, reason, revision).
--- @param ok boolean Settlement outcome.
--- @param reason string Stable settlement reason.
--- @param revision number Logical revision assigned to the request.
local function invoke_callback(callback, ok, reason, revision)
	if type(callback) ~= "function" then return end
	local called, err = xpcall(function()
		callback(ok, reason, revision)
	end, debug.traceback)
	if not called then
		Logger.error(LOG, "Karabiner variable callback threw: %s", tostring(err))
	end
end

--- Announces one first-time poison to the remap lifecycle owner before STOP can
--- publish IDLE. The observer retains recovery intent while the exact fence is
--- pending; it never owns or delays the safety-critical fence itself.
--- @param token string Exact poisoned token.
--- @param reason string Stable poison reason.
local function notify_recovery_observer(token, reason)
	local observer = _recovery_observer
	if type(observer) ~= "function" then
		Logger.error(LOG,
			"Karabiner variable writer has no recovery observer for poisoned lease %s.",
			tostring(token))
		return
	end
	local notified, notify_err = xpcall(function()
		observer(token, reason)
	end, debug.traceback)
	if not notified then
		Logger.error(LOG, "Karabiner variable-writer recovery observer threw: %s.",
			tostring(notify_err))
	end
end

--- Settles one logical operation exactly once.
--- @param operation table Operation record owned by a batch.
--- @param ok boolean Settlement outcome.
--- @param reason string Stable settlement reason.
local function settle_operation(operation, ok, reason)
	if not operation or operation.settled then return end
	operation.settled = true
	invoke_callback(operation.callback, ok, reason, operation.revision)
end

--- Settles every still-live operation in one batch.
--- @param batch table|nil Batch whose callbacks must settle.
--- @param ok boolean Settlement outcome.
--- @param reason string Stable settlement reason.
local function settle_batch(batch, ok, reason)
	if not batch then return end
	for _, scoped_name in ipairs(batch.names) do
		settle_operation(batch.operations[scoped_name], ok, reason)
	end
end

--- Holds poisoned callbacks until an exact fence request is accepted or retired.
--- @param token string Poisoned exact token.
--- @param batch table|nil Batch awaiting terminal settlement.
local function queue_poison_settlement(token, batch)
	if not batch then return end
	local batches = _poison_settlements[token]
	if not batches then
		batches = {}
		_poison_settlements[token] = batches
	end
	batches[#batches + 1] = batch
end

--- Releases every callback held behind one exact fence decision.
--- @param token string Poisoned exact token.
--- @param reason string Terminal settlement reason.
local function release_poison_settlements(token, reason)
	local batches = _poison_settlements[token]
	_poison_settlements[token] = nil
	if not batches then return end
	for _, batch in ipairs(batches) do settle_batch(batch, false, reason) end
end

--- Moves logical state to a new exact token and invalidates old probe revisions.
--- @param token string Exact lease token.
local function adopt_logical_token(token)
	if _logical_token == token then return end
	_logical_token = token
	_logical_values = {}
	for name, revision in pairs(_logical_revisions) do
		_logical_revisions[name] = revision + 1
	end
end

--- Allocates a monotonic logical revision for one accepted request candidate.
--- @param name string Logical runtime name.
--- @param value number|string Desired value.
--- @return number revision Newly allocated revision.
local function allocate_revision(name, value)
	local revision = (_logical_revisions[name] or 0) + 1
	_logical_revisions[name] = revision
	_logical_values[name] = value
	return revision
end

local synchronize_token

--- Builds a single-variable write after validation.
--- @param name any Variable name candidate.
--- @param value any Variable value candidate.
--- @param callback function|nil Optional settlement callback.
--- @return table|nil batch Validated write batch, or nil on rejection.
local function build_write(name, value, callback)
	if type(name) ~= "string" or name == "" then
		Logger.error(LOG, "set(): variable name must be a non-empty string — nothing written.")
		return nil
	end
	if callback ~= nil and type(callback) ~= "function" then
		Logger.error(LOG, "set(): callback for '%s' must be a function or nil — nothing written.", name)
		return nil
	end
	if LeaseContract.is_managed_variable_name(name) then
		Logger.error(LOG,
			"set(): '%s' is already generation-scoped — logical writers cannot claim it.", name)
		return nil
	end
	if not LeaseContract.is_runtime_logical_name(name) then
		Logger.error(LOG,
			"set(): '%s' is not an ErgoptiPlus runtime variable — personal state is untouched.", name)
		return nil
	end
	if type(value) ~= "number" and type(value) ~= "string" then
		Logger.error(LOG, "set(): value for '%s' must be a number or string, got %s — nothing written.",
			name, type(value))
		return nil
	end

	local status_ok, phase, snapshot = pcall(LeaseController.status)
	if not status_ok then
		Logger.error(LOG, "set(): exact Karabiner lease status failed: %s — '%s' was not written.",
			tostring(phase), name)
		return nil
	end
	local accepts_user_input = phase == "active" or phase == "pausing"
	if not accepts_user_input then
		Logger.error(LOG,
			"set(): exact Karabiner lease is not accepting input (%s) — '%s' was not written.",
			tostring(phase), name)
		return nil
	end
	local token = type(snapshot) == "table" and snapshot.token or nil
	if not synchronize_token or synchronize_token(token) ~= true then
		Logger.error(LOG, "set(): exact Karabiner lease generation changed during validation.")
		return nil
	end
	-- Settlement callbacks run synchronously and may re-enter lifecycle code.
	-- Re-read the controller after synchronization so a write can never claim a
	-- token that a callback retired while the first status snapshot was live.
	local recheck_ok, rechecked_phase, rechecked_snapshot = pcall(LeaseController.status)
	if not recheck_ok then
		Logger.error(LOG, "set(): exact Karabiner lease revalidation failed: %s", tostring(rechecked_phase))
		return nil
	end
	local rechecked_token = type(rechecked_snapshot) == "table" and rechecked_snapshot.token or nil
	if rechecked_token ~= token then
		if LeaseContract.is_valid_token(rechecked_token) then synchronize_token(rechecked_token) end
		Logger.error(LOG, "set(): exact Karabiner lease changed from %s to %s during validation.",
			tostring(token), tostring(rechecked_token))
		return nil
	end
	phase = rechecked_phase
	accepts_user_input = phase == "active" or phase == "pausing"
	if not accepts_user_input then
		Logger.error(LOG,
			"set(): exact Karabiner lease stopped accepting input during validation (%s).",
			tostring(phase))
		return nil
	end
	if _poisoned_tokens[token] then
		Logger.error(LOG, "set(): exact Karabiner lease %s is poisoned — '%s' was not written.",
			tostring(token), name)
		return nil
	end
	local scoped_name, scope_err = LeaseContract.runtime_variable_name(name, token)
	if not scoped_name then
		Logger.error(LOG, "set(): could not scope '%s': %s — nothing written.",
			name, tostring(scope_err))
		return nil
	end
	local revision = allocate_revision(name, value)
	local operation = {
		logical_name = name,
		value = value,
		revision = revision,
		callback = callback,
		settled = false,
	}
	return {
		token = token,
		names = { scoped_name },
		values = { [scoped_name] = value },
		operations = { [scoped_name] = operation },
		attempts = 0,
		accepted_async = false,
	}
end

--- Merges a newer desired state into an older pending batch.
--- Values are coalesced independently so a newer layer state supersedes the old
--- one while a disjoint CapsWord write remains in the next serialized payload.
--- @param target table Existing pending batch.
--- @param newer table Newer desired state.
--- @return table target Updated pending batch.
local function merge_batches(target, newer)
	local superseded = {}
	for _, name in ipairs(newer.names) do
		local old_operation = target.operations[name]
		if target.values[name] == nil then
			target.names[#target.names + 1] = name
		end
		target.values[name] = newer.values[name]
		target.operations[name] = newer.operations[name]
		if old_operation and old_operation ~= newer.operations[name] then
			superseded[#superseded + 1] = old_operation
		end
	end
	-- Publish every newer value before invoking user code. A settlement callback
	-- may re-enter set(), and must observe the complete latest-wins state.
	for _, operation in ipairs(superseded) do
		settle_operation(operation, false, "superseded")
	end
	return target
end





-- ==========================================
-- ==========================================
-- ======= 2/ Serialized CLI Executor =======
-- ==========================================
-- ==========================================

local drain_pending
local poison_token
local schedule_retry
local recover_failed_batch
local fence_exact_token

--- Cancels one exact timer through the adapter's strict boolean contract.
--- @param timer table|nil Opaque TimerScheduler handle.
--- @param label string Diagnostic timer role.
--- @return boolean cancelled True only when no native timer remains live.
local function cancel_timer_handle(timer, label)
	if not timer then return true end
	local call_ok, cancelled_or_err = pcall(TimerScheduler.cancel, timer)
	if call_ok and cancelled_or_err == true then return true end
	Logger.error(LOG,
		"Could not cancel Karabiner variable %s timer; retaining the exact handle for retry: %s",
		tostring(label), tostring(cancelled_or_err))
	return false
end

--- Retains one failed exact timer capability without duplicating it.
--- @param timer table Opaque TimerScheduler handle.
--- @param label string Diagnostic timer role.
local function retain_timer_cleanup(timer, label)
	for _, entry in ipairs(_timer_cleanup_backlog) do
		if entry.timer == timer then return end
	end
	_timer_cleanup_backlog[#_timer_cleanup_backlog + 1] = {
		timer = timer,
		label = label,
	}
end

--- Retries every timer whose native cancellation was not previously proven.
--- Callers clear their active identity slots before entering this helper, so a
--- queued callback is already inert even when the host refuses cancellation.
--- @return boolean complete Whether the cleanup backlog is empty.
local function retry_timer_cleanup()
	for index = #_timer_cleanup_backlog, 1, -1 do
		local entry = _timer_cleanup_backlog[index]
		if cancel_timer_handle(entry.timer, entry.label) then
			table.remove(_timer_cleanup_backlog, index)
		end
	end
	return #_timer_cleanup_backlog == 0
end

--- Retries older cleanup first, then cancels or retains this exact timer.
--- @param timer table|nil Opaque TimerScheduler handle.
--- @param label string Diagnostic timer role.
--- @return boolean cancelled True only when this timer cancellation settled.
local function cancel_timer_safely(timer, label)
	retry_timer_cleanup()
	if cancel_timer_handle(timer, label) then return true end
	retain_timer_cleanup(timer, label)
	return false
end

--- Terminates one exact child through the ShellRunner strict boolean contract.
--- @param handle table|nil Opaque ShellRunner child handle.
--- @param label string Diagnostic child role.
--- @return boolean terminated True only when no native task remains live.
local function terminate_child_handle(handle, label)
	if not handle then return true end
	if type(handle) ~= "table" or type(handle.terminate) ~= "function" then
		Logger.error(LOG, "Could not terminate Karabiner variable %s child; invalid exact handle.",
			tostring(label))
		return false
	end
	local call_ok, terminated_or_err = pcall(handle.terminate)
	if call_ok and terminated_or_err == true then return true end
	Logger.error(LOG,
		"Could not terminate Karabiner variable %s child; retaining the exact handle for retry: %s",
		tostring(label), tostring(terminated_or_err))
	return false
end

--- Retains one failed exact child capability without duplicating it.
--- @param handle table Opaque ShellRunner child handle.
--- @param label string Diagnostic child role.
local function retain_child_cleanup(handle, label)
	for _, entry in ipairs(_child_cleanup_backlog) do
		if entry.handle == handle then return end
	end
	_child_cleanup_backlog[#_child_cleanup_backlog + 1] = {
		handle = handle,
		label = label,
	}
end

--- Retries every exact child termination not previously proven complete.
--- @return boolean complete Whether the cleanup backlog is empty.
local function retry_child_cleanup()
	for index = #_child_cleanup_backlog, 1, -1 do
		local entry = _child_cleanup_backlog[index]
		if terminate_child_handle(entry.handle, entry.label) then
			table.remove(_child_cleanup_backlog, index)
		end
	end
	return #_child_cleanup_backlog == 0
end

--- Retries older cleanup first, then terminates or retains this exact child.
--- @param handle table|nil Opaque ShellRunner child handle.
--- @param label string Diagnostic child role.
--- @return boolean terminated True only when this child termination settled.
local function terminate_child_safely(handle, label)
	retry_child_cleanup()
	if terminate_child_handle(handle, label) then return true end
	retain_child_cleanup(handle, label)
	return false
end

--- Detaches the exact active batch before any cancellation side effect can
--- synchronously deliver its completion callback. Batch identity is the
--- serializer authority; a late callback therefore observes a mismatch and is
--- ignored instead of releasing a newer writer.
--- @param batch table Expected active batch identity.
--- @param terminate_child boolean Whether to terminate its subprocess handle.
--- @return boolean detached True only when batch still owned the active slot.
local function detach_active(batch, terminate_child)
	if _active_batch ~= batch then return false end

	local handle = _active_handle
	local timeout = _active_timeout
	_active_batch = nil
	_active_handle = nil
	_active_timeout = nil

	cancel_timer_safely(timeout, "watchdog")
	if terminate_child then terminate_child_safely(handle, "writer") end
	return true
end

--- Cancels the exact retry timer without allowing its late callback to act.
local function cancel_retry()
	local timer = _retry_timer
	_retry_timer = nil
	_retry_token = nil
	cancel_timer_safely(timer, "retry")
end

--- Retires serializer state that belongs to a token other than the live lease.
--- @param token string New exact lease token.
synchronize_token = function(token)
	if not LeaseContract.is_valid_token(token) then return false end
	if _active_batch and _active_batch.token ~= token then
		local retired = _active_batch
		detach_active(retired, true)
		settle_batch(retired, false, "generation-retired")
		if _active_batch and _active_batch.token ~= token then return false end
	end
	if _pending_batch and _pending_batch.token ~= token then
		local retired = _pending_batch
		_pending_batch = nil
		settle_batch(retired, false, "generation-retired")
		if _active_batch and _active_batch.token ~= token then return false end
		if _pending_batch and _pending_batch.token ~= token then return false end
	end
	if _retry_token and _retry_token ~= token then cancel_retry() end
	adopt_logical_token(token)
	return true
end

--- Schedules a bounded retry of exact-token fence acquisition.
--- @param token string Exact poisoned token.
--- @param reason string Poison reason.
--- @param next_attempt number One-based fence attempt to run later.
local function schedule_fence_retry(token, reason, next_attempt)
	if next_attempt > VARIABLE_WRITER_MAX_ATTEMPTS then
		Logger.error(LOG, "Exact Karabiner writer fence exhausted %d attempts for %s.",
			VARIABLE_WRITER_MAX_ATTEMPTS, token)
		release_poison_settlements(token, "writer-fence-failed")
		return
	end
	if _fence_retries[token] then return end
	if not retry_timer_cleanup() then
		Logger.error(LOG, "Exact Karabiner writer fence retry blocked by timer cleanup debt.")
		release_poison_settlements(token, "writer-fence-cleanup-pending")
		return
	end

	local retry_handle = nil
	local fired_before_return = false
	local timer_ok, timer_or_err, timer_committed = pcall(
		TimerScheduler.after,
		VARIABLE_WRITER_RETRY_DELAY_SEC,
		function()
			if retry_handle == nil then
				fired_before_return = true
				return
			end
			local retry = _fence_retries[token]
			if not retry or retry.timer ~= retry_handle then return end
			_fence_retries[token] = nil
			fence_exact_token(token, reason, next_attempt)
		end
	)
	retry_handle = timer_or_err
	if not timer_ok or timer_committed ~= true or type(timer_or_err) ~= "table"
		or timer_or_err.fired == true or fired_before_return then
		if type(timer_or_err) == "table" then cancel_timer_safely(timer_or_err, "fence retry") end
		Logger.error(LOG, "Could not arm exact Karabiner writer-fence retry: %s",
			tostring(timer_ok and "timer unavailable" or timer_or_err))
		release_poison_settlements(token, "writer-fence-failed")
		return
	end
	_fence_retries[token] = { timer = timer_or_err, attempt = next_attempt }
	Logger.warn(LOG, "Retrying exact Karabiner writer fence for %s in %.2f s (attempt %d/%d).",
		token, VARIABLE_WRITER_RETRY_DELAY_SEC, next_attempt, VARIABLE_WRITER_MAX_ATTEMPTS)
end

--- Requests a fence only if the controller still exposes the captured token.
--- @param token string Exact poisoned token.
--- @param reason string Poison reason.
--- @param attempt number|nil One-based fence attempt.
fence_exact_token = function(token, reason, attempt)
	attempt = attempt or 1
	local status_ok, phase, snapshot = pcall(LeaseController.status)
	if not status_ok then
		Logger.error(LOG, "Could not revalidate poisoned Karabiner lease %s: %s",
			tostring(token), tostring(phase))
		schedule_fence_retry(token, reason, attempt + 1)
		return
	end
	local current_token = type(snapshot) == "table" and snapshot.token or nil
	if current_token ~= token then
		local retry = _fence_retries[token]
		if retry then cancel_timer_safely(retry.timer, "fence retry") end
		_fence_retries[token] = nil
		Logger.debug(LOG,
			"Poisoned Karabiner writer token %s is already retired; replacement %s remains untouched.",
			tostring(token), tostring(current_token))
		_fence_requested_tokens[token] = true
		release_poison_settlements(token, "writer-fenced")
		return
	end

	local function on_stopped(ok, stop_reason)
		if ok then
			local retry = _fence_retries[token]
			if retry then cancel_timer_safely(retry.timer, "fence retry") end
			_fence_retries[token] = nil
			_fence_requested_tokens[token] = true
			release_poison_settlements(token, "writer-fenced")
			Logger.info(LOG, "Poisoned Karabiner writer lease %s fenced.", token)
		else
			Logger.error(LOG, "Poisoned Karabiner writer lease %s fence failed: %s",
				token, tostring(stop_reason))
			schedule_fence_retry(token, reason, attempt + 1)
		end
	end
	local stop_ok, accepted_or_err = pcall(
		LeaseController.stop,
		"variable-writer-poison:" .. tostring(reason),
		function(...)
			local callback_args = table.pack(...)
			local callback_ok, callback_err = xpcall(function()
				on_stopped(table.unpack(callback_args, 1, callback_args.n))
			end, debug.traceback)
			if not callback_ok then
				Logger.error(LOG, "Karabiner writer fence callback threw: %s", tostring(callback_err))
			end
		end
	)
	if not stop_ok or accepted_or_err ~= true then
		Logger.error(LOG, "Could not request exact Karabiner writer fence for %s: %s",
			token, tostring(accepted_or_err))
		schedule_fence_retry(token, reason, attempt + 1)
	else
		_fence_requested_tokens[token] = true
		release_poison_settlements(token, "writer-fenced")
	end
end

--- Poisons one token before any same-generation successor can start.
--- @param token string Exact token to make locally unwritable.
--- @param reason string Stable failure reason.
--- @param detached_batch table|nil Batch already detached by its callback.
poison_token = function(token, reason, detached_batch)
	if _poisoned_tokens[token] then
		queue_poison_settlement(token, detached_batch)
		if _fence_requested_tokens[token] then
			release_poison_settlements(token, "writer-fenced")
		end
		return
	end
	_poisoned_tokens[token] = true
	if _retry_token == token then cancel_retry() end

	local batches = {}
	if detached_batch then batches[#batches + 1] = detached_batch end
	if _active_batch and _active_batch.token == token then
		local active = _active_batch
		detach_active(active, true)
		batches[#batches + 1] = active
	end
	if _pending_batch and _pending_batch.token == token then
		batches[#batches + 1] = _pending_batch
		_pending_batch = nil
	end
	if _logical_token == token then
		_logical_values = {}
		for name, revision in pairs(_logical_revisions) do
			_logical_revisions[name] = revision + 1
		end
	end
	-- Request external revocation before invoking arbitrary user callbacks. The
	-- timed-out child can still mutate Karabiner while terminate() is in flight;
	-- no callback may run while the exact generation remains unfenced by request.
	for _, batch in ipairs(batches) do queue_poison_settlement(token, batch) end
	Logger.error(LOG, "Karabiner variable writer poisoned exact lease %s: %s", token, tostring(reason))
	notify_recovery_observer(token, reason)
	fence_exact_token(token, reason)
end

--- Starts one CLI writer and holds the serializer until its exact completion.
--- The watchdog is proven live before start(), so a synchronous false return
--- guarantees that the child had no opportunity to mutate Karabiner state.
--- @param batch table Validated variable batch.
--- @return boolean started Whether the asynchronous attempt started.
--- @return string|nil reason Stable failure reason.
--- @return boolean fatal Whether an accepted batch must fence instead of retry.
local function start_batch(batch)
	if not retry_timer_cleanup() then
		Logger.error(LOG, "Karabiner variable writer blocked by timer cleanup debt.")
		return false, "timer-cleanup-pending", false
	end
	-- A failed native terminate keeps its exact ShellRunner capability here. Retry
	-- it before exposing another writer instead of losing the only safe handle and
	-- falling back to process-name discovery, which could target personal Karabiner.
	retry_child_cleanup()
	if batch.attempts >= VARIABLE_WRITER_MAX_ATTEMPTS then
		return false, "retry-exhausted", true
	end

	local encode_ok, payload, encode_err = pcall(JsonCodec.encode, batch.values)
	if not encode_ok or type(payload) ~= "string" or payload == "" then
		Logger.error(LOG, "Could not encode Karabiner variable state: %s",
			tostring(encode_ok and encode_err or payload))
		return false, "encode-failed", true
	end
	batch.attempts = batch.attempts + 1

	local function on_done(exit_code, _stdout, stderr)
		if not detach_active(batch, false) then
			Logger.debug(LOG, "Ignoring detached Karabiner variable-writer completion.")
			return
		end
		if exit_code == 0 then
			Logger.debug(LOG, "Serialized Karabiner variable write completed (%d value(s)).", #batch.names)
			settle_batch(batch, true, "written")
			drain_pending()
			return
		end
		Logger.error(LOG, "Serialized Karabiner variable write failed (exit %s): %s",
			tostring(exit_code), tostring(stderr))
		recover_failed_batch(batch, "nonzero-exit-" .. tostring(exit_code))
	end

	local spawn_ok, handle_or_err = pcall(
		ShellRunner.spawn,
		KePaths.CLI,
		{ SET_VARIABLES_FLAG, payload },
		on_done
	)
	if not spawn_ok or type(handle_or_err) ~= "table"
		or type(handle_or_err.start) ~= "function"
		or type(handle_or_err.terminate) ~= "function" then
		Logger.error(LOG, "Could not create Karabiner variable writer: %s", tostring(handle_or_err))
		return false, "spawn-failed", false
	end

	Logger.debug(LOG, "Starting serialized Karabiner variable write (%d value(s), attempt %d/%d).",
		#batch.names, batch.attempts, VARIABLE_WRITER_MAX_ATTEMPTS)
	_active_batch = batch
	_active_handle = handle_or_err
	local child_started = false
	local watchdog_fired_before_start = false
	local timer_ok, timeout_or_err, timeout_committed = pcall(
		TimerScheduler.after,
		VARIABLE_WRITER_TIMEOUT_SEC,
		function()
			if not child_started then
				watchdog_fired_before_start = true
				return
			end
			if not detach_active(batch, true) then return end
			Logger.error(LOG,
				"Karabiner variable writer timed out after %.1f s; fencing exact lease %s.",
				VARIABLE_WRITER_TIMEOUT_SEC, batch.token)
			poison_token(batch.token, "writer-timeout", batch)
		end
	)
	if not timer_ok or timeout_committed ~= true or type(timeout_or_err) ~= "table"
		or timeout_or_err.fired == true or watchdog_fired_before_start then
		-- terminate() is also the ShellRunner GC-pin release for a task that was
		-- constructed but deliberately never started.
		detach_active(batch, true)
		if type(timeout_or_err) == "table" then cancel_timer_safely(timeout_or_err, "watchdog") end
		Logger.error(LOG, "Could not arm Karabiner variable-writer watchdog: %s",
			tostring(timer_ok and "timer unavailable" or timeout_or_err))
		return false, "watchdog-unavailable", true
	end
	_active_timeout = timeout_or_err

	-- Mark the child exposed before entering adapter code. If a hostile test
	-- double re-enters the timer during start(), its timeout must fence the exact
	-- generation instead of being mistaken for a pre-start validation failure.
	child_started = true
	local start_ok, started_or_err = pcall(handle_or_err.start)
	if _active_batch ~= batch then
		-- A synchronous completion or timeout already settled/recovered this batch.
		return true, nil, false
	end
	if not start_ok or started_or_err ~= true then
		child_started = false
		detach_active(batch, true)
		Logger.error(LOG, "Could not run '%s' — is Karabiner-Elements installed? (%s)",
			KePaths.CLI, tostring(started_or_err))
		return false, "start-refused", false
	end
	return true, nil, false
end

--- Restores a batch whose deferred launch failed without overwriting newer input.
--- A re-entrant submission can arrive from a test double or adapter callback
--- during start(); its values are newer and therefore win on overlap.
--- @param failed_batch table Batch that could not start.
local function restore_failed_pending(failed_batch)
	if _poisoned_tokens[failed_batch.token] then
		settle_batch(failed_batch, false, "writer-fenced")
		return false
	end
	if _active_batch and _active_batch.token ~= failed_batch.token then
		Logger.debug(LOG, "Discarding failed writer state superseded by the active lease generation.")
		settle_batch(failed_batch, false, "generation-retired")
		return false
	end
	if not _pending_batch then
		_pending_batch = failed_batch
		return true
	end
	if _pending_batch.token ~= failed_batch.token then
		Logger.debug(LOG, "Discarding failed writer state superseded by a newer lease generation.")
		settle_batch(failed_batch, false, "generation-retired")
		return false
	end
	local newer = _pending_batch
	_pending_batch = failed_batch
	merge_batches(_pending_batch, newer)
	return true
end

--- Arms one bounded retry for an already accepted pending batch.
--- @param batch table Current coalesced pending batch.
--- @param failure_reason string Failure that requested recovery.
--- @return boolean scheduled True only for a live retry timer.
schedule_retry = function(batch, failure_reason)
	if not retry_timer_cleanup() then
		Logger.error(LOG, "Karabiner variable writer retry blocked by timer cleanup debt.")
		return false
	end
	if _poisoned_tokens[batch.token] then
		poison_token(batch.token, "retry-on-poisoned-token", nil)
		return false
	end
	if batch.attempts >= VARIABLE_WRITER_MAX_ATTEMPTS then
		Logger.error(LOG, "Karabiner variable writer exhausted %d attempts for exact lease %s.",
			VARIABLE_WRITER_MAX_ATTEMPTS, batch.token)
		poison_token(batch.token, "retry-exhausted:" .. tostring(failure_reason), nil)
		return false
	end
	if _retry_timer then
		if _retry_token == batch.token then return true end
		cancel_retry()
	end

	local retry_handle = nil
	local fired_before_return = false
	local token = batch.token
	local timer_ok, timer_or_err, timer_committed = pcall(
		TimerScheduler.after,
		VARIABLE_WRITER_RETRY_DELAY_SEC,
		function()
			if retry_handle == nil then
				fired_before_return = true
				return
			end
			if _retry_timer ~= retry_handle or _retry_token ~= token then return end
			_retry_timer = nil
			_retry_token = nil
			drain_pending()
		end
	)
	retry_handle = timer_or_err
	if not timer_ok or timer_committed ~= true or type(timer_or_err) ~= "table"
		or timer_or_err.fired == true or fired_before_return then
		if type(timer_or_err) == "table" then cancel_timer_safely(timer_or_err, "retry") end
		Logger.error(LOG, "Could not arm Karabiner variable-writer retry timer: %s",
			tostring(timer_ok and "timer unavailable" or timer_or_err))
		poison_token(token, "retry-timer-unavailable", nil)
		return false
	end
	_retry_timer = timer_or_err
	_retry_token = token
	Logger.warn(LOG, "Retrying serialized Karabiner variable write in %.2f s after %s.",
		VARIABLE_WRITER_RETRY_DELAY_SEC, tostring(failure_reason))
	return true
end

--- Restores and schedules recovery for a failed accepted child.
--- @param batch table Detached failed batch.
--- @param failure_reason string Stable failure reason.
recover_failed_batch = function(batch, failure_reason)
	_recovery_in_progress = true
	local restored = restore_failed_pending(batch)
	_recovery_in_progress = false
	if not restored then return end
	if _pending_batch and _pending_batch.token == batch.token then
		schedule_retry(_pending_batch, failure_reason)
	end
end

--- Starts the coalesced pending state after the active child has exited.
drain_pending = function()
	if _active_batch or _retry_timer or _recovery_in_progress or not _pending_batch then return end
	local next_batch = _pending_batch
	_pending_batch = nil
	local started, reason, fatal = start_batch(next_batch)
	if started then return end
	if not restore_failed_pending(next_batch) then return end
	Logger.error(LOG, "Pending Karabiner variable state could not launch: %s.", tostring(reason))
	if fatal then
		poison_token(next_batch.token, reason or "fatal-launch-failure", nil)
	else
		schedule_retry(_pending_batch, reason or "launch-failure")
	end
end

--- Enqueues one validated state behind the active writer.
--- @param batch table Validated variable batch.
--- @return boolean accepted True when started or safely retained as pending.
local function enqueue_batch(batch)
	if _active_batch then
		local active = _active_batch
		batch.accepted_async = true
		if _pending_batch then
			merge_batches(_pending_batch, batch)
		else
			_pending_batch = batch
		end
		-- A newer accepted value makes the same-name callback obsolete now,
		-- regardless of whether the old child eventually reports exit zero.
		-- Settlement invokes user code, so act only on the captured owner: a
		-- callback may retire this token and install a different active batch.
		if _active_batch == active and active.token == batch.token then
			for _, name in ipairs(batch.names) do
				settle_operation(active.operations[name], false, "superseded")
			end
		end
		local pending_count = _pending_batch and #_pending_batch.names or 0
		Logger.debug(LOG, "Coalesced pending Karabiner state (%d value(s)).", pending_count)
		return true
	end

	if _retry_timer or _recovery_in_progress or _pending_batch then
		batch.accepted_async = true
		if _pending_batch then
			merge_batches(_pending_batch, batch)
		else
			_pending_batch = batch
		end
		drain_pending()
		return true
	end

	batch.accepted_async = true
	local started, reason = start_batch(batch)
	if started then return true end
	batch.accepted_async = false
	settle_batch(batch, false, reason or "launch-failed")
	return false
end





-- =========================================
-- =========================================
-- ======= 3/ Public Variable Writes =======
-- =========================================
-- =========================================

--- Publishes the current lifecycle owner notified when a variable write poisons
--- an exact lease. A fresh remap lifecycle replaces the stale callback from its
--- predecessor; exact clear-by-identity prevents old teardown from erasing it.
--- @param observer function Callback fn(token, reason), invoked before fencing.
--- @return boolean registered True only when the observer became authoritative.
function M.set_recovery_observer(observer)
	if type(observer) ~= "function" then
		Logger.error(LOG, "set_recovery_observer(): observer must be a function.")
		return false
	end
	_recovery_observer = observer
	return true
end

--- Releases the exact lifecycle observer during remap teardown.
--- @param observer function Exact observer capability returned by the owner.
--- @return boolean cleared True only when the current owner was released.
function M.clear_recovery_observer(observer)
	if type(observer) ~= "function" or observer ~= _recovery_observer then
		Logger.error(LOG, "clear_recovery_observer(): observer does not own recovery.")
		return false
	end
	_recovery_observer = nil
	return true
end

--- Queues one Karabiner engine variable through the shared serializer.
--- @param name string The variable name, as it appears in the generated config.
--- @param value number|string The value to write (Karabiner uses 0/1 for flags).
--- @param on_done function|nil Optional fn(ok, reason, revision) settlement callback.
--- @return boolean accepted True when the write started or was safely queued.
--- @return number|nil revision Logical revision assigned to the request.
function M.set(name, value, on_done)
	local batch = build_write(name, value, on_done)
	if not batch then return false, nil end
	local revision = batch.operations[batch.names[1]].revision
	Logger.debug(LOG, "Queued exact-generation Karabiner runtime variable %s=%s.",
		name, tostring(value))
	return enqueue_batch(batch), revision
end

--- Refreshes the logical generation and returns the current CapsWord revision.
--- Status failures are visible but do not fabricate a new revision.
--- @return number revision Monotonic logical CapsWord revision.
function M.capsword_revision()
	local status_ok, phase, snapshot = pcall(LeaseController.status)
	if not status_ok then
		Logger.error(LOG, "capsword_revision(): exact Karabiner lease status failed: %s",
			tostring(phase))
		return _logical_revisions[CAPSWORD_LOGICAL_NAME] or 0
	end
	local token = type(snapshot) == "table" and snapshot.token or nil
	if LeaseContract.is_valid_token(token) and synchronize_token(token) ~= true then
		Logger.error(LOG, "capsword_revision(): lease generation changed during synchronization.")
	end
	return _logical_revisions[CAPSWORD_LOGICAL_NAME] or 0
end

--- Returns the newest same-token operation for one logical variable.
--- Pending state wins because it represents intent newer than the active child.
--- @param logical_name string Runtime logical name.
--- @param token string Exact current token.
--- @return table|nil operation Latest in-flight operation.
local function latest_operation(logical_name, token)
	local function find_in(batch)
		if not batch or batch.token ~= token then return nil end
		for _, scoped_name in ipairs(batch.names) do
			local operation = batch.operations[scoped_name]
			if operation and operation.logical_name == logical_name then return operation end
		end
		return nil
	end
	return find_in(_pending_batch) or find_in(_active_batch)
end

--- Queues a CapsWord clear only when the latest local write still activates it.
--- This does not infer ownership from global Karabiner state, preserving personal
--- CapsLock/Karabiner behavior when ErgoptiPlus has no activation in flight.
--- @param on_done function|nil Optional fn(ok, reason, revision) callback.
--- @return boolean superseded True only when a clear write was accepted.
--- @return number revision Current or newly allocated CapsWord revision.
function M.supersede_capsword_activation(on_done)
	if on_done ~= nil and type(on_done) ~= "function" then
		Logger.error(LOG, "supersede_capsword_activation(): callback must be a function or nil.")
		return false, _logical_revisions[CAPSWORD_LOGICAL_NAME] or 0
	end
	local status_ok, phase, snapshot = pcall(LeaseController.status)
	if not status_ok then
		Logger.error(LOG, "supersede_capsword_activation(): lease status failed: %s", tostring(phase))
		return false, _logical_revisions[CAPSWORD_LOGICAL_NAME] or 0
	end
	local token = type(snapshot) == "table" and snapshot.token or nil
	if not LeaseContract.is_valid_token(token) then
		return false, _logical_revisions[CAPSWORD_LOGICAL_NAME] or 0
	end
	if synchronize_token(token) ~= true then
		Logger.error(LOG, "supersede_capsword_activation(): lease generation changed during synchronization.")
		return false, _logical_revisions[CAPSWORD_LOGICAL_NAME] or 0
	end
	local operation = latest_operation(CAPSWORD_LOGICAL_NAME, token)
	local revision = _logical_revisions[CAPSWORD_LOGICAL_NAME] or 0
	if not operation or operation.value ~= 1 then return false, revision end
	local accepted, clear_revision = M.set(CAPSWORD_LOGICAL_NAME, 0, on_done)
	return accepted, clear_revision or revision
end

--- Writes only if no newer logical operation has superseded a captured probe.
--- @param name string Runtime logical name.
--- @param value number|string Desired value.
--- @param expected_revision number Revision captured before asynchronous work.
--- @param on_done function|nil Optional fn(ok, reason, revision) callback.
--- @return boolean accepted True when the conditional write was accepted.
--- @return number|nil revision Current or newly allocated logical revision.
function M.set_if_revision(name, value, expected_revision, on_done)
	if type(expected_revision) ~= "number" or expected_revision < 0
		or expected_revision ~= math.floor(expected_revision) then
		Logger.error(LOG, "set_if_revision(): expected revision must be a non-negative integer.")
		return false, type(name) == "string" and _logical_revisions[name] or nil
	end
	if on_done ~= nil and type(on_done) ~= "function" then
		Logger.error(LOG, "set_if_revision(): callback must be a function or nil.")
		return false, type(name) == "string" and _logical_revisions[name] or nil
	end

	local status_ok, phase, snapshot = pcall(LeaseController.status)
	if not status_ok then
		Logger.error(LOG, "set_if_revision(): exact Karabiner lease status failed: %s", tostring(phase))
		return false, type(name) == "string" and _logical_revisions[name] or nil
	end
	local token = type(snapshot) == "table" and snapshot.token or nil
	if LeaseContract.is_valid_token(token) and synchronize_token(token) ~= true then
		Logger.error(LOG, "set_if_revision(): lease generation changed during synchronization.")
		local interrupted_revision = type(name) == "string" and (_logical_revisions[name] or 0) or nil
		invoke_callback(on_done, false, "generation-changed", interrupted_revision)
		return false, interrupted_revision
	end
	local current_revision = type(name) == "string" and (_logical_revisions[name] or 0) or nil
	if current_revision ~= expected_revision then
		invoke_callback(on_done, false, "stale-revision", current_revision)
		return false, current_revision
	end
	return M.set(name, value, on_done)
end

return M
