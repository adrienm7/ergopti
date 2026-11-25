--- _shared/shortcuts/engine/workflows/owner.lua

--- ==============================================================================
--- MODULE: User Workflow Owner (Shared)
--- DESCRIPTION:
--- The one object a macOS or Linux driver holds for user workflows: it reads
--- the store, runs a workflow by id for the run_workflow action (a shortcut
--- slot, a gesture, a tap-hold key, a hotstring), stops every run on Escape
--- and tells each failure in a translated notice naming the step.
---
--- FEATURES & RATIONALE:
--- 1. Explicit initialization ownership: new() builds it once with every port;
---    the driver keeps the instance and tears it down with stop().
--- 2. Never silent: an unreadable workflows.json, a missing workflow, a step
---    that fails or times out each end in a notice and a log line.
--- 3. The editor's test run goes through the same runner (start with
---    on_step), so what it highlights is what a shortcut would run.
--- ==============================================================================

local Logger = require("core.logger.engine.shim")
local Store = require("shortcuts.engine.workflows.store")
local Effects = require("shortcuts.engine.workflows.effects")
local Runner = require("shortcuts.engine.workflows.runner")
local Model = require("shortcuts.engine.workflows.model")

local M = {}

local LOG = "workflows"

--- Replaces {1}, {2}… in one pass: an inserted name or reason may itself hold
--- a % or a {n}, which must stay text.
--- @param text string
--- @param values table Array of strings.
--- @return string
function M.fill(text, values)
	return (text:gsub("{(%d+)}", function(index)
		local value = values[tonumber(index)]
		if value == nil then return nil end
		return tostring(value)
	end))
end

--- The step path as a person reads it: 3.then.2 -> 3 › ✓ 2, 3.else.1 -> 3 › ✗ 1.
--- @param path string|nil
--- @return string
function M.readable_path(path)
	if type(path) ~= "string" or path == "" then return "?" end
	return (path:gsub("%.then%.", " › ✓ "):gsub("%.else%.", " › ✗ "):gsub("%.", " › "))
end

--- The store ports of a driver whose file service answers like the shared
--- FileSystem ports: read_with_status(path) -> body, "ok" | "absent" | other,
--- detail. Any status but ok and absent raises: an unreadable file is never an
--- empty list.
--- @param files table {
---   config_path = function(name) -> string,
---   read_with_status = function(path) -> body, status, detail,
---   write = function(path, text) -> written, detail: an atomic replacement,
---   catalogue = decoded steps.json, vocabulary = decoded send_keys.json,
---   wait_max_ms = number }
--- @return table The Store.new ports.
function M.store_ports(files)
	return {
		path = files.config_path,
		read = function(path)
			local body, status, detail = files.read_with_status(path)
			if status == "absent" then return nil end
			if status ~= "ok" then error("workflows: cannot read " .. path .. ": " .. tostring(detail)) end
			return body
		end,
		write = function(path, text)
			local written, detail = files.write(path, text)
			if not written then error("workflows: cannot write " .. path .. ": " .. tostring(detail)) end
		end,
		catalogue = files.catalogue,
		context = { vocabulary = files.vocabulary, timings = { wait_max_ms = files.wait_max_ms } },
	}
end

