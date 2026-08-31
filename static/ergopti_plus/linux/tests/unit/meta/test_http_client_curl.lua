--- tests/unit/meta/test_http_client_curl.lua

--- ==============================================================================
--- MODULE: Asynchronous HTTP Process Ownership
--- DESCRIPTION:
--- Drives the Linux HttpClient through a controllable libuv double. The tests
--- prove dispatch returns before output, timeout and cancel kill the detached
--- process group, and exactly one terminal callback survives late events.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Creates the minimum libuv process/pipe surface used by HttpClient.
--- @param config table|nil
--- @return table fake, table state
local function fake_luv(config)
	local options = config or {}
	local state = { kills = {}, handles = {}, requests = {} }
	local fake = {}

	local function handle(kind)
		local value = { kind = kind, closing = false }
		state.handles[#state.handles + 1] = value
		return value
	end

	function fake.new_pipe() return handle("pipe") end
	function fake.new_timer()
		state.timer = handle("timer")
		return state.timer
	end
	function fake.timer_start(timer, timeout_ms, repeat_ms, callback)
		if options.timer_failure then return nil, "timer refused" end
		timer.timeout_ms = timeout_ms
		timer.repeat_ms = repeat_ms
		timer.callback = callback
		return true
	end
	function fake.timer_stop(timer) timer.stopped = true; return true end
	function fake.read_start(pipe, callback) pipe.read_callback = callback; return true end
	function fake.read_stop(pipe) pipe.read_stopped = true; return true end
	function fake.is_closing(value) return value.closing end
	function fake.close(value) value.closing = true end
	function fake.kill(pid, signal)
		state.kills[#state.kills + 1] = { pid = pid, signal = signal }
		return true
	end
	function fake.spawn(command, options, callback)
		if config and config.spawn_failure then return nil, "EACCES", "permission denied" end
		local pid = 4320 + #state.requests + 1
		state.command = command
		state.options = options
		state.exit_callback = callback
		state.process = handle("process")
		state.requests[#state.requests + 1] = {
			options = options,
			exit_callback = callback,
			process = state.process,
			pid = pid,
		}
		return state.process, pid
	end

	function state.stdout(chunk) state.options.stdio[2].read_callback(nil, chunk) end
	function state.stderr(chunk) state.options.stdio[3].read_callback(nil, chunk) end
	function state.exit(code, signal) state.exit_callback(code or 0, signal or 0) end
	function state.complete(code)
		state.stdout(nil)
		state.stderr(nil)
		state.exit(code or 0)
	end
	function state.complete_request(index, stdout_text, code)
		local request = assert(state.requests[index], "unknown fake request")
		if stdout_text ~= nil then request.options.stdio[2].read_callback(nil, stdout_text) end
		request.options.stdio[2].read_callback(nil, nil)
		request.options.stdio[3].read_callback(nil, nil)
		request.exit_callback(code or 0, 0)
	end
	return fake, state
end

--- Loads a fresh client against one fake libuv instance.
--- @param config table|nil
--- @return table client, table state
local function fresh_client(config)
	local fake, state = fake_luv(config)
	local previous_luv = package.loaded["luv"]
	local previous_client = package.loaded["adapters.http_client"]
	package.loaded["luv"] = fake
	package.loaded["adapters.http_client"] = nil
	local client = require("adapters.http_client")
	package.loaded["luv"] = previous_luv
	package.loaded["adapters.http_client"] = previous_client
	return client, state
end

--- Loads a fresh file digest adapter against one fake libuv instance.
--- @param config table|nil
--- @return table digest, table state
local function fresh_digest(config)
	local fake, state = fake_luv(config)
	local previous_luv = package.loaded["luv"]
	local previous_digest = package.loaded["adapters.file_digest"]
	package.loaded["luv"] = fake
	package.loaded["adapters.file_digest"] = nil
	local digest = require("adapters.file_digest")
	package.loaded["luv"] = previous_luv
	package.loaded["adapters.file_digest"] = previous_digest
	return digest, state
end

helpers.describe("http_client: asynchronous curl ownership", function()
	helpers.it("keeps blocking process APIs out of the LLM transport path", function()
		local self_path = debug.getinfo(1, "S").source:gsub("^@", "")
		local driver_root = (self_path:match("^(.*)[/\\]tests[/\\]") or "."):gsub("\\", "/")
		local scanned = 0
		for _, relative in ipairs({ "adapters/http_client.lua", "modules/llm/api_ollama.lua" }) do
			local handle = assert(io.open(driver_root .. "/" .. relative, "r"))
			local source = handle:read("*a")
			handle:close()
			scanned = scanned + 1
			helpers.assert_true(source:find("io.popen", 1, true) == nil,
				relative .. " must never wait for curl on the keyboard event-loop thread")
		end
		helpers.assert_eq(scanned, 2, "both transport ownership layers must be inspected")
	end)

	helpers.it("exports the canonical port and streaming extension", function()
		local client = fresh_client()
		for _, name in ipairs({ "download", "get", "post", "postStream", "cancel", "isActive" }) do
			helpers.assert_eq(type(client[name]), "function", name .. " must be callable")
		end
		helpers.assert_true(client.HAS_ASYNC)
	end)

	helpers.it("downloads to a bounded caller-owned file without buffering the archive", function()
		local client, state = fresh_client()
		local result = nil
		local dispatched = client.download("https://example.invalid/release.tar.gz", {},
			"/tmp/release.part", {
				owner = "updater",
				https_only = true,
				max_download_bytes = 1048576,
			}, function(value) result = value end)
		helpers.assert_true(dispatched)
		local joined = "\n" .. table.concat(state.options.args, "\n") .. "\n"
		helpers.assert_true(joined:find("\n--output\n/tmp/release.part\n", 1, true) ~= nil)
		helpers.assert_true(joined:find("\n--max-filesize\n1048576\n", 1, true) ~= nil)
		state.complete_request(1, "\nERGOPTI_HTTP_STATUS:200\n")
		helpers.assert_true(result.ok)
		helpers.assert_eq(result.body, "")
	end)

	helpers.it("dispatches a bounded conditional HTTPS GET without a request body", function()
		local client, state = fresh_client()
		local result = nil
		local options = {
			timeout_ms = 1200,
			max_body_bytes = 1024,
			follow_redirects = true,
			https_only = true,
			etag_compare = "/tmp/etag-in",
			etag_save = "/tmp/etag-out",
		}
		local dispatched = client.get("https://api.github.com/releases", {
			Accept = "application/json",
		}, options, function(value) result = value end)
		helpers.assert_true(dispatched)
		helpers.assert_eq(result, nil, "GET must return before response bytes arrive")
		helpers.assert_eq(options.method, nil, "the caller's options must not be mutated")
		local joined = "\n" .. table.concat(state.options.args, "\n") .. "\n"
		helpers.assert_true(joined:find("\nGET\n", 1, true) ~= nil)
		helpers.assert_true(joined:find("\n--location\n", 1, true) ~= nil)
		helpers.assert_true(joined:find("\n=https\n", 1, true) ~= nil)
		helpers.assert_true(joined:find("\n/tmp/etag-in\n", 1, true) ~= nil)
		helpers.assert_true(joined:find("\n/tmp/etag-out\n", 1, true) ~= nil)
		helpers.assert_true(joined:find("\n--data-binary\n", 1, true) == nil)
		state.complete_request(1, "[]\nERGOPTI_HTTP_STATUS:200\n")
		helpers.assert_true(result.ok)
		helpers.assert_eq(result.body, "[]")
	end)

	helpers.it("bounds a buffered response and terminates its process group", function()
		local client, state = fresh_client()
		local result = nil
		client.get("https://api.github.com/releases", {}, { max_body_bytes = 4 },
			function(value) result = value end)
		state.stdout(string.rep("x", 64))
		helpers.assert_eq(result.error, "response body exceeds limit")
		helpers.assert_eq(state.kills[1].pid, -4321)
		helpers.assert_true(not client.isActive())
	end)

	helpers.it("keeps requests from independent owners alive concurrently", function()
		local client, state = fresh_client()
		local default_result = nil
		client.post("http://127.0.0.1:11434/api/chat", {}, "{}",
			function(value) default_result = value end)
		client.get("https://api.github.com/releases", {}, { owner = "updater" }, function() end)
		helpers.assert_true(client.isActive())
		helpers.assert_true(client.isActive("updater"))
		helpers.assert_true(client.cancel("updater"))
		helpers.assert_eq(state.kills[1].pid, -4322)
		helpers.assert_true(client.isActive(), "updater cancellation must not cancel the LLM owner")
		helpers.assert_true(not client.isActive("updater"))
		state.complete_request(1, "{}\nERGOPTI_HTTP_STATUS:200\n")
		helpers.assert_true(default_result.ok)
	end)

	helpers.it("dispatches without waiting and passes data as argv, never through a shell", function()
		local client, state = fresh_client()
		local callback_count = 0
		local result = nil
		client.post("http://127.0.0.1:11434/api/chat",
			{ ["Content-Type"] = "application/json" }, "{'quoted':true}", function(value)
				callback_count = callback_count + 1
				result = value
			end)

		helpers.assert_eq(state.command, "curl", "libuv must spawn curl directly")
		helpers.assert_eq(callback_count, 0, "post must return before any network output arrives")
		helpers.assert_true(client.isActive(), "the adapter owns the live request")
		helpers.assert_eq(state.timer.timeout_ms, 30000, "timeout is armed before completion")
		local joined = table.concat(state.options.args, "\n")
		helpers.assert_true(joined:find("{'quoted':true}", 1, true) ~= nil,
			"the body must remain one literal argv entry")
		helpers.assert_true(state.options.detached == true,
			"curl must own a process group that cancellation can target")

		state.stdout('{"ok":true}\nERGOPTI_HTTP_STATUS:204\n')
		state.complete(0)
		helpers.assert_eq(callback_count, 1, "completion must publish exactly once")
		helpers.assert_eq(result.ok, true)
		helpers.assert_eq(result.status, 204)
		helpers.assert_eq(result.body, '{"ok":true}')
		helpers.assert_true(not client.isActive(), "ownership clears after completion")
	end)

	helpers.it("preserves an HTTP error status", function()
		local client, state = fresh_client()
		local result = nil
		client.post("http://127.0.0.1:11434/api/chat", {}, "", function(value) result = value end)
		state.stdout('{"error":"unauthorized"}\nERGOPTI_HTTP_STATUS:401\n')
		state.complete(22)
		helpers.assert_eq(result.ok, false)
		helpers.assert_eq(result.status, 401)
		helpers.assert_eq(result.error, "HTTP 401")
	end)

	helpers.it("accepts the complete 2xx boundary", function()
		for _, status in ipairs({ 200, 299 }) do
			local client, state = fresh_client()
			local result = nil
			client.post("http://127.0.0.1:11434/api/chat", {}, "", function(value) result = value end)
			state.stdout("ok\nERGOPTI_HTTP_STATUS:" .. tostring(status) .. "\n")
			state.complete(0)
			helpers.assert_true(result.ok, "HTTP " .. tostring(status) .. " must succeed")
			helpers.assert_eq(result.status, status)
		end
	end)

	helpers.it("reports a network exit with captured diagnostics", function()
		local client, state = fresh_client()
		local result = nil
		client.post("http://127.0.0.1:1/api/chat", {}, "", function(value) result = value end)
		state.stderr("connection refused")
		state.complete(7)
		helpers.assert_eq(result.ok, false)
		helpers.assert_eq(result.status, 0)
		helpers.assert_eq(result.error, "connection refused")
	end)

	helpers.it("streams chunks while the caller can keep pumping input", function()
		local client, state = fresh_client()
		local chunks = {}
		local terminals = 0
		local dispatched = client.postStream("http://127.0.0.1:11434/api/chat", {}, "{}",
			{ timeout_ms = 250 }, function(chunk) chunks[#chunks + 1] = chunk end,
			function(result)
				terminals = terminals + 1
				helpers.assert_true(result.ok)
			end)
		helpers.assert_true(dispatched and client.isActive(),
			"a slow response remains event-loop-owned after dispatch returns")
		state.stdout("first")
		state.stdout(" second")
		helpers.assert_eq(table.concat(chunks), "first second")
		state.complete(0)
		helpers.assert_eq(terminals, 1)
	end)

	helpers.it("timeout kills the process group and ignores every late completion", function()
		local client, state = fresh_client()
		local terminals = 0
		local terminal_error = nil
		client.postStream("http://127.0.0.1:11434/api/chat", {}, "{}", { timeout_ms = 25 },
			function() end, function(result)
				terminals = terminals + 1
				terminal_error = result.error
			end)
		state.timer.callback()
		helpers.assert_eq(terminals, 1)
		helpers.assert_eq(terminal_error, "timeout")
		helpers.assert_eq(state.kills[1].pid, -4321, "SIGTERM must target the process group")
		helpers.assert_eq(state.kills[1].signal, "sigterm")
		helpers.assert_eq(state.kills[2].signal, "sigkill")
		helpers.assert_true(not client.isActive())
		state.exit(0)
		helpers.assert_eq(terminals, 1, "a stale exit callback must be inert")
	end)

	helpers.it("cancel kills the group and suppresses the port callback", function()
		local client, state = fresh_client()
		local terminals = 0
		client.post("http://127.0.0.1:11434/api/chat", {}, "", function()
			terminals = terminals + 1
		end)
		helpers.assert_true(client.cancel())
		helpers.assert_eq(state.kills[1].pid, -4321)
		helpers.assert_eq(terminals, 0, "the canonical port suppresses callbacks after cancel")
		helpers.assert_true(not client.isActive())
		helpers.assert_true(client.cancel(), "idle cancellation is idempotent")
	end)

	helpers.it("refuses dispatch when timeout or spawn ownership cannot commit", function()
		for _, config in ipairs({ { timer_failure = true }, { spawn_failure = true } }) do
			local client = fresh_client(config)
			local terminals = 0
			local result = nil
			client.post("http://127.0.0.1:11434/api/chat", {}, "", function(value)
				terminals = terminals + 1
				result = value
			end)
			helpers.assert_eq(terminals, 1)
			helpers.assert_true(type(result.error) == "string" and result.error ~= "")
			helpers.assert_true(not client.isActive())
		end
	end)
end)

helpers.describe("file_digest: asynchronous sha256sum ownership", function()
	helpers.it("hashes a literal absolute path without a shell", function()
		local digest, state = fresh_digest()
		local value = nil
		local err = nil
		local path = "/tmp/release $HOME 'literal'.part"
		local dispatched = digest.sha256(path, { timeout_ms = 250 }, function(result, failure)
			value = result
			err = failure
		end)
		helpers.assert_true(dispatched and digest.isActive())
		helpers.assert_eq(state.command, "sha256sum")
		helpers.assert_eq(state.options.args[4], path,
			"the file path must remain one literal argv entry")
		helpers.assert_eq(value, nil, "hashing must return before the file has been consumed")
		local expected = string.rep("a1", 32)
		state.complete_request(1, expected .. " *" .. path .. "\0", 0)
		helpers.assert_eq(err, nil)
		helpers.assert_eq(value, expected)
		helpers.assert_true(not digest.isActive())
	end)

	helpers.it("rejects malformed digest output instead of trusting it", function()
		local digest, state = fresh_digest()
		local result_error = nil
		digest.sha256("/tmp/release.part", {}, function(_, err) result_error = err end)
		state.complete_request(1, "not-a-digest */tmp/release.part\0", 0)
		helpers.assert_eq(result_error, "invalid sha256sum output")
	end)

	helpers.it("times out and kills the digest process group", function()
		local digest, state = fresh_digest()
		local result_error = nil
		digest.sha256("/tmp/release.part", { timeout_ms = 25 },
			function(_, err) result_error = err end)
		state.timer.callback()
		helpers.assert_eq(result_error, "timeout")
		helpers.assert_eq(state.kills[1].pid, -4321)
		helpers.assert_true(not digest.isActive())
	end)
end)

helpers.describe("http_client: unavailable async runtime", function()
	helpers.it("fails explicitly without ever calling io.popen", function()
		local previous_luv = package.loaded["luv"]
		local previous_preload = package.preload["luv"]
		local previous_client = package.loaded["adapters.http_client"]
		local previous_popen = io.popen
		package.loaded["luv"] = nil
		package.preload["luv"] = function() error("missing luv") end
		package.loaded["adapters.http_client"] = nil
		io.popen = function() error("a synchronous fallback must never run") end
		local client = require("adapters.http_client")
		local result = nil
		client.post("http://127.0.0.1:11434/api/chat", {}, "", function(value) result = value end)
		io.popen = previous_popen
		package.preload["luv"] = previous_preload
		package.loaded["luv"] = previous_luv
		package.loaded["adapters.http_client"] = previous_client
		helpers.assert_eq(result.error, "asynchronous HTTP unavailable")
	end)
end)
