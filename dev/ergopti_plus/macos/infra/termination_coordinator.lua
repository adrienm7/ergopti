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

local function begin_terminal_sequence(transaction)
	if _transaction ~= transaction or transaction.settled then return false end
	if transaction.kind == "reload" and not transaction.reload_marked then
		local marked_ok, marked_or_err = xpcall(_deps.mark_reload, debug.traceback)
		if not marked_ok or marked_or_err ~= true then
			return fail_after_teardown(transaction,
				"reload sentinel could not be committed: " .. tostring(marked_or_err))
		end
		transaction.reload_marked = true
	end

	local teardown_ok, teardown_result = xpcall(
		function() return _deps.teardown(transaction.kind) end,
		debug.traceback
	)
	if not teardown_ok or teardown_result ~= true then
		return fail_after_teardown(transaction,
			"local teardown failed: " .. tostring(teardown_result))
	end
	transaction.teardown_completed = true
	return begin_drain(transaction)
end

local function finish_transaction(transaction, fenced, detail)
	if _transaction ~= transaction or transaction.settled then return end
	if fenced ~= true then
		abort_transaction(transaction,
			"exact Karabiner revocation was not proven: " .. tostring(detail))
		return
	end
	transaction.fenced = true
	Logger.info(LOG, "Exact Karabiner lease fenced; completing controlled %s.", transaction.kind)
	transaction.completion_ok = begin_terminal_sequence(transaction)
end

local function request(kind, reason, arguments, exit_code, on_aborted)
	if not require_state("request_" .. kind) then return false end
	if type(reason) ~= "string" or reason == "" then
		Logger.error(LOG, "Controlled %s requires a non-empty reason.", kind)
		return false
	end

	if _transaction and not _transaction.settled then
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
				fail_after_teardown(transaction,
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
				return fail_after_teardown(transaction,
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
		"request_lease", "teardown", "begin_drain", "finalize_teardown",
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
	return request("reload", reason, table.pack(...), nil, nil)
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
	return request("exit", reason, table.pack(), exit_code, on_aborted)
end

--- Reports whether one exact fence currently owns the terminal transition.
--- @return boolean pending
function M.is_pending()
	if not require_state("is_pending") then return false end
	return _transaction ~= nil and not _transaction.settled
end

return M
