--- modules/gestures/actions_aux_owner.lua

--- ==============================================================================
--- MODULE: Gesture Auxiliary Async Owner
--- DESCRIPTION:
--- Owns delayed gesture callbacks and ShellRunner open/AppleScript processes.
--- Search/click/sticky and screenshots keep their specialised owners; this
--- module covers every other asynchronous capability created by actions.lua.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local ShellRunner = require("adapters.shell_runner")
local TimerScheduler = require("adapters.timer_scheduler")

local LOG = "gestures.actions.aux_owner"

local DEFAULT_ACTION_PARENT = "gestures"
local _scopes = {}
local _next_id = 0
local _timers = {}
local _shells = {}

--- Resolves one parent-scoped admission generation.
--- @param parent string|nil Stable action parent.
--- @return table scope
local function action_scope(parent)
	local scope_id = type(parent) == "string" and parent ~= ""
		and parent or DEFAULT_ACTION_PARENT
	local scope = _scopes[scope_id]
	if scope then return scope end
	scope = {
		id = scope_id,
		paused = false,
		generation = 0,
		acquisitions = 0,
		callback_depth = 0,
	}
	_scopes[scope_id] = scope
	return scope
end

local function next_id()
	_next_id = _next_id + 1
	return _next_id
end

local function entry_is_current(entry)
	if type(entry) ~= "table" or entry.released == true then return false end
	if entry.kind == "timer" then return _timers[entry.id] == entry end
	if entry.kind == "shell" then return _shells[entry.id] == entry end
	return false
end

local function authorized(entry)
	local scope = entry.scope
	return entry_is_current(entry)
		and type(scope) == "table" and scope.paused ~= true
		and entry.discard ~= true
		and entry.generation == scope.generation
end

local function cleanup_debt(parent)
	local scope = action_scope(parent)
	if scope.acquisitions ~= 0 or scope.callback_depth ~= 0 then return true end
	for _, entry in pairs(_timers) do
		if entry.scope == scope
			and (entry.discard == true or entry.committed ~= true) then return true end
	end
	for _, entry in pairs(_shells) do
		if entry.scope == scope
			and (entry.discard == true or entry.committed ~= true) then return true end
	end
	return false
end

local function admission_open(parent)
	local scope = action_scope(parent)
	return scope.paused ~= true and not cleanup_debt(scope.id), scope
end

local function invoke(scope, label, callback, ...)
	if type(callback) ~= "function" then return true end
	local args = table.pack(...)
	scope.callback_depth = scope.callback_depth + 1
	local ok, err = xpcall(function()
		return callback(table.unpack(args, 1, args.n))
	end, debug.traceback)
	scope.callback_depth = scope.callback_depth - 1
	if not ok then
		Logger.error(LOG, "%s callback failed: %s.", tostring(label), tostring(err))
		return false
	end
	return true
end

local drain_timer

local function release_timer(entry)
	if _timers[entry.id] == entry then _timers[entry.id] = nil end
	entry.released = true
	entry.committed = false
end

local function observe_timer(entry)
	if entry.observing == true or type(entry.handle) ~= "table" then return end
	entry.observing = true
	local ok, observed = pcall(TimerScheduler.onSettled, entry.handle, function()
		if entry.due == true or entry.discard == true
			or entry.generation ~= entry.scope.generation
			or entry.scope.paused == true then
			drain_timer(entry)
		end
	end)
	if not ok or observed ~= true then
		entry.observing = false
		Logger.error(LOG, "%s timer observer refused: %s.",
			tostring(entry.label), tostring(observed))
	end
end

drain_timer = function(entry)
	if not entry_is_current(entry) then return true end
	if entry.acquiring == true then return false end
	if type(entry.handle) == "table" and entry.handle.timer ~= nil then return false end
	if entry.due == true and entry.delivery_committed ~= true
		and entry.committed == true and authorized(entry) then
		return false
	end
	local deliver = entry.due == true and entry.delivery_committed == true
		and entry.committed == true and authorized(entry)
	if deliver then
		entry.callback_active = true
		invoke(entry.scope, entry.label, entry.callback)
		entry.callback_active = false
	end
	release_timer(entry)
	return true
end

