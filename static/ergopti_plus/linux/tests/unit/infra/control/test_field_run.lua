--- tests/unit/infra/control/test_field_run.lua

--- ==============================================================================
--- MODULE: Field Run (Linux) Tests
--- DESCRIPTION:
--- The collector's no-click request protocol: the shipped declaration keeps the
--- macOS protocol (file names, verdicts, refusal reasons), a request runs every
--- step once and writes one result each, then the configuration guard and the
--- done marker; each refusal has its declared reason; a check that never answers
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

local function shipped()
	return FieldRun.validate(read_json(helpers.driver_root() .. "/data/field_run.json"))
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
	local session = FieldRun.new({ spec = shipped(), folder = FOLDER, pid = 4242, ports = w.ports })
	session:start()
	return session, w
end

helpers.describe("Linux field run (linux-field-run)", function()
	helpers.it("keeps the macOS protocol: file names, verdicts and refusal reasons", function()
		local linux = shipped()
		local macos = read_json(helpers.driver_root() .. "/../macos/data/field_run.json")
		for key, name in pairs(linux.files) do
			helpers.assert_eq(name, macos.files[key], "files." .. key)
		end
		helpers.assert_eq(linux.verdicts, macos.verdicts)
		helpers.assert_eq(linux.reasons, macos.reasons)
		helpers.assert_eq(linux.request_id_pattern, macos.request_id_pattern)
		helpers.assert_eq(linux.max_request_bytes, macos.max_request_bytes)
		helpers.assert_eq(linux.guard_step, macos.guard_step)
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
		helpers.assert_eq(w.files[FOLDER .. "/ready.json"], nil, "the readiness is withdrawn")
		helpers.assert_true(w.watch_closed)
		-- A daemon killed mid-run leaves its running marker: the next start closes it.
		local second = world()
		second.files[FOLDER .. "/running.json"] = '{"schema":1,"request_id":"k"}'
		FieldRun.new({ spec = shipped(), folder = FOLDER, pid = 7, ports = second.ports }):start()
		helpers.assert_eq(second.json("results/k/done.json").interrupted, true)
		helpers.assert_eq(second.files[FOLDER .. "/running.json"], nil)
	end)

	helpers.it("names the folder in the user's runtime folder and refuses without one", function()
		local spec = shipped()
		helpers.assert_eq(FieldRun.folder(spec, function() return "/run/user/1000/" end, "ergopti_plus"), FOLDER)
		local folder, why = FieldRun.folder(spec, function() return nil end, "ergopti_plus")
		helpers.assert_nil(folder)
		helpers.assert_true(why:find("XDG_RUNTIME_DIR", 1, true) ~= nil)
	end)
end)
