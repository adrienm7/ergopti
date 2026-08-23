--- infra/termination_coordinator.lua

--- ==============================================================================
--- MODULE: Controlled Process Termination Coordinator
--- DESCRIPTION:
--- Serializes user-requested reload and exit operations behind the exact
--- Karabiner lease fence. Uncontrolled process death remains the native lease
--- guardian's responsibility; this module exists so a controlled transition
--- never dismantles Hammerspoon consumers while managed rules can still emit.
---
--- FEATURES & RATIONALE:
--- 1. Fence First: local eventtaps, hotkeys and classifiers remain live until
---    the lease owner reports an exact settled revocation.
--- 2. Single Transaction: concurrent reload/quit requests share one fence;
---    an exit request safely supersedes an earlier reload request.
--- 3. Fail Closed: a rejected or failed fence leaves the current Lua environment
---    and its consumers running. Once the fence commits, any teardown failure
---    exits non-zero because already-stopped owners cannot be rolled back safely.
--- 4. Reload Truth: the reload sentinel is committed before local teardown and
---    cleared again if the native reload call itself fails.
--- 5. Drained Diagnostics: after local owners stop, terminal action waits for the
---    native logger to ACK the complete queue. Any later refusal exits non-zero;
---    rollback is impossible and an inert process is not a safe recovery state.
--- 6. Logged Async Boundary: every lease/drain completion and injected terminal
---    action is protected so Hammerspoon cannot hide a callback exception.
--- 7. Awaitable Teardown: a retained native completion pauses final drain and
---    authorizes exactly one stateful retry with the latest reload/exit intent.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")

local LOG = "infra.termination_coordinator"

local _deps = nil
local _transaction = nil

local function require_state(func_name)
	if not _deps then
		Logger.error(LOG, "'%s' called before M.init() — controlled termination unavailable.", func_name)
		return false
	end
	return true
end

local function notify_aborted(transaction, detail)
	if type(transaction.on_aborted) ~= "function" then return end
	local callback_ok, callback_err = xpcall(function()
		transaction.on_aborted(detail)
	end, debug.traceback)
	if not callback_ok then
		Logger.error(LOG, "Controlled %s abort callback failed: %s.",
			transaction.kind, tostring(callback_err))
	end
end

local function abort_transaction(transaction, detail)
	if transaction.settled then return false end
	transaction.settled = true
	transaction.completion_ok = false
	if _transaction == transaction then _transaction = nil end
	if transaction.reload_marked then
		pcall(_deps.clear_reload)
		transaction.reload_marked = false
	end
	Logger.error(LOG, "Controlled %s aborted: %s.", transaction.kind, tostring(detail))
	notify_aborted(transaction, detail)
	return false
end

--- Ends a transaction whose native exit unexpectedly returned, or whose native
--- reload/exit action raised, after every local capability had already been
--- finalized. At this
--- boundary restart/rollback is impossible: invoke the injected non-zero native
--- exit exactly once, without logging through or restarting the drained sink.
--- @param transaction table Active terminal transaction.
--- @return boolean Always false if the injected fatal exit itself returns.
local function force_post_teardown_exit(transaction)
	if transaction.settled then return false end
	transaction.settled = true
	transaction.completion_ok = false
	if _transaction == transaction then _transaction = nil end
	if transaction.reload_marked then
		pcall(_deps.clear_reload)
		transaction.reload_marked = false
	end
	-- In production this call does not return. Its protected wrapper is only a
	-- last containment boundary for an injected/native defect; there is no live
	-- logger or local consumer left to retry safely from here.
	xpcall(function()
		return _deps.fatal_exit(_deps.fatal_exit_code)
	end, debug.traceback)
	return false
end

--- Records one post-teardown failure without using the logger, then hands the
--- process to the non-zero EOF fallback. Once local owners have stopped there is
--- no rollback state, and the async sink may itself already be finalized.
--- @param transaction table Active terminal transaction.
--- @param detail any Exact causal failure detail retained for inspection.
--- @return boolean Always false if the native fatal exit unexpectedly returns.
local function fail_after_teardown(transaction, detail)
	transaction.terminal_failure = tostring(detail or "post-teardown failure")
	return force_post_teardown_exit(transaction)
