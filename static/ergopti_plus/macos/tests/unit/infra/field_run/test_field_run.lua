--- tests/unit/infra/field_run/test_field_run.lua

--- ==============================================================================
--- MODULE: Developer Field Run
--- DESCRIPTION:
--- Drives the real field run engine over in-memory files, a fake folder watcher
--- and a fake clock, against the shipped data/field_run.json:
--- 1. developer source mode only: without the clone root nothing starts, and
---    init.lua starts it only behind infra/dev_source.lua;
--- 2. request parsing: every step, a subset in declaration order, and the
---    refusals (unknown step, unknown key, bad deadline, oversized);
--- 3. a run writes one result per step with the declared shape, reports the
---    typing step as needs_typing without running it, and ends with done;
--- 4. deadlines: a step that never answers times out and its late answer is
---    dropped; past the request's deadline the remaining steps are skipped;
--- 5. the configuration guard restores and names what a step changed, and a
---    failed snapshot runs no step;
--- 6. a run cut short by a reload is closed as interrupted at the next start.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local MODULES = { "infra.logger", "infra.field_run" }
local FOLDER = "/repo/build/field-run"

local function read(path)
	local file = assert(io.open(path, "rb"))
	local text = assert(file:read("*a"))
	assert(file:close())
	return text
end

local SPEC_TEXT = read(helpers.driver_root() .. "data/field_run.json")

--- Loads a fresh engine with a silent logger and returns it.
local function engine()
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.field_run"] = nil
	return require("infra.field_run")
end

--- A fresh validated declaration.
local function spec_of(FieldRun)
	return FieldRun.validate(Json.decode(SPEC_TEXT))
end

