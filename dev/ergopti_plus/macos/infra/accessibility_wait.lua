--- infra/accessibility_wait.lua

--- ==============================================================================
--- MODULE: Accessibility Wait
--- DESCRIPTION:
--- Walks the user through the Accessibility grant at boot and resumes the boot
--- by itself once macOS trusts the process, instead of exiting and asking for a
--- relaunch.
---
--- FEATURES & RATIONALE:
--- 1. Stale grant first, once per install: a new build or update can have a
---    new code identity. System Settings keeps showing the old switch as
---    checked while macOS refuses the new binary. The entry is reset before the
---    prompt so the switch the user turns on is the current one. Only the first
---    boot of an install resets: a reload or relaunch of the same install that
---    reset at every boot erased the entry the user had just added (field report
---    2026-11-05), so the reset is remembered by install identity.
--- 2. macOS's own prompt, with the Settings pane opened behind it. Its
---    button adds and selects the right entry; a second Ergopti dialog asking
---    to find the app with Cmd+Shift+G and + only competed with it (field
---    report 2026-11-05).
--- 3. Other copies first: a copy signed differently (a local build beside
---    the installed prerelease) shares the bundle identifier, so the switch
---    the user turns on can be its own. Resetting then only erased that
---    switch at every reload. When the probe finds such copies the entry is
---    left alone and a dialog names their paths; a failed probe falls back to
---    the reset, which a lone copy needs.
--- 4. No relaunch: trust is polled, and the boot continues as soon as it is
---    granted. A bounded deadline keeps an ignored request from leaving a
---    process with no input and no menu running forever.
--- 5. Never a dead end: the prompt can be dismissed, and there is no menu yet
---    to bring it back. Opening ErgoptiPlus again while the wait runs asks
---    macOS for its prompt again instead of doing nothing.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.logger")

local LOG = "accessibility_wait"

M.POLL_SECONDS = 1
M.DEADLINE_SECONDS = 600

local _active = nil




-- =====================================
-- ======= 1/ Internal helpers =========
-- =====================================

--- Checks the injected dependencies before any side effect.
--- @param opts table Wait options.
local function validate(opts)
	if type(opts) ~= "table" then error("accessibility_wait.start: opts must be a table", 3) end
	local permission = opts.permission
	for _, name in ipairs({ "is_trusted", "request_prompt", "bundle_id", "reset_grant", "open_settings",
		"other_copies" }) do
		if type(permission) ~= "table" or type(permission[name]) ~= "function" then
			error("accessibility_wait.start: permission." .. name .. " must be a function", 3)
		end
	end
	for _, name in ipairs({ "every", "cancel", "watch_reopen", "name_other_copies", "on_trusted", "on_timeout" }) do
		if type(opts[name]) ~= "function" then
			error("accessibility_wait.start: " .. name .. " must be a function", 3)
		end
	end
	if type(opts.install_identity) ~= "string" or opts.install_identity == "" then
		error("accessibility_wait.start: install_identity must be a non-empty string", 3)
	end
	local memory = opts.reset_memory
	if type(memory) ~= "table" or type(memory.get) ~= "function" or type(memory.set) ~= "function" then
		error("accessibility_wait.start: reset_memory must have get and set functions", 3)
	end
end

--- Asks macOS for its prompt and opens the Settings pane.
--- @param permission table Accessibility permission adapter.
local function prompt_user(permission)
	local prompted, prompt_err = permission.request_prompt()
	if prompted ~= true then
		Logger.error(LOG, "Accessibility prompt could not be requested: %s.", tostring(prompt_err))
	end
	if permission.open_settings() ~= true then
		Logger.error(LOG, "Accessibility settings pane could not be opened.")
	end
end

--- Clears this app's stale entry once per install, then prompts once tccutil has settled.
--- @param permission table Accessibility permission adapter.
--- @param state table The active wait.
--- @param opts table Wait options (install_identity, reset_memory).
local function reset_then_prompt(permission, state, opts)
	if opts.reset_memory.get() == opts.install_identity then
		Logger.info(LOG, "Accessibility entry already reset for install %s; keeping the user's entry.",
			opts.install_identity)
		prompt_user(permission)
		return
	end
	local bundle_id, bundle_err = permission.bundle_id()
	if bundle_id == nil then
		state.reset_pending = false
		Logger.warn(LOG, "Stale Accessibility grant not reset: %s.", tostring(bundle_err))
		prompt_user(permission)
		return
	end
	Logger.start(LOG, "Resetting the Accessibility entry of %s…", bundle_id)
	local started = permission.reset_grant(bundle_id, function(ok, detail)
		state.reset_pending = false
		if state.finished then return end
		if ok then
			Logger.success(LOG, "Accessibility entry of %s reset.", bundle_id)
			if opts.reset_memory.set(opts.install_identity) ~= true then
				Logger.error(LOG, "The reset of install %s could not be remembered; the next boot resets again.",
					opts.install_identity)
			end
		else
			Logger.warn(LOG, "Accessibility entry of %s not reset: %s.", bundle_id, tostring(detail))
		end
		prompt_user(permission)
	end)
	if started ~= true then
		state.reset_pending = false
		Logger.warn(LOG, "tccutil could not be started; prompting without resetting %s.", bundle_id)
		prompt_user(permission)
	end
end

