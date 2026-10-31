--- tests/unit/infra/control/test_field_run.lua

--- ==============================================================================
--- MODULE: Field Run (Linux) Tests
--- DESCRIPTION:
--- The collector's no-click request protocol: the declaration is read from the
--- shared _shared/data/field_run_protocol.json and the Linux steps file it names,
--- with no protocol key repeated; a changed shared rule stops the module; a
--- request runs every step once and writes one result each, then the
--- configuration guard and the done marker, every document with the keys the
--- shared declaration lists; each refusal has its declared reason; a check that never answers
--- times out, one a person is running is skipped, a changed config.toml fails the
--- guard, and a run cut short is closed as interrupted. The timed reload step
--- suspends its run at the daemon's stop and the successor daemon resumes it,
--- naming the reload's duration; a reload refused or never started fails by
--- name, and a restart that leaves no usable resume file closes the run as
--- interrupted. Files and timers are in memory; the checks and the reload owner
--- are doubles.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local FieldRun = require("infra.field_run")

local FOLDER = "/run/user/1000/ergopti_plus/field-run"

local function read_json(path)
	local handle = assert(io.open(path, "rb"))
	local text = handle:read("*a")
	handle:close()
	return Json.decode(text)
end

local function shared_root() return helpers.driver_root() .. "/../_shared" end
local function protocol() return read_json(shared_root() .. "/" .. FieldRun.PROTOCOL_PATH) end
local function linux_steps() return read_json(helpers.driver_root() .. "/data/field_run_steps.json") end

local function shipped()
	return FieldRun.load(shared_root(), helpers.driver_root())
end

--- Every key the shared declaration lists for a document kind is in the document.
local function assert_document(kind, document, may_lack)
	for _, key in ipairs(protocol().documents[kind]) do
		if key ~= may_lack then helpers.assert_true(document[key] ~= nil, kind .. " carries " .. key) end
	end
end

