--- diagnostics/ui/field_check/field_report_progress.lua

--- ==============================================================================
--- MODULE: Field Report Window Progress (macOS)
--- DESCRIPTION:
--- The run behind the field report progress window
--- (_shared/ui/field_report/, hosted by field_report_window.lua): its progress
--- as the in-app field run observer reports it, the page messages it becomes
--- (init, step, done, action), and the five actions the page asks for
--- (cancel, close, open_folder, copy, issue), as the Linux host does
--- (linux/diagnostics/ui/field_check/field_report.lua).
---
--- FEATURES & RATIONALE:
--- 1. The run is admitted before the window opens, and its first step may
---    start before the page has loaded: every state is kept, and the page's
---    ready signal gets the init message with the states so far, then the end.
--- 2. The page names actions only. The folder it opens is the run's own, the
---    text it copies is the report this module holds, and the issue goes
---    through the diagnostics runner (diagnostics/ui/healthcheck/report.lua
---    report_field_run): the bug form carries the evidence line, the clipboard
---    the redacted report.
--- 3. Closing the window, by its button or its close box, during the run
---    cancels it: the session closes it as interrupted.
--- 4. PURE Lua: the host supplies the native window and the side effects.
--- ==============================================================================

local FieldReport = require("diagnostics.engine.field_check.field_report")

local M = {}

--- The actions the page may send.
M.ACTIONS = { cancel = true, close = true, open_folder = true, copy = true, issue = true }





-- ================================
-- ================================
-- ======= 1/ Page Messages =======
-- ================================
-- ================================