end

local function invoke_terminal(transaction)
	if _transaction ~= transaction or transaction.settled then return false end
	-- No log may be emitted from this point through the terminal action: the
	-- drain callback proves the native worker has acknowledged the entire queue.
	local finalizer_ok, finalizer_result = xpcall(_deps.finalize_teardown, debug.traceback)
	if not finalizer_ok or finalizer_result ~= true then
		return fail_after_teardown(transaction,
			"post-drain finalizer failed: " .. tostring(finalizer_result))
	end
	if transaction.kind == "reload" then
		local reload_ok, reload_result = xpcall(function()
			return _deps.reload(table.unpack(transaction.arguments, 1, transaction.arguments.n))
		end, debug.traceback)
		if not reload_ok then
			transaction.terminal_failure = tostring(reload_result)
			return force_post_teardown_exit(transaction)
		end

		-- hs.reload() schedules replacement of the Lua state and is allowed to
		-- return to its caller while that native transition is pending. A protected
		-- return therefore commits this transaction; the reload sentinel must stay
		-- marked so the shutdown callback can distinguish the ensuing reload.
		transaction.settled = true
		transaction.completion_ok = true
		_transaction = nil
		return true
	end

	local exit_ok, exit_result = xpcall(function()
		return _deps.exit(transaction.exit_code)
	end, debug.traceback)
	-- os.exit() is truly non-returning. Either a throw or a return breaks its
	-- terminal ownership contract and requires the non-zero native backstop.
	transaction.terminal_failure = exit_ok
		and "native exit returned unexpectedly"
		or tostring(exit_result)
	return force_post_teardown_exit(transaction)
end

local function begin_drain(transaction)
	if transaction.drain_started then return true end
	transaction.drain_started = true
	local callback_fired = false
	local function on_drained(drained, detail)
		if callback_fired then return end
		callback_fired = true
		if _transaction ~= transaction or transaction.settled then return end
		local callback_ok, callback_err = xpcall(function()
			if drained ~= true then
				fail_after_teardown(transaction,
					"native logger ACK drain failed: " .. tostring(detail))
				return
			end
			invoke_terminal(transaction)
		end, debug.traceback)
		if not callback_ok then
			fail_after_teardown(transaction,
				"native logger drain callback raised: " .. tostring(callback_err))
		end
	end

	local begin_ok, accepted_or_err, begin_err = xpcall(function()
		return _deps.begin_drain(on_drained)
	end, debug.traceback)
	if not begin_ok or accepted_or_err ~= true then
		if not callback_fired then
			return fail_after_teardown(transaction,
				"native logger drain was not committed: "
					.. tostring(begin_ok and begin_err or accepted_or_err))
		end
		return transaction.completion_ok == true
	end
	if callback_fired then return transaction.completion_ok == true end
	-- True means exact callback ownership committed, not that the asynchronous
	-- drain has already completed. Synchronous test/native completions are valid.
	return true
end


local resume_after_teardown_boundary

--- Commits the terminal result of the exact local-teardown owner.
--- @param transaction table Active terminal transaction.
--- @param completed boolean Whether every local owner settled.
--- @param detail any Exact result or failure detail.
local function settle_teardown(transaction, completed, detail)
	transaction.teardown_pending = false
	transaction.teardown_settled = true
	transaction.teardown_completed = completed == true
	transaction.teardown_result = detail
end

--- Advances to drain or the fatal backstop after teardown reaches a terminal.
--- @param transaction table Active terminal transaction.
--- @return boolean continued
local function continue_after_teardown(transaction)
	if transaction.teardown_failure_detail ~= nil then
		local failure = tostring(transaction.teardown_failure_detail)
		if transaction.teardown_completed ~= true then
			failure = failure .. "; local teardown also failed: "
				.. tostring(transaction.teardown_result)
		end
		return fail_after_teardown(transaction, failure)
	end
	if transaction.teardown_completed ~= true then
		return fail_after_teardown(transaction,
			"local teardown failed: " .. tostring(transaction.teardown_result))
	end
	return begin_drain(transaction)
