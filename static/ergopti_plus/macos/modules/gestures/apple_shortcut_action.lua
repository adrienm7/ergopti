--- modules/gestures/apple_shortcut_action.lua

--- ==============================================================================
--- MODULE: Run an Apple Shortcut (macOS)
--- DESCRIPTION:
--- The run_apple_shortcut action of the shared catalogue and the listing its
--- editor picks from. A binding stores one shortcut of the user's Shortcuts
--- library by identifier and name (_shared/shortcuts/engine/user_action_parameter.lua);
--- running it lists the library, refuses a shortcut that was deleted or
--- renamed with a named notice, then invokes it through the chosen Apple
--- Shortcut owner (adapters/apple_shortcuts.lua) over the command-line
--- transport (adapters/apple_shortcuts_cli.lua), which revalidates the
--- identifier once more right before the run.
---
--- FEATURES & RATIONALE:
--- 1. Never blocks the runloop: the listing, the run and the reading of the
---    selection are all asynchronous, one run at a time.
--- 2. Bounded: the run stops after apple_shortcut_run_timeout_ms, and a text
---    output larger than user_action_output_bytes is refused.
--- 3. Pausing the parent that dispatched a run cancels it through the owner,
---    like every other process the gesture actions own (actions_aux_owner).
--- 4. The selection a shortcut receives and the text it returns cross the
---    disk only as private temporary files (mode 0600, removed after the run),
---    and neither, nor the shortcut's name, is logged.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.logger")
local Timings = require("infra.timings")
local AuxOwner = require("modules.gestures.actions_aux_owner")
local UserActions = require("modules.gestures.user_actions")
local FileSystem = require("core.fs.adapters.file_system")
local Owner = require("adapters.apple_shortcuts")
local Cli = require("adapters.apple_shortcuts_cli")
local Parameter = require("shortcuts.engine.user_action_parameter")

local LOG = "gestures.apple_shortcut"

M.RUN_TIMEOUT_SEC = Timings.sec("gestures", "apple_shortcut_run_timeout_ms")
-- One output bound for every user action (modules/gestures/user_actions)
M.MAX_OUTPUT_BYTES = UserActions.MAX_OUTPUT_BYTES

-- The consumer identity the owner records for every run of this action.
M.CONSUMER = "run_apple_shortcut"

-- The owner's terminal categories that name the shortcut itself, and the
-- notice each one shows.
M.REFUSAL_NOTICES = {
	missing = "user_actions.shortcut_missing",
	renamed = "user_actions.shortcut_renamed",
	stale_discovery = "user_actions.shortcut_renamed",
}

-- The one owner and the run in flight. Declared above every reader.
local _owner = nil
local _run = nil
local _ports = nil

--- Test seam: replaces the owner's ports (nil restores the command line).
--- @param ports table|nil
function M._set_ports(ports)
	_ports, _owner, _run = ports, nil, nil
end

--- The shared owner, created on first use.
--- @return table|nil owner
--- @return string|nil reason
local function owner()
	if _owner then return _owner end
	local created, reason = Owner.new(_ports or Cli.ports(function() return _run end))
	_owner = created
	return created, reason
end

--- Removes a run's temporary files, frees the action for the next run and
--- tells the run's own observer how it ended.
--- @param run table
--- @param success boolean|nil True when the shortcut completed.
--- @param category string|nil The closed terminal category.
local function release(run, success, category)
	if run.cancelled then success, category = false, "cancelled" end
	run.release_pending = { success = success == true, category = category }
	-- A native allocation or write can reenter PAUSE and still return a newly
	-- created file afterward. Keep the run published until that call returns so
	-- its exact temporary paths can be attached and removed before a successor.
	if (run.acquiring or 0) > 0 or run.releasing then return false end
	run.releasing = true
	local settled = true
	for _, field in ipairs({ "input_path", "output_path" }) do
		local path = run[field]
		if path then
			local ok, removed, detail = pcall(FileSystem.remove_exact, path)
			local absent = false
			if not ok or removed ~= true then
				local classified, _, status = pcall(FileSystem.classify_no_follow, path)
				absent = classified and status == "absent"
			end
			if (ok and removed == true) or absent then
				run[field] = nil
			else
				settled = false
				Logger.error(LOG, "A temporary file of a shortcut run stayed: %s.", tostring(ok and detail or removed))
			end
		end
	end
	run.releasing = false
	if not settled then return false end
	local outcome = run.release_pending
	run.release_pending = nil
	if _run == run then _run = nil end
	local observer = run.on_finished
	run.on_finished = nil
	if observer then
		local ok, err = pcall(observer, outcome.success, outcome.category or (outcome.success and "completed" or "refused"))
		if not ok then Logger.error(LOG, "A shortcut run observer raised: %s.", tostring(err)) end
	end
	return true
end

