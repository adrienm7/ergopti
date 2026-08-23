--- modules/shortcuts/actions/screenshot_save.lua

--- ==============================================================================
--- MODULE: Screenshot Save Transaction
--- DESCRIPTION:
--- Owns the asynchronous mkdir -> screencapture lifecycle shared by configurable
--- shortcuts and gestures. Every accepted action gets a process-unique target;
--- native construction, start, and exit failures are logged and notified.
--- ==============================================================================

local M = {}

local hs            = hs
local ShellRunner   = require("adapters.shell_runner")
local FileSystem    = require("adapters.file_system")
local Logger        = require("infra.logger")
local notifications = require("infra.notifications")
local i18n          = require("infra.i18n")

local LOG = "shortcuts.actions.screenshot_save"

local MKDIR_BIN         = "/bin/mkdir"
local SCREENCAPTURE_BIN = "/usr/sbin/screencapture"
local SCREENSHOT_DIR_REL = "/Pictures/screenshots"
local SCREENSHOT_STAMP_FMT = "%Y%m%d%H%M%S"

local _target_sequence = 0

-- Screenshot work is shared by configurable shortcuts and gestures. Each parent
-- owns an independent admission generation, so pausing one feature fences only
-- its operations. Every mkdir/capture process remains attached to one operation
-- until ShellRunner proves exact settlement.
local DEFAULT_ACTION_PARENT = "shortcut_bindings"
local _pause_claims = {}
local _generations = {}
local _next_operation_id = 0
local _operations = {}





-- ==========================================
-- ==========================================
-- ======= 1/ Transaction Helpers ===========
-- ==========================================
-- ==========================================

--- Emits one user-visible failure without allowing notification code to escape.
--- @param context string Failure context.
--- @param detail any Failure detail.
local function report_failure(context, detail)
	Logger.error(LOG, "Screenshot %s failed: %s.", context, tostring(detail))
	local notified, notify_error = pcall(
		notifications.notify,
		i18n.get("shortcuts.screenshot_failed"),
		nil,
		"error"
	)
	if not notified then
		Logger.error(LOG, "Screenshot failure notification failed: %s.", tostring(notify_error))
	end
end

local function action_parent(parent)
	return type(parent) == "string" and parent ~= ""
		and parent or DEFAULT_ACTION_PARENT
end

local function parent_generation(parent)
	local scope_id = action_parent(parent)
	if _generations[scope_id] == nil then _generations[scope_id] = 0 end
	return _generations[scope_id]
end

local function operation_is_current(operation)
	return _operations[operation.id] == operation
end

local function operation_has_authority(operation)
	return operation.authorized == true
		and operation.generation == parent_generation(operation.parent)
		and _pause_claims[operation.parent] ~= true
end

local function operation_is_authorized(operation)
	return operation_is_current(operation)
		and operation_has_authority(operation)
end

local function screenshot_cleanup_debt(parent)
	local scope_id = action_parent(parent)
	for _, operation in pairs(_operations) do
		if operation.parent == scope_id and operation.authorized ~= true then return true end
	end
	return false
end

local function screenshot_admission_open(parent)
	local scope_id = action_parent(parent)
	return _pause_claims[scope_id] ~= true and not screenshot_cleanup_debt(scope_id)
end

local function finish_operation(operation)
	if operation_is_current(operation) and operation.phase == nil
		and operation.acquisitions == 0 then
		_operations[operation.id] = nil
		operation.finished = true
	end
end

local function create_operation(label, parent)
	local scope_id = action_parent(parent)
	if not screenshot_admission_open(scope_id) then return nil end
	_next_operation_id = _next_operation_id + 1
	local operation = {
		id = _next_operation_id,
		label = label,
		parent = scope_id,
		generation = parent_generation(scope_id),
		authorized = true,
		acquisitions = 0,
		phase = nil,
		finished = false,
	}
	_operations[operation.id] = operation
	return operation
end

local function report_operation_failure(operation, context, detail)
	if operation_is_authorized(operation) then report_failure(context, detail) end
