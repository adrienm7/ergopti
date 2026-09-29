--- infra/accessibility_wait.lua

--- ==============================================================================
--- MODULE: Accessibility Wait
--- DESCRIPTION:
--- Walks the user through the Accessibility grant at boot and resumes the boot
--- by itself once macOS trusts the process, instead of exiting and asking for a
--- relaunch.
---
--- FEATURES & RATIONALE:
--- 1. Stale grant first: the packaged app is signed ad hoc, so each build or
---    update has a new code identity. System Settings keeps showing the old
---    switch as checked while macOS refuses the new binary. The entry is reset
---    before the prompt so the switch the user turns on is the current one.
--- 2. Everything is opened for the user: the macOS prompt, the exact Settings
---    pane, and a native dialog naming the entry to turn on. The dialog needs
---    no notification permission, which a fresh install may not have, and the
---    wait closes it as soon as the grant arrives.
--- 3. No relaunch: trust is polled, and the boot continues as soon as it is
---    granted. A bounded deadline keeps an ignored request from leaving a
---    process with no input and no menu running forever.
--- 4. Never a dead end: the dialog can be closed, and there is no menu yet to
---    bring it back. Opening ErgoptiPlus again while the wait runs shows the
---    steps again instead of doing nothing.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")

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
	for _, name in ipairs({ "is_trusted", "request_prompt", "bundle_id", "reset_grant", "open_settings" }) do
		if type(permission) ~= "table" or type(permission[name]) ~= "function" then
			error("accessibility_wait.start: permission." .. name .. " must be a function", 3)
		end
	end
	for _, name in ipairs({ "every", "cancel", "show_guidance", "close_guidance", "watch_reopen",
		"on_trusted", "on_timeout" }) do
		if type(opts[name]) ~= "function" then
			error("accessibility_wait.start: " .. name .. " must be a function", 3)
		end
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

--- Clears this app's stale entry, then prompts once tccutil has settled.
--- @param permission table Accessibility permission adapter.
--- @param state table The active wait.
local function reset_then_prompt(permission, state)
	local bundle_id, bundle_err = permission.bundle_id()
	if bundle_id == nil then
		Logger.warn(LOG, "Stale Accessibility grant not reset: %s.", tostring(bundle_err))
		prompt_user(permission)
		return
	end
	Logger.start(LOG, "Resetting the Accessibility entry of %s…", bundle_id)
	local started = permission.reset_grant(bundle_id, function(ok, detail)
		if state.finished then return end
		if ok then
			Logger.success(LOG, "Accessibility entry of %s reset.", bundle_id)
		else
			Logger.warn(LOG, "Accessibility entry of %s not reset: %s.", bundle_id, tostring(detail))
		end
		prompt_user(permission)
	end)
	if started ~= true then
		Logger.warn(LOG, "tccutil could not be started; prompting without resetting %s.", bundle_id)
		prompt_user(permission)
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
	opts.close_guidance()
	continuation()
end




-- ==============================
-- ======= 2/ Public API ========
-- ==============================

--- Starts waiting for Accessibility trust.
--- @param opts table {permission, every(seconds, fn) -> handle, committed,
---        cancel(handle) -> settled, show_guidance(), close_guidance(),
---        watch_reopen(fn) -> stop|nil, detail (calls fn each time the user
---        opens ErgoptiPlus again), on_trusted(), on_timeout(elapsed_seconds),
---        poll_seconds?, deadline_seconds?}.
--- @return boolean started True when the poll timer is armed.
--- @return string|nil detail Exact refusal when started is false.
function M.start(opts)
	validate(opts)
	if _active ~= nil then return false, "an Accessibility wait is already running" end
	local poll_seconds = opts.poll_seconds or M.POLL_SECONDS
	local deadline_seconds = opts.deadline_seconds or M.DEADLINE_SECONDS
	local state = { finished = false, elapsed = 0, query_failed = false }

	local timer, committed = opts.every(poll_seconds, function()
		if state.finished then return end
		state.elapsed = state.elapsed + poll_seconds
		local trusted, detail = opts.permission.is_trusted()
		if trusted == true then
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
	opts.show_guidance()
	local stop_watch, watch_err = opts.watch_reopen(function()
		if state.finished then return end
		Logger.info(LOG, "ErgoptiPlus was opened again while waiting; showing the steps again.")
		opts.show_guidance()
	end)
	if type(stop_watch) == "function" then
		state.stop_reopen_watch = stop_watch
	else
		Logger.warn(LOG, "Reopening ErgoptiPlus will not show the steps again: %s.", tostring(watch_err))
	end
	reset_then_prompt(opts.permission, state)
	return true
end

--- Reports whether a wait is running.
--- @return boolean
function M.is_waiting()
	return _active ~= nil
end

return M
