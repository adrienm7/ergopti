--- infra/field_run.lua

--- ==============================================================================
--- MODULE: Developer Field Run
--- DESCRIPTION:
--- Lets tools/dev/collect-macos-field-report.sh ask a developer ErgoptiPlus.app
--- to run, in one go, every Debug field check, the diagnostics collection and
--- the AI download flows, and to write one JSON result per step. The contract
--- (folder, file names, steps, verdicts, deadlines) is data/field_run.json.
---
--- FEATURES & RATIONALE:
--- 1. Developer source mode only. M.start() refuses without the clone root
---    that only a developer launcher exports (infra/dev_source.lua); a packaged
---    runtime never receives it, so a release build never watches anything.
--- 2. A request file in <clone>/build/field-run, noticed by a folder watcher.
---    The work runs on a later timer, never inside the watcher callback, and a
---    request is consumed before it runs so it never runs twice.
--- 3. One result per step: verdict, closed codes, timings, the step's own
---    report and the log lines written while it ran. A step is settled once,
---    by its runner or by its deadline, whichever comes first; a late answer
---    is logged and dropped.
--- 4. Nothing faked. A step that needs a person (typing, a permission prompt)
---    is reported with that verdict and its reason and is not run.
--- 5. The user's configuration is snapshot before the first step and compared
---    after the last; anything a step changed is put back and named in the
---    config_guard result, which then fails.
--- 6. A run cut short by a reload is closed at the next start: its done file
---    says interrupted, so the collector never waits for a run that is gone.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local Json = require("json")
local Report = require("field_check_report")
local ModelCatalogue = require("llm.model_catalogue")

local LOG = "field_run"

local REQUEST_KEYS = { schema = true, request_id = true, steps = true, deadline_seconds = true }
local REQUEST_ID_CLASS = "^[%w_%-]+$"

-- The request word that selects every declared step.
M.ALL_STEPS = "all"

local _session = nil





-- ==============================
-- ==============================
-- ======= 1/ Declaration =======
-- ==============================
-- ==============================

local function is_integer(value)
	return type(value) == "number" and value == value and value % 1 == 0
end

local function name_set(list, where)
	if type(list) ~= "table" or #list == 0 then error("field run: " .. where .. " must be a nonempty list", 3) end
	local set = {}
	for _, item in ipairs(list) do
		if type(item) ~= "string" or not item:match("^[%w_]+$") or set[item] then
			error("field run: " .. where .. " holds an invalid or duplicate name", 3)
		end
		set[item] = true
	end
	return set
end

--- Validates the decoded declaration; a malformed one stops the caller.
--- @param spec table Decoded data/field_run.json.
--- @return table spec The same table, with verdict_set, reason_set and step_by_id added.
function M.validate(spec)
	if type(spec) ~= "table" or spec.schema ~= 1 then error("field run: unsupported declaration", 2) end
	if type(spec.folder) ~= "string" or not spec.folder:match("^[%w_%-/]+$") or spec.folder:sub(1, 1) == "/" then
		error("field run: folder must be a relative plain path", 2)
	end
	for _, key in ipairs({ "ready", "request", "refused", "running", "results", "accepted", "done" }) do
		local name = type(spec.files) == "table" and spec.files[key] or nil
		if type(name) ~= "string" or not name:match("^[%w_.]+$") then
			error("field run: files." .. key .. " must be a plain file name", 2)
		end
	end
	if not is_integer(spec.max_request_bytes) or spec.max_request_bytes < 128 then
		error("field run: max_request_bytes must be an integer of at least 128", 2)
	end
	-- Lua patterns have no bounded repetition: the class is enforced here and
	-- the length bound is read from the declaration, its single source.
	local id_max = type(spec.request_id_pattern) == "string"
		and spec.request_id_pattern:match("^%^%[A%-Za%-z0%-9_%-%]{1,(%d+)}%$$")
	if not id_max then
		error("field run: request_id_pattern differs from the policy this module enforces", 2)
	end
	spec.request_id_max = tonumber(id_max)
	local deadline = spec.deadline_seconds
	if type(deadline) ~= "table" or not is_integer(deadline.min) or not is_integer(deadline.max)
		or not is_integer(deadline.default) or deadline.min < 1 or deadline.min > deadline.default
		or deadline.default > deadline.max then
		error("field run: deadline_seconds needs min <= default <= max", 2)
	end
	if not is_integer(spec.log_window_max_lines) or spec.log_window_max_lines < 1 then
		error("field run: log_window_max_lines must be a positive integer", 2)
	end
	spec.verdict_set = name_set(spec.verdicts, "verdicts")
	for _, verdict in ipairs({ "pass", "fail", "skip", "timeout", "needs_person", "needs_typing" }) do
		if not spec.verdict_set[verdict] then error("field run: verdict " .. verdict .. " is not declared", 2) end
	end
	spec.reason_set = name_set(spec.reasons, "reasons")
	if type(spec.steps) ~= "table" or #spec.steps == 0 then error("field run: steps must be a nonempty list", 2) end
	spec.step_by_id = {}
	for _, step in ipairs(spec.steps) do
		if type(step) ~= "table" or type(step.id) ~= "string" or not step.id:match("^[%w_]+$")
			or spec.step_by_id[step.id] or step.id == M.ALL_STEPS then
			error("field run: a step has an invalid or duplicate id", 2)
		end
		if step.kind ~= "field_check" and step.kind ~= "diagnostics" and step.kind ~= "ai" then
			error("field run: step " .. step.id .. " has an unknown kind", 2)
		end
		if step.kind == "field_check" and type(step.check) ~= "string" then
			error("field run: field check step " .. step.id .. " names no check", 2)
		end
		if not is_integer(step.deadline_seconds) or step.deadline_seconds < 1 then
			error("field run: step " .. step.id .. " needs a positive deadline", 2)
		end
		if step.person ~= nil and (not spec.verdict_set[step.person] or type(step.reason) ~= "string") then
			error("field run: step " .. step.id .. " names an unknown person verdict or no reason", 2)
		end
		spec.step_by_id[step.id] = step
	end
	if type(spec.guard_step) ~= "string" or spec.step_by_id[spec.guard_step] then
		error("field run: guard_step must name a step outside the requestable list", 2)
	end
	return spec