--- Builds the owner.--- Builds the owner.
--- @param ports table {
---   store = the Store.new ports (path, read, write, catalogue, context),
---   effects = the Effects.new ports,
---   after = function(ms, fn) -> cancel: the runner's timer,
---   translate = function(key) -> string: the active locale,
---   notify = function(text): an error notice to the user,
---   timeouts = table|nil (tests) }
--- @return table owner { run, start, abort_all, is_running, choices, store, stop }
function M.new(ports)
	assert(type(ports) == "table" and type(ports.store) == "table" and type(ports.effects) == "table",
		"a workflow owner needs its store and effect ports")
	assert(type(ports.translate) == "function" and type(ports.notify) == "function"
		and type(ports.after) == "function", "a workflow owner needs translate, notify and after")
	local store = Store.new(ports.store)
	local effects = Effects.new(ports.effects)
	local listeners = {}
	local owner = { store = store }

	local function tell(key, values)
		ports.notify(M.fill(ports.translate(key), values or {}))
	end

	local runner = Runner.new({
		catalogue = ports.store.catalogue,
		timeouts = ports.timeouts,
		after = ports.after,
		perform = effects.perform,
		cancel = effects.cancel,
		approvals = { get = store.approval, set = store.approve },
		on_step = function(workflow, effect)
			local listener = listeners[workflow.id]
			if listener and listener.on_step then listener.on_step(effect) end
		end,
		on_end = function(workflow, outcome)
			local listener = listeners[workflow.id]
			listeners[workflow.id] = nil
			if outcome.op == "failed" then
				tell("workflows.notice.failed", {
					workflow.name, M.readable_path(outcome.path), ports.translate("workflows.step." .. tostring(outcome.kind)),
					ports.translate("workflows.reason." .. tostring(outcome.reason)),
				})
			elseif outcome.op == "aborted" then
				tell("workflows.notice.aborted", { workflow.name })
			end
			if listener and listener.on_end then listener.on_end(outcome) end
		end,
	})

	--- Starts a workflow by id, telling the user why when it cannot.
	--- @param id string
	--- @param listener table|nil { on_step(effect), on_end(outcome) } (the editor's test run).
	--- @return boolean started
	function owner.start(id, listener)
		local workflow, refusal = store.find(id)
		if refusal then
			Logger.error(LOG, "workflows.json is invalid (%s at %s): workflow %s not run.", refusal.reason,
				tostring(refusal.path), tostring(id))
			tell("workflows.notice.file_invalid", { refusal.reason, refusal.path == "" and "/" or refusal.path })
			return false
		end
		if not workflow then
			Logger.warn(LOG, "Workflow %s is assigned but no longer exists.", tostring(id))
			tell("workflows.notice.missing", { id })
			return false
		end
		if runner.is_running(id) then
			Logger.info(LOG, "Workflow %s is already running; this trigger is ignored.", id)
			return false
		end
		listeners[id] = listener
		local started = runner.start(workflow)
		if not started then listeners[id] = nil end
		return started
	end

	--- Test-runs a workflow the editor holds, saved or not: it is checked by
	--- the shared model first, then runs through the same runner.
	--- @param workflow table A workflow decoded with Json.decode_lossless.
	--- @param listener table { on_step(effect), on_end(outcome) }
	--- @return boolean started
	--- @return table|nil refusal { reason, path } when the workflow is invalid.
	function owner.test_run(workflow, listener)
		local result = Model.validate_workflow(workflow, ports.store.catalogue, ports.store.context)
		if not result.ok then return false, { reason = result.reason, path = result.path } end
		if runner.is_running(workflow.id) then return false end
		listeners[workflow.id] = listener
		local started = runner.start(workflow)
		if not started then listeners[workflow.id] = nil end
		return started
	end

	--- The run_workflow action: a decoded parameter { id }.
	--- @param fields table|nil
	--- @return boolean started
	function owner.run(fields)
		if type(fields) ~= "table" or type(fields.id) ~= "string" then
			Logger.warn(LOG, "run_workflow ignored: no valid workflow is stored for the binding.")
			return false
		end
		return owner.start(fields.id)
	end

	--- The decoded steps.json the owner checks with.
	--- @return table
	function owner.catalogue() return ports.store.catalogue end

	--- The check context { vocabulary, timings } of the owner.
	--- @return table
	function owner.context() return ports.store.context end

	--- Stops every running workflow (Escape).
	--- @return integer stopped
	function owner.abort_all() return runner.abort_all() end

	--- @param id string|nil
	--- @return boolean
	function owner.is_running(id) return runner.is_running(id) end

	--- The binding editors' choices { value, label }, or nil and a notice.
	--- @return table|nil
	function owner.choices()
		local choices, refusal = store.choices()
		if not choices then
			tell("workflows.notice.file_invalid", { refusal.reason, refusal.path == "" and "/" or refusal.path })
			return nil
		end
		return choices
	end

	--- Stops every run before the driver releases the owner.
	function owner.stop()
		local stopped = runner.abort_all()
		Logger.info(LOG, "Workflow owner stopped (%d run(s) aborted).", stopped)
	end

	return owner
end

--- A driver's workflow module: one owner, built on first use from the
--- driver's services, with the entry points the action registry, the binding
--- editors, the key hook and the shutdown call.
--- @param spec table {
---   log = string the driver module's log name,
---   default_services = function() -> table the real OS services,
---   options = function(services) -> table the Owner.new options }
--- @return table module { init, run, on_escape, abort_all, choices, stop }
function M.driver_module(spec)
	assert(type(spec) == "table" and type(spec.log) == "string" and type(spec.default_services) == "function"
		and type(spec.options) == "function", "a workflow driver module needs its log, services and options")
	local module = {}
	local owner, given = nil, nil

	--- Builds the owner once; a second call with other services raises.
	--- @param overrides table|nil Replacements of the OS services (tests).
	--- @return table owner
	function module.init(overrides)
		if owner then
			if overrides ~= nil and overrides ~= given then
				error("workflows: the owner is already initialized with other ports", 2)
			end
			return owner
		end
		local services = spec.default_services()
		for key, value in pairs(overrides or {}) do services[key] = value end
		owner = M.new(spec.options(services))
		given = overrides
		Logger.info(spec.log, "Workflow owner initialized.")
		return owner
	end

	--- The run_workflow action: a decoded parameter { id }.
	--- @param fields table|nil
	--- @return boolean started
	function module.run(fields) return module.init().run(fields) end

	--- The owner itself (the editor window's host).
	--- @return table owner
	function module.owner() return module.init() end

	--- Escape while a workflow runs: stops every run.
	--- @return boolean Whether a run was stopped.
	function module.on_escape()
		if not owner or not owner.is_running() then return false end
		return owner.abort_all() > 0
	end

	--- Stops every running workflow (the script pause).
	--- @return integer stopped
	function module.abort_all()
		if not owner then return 0 end
		return owner.abort_all()
	end

	--- The binding editors' choices.
	--- @return table|nil
	function module.choices() return module.init().choices() end

	--- Stops every run and releases the owner (driver shutdown, tests).
	function module.stop()
		if not owner then return end
		owner.stop()
		owner, given = nil, nil
	end

	return module
end

return M
