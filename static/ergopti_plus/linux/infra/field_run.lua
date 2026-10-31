--- infra/field_run.lua

--- ==============================================================================
--- MODULE: Field Run (Linux)
--- DESCRIPTION:
--- Lets tools/dev/collect-linux-field-report.sh ask the running daemon to run
--- its Debug field checks with no window and write one JSON result per step,
--- so a maintainer's field report needs no click. The protocol is the one
--- every driver shares, _shared/data/field_run_protocol.json (macOS was first,
--- macos/infra/field_run.lua): file names, verdicts, refusal reasons, the
--- identifier rules, the folders and the keys each document carries are read
--- from it, never repeated here. data/field_run_steps.json, the Linux steps file
--- the shared declaration names, holds the steps and the deadline bounds.
---
--- FEATURES & RATIONALE:
--- 1. A request file in the declared folder, noticed by an inotify watcher: the
---    clone's build/field-run for a developer run (infra/dev_source.lua), else
---    $XDG_RUNTIME_DIR/ergopti_plus/field-run, a folder only this user can
---    write. The work runs on a later turn, never inside the watcher callback,
---    and a request is consumed before it runs so it never runs twice.
--- 2. One result per step: verdict, closed codes, timings and the check's own
---    privacy-safe report. A step settles once, by its check or by its
---    deadline; a late answer is logged and dropped. Every document is checked
---    against the shared key list before it is written.
--- 3. Nothing faked and nothing asked: the checks run headless
---    (ui/field_check/window.lua run_headless), and a check a person clicked
---    that is still pending makes its step a skip, not a second run.
--- 4. config.toml is compared before and after the run; a change is named in
---    the config_guard result, which then fails.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Json = require("json")
local Report = require("field_check_report")

local LOG = "infra.field_run"
local PRIVATE_MODE = 448 -- 0700
local SCHEMA = 1

-- The files this driver uses; the shared declaration names each of them.
local FILE_KEYS = { "ready", "request", "refused", "running", "results", "accepted", "done" }
-- The request key a collector may add to the shared request document.
local OPTIONAL_REQUEST_KEYS = { deadline_seconds = true }
-- The one step kind the Linux driver runs.
local LINUX_KIND = "field_check"
-- The kind of the configuration guard's result, as macOS writes it.
local GUARD_KIND = "guard"
-- A result file name carries a two-digit index; the guard takes the last one.
local MAX_STEPS = 98

-- The shared declaration, from the shared tree.
M.PROTOCOL_PATH = "data/field_run_protocol.json"

-- The headless runner of each declared check.
M.CHECK_RUNNERS = {
	composer = "ui.field_check.composer_check",
	network = "ui.field_check.network_check",
}





-- ==============================
-- ==============================
-- ======= 1/ Declaration =======
-- ==============================
-- ==============================

local function is_integer(value)
	return type(value) == "number" and value == value and value % 1 == 0
end

local function fail(message) error("field run: " .. message, 3) end

local function name_set(list, where)
	if type(list) ~= "table" or #list == 0 then fail(where .. " must be a nonempty list") end
	local set = {}
	for _, item in ipairs(list) do
		if type(item) ~= "string" or not item:match("^[%w_]+$") or set[item] then
			fail(where .. " holds an invalid or duplicate name")
		end
		set[item] = true
	end
	return set
end

--- Turns a shared `^[class]{1,N}$` rule into a Lua matcher.
--- Lua patterns have no bounded repetition: the class becomes a Lua set and the
--- length bound is kept beside it. Any other shape stops the caller, so a
--- changed rule is never enforced loosely.
--- @return function matcher Answers whether a value follows the rule.
local function bounded_class(rule, where)
	if type(rule) ~= "string" then fail(where .. " is not a rule") end
	local class, max = rule:match("^%^%[([%w_.:+%-]+)%]{1,(%d+)}%$$")
	if not class then fail(where .. " is not a ^[class]{1,N}$ rule this module can enforce") end
	-- A trailing hyphen is literal in the shared rule; Lua needs it escaped.
	local lua = "^[" .. class:gsub("%-$", "%%-") .. "]+$"
	max = tonumber(max)
	return function(value)
		return type(value) == "string" and #value >= 1 and #value <= max and value:match(lua) ~= nil
	end