end

--- Runs one local-teardown attempt. A dependency may return `true, "pending"`
--- after retaining the supplied callback; only that exact callback authorizes
--- the coordinator to retry the stateful teardown with the latest exit/reload kind.
--- @param transaction table Active terminal transaction.
--- @return boolean|nil completed Nil while an exact callback is pending.
--- @return any detail
--- @return boolean pending
local function run_teardown_attempt(transaction)
	while true do
		local installing = true
		local callback_claimed = false
		local synchronous_settled = nil
		local synchronous_detail = nil

		local function on_teardown_ready(settled, detail)
			if callback_claimed then
				if not transaction.settled and not transaction.drain_started then
					Logger.warn(LOG, "Duplicate local teardown readiness callback ignored.")
				end
				return false
			end
			callback_claimed = true
			if installing then
				synchronous_settled = settled == true
				synchronous_detail = detail
				return synchronous_settled
			end
			local resume_ok, resume_result = xpcall(function()
				return resume_after_teardown_boundary(transaction, settled == true, detail)
			end, debug.traceback)
			if resume_ok then return resume_result end
			if _transaction == transaction and not transaction.settled then
				settle_teardown(transaction, false, resume_result)
				Logger.error(LOG, "Local teardown readiness callback raised: %s.",
					tostring(resume_result))
				return fail_after_teardown(transaction,
					"local teardown readiness callback raised: " .. tostring(resume_result))
			end
			return false
		end

		local results = table.pack(xpcall(function()
			return _deps.teardown(transaction.kind, on_teardown_ready)
		end, debug.traceback))
		installing = false

		-- An exact synchronous callback outranks a later return or throw from the
		-- acquisition call, just like native task completion outranks its signal result
		if callback_claimed then
			if synchronous_settled ~= true then
				return false, synchronous_detail, false
			end
			-- The callback settled the pending boundary, not the whole stateful pass;
			-- retry immediately so the dependency can commit its remaining owners
		else
			local call_ok = results[1] == true
			local result = results[2]
			local state = results[3]
			if not call_ok then return false, result, false end
			if result == true and state == "pending" then
				transaction.teardown_pending = true
				transaction.teardown_result = "pending"
				return nil, "pending", true
			end
			return result == true, result, false
		end
	end
end

--- Resumes the coordinator only from the callback retained by a pending teardown.
--- @param transaction table Active terminal transaction.
--- @param settled boolean Whether the pending boundary settled exactly.
--- @param detail any Boundary detail.
--- @return boolean continued
resume_after_teardown_boundary = function(transaction, settled, detail)
	if _transaction ~= transaction or transaction.settled then return false end
	if transaction.teardown_pending ~= true then
		if not transaction.drain_started then
			Logger.warn(LOG, "Late local teardown readiness callback ignored.")
		end
		return false
	end
	transaction.teardown_pending = false
	if settled ~= true then
		settle_teardown(transaction, false, detail)
	else
		local completed, result, pending = run_teardown_attempt(transaction)
		if pending then return true end
		settle_teardown(transaction, completed == true, result)
	end

	return continue_after_teardown(transaction)
end

--- Executes the primary local teardown once, except for retries authorized by
--- its retained readiness callback. Ordinary callers can observe a pending pass
--- but cannot invoke the dependency a second time themselves.
--- @param transaction table Active terminal transaction.
--- @return boolean|nil settled Nil while an exact callback is pending.
--- @return any detail
--- @return boolean pending
local function teardown_once(transaction)
	if transaction.teardown_settled == true then
		return transaction.teardown_completed == true,
			transaction.teardown_result, false
	end
	if transaction.teardown_pending == true then return nil, "pending", true end
	if transaction.teardown_attempted == true then
		return false, "teardown attempt lost its terminal state", false
	end
	transaction.teardown_attempted = true
	local completed, result, pending = run_teardown_attempt(transaction)
	if pending then return nil, result, true end
	settle_teardown(transaction, completed == true, result)
	return transaction.teardown_completed, transaction.teardown_result, false