local function cancel_timer(entry)
	if not entry_is_current(entry) then return true end
	entry.discard = true
	entry.committed = false
	if entry.callback_active == true then return false end
	if entry.acquiring == true then return false end
	if type(entry.handle) ~= "table" then
		release_timer(entry)
		return true
	end
	local ok, cancelled = pcall(TimerScheduler.cancel, entry.handle)
	if ok and cancelled == true then
		if entry_is_current(entry) then drain_timer(entry) end
		return not entry_is_current(entry)
	end
	observe_timer(entry)
	Logger.error(LOG, "%s timer cleanup remains pending: %s.",
		tostring(entry.label), tostring(ok and cancelled or cancelled))
	return false
end

--- Reserves one exact deferred action without authorizing its business callback.
--- @param delay number Seconds.
--- @param label string Diagnostic label.
--- @param callback function Deferred work.
--- @return boolean committed
--- @return table|nil token Exact timer token accepted by commit_after/rollback_after.
function M.prepare_after(delay, label, callback, parent)
	local admitted, scope = admission_open(parent)
	if not admitted or type(callback) ~= "function" then return false, nil end
	local entry = {
		id = next_id(),
		kind = "timer",
		parent = scope.id,
		scope = scope,
		label = label,
		callback = callback,
		generation = scope.generation,
		committed = false,
		delivery_committed = false,
		discard = false,
		due = false,
		acquiring = true,
		released = false,
	}
	_timers[entry.id] = entry
	scope.acquisitions = scope.acquisitions + 1
	local ok, handle, committed = pcall(TimerScheduler.after, delay, function()
		entry.due = true
		drain_timer(entry)
	end)
	scope.acquisitions = scope.acquisitions - 1
	entry.acquiring = false
	if ok and type(handle) == "table" then
		entry.handle = handle
		observe_timer(entry)
	end
	if not ok or type(handle) ~= "table" or committed ~= true
		or handle.timer == nil or not authorized(entry) then
		entry.discard = true
		cancel_timer(entry)
		return false, nil
	end
	entry.committed = true
	return true, entry
end

--- Commits business delivery for one prepared timer.
--- @param token table Exact token returned by prepare_after().
--- @return boolean committed
function M.commit_after(token)
	if not entry_is_current(token) or token.kind ~= "timer"
		or token.committed ~= true or not authorized(token) then
		M.rollback_after(token)
		return false
	end
	token.delivery_committed = true
	if token.due == true then return drain_timer(token) end
	return true
end

--- Cancels one prepared or committed timer by exact identity.
--- @param token table Exact token returned by prepare_after()/after().
--- @return boolean settled
function M.rollback_after(token)
	if type(token) ~= "table" or token.kind ~= "timer" then return false end
	if token.released == true then return true end
	return cancel_timer(token)
end

--- Schedules and immediately authorizes one exact deferred action.
--- @param delay number Seconds.
--- @param label string Diagnostic label.
--- @param callback function Deferred work.
--- @return boolean committed
--- @return table|nil token Exact timer token.
function M.after(delay, label, callback, parent)
	local prepared, token = M.prepare_after(delay, label, callback, parent)
	if prepared ~= true then return false, nil end
	if M.commit_after(token) ~= true then
		M.rollback_after(token)
		return false, nil
	end
	return true, token
end

local function release_shell(entry)
	if _shells[entry.id] == entry then _shells[entry.id] = nil end
	entry.released = true
	entry.committed = false
end

local function observe_shell(entry)
	if entry.observing == true or type(entry.handle) ~= "table" then return end
	entry.observing = true
	local ok, observed = pcall(entry.handle.onSettled, function()
		if entry_is_current(entry) and entry.callback_active ~= true then
			release_shell(entry)
		end
	end)
	if not ok or observed ~= true then
		entry.observing = false
		Logger.error(LOG, "%s process observer refused: %s.",
			tostring(entry.label), tostring(observed))
	end
end

local function terminate_shell(entry)
	if not entry_is_current(entry) then return true end
	entry.discard = true
	entry.committed = false
	if entry.callback_active == true then return false end
	if entry.acquiring == true then return false end
	if type(entry.handle) ~= "table" then return false end
	local terminate_ok, accepted, state = pcall(entry.handle.terminate)
	local settled_ok, settled = pcall(entry.handle.isSettled)
	if settled_ok and settled == true then
		release_shell(entry)
		return true
	end
	observe_shell(entry)
	Logger.error(LOG, "%s process cleanup remains pending: %s (%s).",
		tostring(entry.label), tostring(terminate_ok and accepted or accepted), tostring(state))
	return false