end

local function validate_folder(folder, where)
	if type(folder) ~= "table" or type(folder.base) ~= "string" or not folder.base:match("^[%u_]+$")
		or type(folder.segments) ~= "table" or #folder.segments == 0 then
		fail(where .. " needs a base variable and segments")
	end
	for _, segment in ipairs(folder.segments) do
		if type(segment) ~= "string" or not segment:match("^[%w_.%-]+$") or segment:match("^%.+$") then
			fail(where .. " segments must be plain names")
		end
	end
end

--- Builds the Linux declaration from the shared protocol and the Linux steps.
--- A malformed or unsupported declaration stops the caller.
--- @param protocol table Decoded _shared/data/field_run_protocol.json.
--- @param linux table Decoded data/field_run_steps.json.
--- @return table spec The protocol's names and rules, the steps, step_by_id and matchers.
function M.declaration(protocol, linux)
	if type(protocol) ~= "table" or protocol.schema ~= SCHEMA then fail("unsupported shared declaration") end
	if type(linux) ~= "table" then fail("the Linux steps file is not an object") end
	local spec = { schema = protocol.schema, files = {}, documents = {}, all_steps = protocol.all_steps }
	for _, key in ipairs(FILE_KEYS) do
		local name = type(protocol.files) == "table" and protocol.files[key] or nil
		if type(name) ~= "string" or not name:match("^[%w_.]+$") then fail("files." .. key .. " must be a plain file name") end
		spec.files[key] = name
	end
	if type(protocol.documents) ~= "table" then fail("documents must list the keys of each file") end
	for kind, keys in pairs(protocol.documents) do spec.documents[kind] = name_set(keys, "documents." .. kind) end
	for _, kind in ipairs({ "ready", "request", "refused", "running", "accepted", "result", "done" }) do
		if not spec.documents[kind] then fail("documents." .. kind .. " is missing") end
	end
	if not is_integer(protocol.max_request_bytes) or protocol.max_request_bytes < 128 then
		fail("max_request_bytes must be an integer of at least 128")
	end
	spec.max_request_bytes = protocol.max_request_bytes
	spec.is_request_id = bounded_class(protocol.request_id_pattern, "request_id_pattern")
	spec.is_step_id = bounded_class(protocol.step_id_pattern, "step_id_pattern")
	spec.is_code = bounded_class(protocol.code_pattern, "code_pattern")
	-- This module names a result <NN>_<step id>.json; the shared rule must say the same.
	if protocol.result_file_pattern ~= "^[0-9]{2}_" .. protocol.step_id_pattern:sub(2, -2) .. "\\.json$" then
		fail("result_file_pattern differs from the <NN>_<step id>.json names this module writes")
	end
	if type(spec.all_steps) ~= "string" or spec.all_steps == "" then fail("all_steps must name the every-step word") end
	spec.verdict_set = name_set(protocol.verdicts, "verdicts")
	for _, verdict in ipairs({ "pass", "fail", "skip", "timeout" }) do
		if not spec.verdict_set[verdict] then fail("verdict " .. verdict .. " is not declared") end
	end
	spec.reason_set = name_set(protocol.reasons, "reasons")
	local kinds = name_set(protocol.step_kinds, "step_kinds")
	if type(protocol.folder) ~= "table" or type(protocol.folder.clone) ~= "string" then fail("folder.clone is missing") end
	spec.clone_folder = protocol.folder.clone
	if spec.clone_folder:match("^/") or spec.clone_folder:match("/$") or spec.clone_folder:find("//", 1, true) then
		fail("folder.clone must be a plain relative path")
	end
	for segment in spec.clone_folder:gmatch("[^/]+") do
		if not segment:match("^[%w_.%-]+$") or segment:match("^%.+$") then fail("folder.clone must be a plain relative path") end
	end
	validate_folder(protocol.folder.linux, "folder.linux")
	spec.installed_folder = protocol.folder.linux
	if type(protocol.steps_file) ~= "table" or type(protocol.steps_file.linux) ~= "string" then
		fail("steps_file.linux is missing")
	end
	spec.steps_file = protocol.steps_file.linux

	local deadline = linux.deadline_seconds
	if type(deadline) ~= "table" or not is_integer(deadline.min) or not is_integer(deadline.max)
		or not is_integer(deadline.default) or deadline.min < 1 or deadline.min > deadline.default
		or deadline.default > deadline.max then
		fail("deadline_seconds needs min <= default <= max")
	end
	spec.deadline_seconds = deadline
	if type(linux.steps) ~= "table" or #linux.steps == 0 or #linux.steps > MAX_STEPS then
		fail("steps must be a list of 1 to " .. MAX_STEPS .. " steps")
	end
	spec.steps, spec.step_by_id = linux.steps, {}
	local bound = 0
	for _, step in ipairs(linux.steps) do
		if type(step) ~= "table" or not spec.is_step_id(step.id) or spec.step_by_id[step.id]
			or step.id == spec.all_steps then
			fail("a step has an invalid or duplicate id")
		end
		if not kinds[step.kind] or step.kind ~= LINUX_KIND or M.CHECK_RUNNERS[step.check] == nil then
			fail("step " .. step.id .. " names no Linux field check")
		end
		if not is_integer(step.deadline_seconds) or step.deadline_seconds < 1 then
			fail("step " .. step.id .. " needs a positive deadline")
		end
		if type(step.proves) ~= "string" or not step.proves:match("%.$") then
			fail("step " .. step.id .. " needs one sentence of what its pass proves")
		end
		bound = bound + step.deadline_seconds
		spec.step_by_id[step.id] = step
	end
	if deadline.default < bound then
		fail("deadline_seconds.default is below the sum of the step deadlines (" .. bound .. " s)")
	end
	if not spec.is_step_id(linux.guard_step) or spec.step_by_id[linux.guard_step] then
		fail("guard_step must name a step outside the requestable list")
	end
	spec.guard_step = linux.guard_step
	return spec