--- The init message: the steps of the run with their state so far, the steps
--- not run here and the label of the open-folder button. An empty list is left
--- out, so no encoder can turn it into an object.
--- @param run table { steps, not_run } as Session:submit_in_app returns it.
--- @param states table step id → state ("running" or a verdict); absent is pending.
--- @param title_of function step → localized title, or nil for its id.
--- @param open_key string Locale key of the open-folder button.
--- @return table
function M.init_message(run, states, title_of, open_key)
	assert(type(open_key) == "string" and open_key ~= "", "field report window: no open-folder label")
	local steps, not_run = {}, {}
	for _, step in ipairs(run.steps) do
		steps[#steps + 1] = { id = step.id, title = title_of(step) or step.id, state = states[step.id] or "pending" }
	end
	for _, item in ipairs(run.not_run or {}) do
		not_run[#not_run + 1] = { id = item.step, reason = item.reason }
	end
	return { type = "init", steps = #steps > 0 and steps or nil, not_run = #not_run > 0 and not_run or nil,
		open_key = open_key }
end

--- One step's new state.
--- @param id string
--- @param state string "running" or a verdict of the shared protocol.
--- @return table
function M.step_message(id, state)
	return { type = "step", id = id, state = state }
end

--- The end of the run: its verdict, its counts and its folder.
--- @param summary table From FieldReport.summary.
--- @return table
function M.done_message(summary)
	local counts = {}
	for verdict, count in pairs(summary.counts) do counts[verdict] = count end
	return { type = "done", passed = summary.passed == true, interrupted = summary.interrupted == true,
		counts = counts, folder = summary.dir }
end

--- The outcome of an action.
--- @param action string
--- @param ok boolean
--- @return table
function M.action_message(action, ok)
	return { type = "action", action = action, ok = ok == true }
end





-- =================================
-- =================================
-- ======= 2/ The Controller =======
-- =================================
-- =================================

--- Creates the controller of one in-app run's window.
--- @param opts table {
---   open_key = locale key of the open-folder button,
---   title_of = fn(step) → localized title or nil,
---   cancel = fn() → boolean, the session's cancel_in_app,
---   effects = { open_folder = fn(dir, done(ok)), copy = fn(text) → boolean,
---     issue = fn(line, text, done(ok)), the diagnostics runner's report_field_run },
---   logger = the driver's logger, log = its tag }
--- @return table controller
function M.new(opts)
	for _, name in ipairs({ "open_folder", "copy", "issue" }) do
		assert(type(opts.effects[name]) == "function", "field report window: no effect " .. name)
	end
	assert(type(opts.cancel) == "function" and type(opts.title_of) == "function",
		"field report window: needs cancel and title_of")
	local Logger, LOG = opts.logger, opts.log
	local self = { run = nil, states = {}, done = nil, summary = nil, text = nil, window = nil, ready = false }

	--- Pushes one message when the page is up; it is replayed at ready otherwise.
	local function push(message)
		if self.window == nil or not self.ready then return false end
		return self.window.push(message) == true
	end

	--- Answers one action of the page.
	local function answer(action, ok)
		push(M.action_message(action, ok))
	end

	--- Cancels the run while it goes on.
	local function cancel_run()
		if self.done ~= nil or self.run == nil then return false end
		local cancelled = opts.cancel() == true
		if not cancelled then Logger.warn(LOG, "The field report run could not be cancelled: it is not going on.") end
		return cancelled
	end

	--- Records the run the session admitted.
	--- @param run table
	function self.attach(run)
		assert(self.run == nil, "field report window: a run is already attached")
		self.run = run
	end

	--- Gives the controller its native window: { push = fn(message) → boolean, close = fn() }.
	--- @param window table
	function self.bind(window)
		assert(self.window == nil, "field report window: a window is already bound")
		self.window = window
	end

	--- The observer's step_started.
	--- @param step table
	function self.started(step)
		self.states[step.id] = "running"
		push(M.step_message(step.id, "running"))
	end

	--- The observer's step_recorded.
	--- @param step_id string
	--- @param verdict string
	function self.recorded(step_id, verdict)
		self.states[step_id] = verdict
		push(M.step_message(step_id, verdict))
	end

	--- The observer's finished, once the summary and its text are built.
	--- @param summary table From FieldReport.summary.
	--- @param text string The complete report.
	function self.finished(summary, text)
		self.summary, self.text = summary, text
		self.done = M.done_message(summary)
		push(self.done)
	end

	--- The page loaded: brings it up to date.
	function self.on_ready()
		if self.run == nil then return end
		self.ready = true
		push(M.init_message(self.run, self.states, opts.title_of, opts.open_key))
		if self.done ~= nil then push(self.done) end
	end

	--- The native window closed by its close box (or the host closed it).
	function self.on_closed()
		if self.window == nil then return end
		self.window, self.ready = nil, false
		if cancel_run() then Logger.info(LOG, "The field report window closed during the run, which is cancelled.") end
		Logger.info(LOG, "Field report window closed.")
	end

	local ACTIONS = {}

	function ACTIONS.cancel()
		cancel_run()
	end

	function ACTIONS.close()
		local window = self.window
		self.on_closed()
		if window ~= nil then window.close() end
	end

	function ACTIONS.open_folder()
		local dir = self.summary and self.summary.dir
		assert(type(dir) == "string" and dir ~= "", "the run has no results folder yet")
		opts.effects.open_folder(dir, function(ok) answer("open_folder", ok) end)
	end

	function ACTIONS.copy()
		assert(self.text ~= nil, "the run has no report yet")
		local ok = opts.effects.copy(self.text) == true
		Logger.info(LOG, "Field report copy %s.", ok and "done" or "refused")
		answer("copy", ok)
	end

	function ACTIONS.issue()
		assert(self.text ~= nil, "the run has no report yet")
		opts.effects.issue(FieldReport.format_log_line(self.summary), self.text, function(ok)
			if ok then Logger.success(LOG, "Field report issue form opened.")
			else Logger.error(LOG, "The field report issue form could not be opened.") end
			answer("issue", ok)
		end)
	end

	--- One action of the page; an unknown one is refused, a failure answered.
	--- @param name any
	function self.on_action(name)
		if type(name) ~= "string" or not M.ACTIONS[name] then
			Logger.warn(LOG, "Refused a field report window message that is not one of its actions.")
			return
		end
		Logger.info(LOG, "Field report window action: %s.", name)
		local ok, err = pcall(ACTIONS[name])
		if not ok then
			Logger.error(LOG, "The field report window action '%s' failed: %s", name, tostring(err))
			answer(name, false)
		end
	end

	return self
end

return M
