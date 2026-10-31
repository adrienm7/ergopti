--- infra/field_run.lua

--- ==============================================================================
--- MODULE: Field Run (Linux)
--- DESCRIPTION:
--- Lets tools/dev/collect-linux-field-report.sh ask the running daemon to run
--- its Debug field checks with no window and write one JSON result per step,
--- so a maintainer's field report needs no click. The protocol is the macOS
--- developer field run's (macos/infra/field_run.lua): the same files, verdicts,
--- refusal reasons and result documents; data/field_run.json declares the
--- folder and the Linux steps.
---
--- FEATURES & RATIONALE:
--- 1. A request file in $XDG_RUNTIME_DIR/<app>/field-run, a folder only this
---    user can write, noticed by an inotify watcher. The work runs on a later
---    turn, never inside the watcher callback, and a request is consumed before
---    it runs so it never runs twice.
--- 2. One result per step: verdict, closed codes, timings and the check's own
---    privacy-safe report. A step settles once, by its check or by its
---    deadline; a late answer is logged and dropped.
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

local REQUEST_KEYS = { schema = true, request_id = true, steps = true, deadline_seconds = true }
local REQUEST_ID_CLASS = "^[%w_%-]+$"
local FILE_KEYS = { "ready", "request", "refused", "running", "results", "accepted", "done" }

-- The request word that selects every declared step.
M.ALL_STEPS = "all"

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
--- @return table spec The same table, with verdict_set, reason_set, step_by_id and request_id_max.
function M.validate(spec)
	if type(spec) ~= "table" or spec.schema ~= 1 then error("field run: unsupported declaration", 2) end
	local folder = spec.folder
	if type(folder) ~= "table" or type(folder.base) ~= "string" or type(folder.segments) ~= "table" then
		error("field run: folder needs a base variable and segments", 2)
	end
	for _, segment in ipairs(folder.segments) do
		if type(segment) ~= "string" or not segment:match("^[%w_.{}%-]+$") then
			error("field run: folder segments must be plain names", 2)
		end
	end
	for _, key in ipairs(FILE_KEYS) do
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
	if not id_max then error("field run: request_id_pattern differs from the policy this module enforces", 2) end
	spec.request_id_max = tonumber(id_max)
	local deadline = spec.deadline_seconds
	if type(deadline) ~= "table" or not is_integer(deadline.min) or not is_integer(deadline.max)
		or not is_integer(deadline.default) or deadline.min < 1 or deadline.min > deadline.default
		or deadline.default > deadline.max then
		error("field run: deadline_seconds needs min <= default <= max", 2)
	end
	spec.verdict_set = name_set(spec.verdicts, "verdicts")
	for _, verdict in ipairs({ "pass", "fail", "skip", "timeout" }) do
		if not spec.verdict_set[verdict] then error("field run: verdict " .. verdict .. " is not declared", 2) end
	end
	spec.reason_set = name_set(spec.reasons, "reasons")
	if type(spec.steps) ~= "table" or #spec.steps == 0 then error("field run: steps must be a nonempty list", 2) end
	spec.step_by_id = {}
	local bound = 0
	for _, step in ipairs(spec.steps) do
		if type(step) ~= "table" or type(step.id) ~= "string" or not step.id:match("^[%w_]+$")
			or spec.step_by_id[step.id] or step.id == M.ALL_STEPS then
			error("field run: a step has an invalid or duplicate id", 2)
		end
		if step.kind ~= "field_check" or M.CHECK_RUNNERS[step.check] == nil then
			error("field run: step " .. step.id .. " names no Linux field check", 2)
		end
		if not is_integer(step.deadline_seconds) or step.deadline_seconds < 1 then
			error("field run: step " .. step.id .. " needs a positive deadline", 2)
		end
		bound = bound + step.deadline_seconds
		spec.step_by_id[step.id] = step
	end
	if deadline.default < bound then
		error("field run: deadline_seconds.default is below the sum of the step deadlines (" .. bound .. " s)", 2)
	end
	if type(spec.guard_step) ~= "string" or spec.step_by_id[spec.guard_step] then
		error("field run: guard_step must name a step outside the requestable list", 2)
	end
	return spec