end


--- Runs the once-only local teardown after an exact fence, then exits fatally.
--- @param transaction table Active terminal transaction.
--- @param detail any Causal failure detail.
--- @return boolean Always false if fatal_exit unexpectedly returns.
local function teardown_then_fail_after_fence(transaction, detail)
	transaction.teardown_failure_detail = tostring(detail)
	local _teardown_completed, _teardown_detail, pending = teardown_once(transaction)
	if pending then return true end
	return continue_after_teardown(transaction)
end


local function begin_terminal_sequence(transaction)
	if _transaction ~= transaction or transaction.settled then return false end
	if transaction.kind == "reload" and not transaction.reload_marked then
		local marked_ok, marked_or_err = xpcall(_deps.mark_reload, debug.traceback)
		if not marked_ok or marked_or_err ~= true then
			return teardown_then_fail_after_fence(transaction,
				"reload sentinel could not be committed: " .. tostring(marked_or_err))
		end
		transaction.reload_marked = true
	end

	local teardown_completed, teardown_result, pending = teardown_once(transaction)
	if pending then return true end
	if not teardown_completed then
		return fail_after_teardown(transaction,
			"local teardown failed: " .. tostring(teardown_result))
	end
	return begin_drain(transaction)
end


--- Waits for every synthetic transaction (including paced replacement and its
--- fenced physical replay) before stopping any tap or finalizing timers.
--- @param transaction table Active terminal transaction.
--- @return boolean accepted
local function begin_input_drain(transaction)
	if transaction.input_drain_started then return true end
	transaction.input_drain_started = true
	local callback_fired = false
	local function on_input_drained()
		if callback_fired then return end
		callback_fired = true
		if _transaction ~= transaction or transaction.settled then return end
		local ok, result = xpcall(function()
			transaction.input_drained = true
			return begin_terminal_sequence(transaction)
		end, debug.traceback)
		if not ok or result ~= true then
			fail_after_teardown(transaction,
				"synthetic input drain callback failed: " .. tostring(result))
		end
	end
	local begin_ok, accepted_or_err = xpcall(function()
		return _deps.drain_input(on_input_drained)
	end, debug.traceback)
	if not begin_ok or accepted_or_err ~= true then
		if not callback_fired then
			return teardown_then_fail_after_fence(transaction,
				"synthetic input drain was not committed: " .. tostring(accepted_or_err))
		end
		return transaction.completion_ok == true
	end
	if callback_fired then
		-- A synchronous input-drain callback may have committed an asynchronous
		-- local teardown without completing the terminal action yet. That active
		-- transaction is accepted; only an already-settled failure is a refusal.
		return not transaction.settled or transaction.completion_ok == true
	end
	return true
end

local function finish_transaction(transaction, fenced, detail)
	if _transaction ~= transaction or transaction.settled then return end
	if fenced ~= true then
		abort_transaction(transaction,
			"exact Karabiner revocation was not proven: " .. tostring(detail))
		return
	end
	transaction.fenced = true
	local logged_ok, logged_or_error = xpcall(function()
		Logger.info(LOG, "Exact Karabiner lease fenced; completing controlled %s.",
			transaction.kind)
	end, debug.traceback)
	if not logged_ok then
		return teardown_then_fail_after_fence(transaction,
			"post-fence logger failed: " .. tostring(logged_or_error))
	end
	transaction.completion_ok = begin_input_drain(transaction)
end