--- Pausing a parent cancels its run: the owner invalidates its choices and
--- stops the tool, so no stale completion can type into the paused scope.
AuxOwner.register_pause_listener(M.CONSUMER, function(parent)
	local run = _run
	if not run or run.parent ~= parent then return end
	run.cancelled = true
	if _owner then _owner.invalidate() end
	Logger.info(LOG, "A shortcut run was cancelled by the pause of its parent.")
	release(run, false, "cancelled")
end)





-- ==================================
-- ==================================
-- ======= 1/ Library Listing =======
-- ==================================
-- ==================================

--- Lists the user's shortcuts for the editor.
--- @param finish function fn(rows, reason): rows is an array of { id, name } in
---   library order, nil with a closed reason when the library could not be read.
--- @return boolean accepted
--- @return string|nil reason
function M.list(finish)
	if type(finish) ~= "function" then error("apple_shortcut_action.list: finish must be a function", 2) end
	local current, reason = owner()
	if not current then return false, reason end
	return current.discover(function(result, refused)
		if not result then finish(nil, refused); return end
		local rows = Cli.observed_rows()
		if #rows < #result.choices then finish(nil, "invalid_reply"); return end
		local listed = {}
		for index, choice in ipairs(result.choices) do
			listed[index] = { id = rows[index].id, name = choice.label }
		end
		finish(listed)
	end)
end





-- ======================
-- ======================
-- ======= 2/ Run =======
-- ======================
-- ======================

--- Reports a refused or failed run with the notice its category names.
--- @param run table
--- @param category string The owner's terminal category.
local function report_refusal(run, category)
	local name = run.fields.name
	if run.timed_out then
		Logger.error(LOG, "A shortcut run was stopped after %.0f seconds.", M.RUN_TIMEOUT_SEC)
		UserActions.notify("user_actions.shortcut_timeout", name, string.format("%.0f", M.RUN_TIMEOUT_SEC))
	elseif run.overflow then
		Logger.error(LOG, "A shortcut run printed more than %d bytes and was stopped.", M.MAX_OUTPUT_BYTES)
		UserActions.notify("user_actions.command_output_too_large", M.MAX_OUTPUT_BYTES)
	elseif M.REFUSAL_NOTICES[category] then
		Logger.warn(LOG, "A shortcut run was refused: %s.", category)
		UserActions.notify(M.REFUSAL_NOTICES[category], name)
	elseif category == "execution_refused" then
		Logger.error(LOG, "A shortcut run failed (code %s).", tostring(run.code))
		local line = Parameter.first_line(run.stderr, Parameter.NOTICE_LINE_BYTES)
		if line then
			UserActions.notify("user_actions.shortcut_failed_detail", name, line)
		else
			UserActions.notify("user_actions.shortcut_failed", name)
		end
	elseif category == "admission_refused" then
		-- The parent was paused or the run superseded: nothing to tell the user
		Logger.info(LOG, "A shortcut run was no longer admitted.")
	else
		Logger.error(LOG, "Shortcuts could not run a shortcut: %s.", tostring(category))
		UserActions.notify("user_actions.shortcuts_unavailable")
	end
end

--- Reads the text a finished run wrote and types or copies it.
--- @param run table
local function deliver(run)
	local function admitted()
		return _run == run and not run.cancelled and not AuxOwner.is_paused(run.parent)
	end
	if not admitted() then return end
	if run.fields.output == "none" then return end
	local status, attributes = FileSystem.path_status(run.output_path)
	if not admitted() then return end
	if status ~= "present" or type(attributes) ~= "table" then
		Logger.warn(LOG, "A shortcut run returned no text output.")
		return
	end
	if type(attributes.size) ~= "number" or attributes.size > M.MAX_OUTPUT_BYTES then
		Logger.error(LOG, "A shortcut run returned more than %d bytes.", M.MAX_OUTPUT_BYTES)
		UserActions.notify("user_actions.command_output_too_large", M.MAX_OUTPUT_BYTES)
		return
	end
	local output, read_status = FileSystem.read_bounded(run.output_path, M.MAX_OUTPUT_BYTES)
	if not admitted() then return end
	if read_status == "too_large" then
		Logger.error(LOG, "A shortcut run returned more than %d bytes.", M.MAX_OUTPUT_BYTES)
		UserActions.notify("user_actions.command_output_too_large", M.MAX_OUTPUT_BYTES)
		return
	end
	if type(output) ~= "string" then
		Logger.error(LOG, "A shortcut run's text output could not be read.")
		return
	end
	UserActions.deliver_output(output, run.fields.output, run.max_typed, "A shortcut run")
end

