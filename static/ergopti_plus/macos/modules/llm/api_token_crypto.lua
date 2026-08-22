--- modules/llm/api_token_crypto.lua

--- ==============================================================================
--- MODULE: API Token Crypto (macOS Keychain)
--- DESCRIPTION:
--- Stores remote-API tokens in the macOS user Keychain without ever blocking
--- Hammerspoon's single run loop. Every Keychain subprocess is owned through
--- ShellRunner, has a hard TimerScheduler deadline, and completes exactly once.
--- ==============================================================================

local M = {}

local Logger         = require("infra.logger")
local ShellRunner    = require("adapters.shell_runner")
local TimerScheduler = require("adapters.timer_scheduler")
local Timings        = require("infra.timings")
local LauncherHelper = require("platform.remap.lease_helper")

local LOG = "llm.api_token_crypto"

local KEYCHAIN_PREFIX  = "keychain:"
local OPERATION_TIMEOUT_SEC = Timings.sec("llm", "keychain_operation_timeout_ms")
local TOKEN_WRITE_FLAG  = "--keychain-token-write"
local TOKEN_READ_FLAG   = "--keychain-token-read"
local TOKEN_DELETE_FLAG = "--keychain-token-delete"





-- ======================================
-- ======================================
-- ======= 1/ Async Process Owner =======
-- ======================================
-- ======================================

--- Invokes a client callback without letting its throw disappear in an async
--- task or timer boundary.
--- @param label string Operation label for diagnostics.
--- @param callback function|nil Callback to invoke.
--- @param ... any Callback arguments.
local function invoke_guarded(label, callback, ...)
	if type(callback) ~= "function" then return end
	local args = table.pack(...)
	local ok, err = xpcall(function()
		callback(table.unpack(args, 1, args.n))
	end, debug.traceback)
	if not ok then
		Logger.error(LOG, "%s callback raised: %s", tostring(label), tostring(err))
	end
end