end

local function release_phase(operation, phase)
	if operation.phase == phase then operation.phase = nil end
	phase.committed = false
	finish_operation(operation)
end

local function observe_phase(operation, phase)
	if phase.observing == true or type(phase.handle) ~= "table" then return end
	phase.observing = true
	local observed_ok, observed = pcall(phase.handle.onSettled, function()
		if phase.starting == true then
			phase.settled_during_start = true
			return
		end
		release_phase(operation, phase)
	end)
	if not observed_ok or observed ~= true then
		phase.observing = false
		Logger.error(LOG, "Screenshot %s settlement observer failed: %s.",
			tostring(phase.context), tostring(observed))
	end
end

local function settle_phase(operation, phase)
	if operation.phase ~= phase then return true end
	operation.authorized = false
	phase.discard = true
	phase.committed = false
	local settled_ok, settled = pcall(phase.handle.isSettled)
	if settled_ok and settled == true then
		release_phase(operation, phase)
		return true
	end
	local terminate_ok, accepted, state = pcall(phase.handle.terminate)
	settled_ok, settled = pcall(phase.handle.isSettled)
	if settled_ok and settled == true then
		release_phase(operation, phase)
		return true
	end
	observe_phase(operation, phase)
	Logger.error(LOG, "Screenshot %s cleanup remains pending: %s (%s).",
		tostring(phase.context), tostring(terminate_ok and accepted or accepted),
		tostring(state))
	return false
end

local function apply_phase_terminal(operation, phase, args)
	if phase.terminal_delivered == true then return false end
	phase.terminal_delivered = true
	local deliver = phase.committed == true and phase.discard ~= true
		and operation_is_authorized(operation)
	-- The native phase is terminal before its business callback runs. Detach only
	-- this exact phase now so a successful mkdir callback may publish the capture
	-- successor. `operation.acquisitions` below keeps PAUSE pending until the
	-- callback returns, and an identity check prevents clearing that successor.
	if operation.phase == phase then operation.phase = nil end
	if deliver then
		phase.callback_active = true
		operation.acquisitions = operation.acquisitions + 1
		local callback_ok, callback_error = xpcall(function()
			return phase.on_done(table.unpack(args, 1, args.n))
		end, debug.traceback)
		operation.acquisitions = operation.acquisitions - 1
		phase.callback_active = false
		if not callback_ok then
			report_operation_failure(operation, phase.context .. " callback", callback_error)
		end
	end
	finish_operation(operation)
	return deliver
end

local function deliver_phase_terminal(operation, phase, ...)
	if phase.terminal_received == true then return false end
	phase.terminal_received = true
	local args = table.pack(...)
	if phase.starting == true then
		phase.pending_terminal = args
		return true
	end
	return apply_phase_terminal(operation, phase, args)
end