--- Invokes the stored shortcut once its input is ready: discovers, refuses a
--- deleted or renamed shortcut, then hands the matching choice to the owner.
--- @param run table
local function invoke(run)
	local current, reason = owner()
	if not current then
		report_refusal(run, reason)
		release(run, false, reason)
		return
	end
	local function admitted()
		return _run == run and not run.cancelled and not AuxOwner.is_paused(run.parent)
	end
	local discovery_delivered = false
	local accepted, refused = current.discover(function(result, discover_reason)
		if discovery_delivered then return end
		discovery_delivered = true
		if not admitted() then release(run, false, "admission_refused"); return end
		if not result then
			report_refusal(run, discover_reason)
			release(run, false, discover_reason)
			return
		end
		local rows, index = Cli.observed_rows(), nil
		for position, row in ipairs(rows) do
			if row.id == run.fields.id then index = position end
		end
		local category = index == nil and "missing"
			or (rows[index].name ~= run.fields.name and "renamed")
			-- Past the owner's MAX_CHOICES rows: listed, but no choice to invoke
			or (result.choices[index] == nil and "catalogue_limit") or nil
		if category then
			report_refusal(run, category)
			release(run, false, category)
			return
		end
		local invocation_delivered = false
		local invoked, invoke_reason = current.invoke(result.choices[index].key, M.CONSUMER, admitted,
			function(success, terminal)
				if invocation_delivered then return end
				invocation_delivered = true
				if success then
					Logger.success(LOG, "A shortcut run completed.")
					deliver(run)
				else
					report_refusal(run, terminal)
				end
				release(run, success, terminal)
			end)
		if not invoked and not invocation_delivered then
			invocation_delivered = true
			report_refusal(run, invoke_reason)
			release(run, false, invoke_reason)
		end
	end)
	if not accepted and not discovery_delivered then
		discovery_delivered = true
		report_refusal(run, refused)
		release(run, false, refused)
	end
end

--- Creates a private temporary file for a run, or nil when none could be made.
--- @param content string|nil Text to write, nil for an empty file.
--- @return string|nil path
local function temp_file(run, field, content)
	local path, detail = FileSystem.create_secure_temp_file()
	if not path then
		Logger.error(LOG, "No temporary file for a shortcut run: %s.", tostring(detail))
		return nil
	end
	run[field] = path
	if run.cancelled then return nil end
	if content ~= nil then
		local written = FileSystem.write(path, content)
		if run.cancelled then return nil end
		if written ~= true then
			Logger.error(LOG, "The input of a shortcut run could not be written.")
			return nil
		end
	end
	if run.cancelled then return nil end
	return path
end

--- Keeps a reentrant cancellation pending until the native acquisition returns.
local function acquire_temp_file(run, field, content)
	run.acquiring = run.acquiring + 1
	local ok, result = xpcall(temp_file, debug.traceback, run, field, content)
	run.acquiring = run.acquiring - 1
	if not ok then
		Logger.error(LOG, "A shortcut temporary file acquisition failed: %s.", tostring(result))
		return nil
	end
	return result
end

--- Runs a decoded run_apple_shortcut parameter.
--- @param fields table { id, name, input, output } from user_action_parameter.
--- @param parent string|nil Action parent.
--- @param max_typed number Longest text typed, in code points.
--- @param on_finished function|nil fn(success, category) once the run ends
---   (the field run reads it); never called when the run does not start.
--- @return boolean started
function M.run(fields, parent, max_typed, on_finished)
	if _run and _run.release_pending then
		local pending = _run.release_pending
		release(_run, pending.success, pending.category)
	end
	if _run then
		Logger.warn(LOG, "A shortcut run is still in flight: this one is refused.")
		UserActions.notify("user_actions.shortcut_busy")
		return false
	end
	local scope_id = type(parent) == "string" and parent ~= "" and parent or "gestures"
	local run = { fields = fields, parent = scope_id, max_typed = max_typed, acquiring = 0,
		timeout_sec = M.RUN_TIMEOUT_SEC, max_bytes = M.MAX_OUTPUT_BYTES, on_finished = on_finished }
	_run = run
	if fields.output ~= "none" then
		local allocated = acquire_temp_file(run, "output_path", nil)
		if run.cancelled then
			release(run, false, "cancelled")
			return false
		end
		if not allocated then
			run.on_finished = nil
			release(run)
			UserActions.notify("user_actions.shortcuts_unavailable")
			return false
		end
	end
	Logger.start(LOG, "Running the shortcut of a run_apple_shortcut binding…")
	if _run ~= run or run.cancelled then return false end
	if fields.input ~= "selection" then
		invoke(run)
		return true
	end
	local Text = require("modules.shortcuts.actions.text")
	local started = Text.read_copied_selection(parent, function(selection)
		if _run ~= run or run.cancelled then return end
		local allocated = acquire_temp_file(run, "input_path", selection)
		if run.cancelled then release(run, false, "cancelled"); return end
		if not allocated then
			release(run, false, "input_refused")
			UserActions.notify("user_actions.shortcuts_unavailable")
			return
		end
		invoke(run)
	end, function()
		if _run ~= run or run.cancelled then return end
		Logger.warn(LOG, "Nothing was selected: the shortcut was not run.")
		UserActions.notify("user_actions.no_selection")
		release(run, false, "no_selection")
	end)
	if not started then
		Logger.error(LOG, "The selection for a shortcut run could not be read.")
		run.on_finished = nil
		release(run)
	end
	return started == true
end

--- Whether a run is in flight (the field run and the tests read it).
--- @return boolean
function M.busy() return _run ~= nil end

return M
