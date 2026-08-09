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
---    and its consumers running instead of creating a missing-output window.
--- 4. Reload Truth: the reload sentinel is committed before local teardown and
---    cleared again if the native reload call itself fails.
--- 5. Logged Async Boundary: every lease completion and injected terminal action
---    is protected so Hammerspoon cannot hide a callback exception in Console.
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

local function invoke_terminal(transaction)
	local reload_marked = false
	if transaction.kind == "reload" then
		local marked_ok, marked_or_err = xpcall(_deps.mark_reload, debug.traceback)
		if not marked_ok or marked_or_err ~= true then
			Logger.error(LOG, "Controlled reload sentinel could not be committed: %s.",
				tostring(marked_or_err))
			return false
		end
		reload_marked = true
	end

	local teardown_ok, teardown_result = xpcall(
		function() return _deps.teardown(transaction.kind) end,
		debug.traceback
	)
	if not teardown_ok or teardown_result ~= true then
		if reload_marked then pcall(_deps.clear_reload) end
		Logger.error(LOG, "Controlled %s local teardown failed: %s.",
			transaction.kind, tostring(teardown_result))
		return false
	end

	_transaction = nil
	local terminal_ok, result_or_err
	if transaction.kind == "reload" then
		terminal_ok, result_or_err = xpcall(function()
			return _deps.reload(table.unpack(transaction.arguments, 1, transaction.arguments.n))
		end, debug.traceback)
	else
		terminal_ok, result_or_err = xpcall(function()
			return _deps.exit(transaction.exit_code)
		end, debug.traceback)
	end
	if not terminal_ok then
		if reload_marked then pcall(_deps.clear_reload) end
		Logger.error(LOG, "Controlled %s terminal action failed: %s.",
			transaction.kind, tostring(result_or_err))
		return false
	end
	return true
end

local function finish_transaction(transaction, fenced, detail)
	if _transaction ~= transaction or transaction.settled then return end
	transaction.settled = true
	if fenced ~= true then
		transaction.completion_ok = false
		_transaction = nil
		Logger.error(LOG,
			"Controlled %s aborted because exact Karabiner revocation was not proven: %s.",
			transaction.kind, tostring(detail))
		if type(transaction.on_aborted) == "function" then
			local callback_ok, callback_err = xpcall(function()
				transaction.on_aborted(detail)
			end, debug.traceback)
			if not callback_ok then
				Logger.error(LOG, "Controlled %s abort callback failed: %s.",
					transaction.kind, tostring(callback_err))
			end
		end
		return
	end
	Logger.info(LOG, "Exact Karabiner lease fenced; completing controlled %s.", transaction.kind)
	transaction.completion_ok = invoke_terminal(transaction)
end

local function request(kind, reason, arguments, exit_code, on_aborted)
	if not require_state("request_" .. kind) then return false end
	if type(reason) ~= "string" or reason == "" then
		Logger.error(LOG, "Controlled %s requires a non-empty reason.", kind)
		return false
	end

	if _transaction and not _transaction.settled then
		if kind == "exit" and _transaction.kind == "reload" then
			_transaction.kind = "exit"
			_transaction.reason = reason
			_transaction.exit_code = exit_code
			_transaction.arguments = table.pack()
			Logger.info(LOG, "Pending controlled reload upgraded to an exit request.")
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
			Logger.warn(LOG, "Duplicate controlled %s lease callback ignored.", transaction.kind)
			return
		end
		callback_fired = true
		local callback_ok, callback_err = xpcall(function()
			finish_transaction(transaction, ok == true, detail)
		end, debug.traceback)
		if not callback_ok then
			if _transaction == transaction then _transaction = nil end
			Logger.error(LOG, "Controlled %s lease callback failed: %s.",
				transaction.kind, tostring(callback_err))
		end
	end

	local call_ok, accepted_or_err = xpcall(function()
		return _deps.request_lease(reason, on_fenced)
	end, debug.traceback)
	if not call_ok then
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
--- @param deps table Exact request_lease/teardown/reload/exit/mark/clear functions.
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
		"request_lease", "teardown", "reload", "exit", "mark_reload", "clear_reload",
	}) do
		if type(deps[name]) ~= "function" then
			Logger.error(LOG, "M.init(): dependency '%s' must be a function.", name)
			return false
		end
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