--- Starts one exact ShellRunner phase and contains hostile test/native shapes.
--- The logical slot is published before start; a false/nil/throw after native
--- mutation retains the same handle until onSettled or its terminal callback.
--- @param operation table Parent screenshot operation.
--- @param executable string Absolute executable path.
--- @param args table Argument vector.
--- @param on_done function Completion callback.
--- @param context string Diagnostic context.
--- @return boolean started
local function start_task(operation, executable, args, on_done, context)
	if not operation_is_authorized(operation) or operation.phase ~= nil then return false end
	local phase = {
		context = context,
		handle = nil,
		on_done = on_done,
		committed = false,
		discard = false,
		starting = true,
		terminal_received = false,
		terminal_delivered = false,
	}
	operation.acquisitions = operation.acquisitions + 1
	local constructed, task_or_error = xpcall(
		ShellRunner.spawn,
		debug.traceback,
		executable,
		args,
		function(...)
			return deliver_phase_terminal(operation, phase, ...)
		end
	)
	operation.acquisitions = operation.acquisitions - 1
	if not constructed or type(task_or_error) ~= "table"
		or type(task_or_error.start) ~= "function"
		or type(task_or_error.terminate) ~= "function"
		or type(task_or_error.isSettled) ~= "function"
		or type(task_or_error.onSettled) ~= "function" then
		report_operation_failure(operation,
			context .. " construction", task_or_error or "no task owner")
		finish_operation(operation)
		return false
	end

	phase.handle = task_or_error
	operation.phase = phase
	observe_phase(operation, phase)
	if not operation_is_authorized(operation) then
		phase.starting = false
		settle_phase(operation, phase)
		return false
	end
	local start_ok, started = xpcall(task_or_error.start, debug.traceback)
	phase.starting = false
	if not start_ok or started ~= true then
		phase.discard = true
		report_operation_failure(operation, context .. " start", started)
		if phase.settled_during_start == true then release_phase(operation, phase)
		else settle_phase(operation, phase) end
		return false
	end
	phase.committed = true
	if phase.pending_terminal ~= nil then
		local pending = phase.pending_terminal
		phase.pending_terminal = nil
		apply_phase_terminal(operation, phase, pending)
	elseif phase.settled_during_start == true then
		release_phase(operation, phase)
	end
	if operation.finished == true then return operation_has_authority(operation) end
	if not operation_is_authorized(operation) then
		if operation.phase == phase then settle_phase(operation, phase) end
		return false
	end
	return true
end

--- Allocates a collision-resistant target for one process/run-loop action.
--- @param prefix string Filename prefix.
--- @return string|nil target
--- @return string|nil error_message
local function next_target(prefix)
	local home_ok, home = pcall(FileSystem.expand_path, "~")
	if not home_ok or type(home) ~= "string" or home:sub(1, 1) ~= "/" then
		return nil, home or "home directory is unavailable"
	end

	local time_ok, ticks = pcall(hs.timer.absoluteTime)
	if not time_ok or type(ticks) ~= "number" then
		return nil, ticks or "hs.timer.absoluteTime is unavailable"
	end
	local pid_ok, process_id = pcall(function()
		return hs.processInfo.processID
	end)
	if not pid_ok or tonumber(process_id) == nil then
		return nil, process_id or "Hammerspoon process id is unavailable"
	end
	local stamp_ok, stamp = pcall(os.date, SCREENSHOT_STAMP_FMT)
	if not stamp_ok or type(stamp) ~= "string" then
		return nil, stamp or "wall-clock timestamp is unavailable"
	end

	_target_sequence = _target_sequence + 1
	local directory = home .. SCREENSHOT_DIR_REL
	local filename = string.format(
		"%s_%s_%d_%.0f_%d.png",
		prefix,
		stamp,
		tonumber(process_id),
		ticks,
		_target_sequence
	)
	return directory .. "/" .. filename
end





-- ==========================================
-- ==========================================
-- ======= 2/ Public Transaction ============
-- ==========================================
-- ==========================================