end

local function start_shell(method, payload, label, callback, parent)
	local admitted, scope = admission_open(parent)
	if not admitted then return false end
	local entry = {
		id = next_id(),
		kind = "shell",
		parent = scope.id,
		scope = scope,
		label = label,
		generation = scope.generation,
		committed = false,
		discard = false,
		acquiring = true,
		released = false,
		dispatching = true,
		terminal_received = false,
		terminal_delivered = false,
	}
	_shells[entry.id] = entry
	scope.acquisitions = scope.acquisitions + 1
	local function terminal(...)
		if entry.terminal_received == true then return end
		entry.terminal_received = true
		entry.terminal_args = table.pack(...)
		if entry.dispatching ~= true and entry.committed == true and authorized(entry) then
			entry.terminal_delivered = true
			entry.callback_active = true
			invoke(scope, label, callback,
				table.unpack(entry.terminal_args, 1, entry.terminal_args.n))
			entry.callback_active = false
			local settled_ok, settled = pcall(entry.handle.isSettled)
			if settled_ok and settled == true and entry_is_current(entry) then
				release_shell(entry)
			end
		end
	end
	local ok, started, handle = pcall(method, payload, terminal)
	entry.dispatching = false
	scope.acquisitions = scope.acquisitions - 1
	entry.acquiring = false
	if ok and type(handle) == "table" then
		entry.handle = handle
	end
	if not ok or started ~= true or type(handle) ~= "table"
		or type(handle.terminate) ~= "function"
		or type(handle.isSettled) ~= "function"
		or type(handle.onSettled) ~= "function" or not authorized(entry) then
		entry.discard = true
		if type(handle) == "table" then
			observe_shell(entry)
			terminate_shell(entry)
		else
			release_shell(entry)
		end
		return false
	end
	entry.committed = true
	if entry.terminal_args ~= nil and entry.terminal_delivered ~= true and authorized(entry) then
		entry.terminal_delivered = true
		entry.callback_active = true
		invoke(scope, label, callback,
			table.unpack(entry.terminal_args, 1, entry.terminal_args.n))
		entry.callback_active = false
	end
	observe_shell(entry)
	return true
end

--- Starts an owned `/usr/bin/open` process.
function M.open(target, label, callback, parent)
	return start_shell(ShellRunner.open, target, label or "open", callback, parent)
end

--- Starts an owned osascript process.
function M.applescript(script, label, callback, parent)
	return start_shell(ShellRunner.applescript,
		script, label or "AppleScript", callback, parent)
end

local function settle_all(parent)
	local scope = action_scope(parent)
	local timers, shells = {}, {}
	for _, entry in pairs(_timers) do
		if entry.scope == scope then timers[#timers + 1] = entry end
	end
	for _, entry in pairs(_shells) do
		if entry.scope == scope then shells[#shells + 1] = entry end
	end
	local settled = scope.acquisitions == 0 and scope.callback_depth == 0
	for _, entry in ipairs(timers) do
		if cancel_timer(entry) ~= true then settled = false end
	end
	for _, entry in ipairs(shells) do
		if terminate_shell(entry) ~= true then settled = false end
	end
	if settled ~= true or scope.acquisitions ~= 0 or scope.callback_depth ~= 0 then
		return false
	end
	for _, entry in pairs(_timers) do if entry.scope == scope then return false end end
	for _, entry in pairs(_shells) do if entry.scope == scope then return false end end
	return true
end

function M.pause(parent)
	local scope = action_scope(parent)
	if scope.paused ~= true then
		scope.generation = scope.generation + 1
		scope.paused = true
	end
	return settle_all(scope.id)
end

function M.resume(parent)
	local scope = action_scope(parent)
	if scope.paused ~= true and not cleanup_debt(scope.id) then return true end
	if settle_all(scope.id) ~= true then return false end
	scope.generation = scope.generation + 1
	scope.paused = false
	return true
end

function M.stop(parent) return M.pause(parent) end
function M.is_paused(parent) return action_scope(parent).paused == true end
function M.has_pending(parent)
	local scope = action_scope(parent)
	if scope.acquisitions ~= 0 or scope.callback_depth ~= 0 then return true end
	for _, entry in pairs(_timers) do if entry.scope == scope then return true end end
	for _, entry in pairs(_shells) do if entry.scope == scope then return true end end
	return false
end

return M