local function request(kind, reason, arguments, exit_code, on_aborted, require_fresh)
	if not require_state("request_" .. kind) then return false end
	if type(reason) ~= "string" or reason == "" then
		Logger.error(LOG, "Controlled %s requires a non-empty reason.", kind)
		return false
	end

	if _transaction and not _transaction.settled then
		-- An owned reload handoff must never silently join an older terminal
		-- transition. Its caller has already published reversible state that only
		-- this exact abort callback can compensate while the Lua environment is
		-- still live.
		if require_fresh == true then return false end
		if kind == "exit" and _transaction.kind == "reload" then
			if _transaction.reload_marked then
				local clear_ok, cleared = xpcall(_deps.clear_reload, debug.traceback)
				if not clear_ok or cleared ~= true then
					local detail = "reload-to-exit upgrade could not clear reload sentinel"
					if _transaction.teardown_completed then
						return fail_after_teardown(_transaction, detail)
					end
					return abort_transaction(_transaction, detail)
				end
				_transaction.reload_marked = false
			end
			_transaction.kind = "exit"
			_transaction.reason = reason
			_transaction.exit_code = exit_code
			_transaction.arguments = table.pack()
			Logger.info(LOG, "Pending controlled reload upgraded to an exit request.")
			if _transaction.teardown_completed then
				-- The drain remains live and includes records emitted by this added
				-- quit-only teardown pass. TeardownTransaction runs only the new steps.
				local teardown_ok, teardown_result = xpcall(function()
					return _deps.teardown("exit")
				end, debug.traceback)
				if not teardown_ok or teardown_result ~= true then
					return fail_after_teardown(_transaction,
						"reload-to-exit quit-only teardown failed: " .. tostring(teardown_result))
				end
			end
		end
		if kind == "exit" and type(on_aborted) == "function"
			and type(_transaction.on_aborted) ~= "function" then
			_transaction.on_aborted = on_aborted
		end
		return true
	end

	local transaction = {
		kind = kind,
		reason = reason,
		arguments = arguments or table.pack(),
		exit_code = exit_code or 0,
		settled = false,
		completion_ok = nil,
		on_aborted = on_aborted,
	}
	_transaction = transaction

	local callback_fired = false
	local function on_fenced(ok, detail)
		if callback_fired then
			-- Before teardown settles this diagnostic still belongs to the pending
			-- native drain. Afterwards the sink may be stopped, so logging here would
			-- resurrect the legacy synchronous file path after finalization.
			if not transaction.settled then
				Logger.warn(LOG, "Duplicate controlled %s lease callback ignored.", transaction.kind)
			end
			return
		end
		callback_fired = true
		local callback_ok, callback_err = xpcall(function()
			finish_transaction(transaction, ok == true, detail)
		end, debug.traceback)
		if not callback_ok then
			if ok == true and not transaction.settled then
				-- Native STOPPED is already an irreversible commit. Even a failure
				-- before the first local teardown step leaves the remap half disabled,
				-- so returning this Lua environment as live would violate the same
				-- post-fence rule as a partially completed teardown. Do not depend on
				-- the logger here: it may be the callback component that raised.
				teardown_then_fail_after_fence(transaction,
					"post-fence lease callback raised: " .. tostring(callback_err))
				return
			end
			if _transaction == transaction then _transaction = nil end
			if not transaction.settled then
				Logger.error(LOG, "Controlled %s lease callback failed before fencing: %s.",
					transaction.kind, tostring(callback_err))
			end
		end
	end

	local call_ok, accepted_or_err = xpcall(function()
		return _deps.request_lease(reason, on_fenced)
	end, debug.traceback)
	if not call_ok then
		if callback_fired then
			if transaction.fenced == true and not transaction.settled then
				return teardown_then_fail_after_fence(transaction,
					"lease request raised after exact fence: " .. tostring(accepted_or_err))
			end
			-- A synchronous callback may already have completed a reload, invoked the
			-- fatal backstop, or rejected the fence. Never log through a possibly
			-- finalized sink nor orphan an already-owned transition afterwards.
			if transaction.settled then return transaction.completion_ok == true end
		end
		if _transaction == transaction then _transaction = nil end
		Logger.error(LOG, "Controlled %s lease request raised: %s.", kind, tostring(accepted_or_err))
		return false
	end
	if accepted_or_err ~= true and not callback_fired then
		_transaction = nil
		Logger.error(LOG, "Controlled %s lease request was rejected.", kind)
		return false
	end
	if callback_fired then return transaction.completion_ok == true end
	return accepted_or_err == true