end

--- The Linux steps file, relative to the driver root.
--- @param steps_file any The shared declaration's steps_file.linux, relative to the clone root.
--- @return string relative
function M.steps_relative(steps_file)
	local prefix = require("infra.dev_source").DRIVER_SUBPATH:sub(2) .. "/"
	if type(steps_file) ~= "string" or steps_file:sub(1, #prefix) ~= prefix then
		error("field run: steps_file.linux is not inside " .. prefix, 2)
	end
	return steps_file:sub(#prefix + 1)
end

--- Reads and builds the declaration from the shared tree and the driver tree.
--- @param shared_root string Absolute _shared folder.
--- @param driver_root string Absolute Linux driver folder.
--- @return table spec
function M.load(shared_root, driver_root)
	local function decode(path)
		local handle = io.open(path, "rb")
		if not handle then error("field run: the declaration is unreadable: " .. path, 0) end
		local text = handle:read("*a")
		handle:close()
		local ok, value = pcall(Json.decode, text)
		if not ok then error("field run: the declaration is not JSON: " .. path, 0) end
		return value
	end
	local protocol = decode(shared_root .. "/" .. M.PROTOCOL_PATH)
	local steps_file = type(protocol) == "table" and type(protocol.steps_file) == "table" and protocol.steps_file.linux
	return M.declaration(protocol, decode(driver_root .. "/" .. M.steps_relative(steps_file)))
end

--- The run folder: the clone's developer folder, else this user's installed one.
--- @param spec table Built declaration.
--- @param getenv function os.getenv-compatible.
--- @param clone_root string|nil The clone root of a developer run.
--- @return string|nil folder, string|nil reason
function M.folder(spec, getenv, clone_root)
	if clone_root ~= nil then return clone_root .. "/" .. spec.clone_folder end
	local base = getenv(spec.installed_folder.base)
	if type(base) ~= "string" or base:sub(1, 1) ~= "/" then return nil, spec.installed_folder.base .. " is not set" end
	return (base:gsub("/+$", "")) .. "/" .. table.concat(spec.installed_folder.segments, "/")
end





-- ===========================
-- ===========================
-- ======= 2/ Requests =======
-- ===========================
-- ===========================

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
	local echoed = spec.is_request_id(request.request_id) and request.request_id or nil
	for key in pairs(request) do
		if not spec.documents.request[key] and not OPTIONAL_REQUEST_KEYS[key] then return nil, "malformed", echoed end
	end
	if request.schema ~= spec.schema or not echoed or type(request.steps) ~= "table" or #request.steps == 0 then
		return nil, "malformed", echoed
	end
	local deadline = request.deadline_seconds
	if deadline == nil then deadline = spec.deadline_seconds.default end
	if not is_integer(deadline) or deadline < spec.deadline_seconds.min or deadline > spec.deadline_seconds.max then
		return nil, "bad_deadline", echoed
	end
	local seen, names = {}, {}
	for _, name in ipairs(request.steps) do
		if type(name) ~= "string" or seen[name] then return nil, "malformed", echoed end
		seen[name] = true
		names[#names + 1] = name
	end
	local steps = {}
	if #names == 1 and names[1] == spec.all_steps then
		for _, step in ipairs(spec.steps) do steps[#steps + 1] = step end
	else
		for _, name in ipairs(names) do
			if not spec.step_by_id[name] then return nil, "unknown_step", echoed end
		end
		-- Declaration order, whatever order the request lists them in.
		for _, step in ipairs(spec.steps) do
			if seen[step.id] then steps[#steps + 1] = step end
		end
	end
	return { request_id = echoed, steps = steps, deadline_seconds = deadline }
end

--- The verdict, codes and report of one field check result.
--- @param result table field_check_report result { check, steps, passed }.
--- @return string verdict, table codes, table report
function M.step_outcome(result)
	local codes = {}
	for _, item in ipairs(type(result) == "table" and type(result.steps) == "table" and result.steps or {}) do
		if item.state == Report.STATE_FAIL then codes[#codes + 1] = "fail_" .. tostring(item.id) end
	end
	return result.passed == true and "pass" or "fail", codes, result
end





-- ==========================
-- ==========================
-- ======= 3/ Session =======
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
--- A document missing a key the shared declaration lists for its kind is a
--- defect of this module and stops it.
--- @param kind string The document kind (ready, refused, running, accepted, result, done).
--- @param may_lack string|nil The one listed key this document may lack.
function Session:publish(kind, path, document, may_lack)
	for key in pairs(self.spec.documents[kind] or error("field run: undeclared document kind " .. tostring(kind), 2)) do
		if document[key] == nil and key ~= may_lack then error("field run: the " .. kind .. " document lacks " .. key, 2) end
	end
	local ok, written = pcall(self.ports.write, path, Json.encode(document) .. "\n")
	if not ok or written ~= true then
		Logger.error(LOG, "Field run file %s could not be written: %s.", path, tostring(written))
		return false
	end
	return true
end

function Session:refuse(request_id, reason)
	Logger.warn(LOG, "Field run request %s refused: %s.", tostring(request_id), reason)
	-- A request with no valid identifier is refused without one, as on macOS:
	-- an invalid identifier is never echoed.
	self:publish("refused", self:path("refused"), { schema = self.spec.schema, request_id = request_id, reason = reason },
		"request_id")
end

--- Closes a run an earlier daemon left open, so its collector stops waiting.
function Session:close_interrupted()
	local text = self.ports.read(self:path("running"))
	if text == nil then return end
	local ok, running = pcall(Json.decode, text)
	local request_id = ok and type(running) == "table" and self.spec.is_request_id(running.request_id)
		and running.request_id or nil
	if request_id then
		local done = self:results_dir(request_id) .. "/" .. self.spec.files.done
		if not self.ports.exists(done) then
			self:publish("done", done, { schema = self.spec.schema, request_id = request_id, pid = self.pid,
				interrupted = true, finished_at = self.ports.iso_now(), verdicts = {}, order = Json.array({}) })
			Logger.warn(LOG, "Field run %s was cut short by an earlier daemon; closed as interrupted.", request_id)
		end
	end
	self.ports.remove(self:path("running"))
end

--- Prepares the folder, closes an interrupted run, then watches for requests.
function Session:start()
	if self.started then error("the field run session cannot be started twice", 2) end
	self.started = true
	if not self.ports.make_dir(self:path("results")) then error("the field run folder could not be created", 0) end
	self:close_interrupted()
	-- A request left from an earlier session was written for a daemon that is gone.
	if self.ports.exists(self:path("request")) then
		Logger.warn(LOG, "A stale field run request was left by an earlier session; removed.")
		self.ports.remove(self:path("request"))
	end
	local request_name = self.spec.files.request
	local watcher, why = self.ports.watch(self.folder, function(name)
		if not self.active or self.pending then return end
		if name == request_name then self:queue_request() end
	end)
	if not watcher then error("the field run folder watcher did not start: " .. tostring(why), 0) end
	self.watcher = watcher
	self.active = true
	local ids = {}
	for _, step in ipairs(self.spec.steps) do ids[#ids + 1] = step.id end
	-- Published last: it is the collector's readiness receipt.
	if not self:publish("ready", self:path("ready"), { schema = self.spec.schema, driver = "linux", pid = self.pid,
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

--- Stops watching and withdraws the readiness file; a running run is closed as interrupted.
--- @return boolean stopped
function Session:stop()
	self.active = false
	if self.pending then pcall(self.ports.cancel, self.pending); self.pending = nil end
	local run = self.run
	if run then
		run.abandoned = true
		for handle in pairs(run.timers) do pcall(self.ports.cancel, handle) end
		self:publish("done", run.dir .. "/" .. self.spec.files.done, { schema = self.spec.schema,
			request_id = run.request.request_id, pid = self.pid, interrupted = true,
			cause = { kind = "teardown", step = run.current_step or "none" },
			started_at = run.started_at, finished_at = self.ports.iso_now(),
			verdicts = run.verdicts, order = Json.array(run.order) })
		self.ports.remove(self:path("running"))
		Logger.warn(LOG, "Field run %s cut short by the daemon's stop; closed as interrupted.", run.request.request_id)
		self.run = nil
	end
	local stopped = true
	if self.watcher then
		local ok, closed = pcall(self.watcher.close)
		if not ok or closed == false then
			stopped = false
			Logger.error(LOG, "The field run folder watcher could not stop: %s.", tostring(closed))
		end
		self.watcher = nil
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
-- ======= 4/ Run =======
-- ======================
-- ======================

--- Runs the admitted steps in order, then the configuration guard.
function Session:begin(request, dir)
	local spec, ports = self.spec, self.ports
	local run = { request = request, dir = dir, verdicts = {}, order = {}, timers = {}, abandoned = false,
		started_ms = ports.now_ms(), started_at = ports.iso_now(), config = ports.config_bytes() }
	run.deadline_ms = run.started_ms + request.deadline_seconds * 1000
	self.run = run
	local ids = {}
	for _, step in ipairs(request.steps) do ids[#ids + 1] = step.id end
	self:publish("running", self:path("running"), { schema = spec.schema, request_id = request.request_id })
	self:publish("accepted", dir .. "/" .. spec.files.accepted, { schema = spec.schema, request_id = request.request_id,
		pid = self.pid, steps = Json.array(ids), deadline_seconds = request.deadline_seconds,
		started_at = run.started_at })
	Logger.start(LOG, "Field run %s started: %d step(s) within %d s.", request.request_id, #ids,
		request.deadline_seconds)
	self:advance(1)
	return true
end

function Session:advance(index)
	local run = self.run
	if run == nil or run.abandoned then return end
	local step = run.request.steps[index]
	if step == nil then return self:guard(index) end
	self:run_step(index, step, function()
		-- A fresh turn between steps: a check that settles at once must not
		-- grow the stack by one frame per step.
		local handle
		handle = self.ports.after(0, function()
			if handle then run.timers[handle] = nil end
			self:advance(index + 1)
		end)
		if handle then run.timers[handle] = true end
	end)
end

--- Runs one step under its deadline and records it once.
function Session:run_step(index, step, continue)
	local ports, run = self.ports, self.run
	local left_ms = run.deadline_ms - ports.now_ms()
	if left_ms <= 0 then
		self:record(index, step, { verdict = "skip", codes = { "global_deadline" }, elapsed_ms = 0 })
		return continue()
	end
	local deadline_ms = math.min(step.deadline_seconds * 1000, left_ms)
	local started_ms, started_at = ports.now_ms(), ports.iso_now()
	local settled, timer = false, nil
	run.current_step = step.id
	Logger.info(LOG, "Field run step %d/%d '%s' started.", index, #run.request.steps, step.id)
	local function settle(verdict, codes, report)
		if settled then
			Logger.info(LOG, "Field run step '%s' answered %s after it was settled; dropped.", step.id, tostring(verdict))
			return
		end
		settled = true
		if timer then pcall(ports.cancel, timer); run.timers[timer] = nil; timer = nil end
		if run.abandoned then return end
		self:record(index, step, { verdict = verdict, codes = codes, report = report, started_at = started_at,
			elapsed_ms = ports.now_ms() - started_ms, deadline_ms = deadline_ms })
		continue()
	end
	timer = ports.after(deadline_ms, function()
		if timer then run.timers[timer] = nil end
		timer = nil
		settle("timeout", { "deadline_" .. math.floor(deadline_ms / 1000) .. "s" })
	end)
	if timer then run.timers[timer] = true end
	local ran, started = pcall(ports.run_check, step.check, function(result)
		settle(M.step_outcome(result))
	end)
	if not ran then
		Logger.error(LOG, "Field run step '%s' raised: %s", step.id, tostring(started))
		settle("fail", { "raised" })
	elseif started ~= true then
		-- The same check, clicked from the tray, is still pending: never run it twice.
		settle("skip", { "check_busy" })
	end
end

--- Writes one step result, named by its position.
function Session:record(index, step, fields)
	local run, spec = self.run, self.spec
	local codes = {}
	for _, code in ipairs(type(fields.codes) == "table" and fields.codes or {}) do
		local safe = Report.sanitize_value(code)
		if not spec.is_code(safe) then
			-- Only closed codes leave the daemon: a value outside the shared rule is named, never written.
			Logger.warn(LOG, "Field run step '%s' gave a code outside the shared code rule; replaced.", step.id)
			safe = "unsafe_code"
		end
		codes[#codes + 1] = safe
	end
	if not spec.verdict_set[fields.verdict] then fields.verdict, codes = "fail", { "undeclared_verdict" } end
	run.verdicts[step.id] = fields.verdict
	run.order[#run.order + 1] = step.id
	self:publish("result", string.format("%s/%02d_%s.json", run.dir, index, step.id), {
		schema = spec.schema, request_id = run.request.request_id, index = index, step = step.id,
		kind = step.kind, verdict = fields.verdict, codes = Json.array(codes),
		started_at = fields.started_at or self.ports.iso_now(), finished_at = self.ports.iso_now(),
		elapsed_ms = math.floor(fields.elapsed_ms or 0), deadline_ms = math.floor(fields.deadline_ms or 0),
		report = type(fields.report) == "table" and fields.report or {},
	})
	Logger.evidence(LOG, "Field run step result: step=%s verdict=%s codes=%s", step.id, fields.verdict,
		#codes > 0 and table.concat(codes, ",") or "none")
end

--- Compares config.toml with its bytes before the run, then closes the run.
function Session:guard(index)
	local run = self.run
	local started_ms = self.ports.now_ms()
	local after = self.ports.config_bytes()
	local verdict, codes = "pass", {}
	if after ~= run.config then
		verdict, codes = "fail", { "changed_config_toml" }
		Logger.error(LOG, "A field run step changed config.toml.")
	end
	self:record(index, { id = self.spec.guard_step, kind = GUARD_KIND },
		{ verdict = verdict, codes = codes, elapsed_ms = self.ports.now_ms() - started_ms })
	return self:finish()
end

function Session:finish()
	local run, spec = self.run, self.spec
	local counts = {}
	for _, verdict in pairs(run.verdicts) do counts[verdict] = (counts[verdict] or 0) + 1 end
	local written = self:publish("done", run.dir .. "/" .. spec.files.done, {
		schema = spec.schema, request_id = run.request.request_id, pid = self.pid, interrupted = false,
		started_at = run.started_at, finished_at = self.ports.iso_now(),
		elapsed_ms = math.floor(self.ports.now_ms() - run.started_ms),
		verdicts = run.verdicts, counts = counts, order = Json.array(run.order),
	})
	self.ports.remove(self:path("running"))
	self.run = nil
	if written then Logger.success(LOG, "Field run %s finished.", run.request.request_id)
	else Logger.error(LOG, "Field run %s finished, but its done marker was not written.", run.request.request_id) end
	return written
end

M.Session = Session





-- ========================
-- ========================
-- ======= 5/ Owner =======
-- ========================
-- ========================

--- The daemon's ports: files, an inotify watcher on the folder, libuv timers.
--- @return table ports
local function native_ports()
	local uv = require("luv")
	local FileSystem = require("adapters.file_system")
	local function timer(ms, fn)
		local handle = uv.new_timer()
		handle:start(math.max(0, math.floor(ms)), 0, function()
			handle:close()
			fn()
		end)
		return handle
	end
	return {
		read = function(path) return FileSystem.read(path) end,
		write = function(path, text)
			-- Staged then renamed: the collector never reads half a document.
			local stage = path .. ".tmp"
			if not FileSystem.write(stage, text) then return false end
			return os.rename(stage, path) == true
		end,
		remove = function(path)
			local ok, _, code = uv.fs_unlink(path)
			return ok ~= nil or code == "ENOENT"
		end,
		exists = function(path) return uv.fs_stat(path) ~= nil end,
		make_dir = function(path)
			local parts, current = {}, ""
			for part in path:gmatch("[^/]+") do parts[#parts + 1] = part end
			for _, part in ipairs(parts) do
				current = current .. "/" .. part
				if not uv.fs_stat(current) then uv.fs_mkdir(current, PRIVATE_MODE) end
			end
			local stat = uv.fs_stat(path)
			return stat ~= nil and stat.type == "directory"
		end,
		watch = function(folder, on_change)
			local handle = uv.new_fs_event()
			if not handle then return nil, "no inotify handle" end
			local ok, err = handle:start(folder, {}, function(_, name) if type(name) == "string" then on_change(name) end end)
			if not ok then handle:close(); return nil, err end
			return { close = function() handle:stop(); handle:close(); return true end }
		end,
		after = timer,
		cancel = function(handle) if not handle:is_closing() then handle:stop(); handle:close() end end,
		now_ms = function() uv.update_time(); return uv.now() end,
		iso_now = function() return os.date("!%Y-%m-%dT%H:%M:%SZ") end,
		config_bytes = function() return FileSystem.read(require("infra.config_paths").config("config.toml")) end,
		run_check = function(check, on_result)
			return require(M.CHECK_RUNNERS[check]).run_headless(on_result)
		end,
	}
end

--- Starts the daemon's field run session; a failure is logged and the daemon runs on.
--- @param opts table { pid, spec?, ports?, folder? }
--- @return table|nil session, string|nil error
function M.start(opts)
	Logger.start(LOG, "Starting the field run session…")
	local ok, session_or_err = pcall(function()
		local Paths = require("infra.paths")
		local spec = opts.spec
		if spec == nil then
			local shared = Paths.shared_root()
			if not shared then error("the shared tree is missing", 0) end
			spec = M.load(shared, Paths.driver_root())
		end
		local folder = opts.folder
		if folder == nil then
			local why
			folder, why = M.folder(spec, os.getenv, require("infra.dev_source").root())
			if not folder then error(why, 0) end
		end
		local session = M.new({ spec = spec, folder = folder, pid = opts.pid, ports = opts.ports or native_ports() })
		session:start()
		return session
	end)
	if not ok then
		Logger.error(LOG, "The field run session could not start: %s.", tostring(session_or_err))
		return nil, tostring(session_or_err)
	end
	Logger.success(LOG, "Field run session ready.")
	return session_or_err
end

return M
