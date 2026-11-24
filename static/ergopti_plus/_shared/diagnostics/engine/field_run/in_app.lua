--- _shared/diagnostics/engine/field_run/in_app.lua

--- ==============================================================================
--- MODULE: In-App Field Run (Shared)
--- DESCRIPTION:
--- What the macOS and Linux field run sessions (diagnostics/engine/field_run/field_run.lua)
--- share for Débogage's « Lancer le field report »: which steps an in-app run
--- takes and why it leaves the others out, its request identifier, the
--- admission of the run, and the observer the menu watches it through.
---
--- FEATURES & RATIONALE:
--- 1. An in-app run takes the field check steps only: a guided step needs a
---    person, a timed reload ends the driver that shows the run, and the
---    other kinds (AI downloads, the diagnostics collection, the signed
---    install) are the collector's. Each is listed back with its reason.
--- 2. The run is the session's own: the caller's begin() writes the same
---    accepted, result and done files as a collector's request.
--- 3. An observer that raises is logged and never stops the run.
--- ==============================================================================

local M = {}

--- The request id prefix of an in-app run, set apart from a collector's: the
--- shared protocol's in_app_prefix, which tools/test/test-field-run-protocol.cjs pins it to.
M.PREFIX = "app-"

--- Why a step of each kind is left out of an in-app run.
M.NOT_RUN = { guided = "needs_person", reload = "needs_collector" }

--- The reason of any other step left out (AI downloads, the diagnostics
--- collection, a step that needs the signed install).
M.NOT_RUN_DEFAULT = "needs_collector"

--- Splits the declared steps into the in-app run and the steps left out.
--- @param steps table The session's declared steps, in order.
--- @return table run, table not_run { {step, reason} }
function M.select(steps)
	local run, not_run = {}, {}
	for _, step in ipairs(steps) do
		if step.kind == "field_check" and not step.signed_app then
			run[#run + 1] = step
		else
			not_run[#not_run + 1] = { step = step.id, reason = M.NOT_RUN[step.kind] or M.NOT_RUN_DEFAULT }
		end
	end
	return run, not_run
end

--- Admits and starts one in-app run on a session.
--- @param session table { active, run, pending, spec, ports, results_dir(), begin(request, dir, observer) }.
--- @param observer table The run's observer.
--- @param opts table { busy = boolean (another owner holds the driver), valid_id = fn(id) -> boolean, log = fn(id) }.
--- @return table|nil run { request_id, dir, steps, not_run }, string|nil reason
function M.submit(session, observer, opts)
	if not session.active then return nil, "inactive" end
	if session.run or session.pending or opts.busy then return nil, "busy" end
	local steps, not_run = M.select(session.spec.steps)
	local request_id = M.PREFIX .. session.ports.iso_now():gsub("[^%w]", "")
	assert(opts.valid_id(request_id), "field run: the in-app request id breaks the shared rule")
	local dir = session:results_dir(request_id)
	if session.ports.exists(dir) then return nil, "duplicate_request" end
	if not session.ports.make_dir(dir) then return nil, "failed" end
	opts.log(request_id)
	session:begin({ request_id = request_id, steps = steps, deadline_seconds = session.spec.deadline_seconds.default },
		dir, observer)
	return { request_id = request_id, dir = dir, steps = steps, not_run = not_run }
end

--- Tells a run's observer about one event.
--- @param run table|nil The run.
--- @param event string "step_started", "step_recorded" or "finished".
--- @param on_error function fn(event, err) when the observer raised.
function M.notify(run, event, on_error, ...)
	local observer = run and run.observer
	if observer == nil or type(observer[event]) ~= "function" then return end
	local ok, err = pcall(observer[event], ...)
	if not ok then on_error(event, err) end
end

--- Gives a driver's Session class the in-app methods, so both drivers share
--- their one body: Session:submit_in_app(observer), Session:cancel_in_app() and
--- Session:notify(run, event, ...).
--- @param Session table The driver's session class.
--- @param opts table { busy = fn() -> boolean (another owner holds the driver),
---   valid_id = fn(session, id) -> boolean, cancel = fn(session, run) closing the run as
---   interrupted, logger = the driver's logger, log = its tag }.
function M.install(Session, opts)
	--- Runs the session's field check steps in-process for the menu's « Lancer
	--- le field report »: no request file, the same results; the steps left out
	--- are listed back with their reason.
	function Session:submit_in_app(observer)
		return M.submit(self, observer, {
			busy = opts.busy(),
			valid_id = function(id) return opts.valid_id(self, id) end,
			log = function(id) opts.logger.info(opts.log, "In-app field run %s requested from the menu.", id) end,
		})
	end

	--- Cancels the in-app run the person stopped: the driver closes it as
	--- interrupted, which tells the observer once.
	--- @return boolean cancelled False when no in-app run is going on.
	function Session:cancel_in_app()
		local run = self.run
		if run == nil or run.observer == nil or run.abandoned then return false end
		opts.cancel(self, run)
		opts.logger.info(opts.log, "In-app field run %s cancelled by the person.", run.request.request_id)
		return true
	end

	--- Tells the in-app run's observer about one event.
	function Session:notify(run, event, ...)
		M.notify(run, event, function(name, err)
			opts.logger.error(opts.log, "The field run observer raised on %s: %s", name, tostring(err))
		end, ...)
	end
end

return M