end

--- The run folder of this user: the declared base variable and segments.
--- @param spec table Validated declaration.
--- @param getenv function os.getenv-compatible.
--- @param app_folder string The application folder name (app_dirs.folder_name).
--- @return string|nil folder, string|nil reason
function M.folder(spec, getenv, app_folder)
	local base = getenv(spec.folder.base)
	if type(base) ~= "string" or base:sub(1, 1) ~= "/" then return nil, spec.folder.base .. " is not set" end
	local parts = { (base:gsub("/+$", "")) }
	for _, segment in ipairs(spec.folder.segments) do
		parts[#parts + 1] = segment == "{app}" and app_folder or segment
	end
	return table.concat(parts, "/")
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
	local seen, names = {}, {}
	for _, name in ipairs(request.steps) do
		if type(name) ~= "string" or seen[name] then return nil, "malformed", echoed end
		seen[name] = true
		names[#names + 1] = name
	end
	local steps = {}
	if #names == 1 and names[1] == M.ALL_STEPS then
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
function Session:publish(path, document)
	local ok, written = pcall(self.ports.write, path, Json.encode(document) .. "\n")
	if not ok or written ~= true then
		Logger.error(LOG, "Field run file %s could not be written: %s.", path, tostring(written))
		return false
	end
	return true
end

function Session:refuse(request_id, reason)
	Logger.warn(LOG, "Field run request %s refused: %s.", tostring(request_id), reason)
	self:publish(self:path("refused"), { schema = self.spec.schema, request_id = request_id, reason = reason })
end

--- Closes a run an earlier daemon left open, so its collector stops waiting.
function Session:close_interrupted()
	local text = self.ports.read(self:path("running"))
	if text == nil then return end
	local ok, running = pcall(Json.decode, text)
	local request_id = ok and type(running) == "table" and is_request_id(self.spec, running.request_id)
		and running.request_id or nil
	if request_id then
		local done = self:results_dir(request_id) .. "/" .. self.spec.files.done
		if not self.ports.exists(done) then
			self:publish(done, { schema = self.spec.schema, request_id = request_id, pid = self.pid,
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
	if not self:publish(self:path("ready"), { schema = self.spec.schema, driver = "linux", pid = self.pid,
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
		self:publish(run.dir .. "/" .. self.spec.files.done, { schema = self.spec.schema,
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
	self:publish(self:path("running"), { schema = spec.schema, request_id = request.request_id })
	self:publish(dir .. "/" .. spec.files.accepted, { schema = spec.schema, request_id = request.request_id,
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
		codes[#codes + 1] = Report.sanitize_value(code) or "empty"
	end
	if not spec.verdict_set[fields.verdict] then fields.verdict, codes = "fail", { "undeclared_verdict" } end
	run.verdicts[step.id] = fields.verdict
	run.order[#run.order + 1] = step.id
	self:publish(string.format("%s/%02d_%s.json", run.dir, index, step.id), {
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
	self:record(index, { id = self.spec.guard_step, kind = "guard" },
		{ verdict = verdict, codes = codes, elapsed_ms = self.ports.now_ms() - started_ms })
	return self:finish()
end

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
--- @param opts table { pid, declaration?, ports?, folder? }
--- @return table|nil session, string|nil error
function M.start(opts)
	Logger.start(LOG, "Starting the field run session…")
	local ok, session_or_err = pcall(function()
		local path = opts.declaration or (require("infra.paths").driver_root() .. "/data/field_run.json")
		local text = require("adapters.file_system").read(path)
		if type(text) ~= "string" then error("the field run declaration is unreadable: " .. path, 0) end
		local spec = M.validate(Json.decode(text))
		local folder = opts.folder
		if folder == nil then
			local why
			folder, why = M.folder(spec, os.getenv, require("app_dirs").folder_name)
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