--- In-memory world: files, a manual clock and timers, a fake folder watcher.
--- @param runners table|nil step id → fn(step, finish, world); default: pass.
local function world(runners)
	local state = { files = {}, dirs = {}, now = 0, timers = {}, calls = {}, ring = {}, restored = nil, mark = 0 }
	state.ports = {
		read_declaration = function() return SPEC_TEXT end,
		read = function(path)
			if state.files[path] == nil then return nil, "absent" end
			return state.files[path], "ok"
		end,
		write = function(path, text) state.files[path] = text; return true end,
		remove = function(path) state.files[path] = nil; return true end,
		exists = function(path) return state.files[path] ~= nil or state.dirs[path] == true end,
		make_dir = function(path) state.dirs[path] = true; return true end,
		watch = function(path, callback)
			state.watched, state.deliver = path, callback
			local handle = {}
			function handle:start() state.watching = true; return self end
			function handle:stop() state.watching = false; return self end
			return handle
		end,
		after = function(seconds, fn)
			local handle = { at = state.now + seconds * 1000, fn = fn }
			state.timers[#state.timers + 1] = handle
			return handle, true
		end,
		cancel = function(handle) handle.cancelled = true; return true end,
		now_ms = function() return state.now end,
		progress_mark = function() return state.mark end,
		iso_now = function() return "2026-10-27T10:00:00Z" end,
		-- A copy, as the logger's snapshot is
		log_ring = function() return { table.unpack(state.ring) } end,
		config_snapshot = function()
			if state.snapshot_error then error("unreadable") end
			return { tag = "snapshot" }
		end,
		config_restore = function(snapshot)
			state.restored = snapshot
			return state.restore_outcome or { restored = {}, failed = {} }
		end,
		run_step = function(step, finish)
			state.calls[#state.calls + 1] = step.id
			local runner = runners and runners[step.id]
			if runner then return runner(step, finish, state) end
			state.ring[#state.ring + 1] = "line of " .. step.id
			finish("pass", { "ok" }, { step = step.id })
		end,
	}
	--- Runs every due timer, advancing the clock by `ms` at most.
	function state.advance(ms)
		local limit = state.now + (ms or 0)
		while true do
			local due, index = nil, nil
			for i, handle in ipairs(state.timers) do
				if not handle.cancelled and handle.at <= limit and (due == nil or handle.at < due.at) then
					due, index = handle, i
				end
			end
			if not due then break end
			table.remove(state.timers, index)
			state.now = math.max(state.now, due.at)
			due.fn()
		end
		state.now = math.max(state.now, limit)
	end
	--- Writes a request and rings the watcher.
	function state.request(document)
		local text = type(document) == "string" and document or Json.encode(document)
		state.files[FOLDER .. "/request.json"] = text
		state.deliver({ FOLDER .. "/request.json" })
	end
	function state.json(path)
		local text = state.files[path]
		return text and Json.decode(text) or nil
	end
	return state
end

--- Starts a session over a world.
local function started(FieldRun, state)
	local session = FieldRun.new({ spec = spec_of(FieldRun), folder = FOLDER, pid = 4242, ports = state.ports })
	session:start()
	return session
end

local function result_path(id, index, step)
	return string.format("%s/results/%s/%02d_%s.json", FOLDER, id, index, step)
end

helpers.describe("field run: developer source mode only", function()
	helpers.it("refuses to start without the clone root and touches nothing", function()
		helpers.with_stub_scope(MODULES, function()
			local FieldRun = engine()
			local touched = false
			local ports = setmetatable({}, { __index = function() touched = true end })
			helpers.assert_eq(FieldRun.start({ root = nil, pid = 1, ports = ports }), false)
			helpers.assert_eq(FieldRun.start({ root = "relative/clone", pid = 1, ports = ports }), false)
			helpers.assert_eq(touched, false, "a non-developer runtime must not reach a port")
		end)
	end)

	helpers.it("starts with a clone root and publishes its readiness", function()
		helpers.with_stub_scope(MODULES, function()
			local FieldRun = engine()
			local state = world()
			helpers.assert_eq(FieldRun.start({ root = "/repo", pid = 4242, ports = state.ports }), true)
			local ready = state.json(FOLDER .. "/ready.json")
			helpers.assert_eq(ready.pid, 4242)
			helpers.assert_eq(ready.driver, "macos")
			helpers.assert_eq(state.watched, FOLDER)
			helpers.assert_eq(FieldRun.stop(), true)
			helpers.assert_nil(state.files[FOLDER .. "/ready.json"], "stop withdraws the readiness file")
		end)
	end)

	helpers.it("is started by init.lua only behind the developer source check", function()
		local source = read(helpers.driver_root() .. "init.lua")
		local gate = source:find('if require("infra.dev_source").is_active() then', 1, true)
		local start = source:find('require("infra.field_run").start(', 1, true)
		helpers.assert_not_nil(gate, "init.lua must gate the field run on developer source mode")
		helpers.assert_not_nil(start, "init.lua must start the field run")
		helpers.assert_true(gate < start, "the gate must come before the start")
		local between = source:sub(gate, start)
		helpers.assert_nil(between:find("\nend", 1, true), "the start must sit inside the gate")
		helpers.assert_not_nil(source:find('package.loaded["infra.field_run"]', 1, true),
			"the local teardown must stop the field run")
	end)
end)

helpers.describe("field run: declaration and requests", function()
	helpers.it("declares a step for every Debug field check", function()
		helpers.with_stub_scope(MODULES, function()
			local FieldRun = engine()
			local spec = spec_of(FieldRun)
			local declared = {}
			for _, step in ipairs(spec.steps) do
				if step.kind == "field_check" then declared[step.check] = true end
			end
			for check in pairs(require("infra.field_check_checks").checks) do
				helpers.assert_true(declared[check], "no field run step runs the check " .. check)
			end
		end)
	end)

	helpers.it("admits every step, or a subset in declaration order", function()
		helpers.with_stub_scope(MODULES, function()
			local FieldRun = engine()
			local spec = spec_of(FieldRun)
			local all = FieldRun.parse_request(spec, '{"schema":1,"request_id":"r1","steps":["all"]}')
			helpers.assert_eq(#all.steps, #spec.steps)
			helpers.assert_eq(all.deadline_seconds, spec.deadline_seconds.default)
			local some = FieldRun.parse_request(spec,
				'{"schema":1,"request_id":"r2","steps":["mlx_model","field_lease"],"deadline_seconds":120}')
			helpers.assert_eq(#some.steps, 2)
			helpers.assert_eq(some.steps[1].id, "field_lease")
			helpers.assert_eq(some.steps[2].id, "mlx_model")
			helpers.assert_eq(some.deadline_seconds, 120)
		end)
	end)

	helpers.it("refuses an unknown step, key, schema or deadline", function()
		helpers.with_stub_scope(MODULES, function()
			local FieldRun = engine()
			local spec = spec_of(FieldRun)
			local function refusal(text)
				local request, reason, echoed = FieldRun.parse_request(spec, text)
				helpers.assert_nil(request)
				return reason, echoed
			end
			local reason, echoed = refusal('{"schema":1,"request_id":"r3","steps":["field_lease","format_disk"]}')
			helpers.assert_eq(reason, "unknown_step")
			helpers.assert_eq(echoed, "r3")
			helpers.assert_eq(refusal('{"schema":1,"request_id":"r4","steps":["all"],"run":"x"}'), "malformed")
			helpers.assert_eq(refusal('{"schema":2,"request_id":"r5","steps":["all"]}'), "malformed")
			helpers.assert_eq(refusal('{"schema":1,"request_id":"bad id","steps":["all"]}'), "malformed")
			helpers.assert_eq(refusal('{"schema":1,"request_id":"r6","steps":[]}'), "malformed")
			helpers.assert_eq(refusal('{"schema":1,"request_id":"r7","steps":["field_lease","field_lease"]}'),
				"malformed")
			helpers.assert_eq(refusal('{"schema":1,"request_id":"r8","steps":["all"],"deadline_seconds":5}'),
				"bad_deadline")
			helpers.assert_eq(refusal('{"schema":1,"request_id":"r9","steps":["all"],"deadline_seconds":99999}'),
				"bad_deadline")
			helpers.assert_eq(refusal("not json"), "malformed")
			helpers.assert_eq(refusal(string.rep(" ", spec.max_request_bytes + 1)), "malformed")
		end)
	end)

	helpers.it("bounds the request id by the length the declaration names", function()
		helpers.with_stub_scope(MODULES, function()
			local FieldRun = engine()
			local function request(id) return '{"schema":1,"request_id":"' .. id .. '","steps":["all"]}' end
			local spec = spec_of(FieldRun)
			helpers.assert_true(FieldRun.parse_request(spec, request(string.rep("a", 64))) ~= nil)
			helpers.assert_eq(select(2, FieldRun.parse_request(spec, request(string.rep("a", 65)))), "malformed")
			local narrow = Json.decode(SPEC_TEXT)
			narrow.request_id_pattern = "^[A-Za-z0-9_-]{1,8}$"
			narrow = FieldRun.validate(narrow)
			helpers.assert_true(FieldRun.parse_request(narrow, request("abcdefgh")) ~= nil)
			helpers.assert_eq(select(2, FieldRun.parse_request(narrow, request("abcdefghi"))), "malformed")
			local other = Json.decode(SPEC_TEXT)
			other.request_id_pattern = "^[a-z]{1,64}$"
			helpers.assert_true(not pcall(FieldRun.validate, other))
		end)
	end)

	helpers.it("writes the refusal of an unknown step and runs nothing", function()
		helpers.with_stub_scope(MODULES, function()
			local FieldRun = engine()
			local state = world()
			started(FieldRun, state)
			state.request({ schema = 1, request_id = "r10", steps = Json.array({ "rm_rf" }) })
			state.advance(0)
			local refused = state.json(FOLDER .. "/refused.json")
			helpers.assert_eq(refused.reason, "unknown_step")
			helpers.assert_eq(refused.request_id, "r10")
			helpers.assert_eq(#state.calls, 0)
			helpers.assert_nil(state.files[FOLDER .. "/request.json"], "a request is consumed")
		end)
	end)
end)

helpers.describe("field run: a run", function()
	helpers.it("writes one result per step, the guard and done", function()
		helpers.with_stub_scope(MODULES, function()
			local FieldRun = engine()
			local state = world()
			local spec = spec_of(FieldRun)
			started(FieldRun, state)
			state.request({ schema = 1, request_id = "r11", steps = Json.array({ "all" }) })
			state.advance(0)
			for index, step in ipairs(spec.steps) do
				local result = state.json(result_path("r11", index, step.id))
				helpers.assert_not_nil(result, "no result for " .. step.id)
				helpers.assert_eq(result.schema, 1)
				helpers.assert_eq(result.request_id, "r11")
				helpers.assert_eq(result.step, step.id)
				helpers.assert_eq(result.index, index)
				helpers.assert_type(result.codes, "table")
				helpers.assert_type(result.elapsed_ms, "number")
				helpers.assert_type(result.started_at, "string")
				helpers.assert_type(result.log_window.lines, "table")
				helpers.assert_true(spec.verdict_set[result.verdict], "undeclared verdict " .. tostring(result.verdict))
			end
			local typing = state.json(result_path("r11", 7, "key_accounting"))
			helpers.assert_eq(typing.verdict, "needs_typing")
			helpers.assert_eq(typing.codes[1], "synthetic_input_unsafe")
			for _, id in ipairs(state.calls) do
				helpers.assert_true(id ~= "key_accounting", "a step that needs a person must not run")
			end
			local lease = state.json(result_path("r11", 1, "field_lease"))
			helpers.assert_eq(lease.verdict, "pass")
			helpers.assert_eq(lease.log_window.lines[1], "line of field_lease")
			helpers.assert_eq(lease.report.step, "field_lease")
			local guard = state.json(result_path("r11", #spec.steps + 1, "config_guard"))
			helpers.assert_eq(guard.verdict, "pass")
			helpers.assert_eq(state.restored.tag, "snapshot", "the guard compares against the run's snapshot")
			local done = state.json(FOLDER .. "/results/r11/done.json")
			helpers.assert_eq(done.interrupted, false)
			helpers.assert_eq(done.verdicts.key_accounting, "needs_typing")
			helpers.assert_eq(#done.order, #spec.steps + 1)
			helpers.assert_nil(state.files[FOLDER .. "/running.json"], "done clears the running marker")
			helpers.assert_not_nil(state.json(FOLDER .. "/results/r11/accepted.json"))
		end)
	end)

	helpers.it("refuses a second request while a run is pending, and a repeated id", function()
		helpers.with_stub_scope(MODULES, function()
			local FieldRun = engine()
			local hold
			local state = world({ field_lease = function(_, finish) hold = finish end })
			started(FieldRun, state)
			state.request({ schema = 1, request_id = "r12", steps = Json.array({ "field_lease" }) })
			state.advance(0)
			state.request({ schema = 1, request_id = "r13", steps = Json.array({ "field_lease" }) })
			state.advance(0)
			helpers.assert_eq(state.json(FOLDER .. "/refused.json").reason, "busy")
			hold("pass", {})
			state.advance(0)
			state.request({ schema = 1, request_id = "r12", steps = Json.array({ "field_lease" }) })
			state.advance(0)
			helpers.assert_eq(state.json(FOLDER .. "/refused.json").reason, "duplicate_request")
		end)
	end)

	helpers.it("times a silent step out at its deadline and drops its late answer", function()
		helpers.with_stub_scope(MODULES, function()
			local FieldRun = engine()
			local late
			local state = world({ field_network = function(_, finish) late = finish end })
			local spec = spec_of(FieldRun)
			started(FieldRun, state)
			state.request({ schema = 1, request_id = "r14", steps = Json.array({ "field_network", "diagnostics" }) })
			state.advance(0)
			helpers.assert_nil(state.files[FOLDER .. "/results/r14/done.json"], "the step is still pending")
			state.advance(spec.step_by_id.field_network.deadline_seconds * 1000)
			local timed = state.json(result_path("r14", 1, "field_network"))
			helpers.assert_eq(timed.verdict, "timeout")
			helpers.assert_eq(timed.codes[1], "deadline_" .. spec.step_by_id.field_network.deadline_seconds .. "s")
			late("pass", { "too_late" })
			state.advance(0)
			helpers.assert_eq(state.json(result_path("r14", 1, "field_network")).verdict, "timeout",
				"a late answer must not overwrite the timeout")
			helpers.assert_eq(state.json(FOLDER .. "/results/r14/done.json").verdicts.diagnostics, "pass")
		end)
	end)

	helpers.it("keeps a progressing download alive past its deadline", function()
		helpers.with_stub_scope(MODULES, function()
			local FieldRun = engine()
			local finish_pull
			local state = world({ ollama_model = function(_, finish) finish_pull = finish end })
			local spec = spec_of(FieldRun)
			local step = spec.step_by_id.ollama_model
			helpers.assert_true(step.progress_max_seconds > step.deadline_seconds,
				"the model download must be progress-aware")
			started(FieldRun, state)
			state.request({ schema = 1, request_id = "r30", steps = Json.array({ "ollama_model" }) })
			state.advance(0)
			-- The 16:47 field run: granite4:350m-h finished after 240 s of steady bytes
			for _ = 1, 3 do
				state.advance(step.deadline_seconds * 500)
				state.mark = state.mark + 1
				state.advance(step.deadline_seconds * 500)
			end
			helpers.assert_nil(state.files[result_path("r30", 1, "ollama_model")],
				"a download that keeps moving must not time out")
			finish_pull("pass", { "pulled" })
			state.advance(0)
			helpers.assert_eq(state.json(result_path("r30", 1, "ollama_model")).verdict, "pass")
		end)
	end)

	helpers.it("times a stalled download out after one silent window, and any download at its bound", function()
		helpers.with_stub_scope(MODULES, function()
			local FieldRun = engine()
			local state = world({ ollama_model = function() end, mlx_model = function() end })
			local spec = spec_of(FieldRun)
			local step = spec.step_by_id.ollama_model
			started(FieldRun, state)
			state.request({ schema = 1, request_id = "r31", steps = Json.array({ "ollama_model" }) })
			state.advance(0)
			state.mark = state.mark + 1
			state.advance(step.deadline_seconds * 1000)
			helpers.assert_nil(state.files[result_path("r31", 1, "ollama_model")], "progress grants a window")
			state.advance(step.deadline_seconds * 1000)
			local stalled = state.json(result_path("r31", 1, "ollama_model"))
			helpers.assert_eq(stalled.verdict, "timeout")
			helpers.assert_eq(stalled.codes[1], "stalled_" .. step.deadline_seconds .. "s")

			local bound = spec.step_by_id.mlx_model
			state.request({ schema = 1, request_id = "r32", steps = Json.array({ "mlx_model" }) })
			state.advance(0)
			local waited = 0
			while state.files[result_path("r32", 1, "mlx_model")] == nil and waited <= bound.progress_max_seconds do
				state.mark = state.mark + 1
				state.advance(10000)
				waited = waited + 10
			end
			local bounded = state.json(result_path("r32", 1, "mlx_model"))
			helpers.assert_eq(bounded.codes[1], "bound_" .. bound.progress_max_seconds .. "s")
			helpers.assert_eq(waited, bound.progress_max_seconds, "the bound ends the step exactly")
		end)
	end)

	helpers.it("declares a default request deadline that covers every step at its bound", function()
		helpers.with_stub_scope(MODULES, function()
			local FieldRun = engine()
			local spec = spec_of(FieldRun)
			local total = 0
			for _, step in ipairs(spec.steps) do total = total + FieldRun.step_bound_seconds(step) end
			helpers.assert_true(spec.deadline_seconds.default >= total)
			local short = Json.decode(SPEC_TEXT)
			short.deadline_seconds.default = total - 1
			local ok, err = pcall(FieldRun.validate, short)
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(err):find("sum of the step bounds", 1, true) ~= nil, tostring(err))
		end)
	end)

	helpers.it("skips the steps left past the request's own deadline", function()
		helpers.with_stub_scope(MODULES, function()
			local FieldRun = engine()
			local state = world({ field_lease = function(_, finish, world_state)
				world_state.now = world_state.now + 61000
				finish("pass", {})
			end })
			started(FieldRun, state)
			state.request({ schema = 1, request_id = "r15", steps = Json.array({ "field_lease", "field_network" }),
				deadline_seconds = 60 })
			state.advance(0)
			-- The runner moved the clock: the next step's turn is due only now
			state.advance(0)
			local skipped = state.json(result_path("r15", 2, "field_network"))
			helpers.assert_eq(skipped.verdict, "skip")
			helpers.assert_eq(skipped.codes[1], "global_deadline")
			helpers.assert_eq(#state.calls, 1, "a step past the deadline must not run")
		end)
	end)

	helpers.it("records a raising runner as failed and keeps going", function()
		helpers.with_stub_scope(MODULES, function()
			local FieldRun = engine()
			local state = world({ field_lease = function() error("boom") end })
			started(FieldRun, state)
			state.request({ schema = 1, request_id = "r16", steps = Json.array({ "field_lease", "field_network" }) })
			state.advance(0)
			local failed = state.json(result_path("r16", 1, "field_lease"))
			helpers.assert_eq(failed.verdict, "fail")
			helpers.assert_eq(failed.codes[1], "raised")
			helpers.assert_eq(state.json(result_path("r16", 2, "field_network")).verdict, "pass")
		end)
	end)

	helpers.it("keeps a code inside the evidence grammar", function()
		helpers.with_stub_scope(MODULES, function()
			local FieldRun = engine()
			local state = world({ field_lease = function(_, finish) finish("fail", { "/Users/jane/secret" }) end })
			started(FieldRun, state)
			state.request({ schema = 1, request_id = "r17", steps = Json.array({ "field_lease" }) })
			state.advance(0)
			helpers.assert_eq(state.json(result_path("r17", 1, "field_lease")).codes[1], "redacted")
		end)
	end)
end)

helpers.describe("field run: configuration guard", function()
	helpers.it("fails the guard and names what it restored", function()
		helpers.with_stub_scope(MODULES, function()
			local FieldRun = engine()
			local state = world()
			state.restore_outcome = { restored = { "ConfigTomlPath" }, failed = { "setting_llm_backend" } }
			started(FieldRun, state)
			state.request({ schema = 1, request_id = "r18", steps = Json.array({ "field_lease" }) })
			state.advance(0)
			local guard = state.json(result_path("r18", 2, "config_guard"))
			helpers.assert_eq(guard.verdict, "fail")
			helpers.assert_eq(guard.codes[1], "restored_ConfigTomlPath")
			helpers.assert_eq(guard.codes[2], "restore_failed_setting_llm_backend")
		end)
	end)

	helpers.it("runs no step when the configuration cannot be snapshot", function()
		helpers.with_stub_scope(MODULES, function()
			local FieldRun = engine()
			local state = world()
			state.snapshot_error = true
			started(FieldRun, state)
			state.request({ schema = 1, request_id = "r19", steps = Json.array({ "field_lease", "mlx_model" }) })
			state.advance(0)
			helpers.assert_eq(#state.calls, 0)
			helpers.assert_eq(state.json(result_path("r19", 1, "field_lease")).codes[1], "config_unprotected")
			helpers.assert_eq(state.json(result_path("r19", 3, "config_guard")).codes[1], "snapshot_failed")
			helpers.assert_not_nil(state.json(FOLDER .. "/results/r19/done.json"))
		end)
	end)
end)

helpers.describe("field run: interrupted run and stale request", function()
	helpers.it("closes a run a reload cut short and drops a stale request", function()
		helpers.with_stub_scope(MODULES, function()
			local FieldRun = engine()
			local state = world()
			state.files[FOLDER .. "/running.json"] = '{"schema":1,"request_id":"r20"}'
			state.files[FOLDER .. "/request.json"] = '{"schema":1,"request_id":"r21","steps":["all"]}'
			started(FieldRun, state)
			local done = state.json(FOLDER .. "/results/r20/done.json")
			helpers.assert_eq(done.interrupted, true)
			helpers.assert_nil(state.files[FOLDER .. "/running.json"])
			helpers.assert_nil(state.files[FOLDER .. "/request.json"])
			state.advance(0)
			helpers.assert_eq(#state.calls, 0, "a stale request must not run")
		end)
	end)
end)

helpers.describe("field run: a reload during a run", function()
	helpers.it("holds reloads while it runs and closes a run teardown cuts short with its cause", function()
		helpers.with_stub_scope(MODULES, function()
			local FieldRun = engine()
			local state = world({ ollama_model = function() end })
			local ports = state.ports
			local ok = FieldRun.start({ root = "/repo", pid = 4242, ports = ports })
			helpers.assert_eq(ok, true)
			helpers.assert_eq(FieldRun.holds_reload(), false, "no run, no hold")
			state.request({ schema = 1, request_id = "r40", steps = Json.array({ "field_lease", "ollama_model" }) })
			state.advance(0)
			helpers.assert_eq(FieldRun.holds_reload(), true, "a running field run holds the auto reloads")
			helpers.assert_eq(FieldRun.stop({ kind = "reload", reason = "watcher" }), true)
			local done = state.json(FOLDER .. "/results/r40/done.json")
			helpers.assert_eq(done.interrupted, true)
			helpers.assert_eq(done.cause.kind, "reload")
			helpers.assert_eq(done.cause.reason, "watcher")
			helpers.assert_eq(done.cause.step, "ollama_model")
			helpers.assert_eq(done.verdicts.field_lease, "pass", "the steps already run are kept")
			helpers.assert_nil(state.files[FOLDER .. "/running.json"])
			helpers.assert_eq(FieldRun.holds_reload(), false)
			FieldRun._reset()
		end)
	end)
end)

helpers.describe("field run: pure helpers", function()
	helpers.it("finds the log lines written between two ring snapshots", function()
		helpers.with_stub_scope(MODULES, function()
			local FieldRun = engine()
			local lines, truncated = FieldRun.log_window({ "a", "b", "c" }, { "a", "b", "c", "d", "e" }, 10)
			helpers.assert_eq(table.concat(lines, ","), "d,e")
			helpers.assert_eq(truncated, false)
			-- The ring wrapped: the oldest lines fell out
			lines, truncated = FieldRun.log_window({ "a", "b", "c" }, { "c", "d" }, 10)
			helpers.assert_eq(table.concat(lines, ","), "d")
			helpers.assert_eq(truncated, false)
			lines, truncated = FieldRun.log_window({ "a" }, { "x", "y", "z" }, 2)
			helpers.assert_eq(table.concat(lines, ","), "y,z")
			helpers.assert_eq(truncated, true)
			lines = FieldRun.log_window({}, { "x" }, 5)
			helpers.assert_eq(table.concat(lines, ","), "x")
		end)
	end)

	helpers.it("picks the smallest pullable catalogue model per backend", function()
		helpers.with_stub_scope(MODULES, function()
			local FieldRun = engine()
			local catalogue = Json.decode(read(helpers.shared("modules/llm/models.json")))
			for _, backend in ipairs({ "ollama", "mlx" }) do
				local chosen = FieldRun.smallest_model(catalogue, backend)
				helpers.assert_not_nil(chosen, "no " .. backend .. " model")
				for _, provider in ipairs(catalogue) do
					for _, family in ipairs(provider.families) do
						for _, model in ipairs(family.models) do
							local url = model.urls and model.urls[backend] or ""
							local size = model.hardware_requirements and model.hardware_requirements[backend]
								and model.hardware_requirements[backend].download_gb
							local pullable = url ~= "" and (backend ~= "ollama" or url:find("ollama.com/library/", 1, true))
							if pullable and size then
								helpers.assert_true(size >= chosen.download_gb,
									model.name .. " is smaller than the chosen " .. chosen.name)
							end
						end
					end
				end
			end
			local ollama = FieldRun.smallest_model(catalogue, "ollama")
			helpers.assert_true(ollama.runtime_name ~= ollama.name, "an Ollama pull takes the library tag")
		end)
	end)
end)

helpers.describe("field run ports: configuration guard", function()
	helpers.it("puts back a changed file, removes a created one and restores a preference", function()
		local stubbed = { "infra.logger", "adapters.field_run_ports", "adapters.file_system", "adapters.storage",
			"infra.config_paths", "adapters.shell_runner", "adapters.timer_scheduler" }
		helpers.with_stub_scope(stubbed, function()
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			local files = { ["/cfg/config.toml"] = "a = 1\n" }
			local settings = { llm_backend = "ollama", keep = true }
			package.loaded["infra.config_paths"] = { get = function(key)
				return key == "ConfigTomlPath" and "/cfg/config.toml" or ("/cfg/" .. key)
			end }
			package.loaded["adapters.file_system"] = {
				read_with_status = function(path)
					if files[path] == nil then return nil, "absent" end
					return files[path], "ok"
				end,
				write = function(path, text) files[path] = text; return true end,
				delete = function(path) files[path] = nil; return true end,
			}
			package.loaded["adapters.storage"] = {
				keys = function()
					local keys = {}
					for key in pairs(settings) do keys[#keys + 1] = key end
					table.sort(keys)
					return keys
				end,
				get = function(key) return settings[key] end,
				set = function(key, value) settings[key] = value; return true end,
				delete = function(key) settings[key] = nil; return true end,
			}
			package.loaded["adapters.shell_runner"] = { exec = function() return "" end }
			package.loaded["adapters.timer_scheduler"] = { after = function() end, cancel = function() end }
			package.loaded["adapters.field_run_ports"] = nil
			local ports = require("adapters.field_run_ports").new("/repo")
			local snapshot = ports.config_snapshot()
			helpers.assert_eq(ports.config_restore(snapshot).restored[1], nil, "an untouched configuration restores nothing")
			files["/cfg/config.toml"] = "a = 2\n"
			files["/cfg/KarabinerConfigPath"] = "new"
			settings.llm_backend = "mlx"
			settings.added = 1
			local outcome = ports.config_restore(snapshot)
			helpers.assert_eq(files["/cfg/config.toml"], "a = 1\n")
			helpers.assert_nil(files["/cfg/KarabinerConfigPath"], "a file the run created is removed")
			helpers.assert_eq(settings.llm_backend, "ollama")
			helpers.assert_nil(settings.added, "a preference the run added is removed")
			helpers.assert_eq(settings.keep, true)
			helpers.assert_eq(table.concat(outcome.restored, ","),
				"ConfigTomlPath,KarabinerConfigPath,setting_added,setting_llm_backend")
			helpers.assert_eq(#outcome.failed, 0)
		end)
	end)
end)