end





-- ===========================
-- ===========================
-- ======= 2/ Requests =======
-- ===========================
-- ===========================

local function is_request_id(spec, value)
	return type(value) == "string" and #value >= 1 and #value <= spec.request_id_max
		and value:match(REQUEST_ID_CLASS) ~= nil
end

--- Admits one request text.
--- @param spec table Validated declaration.
--- @param text any Raw request bytes.
--- @return table|nil request { request_id, steps = { step declarations }, deadline_seconds }
--- @return string|nil reason A declared refusal reason.
--- @return string|nil echoed_id The request's own valid identifier, when it had one.
function M.parse_request(spec, text)
	if type(text) ~= "string" or #text == 0 or #text > spec.max_request_bytes then return nil, "malformed" end
	local ok, request = pcall(Json.decode, text)
	if not ok or type(request) ~= "table" then return nil, "malformed" end
	local echoed = is_request_id(spec, request.request_id) and request.request_id or nil
	for key in pairs(request) do
		if not REQUEST_KEYS[key] then return nil, "malformed", echoed end
	end
	if request.schema ~= spec.schema or not echoed or type(request.steps) ~= "table" or #request.steps == 0 then
		return nil, "malformed", echoed
	end
	local deadline = request.deadline_seconds
	if deadline == nil then deadline = spec.deadline_seconds.default end
	if not is_integer(deadline) or deadline < spec.deadline_seconds.min or deadline > spec.deadline_seconds.max then
		return nil, "bad_deadline", echoed
	end
	local names, seen = {}, {}
	for _, name in ipairs(request.steps) do
		if type(name) ~= "string" or seen[name] then return nil, "malformed", echoed end
		seen[name] = true
		names[#names + 1] = name
	end
	local steps = {}
	if #names == 1 and names[1] == M.ALL_STEPS then
		for _, step in ipairs(spec.steps) do steps[#steps + 1] = step end
	else
		-- Declaration order, whatever order the request lists them in
		for _, name in ipairs(names) do
			if not spec.step_by_id[name] then return nil, "unknown_step", echoed end
		end
		for _, step in ipairs(spec.steps) do
			if seen[step.id] then steps[#steps + 1] = step end
		end
	end
	return { request_id = echoed, steps = steps, deadline_seconds = deadline }
end





-- ===============================
-- ===============================
-- ======= 3/ Result model =======
-- ===============================
-- ===============================

--- The log lines written between two ring snapshots, oldest first.
--- The ring holds the newest lines only, so the window is found by the longest
--- suffix of `before` that starts `after`; without one, more lines were written
--- than the ring holds and the whole `after` is returned as truncated.
--- @param before table Ring snapshot at the step's start.
--- @param after table Ring snapshot at its end.
--- @param max integer Most lines kept (the newest).
--- @return table lines
--- @return boolean truncated
function M.log_window(before, after, max)
	before, after = before or {}, after or {}
	local start, truncated = 1, true
	if #before == 0 then
		truncated = false
	else
		for overlap = math.min(#before, #after), 1, -1 do
			local offset, same = #before - overlap, true
			for index = 1, overlap do
				if after[index] ~= before[offset + index] then
					same = false
					break
				end
			end
			if same then
				start, truncated = overlap + 1, false
				break
			end
		end
	end
	local lines = {}
	for index = math.max(start, #after - max + 1), #after do lines[#lines + 1] = after[index] end
	if #after - start + 1 > max then truncated = true end
	return lines, truncated
end

--- Keeps a code inside the evidence grammar of the field checks.
--- @param code any Candidate code.
--- @return string|nil
local function safe_code(code)
	return Report.sanitize_value(code)
end

--- The smallest catalogue model a backend can download, for the AI flows.
--- Ollama needs a library tag (the only form its registry pull takes); MLX
--- takes the display name, which the models manager maps to its repository.
--- @param catalogue table Decoded _shared/modules/llm/models.json.
--- @param backend string "ollama" or "mlx".
--- @return table|nil model { name, runtime_name, download_gb }
function M.smallest_model(catalogue, backend)
	local best = nil
	for _, provider in ipairs(type(catalogue) == "table" and catalogue or {}) do
		for _, family in ipairs(type(provider.families) == "table" and provider.families or {}) do
			for _, model in ipairs(type(family.models) == "table" and family.models or {}) do
				local runtime = ModelCatalogue.runtime_name(model, backend)
				local url = type(model.urls) == "table" and model.urls[backend] or nil
				local sizes = type(model.hardware_requirements) == "table"
					and model.hardware_requirements[backend] or nil
				local size = type(sizes) == "table" and tonumber(sizes.download_gb) or nil
				local pullable = backend ~= "ollama"
					or (type(url) == "string" and url:match("^https://ollama%.com/library/") ~= nil)
				if runtime and size and size > 0 and pullable and type(model.name) == "string" then
					if best == nil or size < best.download_gb
						or (size == best.download_gb and model.name < best.name) then
						best = { name = model.name, runtime_name = runtime, download_gb = size }
					end
				end
			end
		end
	end
	return best
end





-- ==========================
-- ==========================
-- ======= 4/ Session =======
-- ==========================
-- ==========================

local Session = {}
Session.__index = Session

--- Creates one session; it publishes nothing until start().
--- @param opts table { spec, folder, pid, ports }
--- @return table session
function M.new(opts)
	assert(type(opts) == "table" and type(opts.spec) == "table", "field run needs its declaration")
	assert(type(opts.folder) == "string" and opts.folder:sub(1, 1) == "/", "field run needs an absolute folder")
	assert(type(opts.pid) == "number" and opts.pid > 0, "field run needs this process id")
	assert(type(opts.ports) == "table", "field run needs its ports")
	return setmetatable({ spec = opts.spec, folder = opts.folder, pid = opts.pid, ports = opts.ports,
		started = false, active = false, watcher = nil, pending = nil, run = nil }, Session)
end

function Session:path(kind)
	return self.folder .. "/" .. self.spec.files[kind]
end

function Session:results_dir(request_id)
	return self:path("results") .. "/" .. request_id
end

--- Writes one JSON document; a failure is logged and reported to the caller.
function Session:publish(path, document)
	local text = Json.encode(document)
	local ok, written = pcall(self.ports.write, path, text .. "\n")
	if not ok or written ~= true then
		Logger.error(LOG, "Field run file %s could not be written: %s.", path, tostring(written))
		return false
	end
	return true
end

function Session:refuse(request_id, reason)
	Logger.warn(LOG, "Field run request %s refused: %s.", tostring(request_id), reason)
	-- A request without a valid identifier is refused without one
	self:publish(self:path("refused"), { schema = self.spec.schema, request_id = request_id, reason = reason })
end

--- Closes a run a reload cut short, so its collector stops waiting for it.
function Session:close_interrupted()
	local text, status = self.ports.read(self:path("running"))
	if status == "absent" then return end
	local ok, running = pcall(Json.decode, text or "")
	local request_id = ok and type(running) == "table" and is_request_id(self.spec, running.request_id) and running.request_id or nil
	if request_id then
		local done = self:results_dir(request_id) .. "/" .. self.spec.files.done
		if not self.ports.exists(done) then
			self:publish(done, { schema = self.spec.schema, request_id = request_id, pid = self.pid,
				interrupted = true, finished_at = self.ports.iso_now(), verdicts = {}, order = Json.array({}) })
			Logger.warn(LOG, "Field run %s was cut short by a reload; closed as interrupted.", request_id)
		end
	else
		Logger.warn(LOG, "An unreadable running marker was left by an earlier field run; removed.")
	end
	self.ports.remove(self:path("running"))
end

--- Prepares the folder, closes an interrupted run, then watches for requests.
function Session:start()
	if self.started then error("the field run session cannot be started twice", 2) end
	self.started = true
	if not self.ports.make_dir(self:path("results")) then error("the field run folder could not be created: " .. self.folder, 0) end
	self:close_interrupted()
	-- A request left from an earlier session was written for a driver that is gone
	if self.ports.exists(self:path("request")) then
		Logger.warn(LOG, "A stale field run request was left by an earlier session; removed.")
		self.ports.remove(self:path("request"))
	end
	local request_name = self.spec.files.request
	local watcher = self.ports.watch(self.folder, function(paths)
		if not self.active or self.pending then return end
		for _, changed in ipairs(type(paths) == "table" and paths or {}) do
			if type(changed) == "string" and changed:sub(-#request_name - 1) == "/" .. request_name then
				self:queue_request()
				return
			end
		end
	end)
	if not watcher then error("the field run folder watcher was not constructed", 0) end
	self.watcher = watcher
	if watcher:start() ~= watcher then error("the field run folder watcher did not start", 0) end
	self.active = true
	local ids = {}
	for _, step in ipairs(self.spec.steps) do ids[#ids + 1] = step.id end
	-- Published last: it is the collector's readiness receipt
	if not self:publish(self:path("ready"), { schema = self.spec.schema, driver = "macos", pid = self.pid,
		steps = Json.array(ids) }) then
		error("the field run readiness file could not be written", 0)
	end
end

--- Defers one request out of the watcher callback.
function Session:queue_request()
	self.pending = self.ports.after(0, function()
		self.pending = nil
		if self.active then self:handle() end
	end)
end

--- Stops watching and withdraws the readiness file; a running run is abandoned
--- and closed as interrupted by the next start.
--- @return boolean stopped
function Session:stop()
	self.active = false
	if self.pending then pcall(self.ports.cancel, self.pending); self.pending = nil end
	if self.run then self.run.abandoned = true; self.run.cancel_timers() end
	local stopped = true
	if self.watcher then
		local ok, result = pcall(function() return self.watcher:stop() end)
		if not ok or result ~= self.watcher then
			stopped = false
			Logger.error(LOG, "The field run folder watcher could not stop: %s.", tostring(result))
		else
			self.watcher = nil
		end
	end
	self.ports.remove(self:path("ready"))
	return stopped
end

--- Consumes and admits one request, then starts its run.
--- @return boolean started
function Session:handle()
	local request_path = self:path("request")
	if not self.ports.exists(request_path) then return false end
	local text = self.ports.read(request_path)
	if not self.ports.remove(request_path) then
		self:refuse(nil, "failed")
		return false
	end
	local request, reason, echoed = M.parse_request(self.spec, text)
	if not request then
		self:refuse(echoed, reason)
		return false
	end
	if self.run then
		self:refuse(request.request_id, "busy")
		return false
	end
	local dir = self:results_dir(request.request_id)
	if self.ports.exists(dir) then
		self:refuse(request.request_id, "duplicate_request")
		return false
	end
	if not self.ports.make_dir(dir) then
		self:refuse(request.request_id, "failed")
		return false
	end
	return self:begin(request, dir)
end





-- ======================
-- ======================
-- ======= 5/ Run =======
-- ======================
-- ======================

--- Runs the admitted steps in order, then the configuration guard.
--- @param request table From M.parse_request().
--- @param dir string Results folder of this request.
--- @return boolean started
function Session:begin(request, dir)
	local spec, ports = self.spec, self.ports
	local run = { request = request, dir = dir, verdicts = {}, order = {}, timers = {}, abandoned = false,
		started_ms = ports.now_ms(), started_at = ports.iso_now() }
	run.deadline_ms = run.started_ms + request.deadline_seconds * 1000
	function run.cancel_timers()
		for handle in pairs(run.timers) do pcall(ports.cancel, handle) end
		run.timers = {}
	end
	self.run = run
	local ids = {}
	for _, step in ipairs(request.steps) do ids[#ids + 1] = step.id end
	self:publish(self:path("running"), { schema = spec.schema, request_id = request.request_id })
	self:publish(dir .. "/" .. spec.files.accepted, { schema = spec.schema, request_id = request.request_id,
		pid = self.pid, steps = Json.array(ids), deadline_seconds = request.deadline_seconds,
		started_at = run.started_at })
	Logger.start(LOG, "Field run %s started: %d step(s) within %d s.", request.request_id, #ids,
		request.deadline_seconds)

	local ok, snapshot = pcall(ports.config_snapshot)
	if not ok or snapshot == nil then
		Logger.error(LOG, "The configuration could not be snapshot; no step runs: %s.", tostring(snapshot))
		for index, step in ipairs(request.steps) do
			self:record(index, step, { verdict = "skip", codes = { "config_unprotected" }, elapsed_ms = 0 })
		end
		self:record(#request.steps + 1, { id = spec.guard_step, kind = "guard" },
			{ verdict = "fail", codes = { "snapshot_failed" }, elapsed_ms = 0 })
		self:finish()
		return true
	end
	run.snapshot = snapshot

	local function next_step(index)
		if run.abandoned then return end
		local step = request.steps[index]
		if step == nil then return self:guard(index) end
		self:run_step(index, step, function()
			-- A fresh turn between steps: a runner that settles synchronously
			-- must not grow the stack by one frame per step.
			local handle
			handle = ports.after(0, function()
				if handle then run.timers[handle] = nil end
				next_step(index + 1)
			end)
			if handle then run.timers[handle] = true end
		end)
	end
	next_step(1)
	return true
end

--- Runs one step under its deadline and records it once.
function Session:run_step(index, step, continue)
	local spec, ports, run = self.spec, self.ports, self.run
	local left_ms = run.deadline_ms - ports.now_ms()
	if step.person then
		self:record(index, step, { verdict = step.person, codes = { step.reason }, elapsed_ms = 0 })
		return continue()
	end
	if left_ms <= 0 then
		self:record(index, step, { verdict = "skip", codes = { "global_deadline" }, elapsed_ms = 0 })
		return continue()
	end
	local deadline_ms = math.min(step.deadline_seconds * 1000, left_ms)
	local ring_before = ports.log_ring()
	local started_ms, started_at = ports.now_ms(), ports.iso_now()
	local settled, timer = false, nil
	Logger.info(LOG, "Field run step %d/%d '%s' started.", index, #run.request.steps, step.id)
	local function settle(verdict, codes, report)
		if settled then
			Logger.warn(LOG, "Field run step '%s' answered after it was settled; answer dropped.", step.id)
			return
		end
		settled = true
		if timer then pcall(ports.cancel, timer); run.timers[timer] = nil; timer = nil end
		if run.abandoned then return end
		if not spec.verdict_set[verdict] then
			Logger.error(LOG, "Field run step '%s' gave an undeclared verdict %s.", step.id, tostring(verdict))
			codes = { "undeclared_verdict" }
			verdict = "fail"
		end
		local lines, truncated = M.log_window(ring_before, ports.log_ring(), spec.log_window_max_lines)
		self:record(index, step, { verdict = verdict, codes = codes, report = report, started_at = started_at,
			elapsed_ms = ports.now_ms() - started_ms, deadline_ms = deadline_ms,
			log_window = { lines = Json.array(lines), truncated = truncated } })
		continue()
	end
	timer = ports.after(deadline_ms / 1000, function()
		if timer then run.timers[timer] = nil end
		timer = nil
		settle("timeout", { "deadline_" .. math.floor(deadline_ms / 1000) .. "s" })
	end)
	if timer then run.timers[timer] = true end
	local ran, err = pcall(ports.run_step, step, function(verdict, codes, report)
		settle(verdict, codes, report)
	end)
	if not ran then
		Logger.error(LOG, "Field run step '%s' raised: %s", step.id, tostring(err))
		settle("fail", { "raised" })
	end
end

--- Writes one step result.
function Session:record(index, step, fields)
	local run, spec = self.run, self.spec
	local codes = {}
	for _, code in ipairs(type(fields.codes) == "table" and fields.codes or {}) do
		codes[#codes + 1] = safe_code(code) or "empty"
	end
	run.verdicts[step.id] = fields.verdict
	run.order[#run.order + 1] = step.id
	local document = {
		schema = spec.schema,
		request_id = run.request.request_id,
		index = index,
		step = step.id,
		kind = step.kind,
		verdict = fields.verdict,
		codes = Json.array(codes),
		started_at = fields.started_at or self.ports.iso_now(),
		finished_at = self.ports.iso_now(),
		elapsed_ms = math.floor(fields.elapsed_ms or 0),
		deadline_ms = math.floor(fields.deadline_ms or 0),
		report = type(fields.report) == "table" and fields.report or {},
		log_window = fields.log_window or { lines = Json.array({}), truncated = false },
	}
	self:publish(string.format("%s/%02d_%s.json", run.dir, index, step.id), document)
	Logger.evidence(LOG, "Field run step result: step=%s verdict=%s codes=%s", step.id, fields.verdict,
		#codes > 0 and table.concat(codes, ",") or "none")
end

--- Compares the configuration with its snapshot and restores what changed.
function Session:guard(index)
	local spec, run = self.spec, self.run
	local step = { id = spec.guard_step, kind = "guard" }
	local started_ms = self.ports.now_ms()
	local ok, outcome = pcall(self.ports.config_restore, run.snapshot)
	local verdict, codes = "pass", {}
	if not ok or type(outcome) ~= "table" then
		Logger.error(LOG, "The configuration could not be compared with its snapshot: %s.", tostring(outcome))
		verdict, codes = "fail", { "restore_raised" }
	else
		for _, name in ipairs(outcome.restored or {}) do codes[#codes + 1] = "restored_" .. name end
		for _, name in ipairs(outcome.failed or {}) do codes[#codes + 1] = "restore_failed_" .. name end
		if #codes > 0 then
			verdict = "fail"
			Logger.error(LOG, "A field run step changed the configuration: %s.", table.concat(codes, ", "))
		end
	end
	self:record(index, step, { verdict = verdict, codes = codes, elapsed_ms = self.ports.now_ms() - started_ms })
	return self:finish()
end

--- Publishes the done marker and frees the session for the next request.
--- @return boolean finished
function Session:finish()
	local run, spec = self.run, self.spec
	local counts = {}
	for _, verdict in pairs(run.verdicts) do counts[verdict] = (counts[verdict] or 0) + 1 end
	local written = self:publish(run.dir .. "/" .. spec.files.done, {
		schema = spec.schema, request_id = run.request.request_id, pid = self.pid, interrupted = false,
		started_at = run.started_at, finished_at = self.ports.iso_now(),
		elapsed_ms = math.floor(self.ports.now_ms() - run.started_ms),
		verdicts = run.verdicts, counts = counts, order = Json.array(run.order),
	})
	self.ports.remove(self:path("running"))
	self.run = nil
	if written then
		Logger.success(LOG, "Field run %s finished.", run.request.request_id)
	else
		Logger.error(LOG, "Field run %s finished, but its done marker was not written.", run.request.request_id)
	end
	return written
end

M.Session = Session





-- ========================
-- ========================
-- ======= 6/ Owner =======
-- ========================
-- ========================

--- Starts the field run watcher of a developer runtime.
--- @param opts table { root = clone root|nil, pid, ports?, declaration? }
--- @return boolean started False for an ordinary runtime or a refused start.
function M.start(opts)
	if _session ~= nil then error("the field run already has an owner", 2) end
	if type(opts) ~= "table" or type(opts.root) ~= "string" or opts.root:sub(1, 1) ~= "/" then
		Logger.info(LOG, "Field run unavailable: this runtime is not in developer source mode.")
		return false
	end
	Logger.start(LOG, "Starting the developer field run watcher…")
	local ok, err = pcall(function()
		local ports = opts.ports or require("adapters.field_run_ports").new(opts.root)
		local spec = M.validate(Json.decode(assert(ports.read_declaration(), "the declaration could not be read")))
		local session = M.new({ spec = spec, folder = opts.root .. "/" .. spec.folder, pid = opts.pid, ports = ports })
		_session = session
		session:start()
	end)
	if not ok then
		if _session then _session:stop(); _session = nil end
		Logger.error(LOG, "The developer field run watcher could not start: %s.", tostring(err))
		return false
	end
	Logger.success(LOG, "Developer field run watcher ready.")
	return true
end

--- Retires the field run watcher.
--- @return boolean stopped
function M.stop()
	if _session == nil then return true end
	local stopped = _session:stop()
	if stopped then
		_session = nil
		Logger.info(LOG, "Developer field run watcher retired.")
	end
	return stopped
end

--- Forgets the owner; tests only.
function M._reset()
	_session = nil
end

return M
