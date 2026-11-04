--- tests/unit/infra/field_check/test_field_check_launcher_roles.lua

--- ==============================================================================
--- MODULE: Field Run Launcher Roles Probe
--- DESCRIPTION:
--- The field run's launcher roles check over scripted ports:
--- 1. the HTTP worker role must refuse malformed arguments with EX_USAGE; a
---    timeout or any other exit fails it (the role did not dispatch);
--- 2. the loopback request is the exact request native_http.py sends, with
---    the budget and idle bound the worker's arguments repeat, and it passes
---    only when the worker exits 0 and the loopback server saw it once;
--- 3. an exit 64 (the 2026-10-30 field run's native_child_status), a refusal
---    stage, a request that never arrived and a server that cannot bind are
---    each named, and the server is always stopped.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "infra.logger", "infra.field_check", "infra.field_check_checks", "infra.field_check_probes" }

local LAUNCHER = "/Users/someone/ergopti/build/macos/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus"

--- Builds scripted ports; `world` records every command.
--- @return table ports, table world
local function make_ports()
	local world = {
		commands = {},
		usage_exit = 64,
		worker = { exit = 0, stdout = '\0\0\0\44H{"version":1,"status":204,"headers":[]}', hits = 1 },
		server_ok = true,
		stopped = 0,
		environment = { ERGOPTI = "1" },
	}
	local ports = {
		launcher = function()
			if world.launcher_missing then return nil end
			return LAUNCHER, world.environment
		end,
		exec = function(executable, args, timeout_s, callback, environment)
			world.commands[#world.commands + 1] = { key = executable .. " " .. table.concat(args, " "),
				environment = environment }
			callback(world.usage_exit, "", "")
		end,
		loopback_server = function(path, callback)
			world.path = path
			if not world.server_ok then return callback(nil) end
			local hits = 0
			world.server = {
				port = 51234,
				hits = function() return hits end,
				stop = function() world.stopped = world.stopped + 1 end,
			}
			world.arrive = function(count) hits = count end
			callback(world.server)
		end,
		exec_input = function(executable, args, input, timeout_s, callback, environment)
			world.worker_call = { key = executable .. " " .. table.concat(args, " "), input = input,
				environment = environment, timeout = timeout_s }
			world.arrive(world.worker.hits)
			callback(world.worker.exit, world.worker.stdout, "")
		end,
	}
	return ports, world
end

--- Runs the check and returns its steps keyed by id.
--- @param ports table Ports.
--- @return table steps, table result
local function run(ports)
	local result
	helpers.with_stub_scope(MODULES, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.field_check"] = nil
		package.loaded["infra.field_check_checks"] = nil
		package.loaded["infra.field_check_probes"] = nil
		local Engine = require("infra.field_check")
		assert(Engine.run("launcher_roles", ports, function(done) result = done end), "check did not start")
	end)
	helpers.assert_not_nil(result, "the check never finished")
	local steps = {}
	for _, step in ipairs(result.steps) do steps[step.id] = step end
	return steps, result
end

helpers.describe("launcher roles probe", function()
	helpers.it("passes a dispatching role and a loopback request the server received once", function()
		local ports, world = make_ports()
		local steps, result = run(ports)
		helpers.assert_true(result.passed)
		helpers.assert_eq(steps.launcher_present.value, "yes")
		helpers.assert_eq(steps.http_worker_usage.value, "usage_refused")
		helpers.assert_eq(steps.http_worker_loopback.value, "http_204")
		helpers.assert_eq(steps.http_worker_request.value, "args_4:bytes_" .. #world.worker_call.input,
			"the worker's own argument count includes the executable")
		helpers.assert_eq(world.commands[1].key, LAUNCHER .. " --managed-http-worker")
		helpers.assert_eq(world.commands[1].environment, world.environment, "the launcher's own environment")
		helpers.assert_eq(world.worker_call.key, LAUNCHER .. " --managed-http-worker 5 5")
		helpers.assert_eq(world.worker_call.environment, world.environment)
		helpers.assert_eq(world.stopped, 1, "the loopback server must be stopped")
	end)

	helpers.it("sends exactly the request the worker admits", function()
		local ports, world = make_ports()
		run(ports)
		local request = require("json").decode(world.worker_call.input)
		local keys = {}
		for key in pairs(request) do keys[#keys + 1] = key end
		table.sort(keys)
		helpers.assert_eq(table.concat(keys, ","), "direct,headers,idle_timeout,method,timeout,url,version")
		helpers.assert_eq(request.url, "http://127.0.0.1:51234" .. world.path)
		helpers.assert_eq(request.method, "GET")
		helpers.assert_eq(request.timeout, 5)
		helpers.assert_eq(request.idle_timeout, 5)
		helpers.assert_eq(request.direct, true)
		helpers.assert_eq(#request.headers, 0)
		helpers.assert_true(world.worker_call.input:find('"headers":[]', 1, true) ~= nil,
			"headers must encode as an array, which the worker requires")
	end)

	helpers.it("fails a role that does not dispatch, by exit or timeout", function()
		local ports, world = make_ports()
		world.usage_exit = 137
		local steps, result = run(ports)
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.http_worker_usage.value, "exit_137")
		world.usage_exit = nil
		helpers.assert_eq(run(ports).http_worker_usage.value, "timeout")
	end)

	helpers.it("names an exit 64 that never reached the server, and a refusal stage", function()
		local ports, world = make_ports()
		world.worker = { exit = 64, stdout = "", hits = 0 }
		local steps, result = run(ports)
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.http_worker_loopback.value, "exit_64:not_reached")
		helpers.assert_eq(world.stopped, 1)
		world.worker = { exit = 78, hits = 0,
			stdout = '\0\0\0\90C{"version":1,"success":false,"reason":"unavailable","native_refusal_stage":"native_policy_load"}' }
		helpers.assert_eq(run(ports).http_worker_loopback.value, "exit_78:native_policy_load")
		world.worker = { exit = nil, stdout = "", hits = 1 }
		helpers.assert_eq(run(ports).http_worker_loopback.value, "timeout:hits_1")
	end)

	helpers.it("fails a server that cannot bind and a launcher that does not resolve", function()
		local ports, world = make_ports()
		world.server_ok = false
		helpers.assert_eq(run(ports).http_worker_loopback.value, "server_refused")
		world.server_ok = true
		world.launcher_missing = true
		local steps, result = run(ports)
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.launcher_present.value, "unresolved")
		helpers.assert_eq(steps.http_worker_loopback.state, "skip")
	end)
end)
