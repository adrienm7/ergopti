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
--- guard, and a run cut short is closed as interrupted. Files and timers are in
--- memory; the checks are doubles.
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
	local w = { files = {}, dirs = {}, timers = {}, now = 0, checks = {}, config = options.config or "a = 1\n" }
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
	local session = FieldRun.new({ spec = options and options.spec or shipped(), folder = FOLDER, pid = 4242, ports = w.ports })
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
		helpers.assert_eq(ready.steps, { "field_composer", "field_network" })
	end)

	helpers.it("runs every step headless, writes one result each, the guard and the done marker", function()
		local failing = { check = "network", passed = false,
			steps = { { id = "proxy_settings", state = "info", value = "none" }, { id = "tls", state = "fail", value = "untrusted" } } }
		local _, w = started({ checks = { network = failing } })
		w.request('{"schema":1,"request_id":"r1","steps":["all"]}')
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