--- Leaves the entry alone when another copy signed differently can hold the
--- switch, and names those copies; otherwise resets once per install.
--- @param permission table Accessibility permission adapter.
--- @param state table The active wait.
--- @param opts table Wait options (name_other_copies, install_identity, reset_memory).
local function check_copies_then_reset(permission, state, opts)
	local started, start_err = permission.other_copies(function(paths, detail)
		if state.finished then
			state.reset_pending = false
			return
		end
		if type(paths) ~= "table" then
			Logger.warn(LOG, "Other copies of the app could not be listed (%s); resetting as for a lone copy.",
				tostring(detail))
			reset_then_prompt(permission, state, opts)
			return
		end
		if #paths == 0 then
			reset_then_prompt(permission, state, opts)
			return
		end
		state.reset_pending = false
		Logger.warn(LOG, "%d other copies signed differently can hold the Accessibility switch: %s; not resetting.",
			#paths, table.concat(paths, ", "))
		prompt_user(permission)
		state.other_copies = paths
		local ok, close = xpcall(opts.name_other_copies, debug.traceback, paths)
		if ok and type(close) == "function" then
			state.close_copies_dialog = close
		else
			Logger.error(LOG, "The dialog naming the other copies did not open: %s.", tostring(close))
		end
	end)
	if started ~= true then
		Logger.warn(LOG, "Other copies of the app could not be listed (%s); resetting as for a lone copy.",
			tostring(start_err))
		reset_then_prompt(permission, state, opts)
	end
end

--- Ends the active wait exactly once.
--- @param state table The active wait.
--- @param opts table Wait options.
--- @param continuation function on_trusted or on_timeout.
local function finish(state, opts, continuation)
	if state.finished then return end
	state.finished = true
	if _active == state then _active = nil end
	if opts.cancel(state.timer) ~= true then
		Logger.warn(LOG, "Accessibility poll timer did not settle on cancel.")
	end
	if state.stop_reopen_watch ~= nil then state.stop_reopen_watch() end
	if state.close_copies_dialog ~= nil then state.close_copies_dialog() end
	continuation()
end




-- ==============================
-- ======= 2/ Public API ========
-- ==============================

--- Starts waiting for Accessibility trust.
--- @param opts table {permission, every(seconds, fn) -> handle, committed,
---        cancel(handle) -> settled, watch_reopen(fn) -> stop|nil, detail (calls fn each time the user
---        opens ErgoptiPlus again), name_other_copies(paths) -> close|nil (shows
---        the copies that can hold the switch), on_trusted(), on_timeout(elapsed_seconds),
---        install_identity (this install's code identity), reset_memory
---        {get() -> identity|nil, set(identity) -> ok} (the install whose stale
---        entry was last reset), poll_seconds?, deadline_seconds?}.
--- @return boolean started True when the poll timer is armed.
--- @return string|nil detail Exact refusal when started is false.
function M.start(opts)
	validate(opts)
	if _active ~= nil then return false, "an Accessibility wait is already running" end
	local poll_seconds = opts.poll_seconds or M.POLL_SECONDS
	local deadline_seconds = opts.deadline_seconds or M.DEADLINE_SECONDS
	local state = { finished = false, elapsed = 0, query_failed = false, reset_pending = true }

	local timer, committed = opts.every(poll_seconds, function()
		if state.finished then return end
		state.elapsed = state.elapsed + poll_seconds
		local trusted, detail = opts.permission.is_trusted()
		-- A still-running tccutil can revoke trust after an apparently successful
		-- poll. Boot must not arm input taps until that reset has settled.
		if trusted == true and not state.reset_pending then
			Logger.success(LOG, "Accessibility granted after %d s; resuming boot.", state.elapsed)
			finish(state, opts, opts.on_trusted)
			return
		end
		if trusted == nil and not state.query_failed then
			state.query_failed = true
			Logger.warn(LOG, "Accessibility state query failed while waiting: %s.", tostring(detail))
		end
		if state.elapsed >= deadline_seconds then
			Logger.error(LOG, "Accessibility still not granted after %d s.", state.elapsed)
			finish(state, opts, function() opts.on_timeout(state.elapsed) end)
		end
	end)
	if committed ~= true then return false, "Accessibility poll timer did not arm" end
	state.timer = timer
	_active = state

	Logger.info(LOG, "Waiting for the Accessibility permission (up to %d s)…", deadline_seconds)
	local stop_watch, watch_err = opts.watch_reopen(function()
		if state.finished then return end
		Logger.info(LOG, "ErgoptiPlus was opened again while waiting; asking macOS for its prompt again.")
		prompt_user(opts.permission)
		if state.other_copies ~= nil then
			local ok, err = xpcall(opts.name_other_copies, debug.traceback, state.other_copies)
			if not ok then Logger.error(LOG, "The dialog naming the other copies raised: %s.", tostring(err)) end
		end
	end)
	if type(stop_watch) == "function" then
		state.stop_reopen_watch = stop_watch
	else
		Logger.warn(LOG, "Reopening ErgoptiPlus will not ask for the prompt again: %s.", tostring(watch_err))
	end
	check_copies_then_reset(opts.permission, state, opts)
	return true
end

--- Reports whether a wait is running.
--- @return boolean
function M.is_waiting()
	return _active ~= nil
end

return M