--- An in-memory world: files, a folder watcher, manual timers and check doubles.
local function world(options)
	options = options or {}
	-- A successor daemon shares its predecessor's files: options.files.
	local w = { files = options.files or {}, dirs = {}, timers = {}, now = options.now or 0, checks = {},
		config = options.config or "a = 1\n", reloads = {} }
	local next_id = 0
	w.ports = {
		read = function(path) return w.files[path] end,
		write = function(path, text) w.files[path] = text; return true end,
		remove = function(path) w.files[path] = nil; return true end,
		exists = function(path) return w.files[path] ~= nil or w.dirs[path] == true end,
		make_dir = function(path) w.dirs[path] = true; return true end,
		watch = function(_, on_change) w.on_change = on_change; return { close = function() w.watch_closed = true; return true end } end,
		after = function(ms, fn)
			next_id = next_id + 1
			local handle = { id = next_id, at = w.now + ms, fn = fn }
			w.timers[handle] = true
			return handle
		end,
		cancel = function(handle) w.timers[handle] = nil end,
		now_ms = function() return w.now end,
		iso_now = function() return "2026-10-31T00:00:00Z" end,
		config_bytes = function() return w.config end,
		reload = function(trigger)
			w.reloads[#w.reloads + 1] = trigger
			if options.reload then return options.reload(trigger) end
			return true
		end,
		run_check = function(check, on_result)
			w.checks[#w.checks + 1] = check
			local answer = options.checks and options.checks[check]
			if answer == "busy" then return false end
			if answer == "silent" then return true end
			on_result(answer or { check = check, passed = true, steps = { { id = "only", state = "pass", value = "ok" } } })
			return true
		end,
	}
	--- Runs every timer due by now, earliest first, until none is left due.
	function w.flush(advance_ms)
		w.now = w.now + (advance_ms or 0)
		while true do
			local due
			for handle in pairs(w.timers) do
				if handle.at <= w.now and (due == nil or handle.id < due.id) then due = handle end
			end
			if not due then return end
			w.timers[due] = nil
			due.fn()
		end
	end
	function w.request(text)
		w.files[FOLDER .. "/request.json"] = text
		w.on_change("request.json")
		w.flush()
	end
	function w.json(name) return w.files[FOLDER .. "/" .. name] and Json.decode(w.files[FOLDER .. "/" .. name]) end
	return w
end

local function started(options)
	local w = world(options)
	local session = FieldRun.new({ spec = options and options.spec or shipped(), folder = FOLDER,
		pid = options and options.pid or 4242, ports = w.ports, reload_ms = options and options.reload_ms })
	session:start()
	return session, w
end

helpers.describe("Linux field run (linux-field-run)", function()
	helpers.it("reads the protocol from the shared declaration and repeats none of it", function()
		local shared, spec = protocol(), shipped()
		for key, name in pairs(spec.files) do helpers.assert_eq(name, shared.files[key], "files." .. key) end
		for _, verdict in ipairs(shared.verdicts) do helpers.assert_true(spec.verdict_set[verdict], verdict) end
		for _, reason in ipairs(shared.reasons) do helpers.assert_true(spec.reason_set[reason], reason) end
		helpers.assert_eq(spec.max_request_bytes, shared.max_request_bytes)
		helpers.assert_eq(FieldRun.steps_relative(shared.steps_file.linux), "data/field_run_steps.json")
		-- The installed folder's application segment is the one every Linux folder uses.
		helpers.assert_eq(shared.folder.linux.segments[1], require("app_dirs").folder_name)
		for key in pairs(linux_steps()) do
			helpers.assert_true(shared[key] == nil or key == "_comment",
				"the Linux steps file repeats the shared key " .. key)
		end
	end)

	helpers.it("stops at a shared rule it cannot enforce exactly", function()
		for key, value in pairs({ request_id_pattern = "^[A-Za-z0-9]+$", code_pattern = "^.{1,64}$",
			result_file_pattern = "^[0-9]{3}_[a-z0-9_]{1,64}\\.json$", step_kinds = { "diagnostics" } }) do
			local changed = protocol()
			changed[key] = value
			local ok, err = pcall(FieldRun.declaration, changed, linux_steps())
			helpers.assert_eq(ok, false, key)
			helpers.assert_true(tostring(err):find("field run:", 1, true) ~= nil, tostring(err))
		end
		local id = protocol()
		id.request_id_pattern = "^[A-Za-z0-9_-]{1,8}$"
		local spec = FieldRun.declaration(id, linux_steps())
		helpers.assert_eq({ spec.is_request_id("abc-_9"), spec.is_request_id("123456789"), spec.is_request_id("a b") },
			{ true, false, false })
	end)

	helpers.it("publishes its readiness with the Linux steps", function()
		local _, w = started()
		local ready = w.json("ready.json")
		helpers.assert_eq(ready.driver, "linux")
		helpers.assert_eq(ready.pid, 4242)
		helpers.assert_eq(ready.steps, { "field_composer", "field_network", "driver_reload" })
	end)

	helpers.it("runs every step headless, writes one result each, the guard and the done marker", function()
		local failing = { check = "network", passed = false,
			steps = { { id = "proxy_settings", state = "info", value = "none" }, { id = "tls", state = "fail", value = "untrusted" } } }
		local _, w = started({ checks = { network = failing } })
		w.request('{"schema":1,"request_id":"r1","steps":["field_network","field_composer"]}')
		helpers.assert_eq(w.files[FOLDER .. "/request.json"], nil, "the request is consumed")
		helpers.assert_eq(w.checks, { "composer", "network" }, "each check ran once, in order")
		local dir = "results/r1/"
		helpers.assert_eq(w.json(dir .. "accepted.json").steps, { "field_composer", "field_network" })
		local composer, network = w.json(dir .. "01_field_composer.json"), w.json(dir .. "02_field_network.json")
		helpers.assert_eq({ composer.verdict, composer.step, composer.kind }, { "pass", "field_composer", "field_check" })
		helpers.assert_eq({ network.verdict, network.codes }, { "fail", { "fail_tls" } })
		helpers.assert_eq(network.report.check, "network", "the check's own report travels")
		helpers.assert_eq(w.json(dir .. "03_config_guard.json").verdict, "pass")
		local done = w.json(dir .. "done.json")
		helpers.assert_eq({ done.interrupted, done.order }, { false, { "field_composer", "field_network", "config_guard" } })
		helpers.assert_eq(done.counts, { pass = 2, fail = 1 })
		helpers.assert_eq(w.files[FOLDER .. "/running.json"], nil)
		assert_document("ready", w.json("ready.json"))
		assert_document("accepted", w.json(dir .. "accepted.json"))
		for _, name in ipairs({ "01_field_composer.json", "02_field_network.json", "03_config_guard.json" }) do
			assert_document("result", w.json(dir .. name))
		end
		assert_document("done", done)
	end)

	helpers.it("refuses each bad request with its declared reason", function()
		local _, w = started()
		for _, case in ipairs({
			{ "not json", "malformed", nil },
			{ '{"schema":1,"request_id":"r2","steps":["field_typing"]}', "unknown_step", "r2" },
			{ '{"schema":1,"request_id":"r3","steps":["all"],"deadline_seconds":5}', "bad_deadline", "r3" },
			{ '{"schema":1,"request_id":"r4","steps":["all"],"extra":1}', "malformed", "r4" },
		}) do
			w.request(case[1])
			local refused = w.json("refused.json")
			helpers.assert_eq({ refused.reason, refused.request_id }, { case[2], case[3] }, case[1])
			-- A request with no valid identifier is refused without one, as on macOS.
			assert_document("refused", refused, case[3] == nil and "request_id" or nil)
		end
		helpers.assert_eq(#w.checks, 0, "nothing ran")
		w.request('{"schema":1,"request_id":"r5","steps":["field_network"]}')
		w.request('{"schema":1,"request_id":"r5","steps":["field_network"]}')
		helpers.assert_eq(w.json("refused.json").reason, "duplicate_request")
	end)

	helpers.it("refuses a second request while a run is open", function()
		local _, w = started({ checks = { composer = "silent" } })
		w.request('{"schema":1,"request_id":"a","steps":["all"]}')
		w.request('{"schema":1,"request_id":"b","steps":["all"]}')
		helpers.assert_eq({ w.json("refused.json").reason, w.json("refused.json").request_id }, { "busy", "b" })
	end)

	helpers.it("times a silent check out at its deadline and drops its late answer", function()
		local _, w = started({ checks = { composer = "silent" } })
		w.request('{"schema":1,"request_id":"t","steps":["field_composer"]}')
		helpers.assert_eq(w.json("results/t/done.json"), nil, "the run waits for the check")
		w.flush(120000)
		local result = w.json("results/t/01_field_composer.json")
		helpers.assert_eq({ result.verdict, result.codes }, { "timeout", { "deadline_120s" } })
		helpers.assert_eq(w.json("results/t/done.json").interrupted, false)
	end)

	helpers.it("writes only codes the shared code rule admits", function()
		-- The shared rule governs, even when it is narrower than the report sanitizer.
		local narrow = protocol()
		narrow.code_pattern = "^[a-z_]{1,64}$"
		local failing = { check = "network", passed = false, steps = { { id = "TLS", state = "fail", value = "v" },
			{ id = "tls", state = "fail", value = "untrusted" } } }
		local _, w = started({ checks = { network = failing }, spec = FieldRun.declaration(narrow, linux_steps()) })
		w.request('{"schema":1,"request_id":"c","steps":["field_network"]}')
		helpers.assert_eq(w.json("results/c/01_field_network.json").codes, { "unsafe_code", "fail_tls" })
	end)

	helpers.it("skips a check a person is running instead of running it twice", function()
		local _, w = started({ checks = { network = "busy" } })
		w.request('{"schema":1,"request_id":"s","steps":["field_network"]}')
		local result = w.json("results/s/01_field_network.json")
		helpers.assert_eq({ result.verdict, result.codes }, { "skip", { "check_busy" } })
	end)

	helpers.it("fails the guard when a step changed config.toml", function()
		local session, w = started()
		w.ports.run_check = function(_, on_result)
			w.config = "a = 2\n"
			on_result({ check = "composer", passed = true, steps = {} })
			return true
		end
		w.request('{"schema":1,"request_id":"g","steps":["field_composer"]}')
		local guard = w.json("results/g/02_config_guard.json")
		helpers.assert_eq({ guard.verdict, guard.codes }, { "fail", { "changed_config_toml" } })
		helpers.assert_true(session.run == nil)
	end)

	helpers.it("closes a run cut short, at stop and at the next start", function()
		local session, w = started({ checks = { composer = "silent" } })
		w.request('{"schema":1,"request_id":"i","steps":["all"]}')
		helpers.assert_true(session:stop())
		local done = w.json("results/i/done.json")
		helpers.assert_eq({ done.interrupted, done.cause.step }, { true, "field_composer" })
		assert_document("done", done)
		helpers.assert_eq(w.files[FOLDER .. "/ready.json"], nil, "the readiness is withdrawn")
		helpers.assert_true(w.watch_closed)
		-- A daemon killed mid-run leaves its running marker: the next start closes it.
		local second = world()
		second.files[FOLDER .. "/running.json"] = '{"schema":1,"request_id":"k"}'
		FieldRun.new({ spec = shipped(), folder = FOLDER, pid = 7, ports = second.ports }):start()
		helpers.assert_eq(second.json("results/k/done.json").interrupted, true)
		assert_document("done", second.json("results/k/done.json"))
		helpers.assert_eq(second.files[FOLDER .. "/running.json"], nil)
	end)

	--- Runs every step up to the timed reload, then stops the daemon as the restart does.
	local function reloaded_daemon(options)
		local session, w = started(options)
		w.request('{"schema":1,"request_id":"rl","steps":["all"]}')
		return session, w
	end

	--- The successor daemon on the predecessor's files.
	local function successor(w, options)
		options = options or {}
		options.files, options.pid, options.now = w.files, 5151, 0
		local session, next_world = started(options)
		next_world.flush()
		return session, next_world
	end

	helpers.it("resumes a run in the successor daemon after its timed reload", function()
		local session, w = reloaded_daemon()
		helpers.assert_eq(w.reloads, { FieldRun.RELOAD_TRIGGER }, "the reload owner was asked once")
		local resume = w.json("resume.json")
		assert_document("resume", resume)
		helpers.assert_eq({ resume.index, resume.step, resume.steps, resume.order, resume.codes },
			{ 3, "driver_reload", { "field_composer", "field_network", "driver_reload" },
				{ "field_composer", "field_network" }, {} })
		helpers.assert_eq(w.json("results/rl/done.json"), nil, "the run waits for its restart")
		helpers.assert_true(session:stop())
		helpers.assert_eq(w.json("results/rl/done.json"), nil, "the stop suspends the run instead of closing it")
		helpers.assert_eq(w.json("running.json").request_id, "rl", "the running marker stays for the successor")
		helpers.assert_eq(w.files[FOLDER .. "/ready.json"], nil)

		local _, next_world = successor(w, { reload_ms = 850 })
		helpers.assert_eq(next_world.checks, {}, "no check before the reload runs twice")
		helpers.assert_eq(next_world.files[FOLDER .. "/resume.json"], nil, "the resume file is read once")
		local reload = next_world.json("results/rl/03_driver_reload.json")
		assert_document("result", reload)
		helpers.assert_eq({ reload.kind, reload.verdict, reload.codes, reload.elapsed_ms, reload.report.reload_ms },
			{ "reload", "pass", { "reloaded" }, 850, 850 })
		helpers.assert_eq(next_world.json("results/rl/04_config_guard.json").verdict, "pass")
		local done = next_world.json("results/rl/done.json")
		assert_document("done", done)
		helpers.assert_eq({ done.interrupted, done.pid, done.order },
			{ false, 5151, { "field_composer", "field_network", "driver_reload", "config_guard" } })
		helpers.assert_eq(done.counts, { pass = 4 })
		helpers.assert_eq(next_world.files[FOLDER .. "/running.json"], nil)
		helpers.assert_eq(next_world.json("ready.json").pid, 5151, "the successor publishes its own readiness")
	end)

	helpers.it("fails the resumed reload step for a change before it or an unmeasured reload", function()
		local session, w = reloaded_daemon()
		helpers.assert_true(session:stop())
		local _, unmeasured = successor(w, { config = "a = 2\n" })
		local reload = unmeasured.json("results/rl/03_driver_reload.json")
		helpers.assert_eq({ reload.verdict, reload.codes }, { "fail", { "reloaded", "reload_unmeasured" } })
		helpers.assert_eq(unmeasured.json("results/rl/04_config_guard.json").verdict, "pass",
			"the guard compares with a snapshot taken after the restart")

		local changed = world()
		local first = FieldRun.new({ spec = shipped(), folder = FOLDER, pid = 1, ports = changed.ports })
		first:start()
		changed.ports.run_check = function(check, on_result)
			changed.config = "a = 3\n"
			on_result({ check = check, passed = true, steps = {} })
			return true
		end
		changed.request('{"schema":1,"request_id":"cc","steps":["field_composer","driver_reload"]}')
		-- The change is named before the restart: the snapshot does not survive it.
		helpers.assert_eq(changed.json("resume.json").codes, { "changed_config_toml" })
		helpers.assert_true(first:stop())
		local _, after = successor(changed, { reload_ms = 10, config = "a = 3\n" })
		local step = after.json("results/cc/02_driver_reload.json")
		helpers.assert_eq({ step.verdict, step.codes }, { "fail", { "reloaded", "changed_config_toml" } })
	end)

	helpers.it("fails the reload step by name when the reload is refused or never starts", function()
		local _, w = reloaded_daemon({ reload = function() return false, "postponed" end })
		local refused = w.json("results/rl/03_driver_reload.json")
		helpers.assert_eq({ refused.verdict, refused.codes }, { "fail", { "reload_refused", "reload_postponed" } })
		helpers.assert_eq(w.files[FOLDER .. "/resume.json"], nil, "a refused reload leaves no resume file")
		helpers.assert_eq(w.json("results/rl/done.json").order,
			{ "field_composer", "field_network", "driver_reload", "config_guard" })

		local _, raised = reloaded_daemon({ reload = function() error("no restart") end })
		helpers.assert_eq(raised.json("results/rl/03_driver_reload.json").codes, { "reload_refused" })

		local _, silent = reloaded_daemon()
		helpers.assert_eq(silent.json("results/rl/done.json"), nil)
		silent.flush(60000)
		local never = silent.json("results/rl/03_driver_reload.json")
		helpers.assert_eq({ never.verdict, never.codes }, { "timeout", { "reload_not_started" } })
		helpers.assert_eq(silent.files[FOLDER .. "/resume.json"], nil)
		helpers.assert_eq(silent.json("results/rl/done.json").interrupted, false)
	end)

	helpers.it("closes as interrupted a run whose restart left no usable resume file", function()
		for _, case in ipairs({
			{ "missing", nil, "restart" },
			{ "not json", "{", nil },
			{ "foreign run", '{"schema":1,"request_id":"other","index":3,"step":"driver_reload",'
				.. '"steps":["field_composer","field_network","driver_reload"],"deadline_seconds":300,'
				.. '"started_at":"x","elapsed_ms":1,"verdicts":{},"order":[],"codes":[]}', "restart" },
			{ "index off the reload step", '{"schema":1,"request_id":"rl","index":1,"step":"driver_reload",'
				.. '"steps":["field_composer","field_network","driver_reload"],"deadline_seconds":300,'
				.. '"started_at":"x","elapsed_ms":1,"verdicts":{},"order":[],"codes":[]}', "resume_unusable" },
			{ "undeclared verdict", '{"schema":1,"request_id":"rl","index":3,"step":"driver_reload",'
				.. '"steps":["field_composer","field_network","driver_reload"],"deadline_seconds":300,'
				.. '"started_at":"x","elapsed_ms":1,"verdicts":{"field_composer":"great"},"order":[],"codes":[]}',
				"resume_unusable" },
		}) do
			local session, w = reloaded_daemon()
			helpers.assert_true(session:stop())
			w.files[FOLDER .. "/resume.json"] = case[2]
			local _, next_world = successor(w, { reload_ms = 5 })
			local done = next_world.json("results/rl/done.json")
			helpers.assert_eq(done.interrupted, true, case[1])
			assert_document("done", done)
			if case[3] then helpers.assert_eq(done.cause.kind, case[3], case[1]) end
			helpers.assert_eq(next_world.json("results/rl/03_driver_reload.json"), nil, case[1] .. ": nothing resumed")
			helpers.assert_eq(next_world.files[FOLDER .. "/running.json"], nil, case[1])
			helpers.assert_eq(next_world.files[FOLDER .. "/resume.json"], nil, case[1])
		end
	end)

	helpers.it("rejects a reload step that names a check, and a check step that names none", function()
		for _, change in ipairs({
			function(steps) steps.steps[3].check = "composer" end,
			function(steps) steps.steps[1].check = nil end,
			function(steps) steps.steps[3].kind = "diagnostics" end,
		}) do
			local steps = linux_steps()
			change(steps)
			helpers.assert_eq(pcall(FieldRun.declaration, protocol(), steps), false)
		end
		helpers.assert_eq(shipped().step_by_id.driver_reload.kind, "reload")
	end)

	helpers.it("names the clone folder for a developer run, else the user's runtime folder", function()
		local spec = shipped()
		helpers.assert_eq(FieldRun.folder(spec, function() error("not read") end, "/src/ergopti"),
			"/src/ergopti/" .. protocol().folder.clone)
		helpers.assert_eq(FieldRun.folder(spec, function() return "/run/user/1000/" end, nil), FOLDER)
		local folder, why = FieldRun.folder(spec, function() return nil end, nil)
		helpers.assert_nil(folder)
		helpers.assert_true(why:find("XDG_RUNTIME_DIR", 1, true) ~= nil)
	end)
end)