--- Runs one owned signed-launcher Keychain operation with a hard deadline.
--- @param label string Safe diagnostic label (never includes a credential).
--- @param args table Argument vector.
--- @param input string|nil Optional stdin payload.
--- @param callback function Receives (completed, exit_code, stdout, stderr, reason).
--- @param mutates_keychain boolean Whether the helper may have dispatched a
---   Security.framework mutation that must reach natural completion.
--- @return table operation Handle exposing cancel().
local function run_security(label, args, input, callback, mutates_keychain)
	local completed = false
	local task_handle = nil
	local timeout_handle = nil
	local discard_native_completion = false
	local cancellation_reason = nil
	local task_started = false
	local deadline_triggered = false
	local pending_terminal = nil
	local timeout_settlement_observer_handle = nil
	local timeout_acquisition_in_progress = false
	local operation = {}
	local complete

	local function cancel_timeout()
		if timeout_handle == nil then return true end
		local handle = timeout_handle
		local ok, settled = xpcall(function()
			return TimerScheduler.cancel(handle)
		end, debug.traceback)
		if not ok or settled ~= true then
			Logger.error(LOG, "%s timeout cleanup failed: %s",
				tostring(label), tostring(ok and settled or settled))
			return false
		end
		if timeout_handle == handle then timeout_handle = nil end
		return true
	end

	local function terminate_task(reason)
		if task_handle == nil then return true, "settled" end
		local owned = task_handle
		local ok, settled, state = xpcall(function()
			return owned.terminate()
		end, debug.traceback)
		-- ShellRunner's first return preserves its public compatibility contract:
		-- true means the stop request was accepted. Only the second return proves
		-- whether native exit has already settled.
		if ok and state == "settled" then return true, "settled" end
		if ok and state == "pending" then return false, "pending" end
		if ok and settled == true and state == nil then return true, "settled" end
		if not ok or state ~= "pending" then
			Logger.error(LOG, "%s task termination failed after %s: %s",
				tostring(label), tostring(reason), tostring(ok and (state or settled) or settled))
		end
		return false, "refused"
	end

	--- Observes autonomous settlement after a timeout stop refusal. A repeating
	--- native timer may later prove its own cleanup without another lifecycle
	--- caller; the retained terminal must then be published exactly once.
	--- @param handle table Exact TimerScheduler handle.
	--- @return boolean registered
	local function observe_timeout_settlement(handle)
		if type(handle) ~= "table" or timeout_settlement_observer_handle == handle then
			return true
		end
		if type(TimerScheduler.onSettled) ~= "function" then return false end
		timeout_settlement_observer_handle = handle
		local ok, registered_or_err = xpcall(function()
			return TimerScheduler.onSettled(handle, function()
				if timeout_settlement_observer_handle == handle then
					timeout_settlement_observer_handle = nil
				end
				if timeout_handle == handle and handle.timer == nil then
					timeout_handle = nil
				end
				if not completed and pending_terminal ~= nil then
					complete(false, nil, nil, nil, "timeout_settled")
				end
			end)
		end, debug.traceback)
		if not ok or registered_or_err ~= true then
			if timeout_settlement_observer_handle == handle then
				timeout_settlement_observer_handle = nil
			end
			Logger.error(LOG, "%s timeout settlement observer failed: %s",
				tostring(label), tostring(registered_or_err))
			return false
		end
		return true
	end

	complete = function(process_completed, exit_code, stdout, stderr, reason)
		if completed then return true end
		if pending_terminal == nil then
			pending_terminal = table.pack(
				process_completed, exit_code, stdout, stderr, reason)
		end
		-- A hostile scheduler may deliver before after() publishes the exact handle.
		-- Keep the terminal private until that acquisition frame can either join the
		-- handle or prove that no native timer was created.
		if timeout_acquisition_in_progress == true then return false end
		-- The terminal callback is itself a capability boundary: publishing it while
		-- the deadline timer is still live loses the only handle able to join a late
		-- timeout. Retain both the result and handle until literal settlement.
		if cancel_timeout() ~= true then
			observe_timeout_settlement(timeout_handle)
			return completed
		end
		-- TimerScheduler.cancel() settles observers synchronously. One of them
		-- may have re-entered this function and consumed the retained terminal
		-- while cancel_timeout() was still on the outer stack.
		if completed then return true end
		completed = true
		local terminal = pending_terminal
		pending_terminal = nil
		invoke_guarded(label, callback,
			table.unpack(terminal, 1, terminal.n))
		return true
	end

	operation.cancel = function()
		if completed then
			if cancel_timeout() == true then return true, "settled" end
			observe_timeout_settlement(timeout_handle)
			return false, "pending"
		end
		cancellation_reason = cancellation_reason or "cancelled"
		if task_started and mutates_keychain == true then
			-- SecItem write/delete is synchronous only from the helper's point of
			-- view. Once dispatched to securityd, killing the helper cannot prove
			-- that the mutation will not commit afterward. Preserve the live task
			-- and wait for its natural callback before cleanup or a successor.
			return false, "pending"
		end
		local settled, state = terminate_task("cancellation")
		-- An accepted SIGTERM is only a pending request. Keep the task and its
		-- native completion observable so persistence cannot overlap a successor
		-- with Security.framework side effects from this helper.
		if settled then
			local terminal_settled = complete(
				false, nil, nil, nil, cancellation_reason)
			if terminal_settled ~= true then return false, "pending" end
		end
		return settled, state
	end

	local resolve_ok, executable_or_err, resolution_error = xpcall(function()
		return LauncherHelper.resolve()
	end, debug.traceback)
	if not resolve_ok or type(executable_or_err) ~= "string" or executable_or_err == "" then
		Logger.error(LOG, "%s launcher helper resolution failed: %s",
			tostring(label), tostring(resolve_ok and resolution_error or executable_or_err))
		complete(false, nil, nil, nil, "helper_unavailable")
		return operation
	end

	local spawn_ok, candidate_or_err = xpcall(function()
		return ShellRunner.spawn(executable_or_err, args, function(exit_code, stdout, stderr)
			task_handle = nil
			if discard_native_completion then return end
			if cancellation_reason ~= nil then
				complete(false, nil, nil, nil, cancellation_reason)
				return
			end
			complete(true, exit_code, stdout, stderr, nil)
		end)
	end, debug.traceback)
	if not spawn_ok or type(candidate_or_err) ~= "table" then
		Logger.error(LOG, "%s task construction failed: %s",
			tostring(label), tostring(candidate_or_err))
		complete(false, nil, nil, nil, "launch_failed")
		return operation
	end
	task_handle = candidate_or_err

	-- A hostile or broken constructor may call completion synchronously. Do not
	-- launch a process after the operation has already reached a terminal state.
	if completed then
		terminate_task("completion during construction")
		return operation
	end

	if input ~= nil then
		local input_ok, accepted_or_err = xpcall(function()
			return task_handle.set_input(input)
		end, debug.traceback)
		if not input_ok or accepted_or_err ~= true then
			Logger.error(LOG, "%s stdin setup failed: %s",
				tostring(label), tostring(input_ok and accepted_or_err or accepted_or_err))
			discard_native_completion = true
			terminate_task("stdin setup failure")
			complete(false, nil, nil, nil, "input_failed")
			return operation
		end
		-- This spawn deliberately has no streaming callback. hs.task:setInput()
		-- queues the bytes before start and automatically closes stdin afterward;
		-- closeInput() is valid only for the streaming-callback task form.
	end

	timeout_acquisition_in_progress = true
	local timer_ok, timer_or_err, timer_committed = xpcall(function()
		local handle, committed = TimerScheduler.after(OPERATION_TIMEOUT_SEC, function()
			if completed then return end
			deadline_triggered = true
			Logger.error(LOG, "%s timed out after %.3f seconds.", label, OPERATION_TIMEOUT_SEC)
			cancellation_reason = cancellation_reason or "timeout"
			if task_started and mutates_keychain == true then
				-- Logical timeout fences the caller, but native ownership remains
				-- pending until the non-cancellable Keychain mutation returns.
				return
			end
			local settled = terminate_task("deadline")
			-- Before start there is no OS mutation to await, even if a hostile
			-- prepared-task double refuses terminate(). Never launch it afterward.
			if settled or not task_started then
				complete(false, nil, nil, nil, cancellation_reason)
			end
		end)
		return handle, committed
	end, debug.traceback)
	timeout_acquisition_in_progress = false
	if timer_ok then timeout_handle = timer_or_err end
	if not timer_ok or timer_committed ~= true then
		Logger.error(LOG, "%s deadline could not be armed: %s",
			tostring(label), tostring(timer_ok and timer_committed or timer_or_err))
		discard_native_completion = true
		terminate_task("deadline setup failure")
		complete(false, nil, nil, nil, "deadline_failed")
		return operation
	end
	if deadline_triggered or completed or pending_terminal ~= nil then
		-- A hostile scheduler can deliver during acquisition and still return a
		-- committed handle. The deadline callback already retired the task; the
		-- newly returned timer handle must settle before the retained terminal is
		-- published.
		complete(false, nil, nil, nil, cancellation_reason or "timeout")
		return operation
	end

	local start_ok, started_or_err = xpcall(function()
		return task_handle.start()
	end, debug.traceback)
	if not start_ok or started_or_err ~= true then
		Logger.error(LOG, "%s task launch failed: %s",
			tostring(label), tostring(start_ok and started_or_err or started_or_err))
		discard_native_completion = true
		terminate_task("launch failure")
		complete(false, nil, nil, nil, "launch_failed")
	else
		if not completed then task_started = true end
	end

	return operation