end

--- Injects the root lifecycle capabilities once all boot-time dependencies exist.
--- @param deps table Exact fence/teardown/drain/finalize/terminal/fatal functions.
--- @return boolean initialized
function M.init(deps)
	if _deps then
		Logger.warn(LOG, "M.init() called more than once — ignoring duplicate call.")
		return false
	end
	if type(deps) ~= "table" then
		Logger.error(LOG, "M.init(): dependency table is required.")
		return false
	end
	for _, name in ipairs({
		"request_lease", "drain_input", "teardown", "begin_drain", "finalize_teardown",
		"reload", "exit", "fatal_exit", "mark_reload", "clear_reload",
	}) do
		if type(deps[name]) ~= "function" then
			Logger.error(LOG, "M.init(): dependency '%s' must be a function.", name)
			return false
		end
	end
	if type(deps.fatal_exit_code) ~= "number" or deps.fatal_exit_code % 1 ~= 0
		or deps.fatal_exit_code < 1 or deps.fatal_exit_code > 255 then
		Logger.error(LOG, "M.init(): fatal_exit_code must be an integer from 1 to 255.")
		return false
	end
	_deps = deps
	Logger.success(LOG, "Controlled termination coordinator initialized.")
	return true
end

--- Reports initialization without logging, so the early hs.reload wrapper can
--- retain native recovery before any lease generation is allowed to start.
--- @return boolean initialized
function M.is_initialized()
	return _deps ~= nil
end

--- Requests a reload only after the exact lease fence settles.
--- @param reason string Stable diagnostic reason.
--- @param ... any Native hs.reload arguments.
--- @return boolean accepted
function M.request_reload(reason, ...)
	return request("reload", reason, table.pack(...), nil, nil, false)
end

--- Requests an exclusive reload and transfers one reversible caller owner into
--- the coordinator. The abort callback runs only while rollback is still safe;
--- a successful handoff has deliberately no completion callback because
--- hs.reload may return after the logger and local owners have been finalized.
--- @param reason string Stable diagnostic reason.
--- @param on_aborted function Exact pre-fence abort callback.
--- @param ... any Native hs.reload arguments.
--- @return boolean accepted
function M.request_reload_owned(reason, on_aborted, ...)
	if type(on_aborted) ~= "function" then
		Logger.error(LOG, "Owned controlled reload requires an abort callback.")
		return false
	end
	return request("reload", reason, table.pack(...), nil, on_aborted, true)
end

--- Requests process exit only after the exact lease fence settles.
--- @param reason string Stable diagnostic reason.
--- @param exit_code integer|nil Process exit status, default zero.
--- @param on_aborted function|nil Optional emergency callback invoked only when
---   the exact fence reports failure. Ordinary user quits should omit it.
--- @return boolean accepted
function M.request_exit(reason, exit_code, on_aborted)
	if exit_code == nil then exit_code = 0 end
	if type(exit_code) ~= "number" or exit_code % 1 ~= 0 or exit_code < 0 or exit_code > 255 then
		Logger.error(LOG, "Controlled exit code must be an integer from 0 to 255.")
		return false
	end
	if on_aborted ~= nil and type(on_aborted) ~= "function" then
		Logger.error(LOG, "Controlled exit abort callback must be a function when provided.")
		return false
	end
	return request("exit", reason, table.pack(), exit_code, on_aborted, false)
end

--- Reports whether one exact fence currently owns the terminal transition.
--- @return boolean pending
function M.is_pending()
	if not require_state("is_pending") then return false end
	return _transaction ~= nil and not _transaction.settled
end

return M
