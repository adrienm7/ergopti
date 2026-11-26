--- tests/unit/core/network/adapters/test_managed_http_worker.lua

--- ==============================================================================
--- MODULE: Managed HTTP Worker Transport
--- DESCRIPTION:
--- The manual update check runs through the launcher's native HTTP worker
--- (UPD-13). The transport sends the worker its exact request on stdin, keeps
--- the binary frames out of hs.task's text stdout through a private file it
--- always removes, and answers once with the http_client result shape plus the
--- failed transfer's native receipt. A missing launcher refuses the request; it
--- never falls back to hs.http.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")

local LAUNCHER = "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus"
local OUTPUT = "/tmp/lua_worker_output"

local function frame(tag, payload)
	return string.pack(">I4", #payload + 1) .. string.char(tag) .. payload
end

--- Loads a fresh transport over recording seams. world: spawned, input,
--- removed, output (bytes the fake worker wrote), complete(exit_code).
local function load(world)
	package.loaded["core.network.adapters.managed_http_worker"] = nil
	local logger = package.loaded["core.logger.engine.logger"]
	package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
	local Worker = require("core.network.adapters.managed_http_worker")
	package.loaded["core.logger.engine.logger"] = logger
	world.removed = {}
	Worker._resolve = function() return world.launcher, "no launcher in this test" end
	Worker._tmpname = function() return OUTPUT end
	Worker._read = function(path)
		helpers.assert_eq(path, OUTPUT)
		return world.output
	end
	Worker._remove = function(path) world.removed[#world.removed + 1] = path; return true end
	Worker._spawn = function(executable, args, on_done, on_chunk, environment, private)
		world.spawned = { executable = executable, args = args, on_chunk = on_chunk, environment = environment,
			private = private }
		world.complete = on_done
		return {
			isSettled = function() return false end,
			set_input = function(input) world.input = input; return true end,
			start = function() return world.start_refused ~= true end,
			terminate = function() world.terminated = true; return true end,
		}
	end
	return Worker
end

helpers.describe("managed_http_worker: the manual check's native transport (upd-13)", function()
	helpers.it("runs the launcher's worker role with its bounds and an identity request", function()
		local world = { launcher = LAUNCHER }
		local client = load(world).new({ timeout_sec = 15 })
		helpers.assert_true(client.get("https://api.github.com/repos/o/r/releases", { Accept = "application/json" },
			function() end))
		helpers.assert_eq(world.spawned.executable, "/bin/sh")
		helpers.assert_eq(world.spawned.args, { "-c", 'exec "$1" "$2" "$3" "$4" > "$5"', "managed-http-worker",
			LAUNCHER, "--managed-http-worker", "15", "15", OUTPUT })
		helpers.assert_eq(world.spawned.private, true, "the request is never logged")
		local request = Json.decode(world.input)
		helpers.assert_eq(request.headers, { { "Accept", "application/json" }, { "Accept-Encoding", "identity" } })
		helpers.assert_eq(request.timeout, 15)
		helpers.assert_eq(request.idle_timeout, 15)
		helpers.assert_eq(request.direct, false)
	end)

	helpers.it("answers with the failed transfer's receipt and removes the output", function()
		local world = { launcher = LAUNCHER }
		local Worker = load(world)
		local results = {}
		Worker.new({ timeout_sec = 15 }).get("https://api.github.com/", nil, function(r) results[#results + 1] = r end)
		world.output = frame(67, '{"version":1,"success":false,"reason":"certificate"}')
		world.complete(74, "", "")
		world.complete(74, "", "")
		helpers.assert_eq(#results, 1, "one answer")
		helpers.assert_eq(results[1].status, 0)
		helpers.assert_eq(results[1].failure_receipt.tls_status, "untrusted_certificate")
		helpers.assert_eq(world.removed, { OUTPUT })
	end)

	helpers.it("an unreadable output is a failure with no receipt", function()
		local world = { launcher = LAUNCHER }
		local results = {}
		load(world).new({ timeout_sec = 15 }).get("https://api.github.com/", nil, function(r) results[#results + 1] = r end)
		world.output = nil
		world.complete(75, "", "")
		helpers.assert_eq(results[1].ok, false)
		helpers.assert_eq(results[1].status, 0)
		helpers.assert_nil(results[1].failure_receipt)
		helpers.assert_eq(world.removed, { OUTPUT })
	end)

	helpers.it("refuses without a launcher instead of falling back to hs.http", function()
		local world = {}
		local called = false
		local sent = load(world).new({ timeout_sec = 15 }).get("https://api.github.com/", nil,
			function() called = true end)
		helpers.assert_eq(sent, false)
		helpers.assert_nil(world.spawned)
		helpers.assert_eq(called, false)
	end)

	helpers.it("a worker that cannot start is refused, its output removed and its late exit inert", function()
		local world = { launcher = LAUNCHER, start_refused = true }
		local called = false
		local sent = load(world).new({ timeout_sec = 15 }).get("https://api.github.com/", nil,
			function() called = true end)
		helpers.assert_eq(sent, false)
		helpers.assert_eq(world.removed, { OUTPUT })
		world.complete(74, "", "")
		helpers.assert_eq(called, false)
	end)

	helpers.it("refuses a caller's own content coding and a fractional bound", function()
		local world = { launcher = LAUNCHER }
		local Worker = load(world)
		helpers.assert_eq(Worker.new({ timeout_sec = 15 }).get("https://api.github.com/",
			{ ["accept-encoding"] = "gzip" }, function() end), false)
		helpers.assert_nil(world.spawned)
		helpers.assert_eq(pcall(Worker.new, { timeout_sec = 1.5 }), false)
	end)
end)