end




-- ====================================
-- ====================================
-- ======= 2/ Public API ==============
-- ====================================
-- ====================================

--- True when a persisted value is a Keychain reference.
--- @param stored string|nil Persisted token field.
--- @return boolean encrypted
function M.is_encrypted(stored)
	return type(stored) == "string"
		and #stored > #KEYCHAIN_PREFIX
		and stored:sub(1, #KEYCHAIN_PREFIX) == KEYCHAIN_PREFIX
end

--- Stores a token and returns only an opaque Keychain reference on success.
--- Cleartext is never returned as a failure fallback.
--- @param entry_id string Stable account identifier.
--- @param cleartext string Secret token.
--- @param callback function Receives (ok, reference, reason).
--- @return table operation Cancellation handle.
function M.encrypt_async(entry_id, cleartext, callback)
	if type(entry_id) ~= "string" or entry_id == ""
		or type(cleartext) ~= "string" or cleartext == "" then
		invoke_guarded("Keychain token write", callback, false, nil, "invalid_input")
		return { cancel = function() return true end }
	end
	if M.is_encrypted(cleartext) then
		invoke_guarded("Keychain token write", callback, true, cleartext, nil)
		return { cancel = function() return true end }
	end

	return run_security("Keychain token write", {
		TOKEN_WRITE_FLAG, entry_id,
	}, cleartext, function(completed, exit_code, _stdout, stderr, reason)
		if completed == true and exit_code == 0 then
			invoke_guarded("Keychain token write result", callback,
				true, KEYCHAIN_PREFIX .. entry_id, nil)
			return
		end
		Logger.error(LOG, "Keychain token write failed for entry '%s' (reason=%s, rc=%s): %s",
			tostring(entry_id), tostring(reason), tostring(exit_code), tostring(stderr or ""))
		invoke_guarded("Keychain token write result", callback,
			false, nil, reason or "security_failed")
	end, true)
end

--- Resolves a Keychain reference without blocking the run loop.
--- Legacy cleartext is returned unchanged so the next durable save can migrate it.
--- @param stored string Persisted token field.
--- @param callback function Receives (ok, cleartext, reason).
--- @return table operation Cancellation handle.
function M.decrypt_async(stored, callback)
	if type(stored) ~= "string" or stored == "" then
		invoke_guarded("Keychain token read", callback, false, nil, "invalid_input")
		return { cancel = function() return true end }
	end
	if not M.is_encrypted(stored) then
		invoke_guarded("Keychain token read", callback, true, stored, nil)
		return { cancel = function() return true end }
	end

	local entry_id = stored:sub(#KEYCHAIN_PREFIX + 1)
	return run_security("Keychain token read", {
		TOKEN_READ_FLAG, entry_id,
	}, nil, function(completed, exit_code, stdout, stderr, reason)
		local cleartext = type(stdout) == "string" and (stdout:gsub("\n+$", "")) or ""
		if completed == true and exit_code == 0 and cleartext ~= "" then
			invoke_guarded("Keychain token read result", callback, true, cleartext, nil)
			return
		end
		Logger.error(LOG, "Keychain token read failed for entry '%s' (reason=%s, rc=%s): %s",
			tostring(entry_id), tostring(reason), tostring(exit_code), tostring(stderr or ""))
		invoke_guarded("Keychain token read result", callback,
			false, nil, reason or "security_failed")
	end, false)
end

--- Removes a Keychain entry with the same ownership and deadline guarantees.
--- An already-absent entry counts as success so durable cleanup tombstones can
--- be retried safely after a crash between deletion and tombstone removal.
--- @param entry_id string Stable account identifier.
--- @param callback function Receives (ok, reason).
--- @return table operation Cancellation handle.
function M.delete_async(entry_id, callback)
	if type(entry_id) ~= "string" or entry_id == "" then
		invoke_guarded("Keychain token delete", callback, false, "invalid_input")
		return { cancel = function() return true end }
	end

	return run_security("Keychain token delete", {
		TOKEN_DELETE_FLAG, entry_id,
	}, nil, function(completed, exit_code, _stdout, stderr, reason)
		if completed == true and exit_code == 0 then
			invoke_guarded("Keychain token delete result", callback, true, nil)
			return
		end
		Logger.error(LOG, "Keychain token delete failed for entry '%s' (reason=%s, rc=%s): %s",
			tostring(entry_id), tostring(reason), tostring(exit_code), tostring(stderr or ""))
		invoke_guarded("Keychain token delete result", callback,
			false, reason or "security_failed")
	end, true)
end

return M