--- Saves one screenshot after its parent directory has committed.
--- @param flags table screencapture flags, excluding the final target path.
--- @param prefix string Filename prefix.
--- @return boolean accepted True only when the mkdir task was started.
function M.save(flags, prefix, parent)
	local scope_id = action_parent(parent)
	if not screenshot_admission_open(scope_id) then return false end
	if type(flags) ~= "table" or type(prefix) ~= "string" or prefix == "" then
		report_failure("request validation", "flags table and non-empty prefix are required")
		return false
	end

	local target, target_error = next_target(prefix)
	if not target then
		report_failure("target allocation", target_error)
		return false
	end
	local directory = target:match("^(.*)/[^/]+$")
	if not directory then
		report_failure("target allocation", "target directory is invalid")
		return false
	end

	local operation = create_operation("saved screenshot", scope_id)
	if not operation then return false end
	return start_task(operation, MKDIR_BIN, { "-p", directory }, function(exit_code)
		if exit_code ~= 0 then
			report_operation_failure(operation,
				"directory creation", "exit code " .. tostring(exit_code))
			return false
		end

		local args = {}
		for _, flag in ipairs(flags) do args[#args + 1] = tostring(flag) end
		args[#args + 1] = target
		return start_task(operation, SCREENCAPTURE_BIN, args, function(capture_exit_code)
			if capture_exit_code ~= 0 then
				report_operation_failure(operation,
					"capture", "exit code " .. tostring(capture_exit_code))
				return false
			end
			local notified, notify_error = pcall(
				notifications.notify,
				string.format(i18n.get("shortcuts.saved"), target),
				nil,
				"success"
			)
			if not notified then
				Logger.error(LOG, "Screenshot success notification failed: %s.",
					tostring(notify_error))
			end
			return true
		end, "capture")
	end, "directory")
end

--- Runs a clipboard/interactive screencapture under the same exact owner without
--- allocating a save target. Used by gesture entry points.
--- @param flags table Complete screencapture argument vector.
--- @return boolean accepted
function M.capture(flags, parent)
	local scope_id = action_parent(parent)
	if not screenshot_admission_open(scope_id) or type(flags) ~= "table" then return false end
	local operation = create_operation("clipboard screenshot", scope_id)
	if not operation then return false end
	local args = {}
	for _, flag in ipairs(flags) do args[#args + 1] = tostring(flag) end
	return start_task(operation, SCREENCAPTURE_BIN, args, function(exit_code)
		if exit_code ~= 0 then
			report_operation_failure(operation,
				"capture", "exit code " .. tostring(exit_code))
			return false
		end
		return true
	end, "capture")
end

local function settle_screenshot_operations(parent)
	local scope_id = action_parent(parent)
	local snapshot = {}
	for _, operation in pairs(_operations) do
		if operation.parent == scope_id then snapshot[#snapshot + 1] = operation end
	end
	local settled = true
	for _, operation in ipairs(snapshot) do
		operation.authorized = false
		if operation.acquisitions ~= 0 then
			settled = false
		elseif operation.phase ~= nil then
			if settle_phase(operation, operation.phase) ~= true then settled = false end
		else
			finish_operation(operation)
		end
	end
	if settled ~= true then return false end
	for _, operation in pairs(_operations) do
		if operation.parent == scope_id then return false end
	end
	return true
end

--- Adds one parent pause claim and joins every shared screenshot operation.
--- @param parent string Stable parent ID (`shortcut_bindings` or `gestures`).
--- @return boolean settled
function M.pause_screenshot_actions(parent)
	if type(parent) ~= "string" or parent == "" then return false end
	if _pause_claims[parent] ~= true then
		_generations[parent] = parent_generation(parent) + 1
		_pause_claims[parent] = true
	end
	return settle_screenshot_operations(parent)
end

--- Releases one claim only after exact cleanup. Admission reopens after the last
--- parent releases; interrupted screenshots are never replayed.
--- @param parent string Stable parent ID.
--- @return boolean settled
function M.resume_screenshot_actions(parent)
	if type(parent) ~= "string" or parent == "" then return false end
	if _pause_claims[parent] ~= true then return true end
	if settle_screenshot_operations(parent) ~= true then return false end
	_pause_claims[parent] = nil
	_generations[parent] = parent_generation(parent) + 1
	return true
end

--- Stop is a retained pause claim for the named parent.
--- @param parent string Stable parent ID.
--- @return boolean settled
function M.stop_screenshot_actions(parent)
	return M.pause_screenshot_actions(parent)
end

--- Reports whether one exact parent currently owns a pause claim.
--- @param parent string Stable parent ID.
--- @return boolean claimed
function M.has_screenshot_pause_claim(parent)
	if type(parent) ~= "string" or parent == "" then return false end
	return _pause_claims[parent] == true
end

--- @return boolean paused
function M.is_screenshot_actions_paused(parent)
	return _pause_claims[action_parent(parent)] == true
end

--- @return boolean pending
function M.has_pending_screenshot_action(parent)
	local scope_id = action_parent(parent)
	for _, operation in pairs(_operations) do
		if operation.parent == scope_id then return true end
	end
	return false
end

return M
