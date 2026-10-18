--- tests/unit/adapters/network/test_http_client_curl_asynchronous_ownership.lua

--- ==============================================================================
--- MODULE: Asynchronous HTTP Process Ownership
--- DESCRIPTION:
--- Drives the Linux HttpClient through a controllable libuv double. The tests
--- prove dispatch returns before output, timeout and cancel kill the detached
--- process group, and exactly one terminal callback survives late events.
--- ==============================================================================

package.loaded["tests.support.adapters.network.http_client_curl_fixture"] = nil
local Fixture = require("tests.support.adapters.network.http_client_curl_fixture")
local helpers, fresh_client =
	Fixture.helpers, Fixture.fresh_client




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
end)




helpers.describe("http_client: asynchronous curl ownership", function()
	helpers.it("exports the canonical port and streaming extension", function()
		local client = fresh_client()
		for _, name in ipairs({ "download", "get", "post", "postStream", "cancel", "isActive" }) do
			helpers.assert_eq(type(client[name]), "function", name .. " must be callable")
		end
		helpers.assert_true(client.HAS_ASYNC)
	end)
end)




helpers.describe("http_client: asynchronous curl ownership", function()
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
end)




helpers.describe("http_client: asynchronous curl ownership", function()
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
end)




helpers.describe("http_client: asynchronous curl ownership", function()
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
end)




helpers.describe("http_client: asynchronous curl ownership", function()
	for _, method in ipairs({ "get", "get_owned", "post", "postStream", "download" }) do
		helpers.it("literal-URL: " .. method .. " disables curl URL expansion", function()
			local client, state = fresh_client()
			local result
			local function done(value) result = value end
			local target = "http://127.0.0.1:9000/models?filter[name]=value&set={one,two}"
			local operation
			if method == "get" then client.get(target, {}, {}, done)
			elseif method == "get_owned" then operation = client.get_owned(target, {}, {}, done)
			elseif method == "post" then client.post(target, {}, "{}", done)
			elseif method == "download" then client.download(target, {}, "/tmp/owned-download", {}, done)
			else client.postStream(target, {}, "{}", {}, function() end, done) end
			helpers.assert_eq(#state.requests, 1)
			helpers.assert_nil(result, "curl must remain asynchronous")
			helpers.assert_eq(state.options.args[1], "--disable", "personal config stays disabled first")
			helpers.assert_true(("\n" .. table.concat(state.options.args, "\n") .. "\n"):find("\n--globoff\n", 1, true) ~= nil,
				"curl's own URL parser must not expand or reject literal caller brackets and braces")
			helpers.assert_true(state.config:find('url = "' .. target .. '"', 1, true) ~= nil)
			if method == "postStream" then state.stdout("abc"); state.stderr("\nERGOPTI_HTTP_STATUS:200\n")
			else state.stdout("abc\nERGOPTI_HTTP_STATUS:200\n") end
			state.complete()
			helpers.assert_true(result.ok and result.status == 200)
			if operation then helpers.assert_true(operation:is_settled()) end
		end)
	end
end)




helpers.describe("http_client: asynchronous curl ownership", function()
	helpers.it("enforces the exact buffered body limit after separating the curl receipt", function()
		for _, status in ipairs({ 200, 401 }) do
			for _, size in ipairs({ 3, 4, 5, 13 }) do
				for _, split in ipairs({ false, true }) do
					local client, state = fresh_client()
					local result, callbacks = nil, 0
					client.get("https://api.github.com/releases", {}, { max_body_bytes = 4 }, function(value)
						result, callbacks = value, callbacks + 1
					end)
					local body = string.rep("x", size)
					local receipt = "\nERGOPTI_HTTP_STATUS:" .. status .. "\n"
					if split then
						state.stdout(body)
						for index = 1, #receipt do state.stdout(receipt:sub(index, index)) end
					else state.stdout(body .. receipt) end
					state.complete(status == 200 and 0 or 22)
					helpers.assert_eq(callbacks, 1)
					helpers.assert_true(not client.isActive())
					if size > 4 then
						helpers.assert_eq(result.ok, false)
						helpers.assert_eq(result.status, 0)
						helpers.assert_eq(result.error, "response body exceeds limit")
						helpers.assert_eq(result.body, "")
						helpers.assert_nil(result.error_body, "oversized refusal bytes must not be published")
					else
						helpers.assert_eq(result.status, status)
						helpers.assert_eq(result.ok, status == 200)
						helpers.assert_eq(status == 200 and result.body or result.error_body, body)
					end
				end
			end
		end
	end)
end)




helpers.describe("http_client: asynchronous curl ownership", function()
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
end)




helpers.describe("http_client: asynchronous curl ownership", function()
	for _, method in ipairs({ "get", "get_owned", "post", "postStream" }) do
		helpers.it("curl empty headers: " .. method .. " serializes present empty fields without removal directives", function()
			local client, state = fresh_client()
			local calls, result = 0, nil
			local function done(value) result, calls = value, calls + 1 end
			local headers = { ["X-Empty-Fixture"] = "", Accept = "", ["User-Agent"] = "",
				["Content-Type"] = "", ["X-Ordinary-Fixture"] = "literal-value" }
			local operation
			if method == "get" or method == "get_owned" then
				operation = client[method]("http://127.0.0.1:9000/", headers, {}, done)
			elseif method == "post" then
				operation = client.post("http://127.0.0.1:9000/", headers, "literal-body", done)
			else
				operation = client.postStream("http://127.0.0.1:9000/", headers, "literal-body", {}, function() end, done)
			end
			helpers.assert_eq(#state.requests, 1)
			for _, name in ipairs({ "X-Empty-Fixture", "Accept", "User-Agent", "Content-Type" }) do
				helpers.assert_contains(state.config, 'header = "' .. name .. ';"')
			end
			helpers.assert_contains(state.config, 'header = "X-Ordinary-Fixture: literal-value"')
			helpers.assert_nil(state.config:find("X-Absent-Fixture", 1, true))
			if method == "postStream" then
				state.stdout("literal-response")
				state.stderr("\nERGOPTI_HTTP_STATUS:200\n")
			else
				state.stdout("literal-response\nERGOPTI_HTTP_STATUS:200\n")
			end
			state.complete(0)
			helpers.assert_eq(calls, 1)
			helpers.assert_true(result.ok and result.status == 200)
			if method == "get_owned" then helpers.assert_true(operation:is_settled()) end
		end)
	end
end)




helpers.describe("http_client: asynchronous curl ownership", function()
	for _, method in ipairs({ "get", "get_owned", "post", "postStream" }) do
		for _, value in ipairs({ " ", "\t", " \t " }) do
			helpers.it("curl OWS headers: " .. method .. " preserves SP/HTAB-empty fields and every nonempty serialized byte", function()
				local client, state = fresh_client()
				local result, calls = nil, 0
				local function done(receipt) result, calls = receipt, calls + 1 end
				local headers = { ["X-Empty-Fixture"] = value, Accept = value, ["User-Agent"] = value,
					["Content-Type"] = value, ["X-Ordinary-Fixture"] = " \tliteral \t value \t", ["X-Vertical-Control"] = "\v" }
				local operation
				if method == "get" or method == "get_owned" then
					operation = client[method]("http://127.0.0.1:9000/", headers, {}, done)
				elseif method == "post" then
					operation = client.post("http://127.0.0.1:9000/", headers, "literal-body", done)
				else
					operation = client.postStream("http://127.0.0.1:9000/", headers, "literal-body", {}, function() end, done)
				end
				helpers.assert_eq(#state.requests, 1)
				for _, name in ipairs({ "X-Empty-Fixture", "Accept", "User-Agent", "Content-Type" }) do
					helpers.assert_contains(state.config, 'header = "' .. name .. ';"')
				end
				helpers.assert_contains(state.config, 'header = "X-Ordinary-Fixture:  \\tliteral \\t value \\t"')
				helpers.assert_contains(state.config, 'header = "X-Vertical-Control: \\v"', "non-OWS controls retain their original serialization")
				if method == "postStream" then
					state.stdout("literal-response"); state.stderr("\nERGOPTI_HTTP_STATUS:200\n")
				else state.stdout("literal-response\nERGOPTI_HTTP_STATUS:200\n") end
				state.complete(0)
				helpers.assert_true(result.ok and result.status == 200)
				helpers.assert_eq(calls, 1)
				if method == "get_owned" then helpers.assert_true(operation:is_settled()) end
			end)
		end
	end
end)




helpers.describe("http_client: asynchronous curl ownership", function()
	helpers.it("keeps the headers, the body and the URL off the command line", function()
		-- Every local process can read /proc/<pid>/cmdline: an API key in a
		-- header and the typed text in a body were exposed there.
		local client, state = fresh_client()
		client.post("https://api.cerebras.ai/v1/chat/completions",
			{ Authorization = "Bearer sk-secret" }, '{"q":"Mon mot de passe \\"x\\""}', function() end)
		local joined = table.concat(state.options.args, "\n")
		helpers.assert_true(joined:find("sk-secret", 1, true) == nil, "the key must not be in argv")
		helpers.assert_true(joined:find("mot de passe", 1, true) == nil, "the typed text must not be in argv")
		helpers.assert_true(joined:find("cerebras", 1, true) == nil, "the URL must not be in argv")
		helpers.assert_true(joined:find("\n--config\n-", 1, true) ~= nil, "curl reads its config from stdin")
		helpers.assert_true(state.config:find('header = "Authorization: Bearer sk-secret"', 1, true) ~= nil)
		helpers.assert_eq(state.body, '{"q":"Mon mot de passe \\"x\\""}', "the body channel preserves literal quotes and backslashes")
		helpers.assert_nil(state.config:find("mot de passe", 1, true), "the config carries no caller body")
		helpers.assert_true(state.config:find('url = "https://api.cerebras.ai/v1/chat/completions"', 1, true) ~= nil)
	end)
end)




helpers.describe("http_client: asynchronous curl ownership", function()
	helpers.it("dispatches without waiting and passes data on stdin, never through a shell", function()
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
		helpers.assert_eq(state.body, "{'quoted':true}", "the body must reach curl literally")
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
end)




helpers.describe("http_client: asynchronous curl ownership", function()
	helpers.it("inherits the proxy environment that curl reads itself", function()
		-- Behind a corporate proxy curl only reaches GitHub through
		-- https_proxy/all_proxy/no_proxy. A replaced environment or an explicit
		-- proxy override would silently route around the user's configuration.
		local client, state = fresh_client()
		client.get("https://github.com/adrienm7/ergopti/releases.atom", {}, {
			timeout_ms = 1000, https_only = true, follow_redirects = true,
		}, function() end)
		helpers.assert_eq(state.options.env, nil, "curl must inherit the daemon environment")
		for _, arg in ipairs(state.options.args) do
			helpers.assert_true(arg ~= "--noproxy" and arg ~= "--proxy" and arg ~= "-x",
				"curl must keep its environment proxy selection")
		end
	end)
end)




helpers.describe("http_client: asynchronous curl ownership", function()
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
end)




helpers.describe("http_client: asynchronous curl ownership", function()
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
end)




helpers.describe("http_client: asynchronous curl ownership", function()
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
end)




helpers.describe("http_client: asynchronous curl ownership", function()
	helpers.it("streams chunks while the caller can keep pumping input", function()
		local client, state = fresh_client()
		local chunks = {}
		local terminals, receipt = 0, nil
		local dispatched = client.postStream("http://127.0.0.1:11434/api/chat", {}, "{}",
			{ timeout_ms = 250 }, function(chunk) chunks[#chunks + 1] = chunk end,
			function(result)
				terminals = terminals + 1
				receipt = result
			end)
		helpers.assert_true(dispatched and client.isActive(),
			"a slow response remains event-loop-owned after dispatch returns")
		state.stdout("first")
		state.stdout(" second")
		helpers.assert_eq(table.concat(chunks), "first second")
		state.stderr("\nERGOPTI_HTTP_STATUS:200\n")
		state.complete(0)
		helpers.assert_eq(terminals, 1)
		helpers.assert_true(receipt.ok, "callback assertions must execute outside the production pcall")
		helpers.assert_eq(receipt.status, 200)
	end)
end)




helpers.describe("http_client: asynchronous curl ownership", function()
	helpers.it("streams real status on stderr without protocol metadata in response chunks", function()
		local marker = "\nERGOPTI_HTTP_STATUS:404\n"
		local body = '{"error":"model \"fixture:latest\" not found"}'
		for split = 1, #marker do
			local client, state = fresh_client()
			local chunks, result, terminals = {}, nil, 0
			client.postStream("http://127.0.0.1:11434/api/chat", {}, "{}", {},
				function(chunk) chunks[#chunks + 1] = chunk end,
				function(receipt) result = receipt; terminals = terminals + 1 end)
			local arguments = table.concat(state.options.args, "\n")
			helpers.assert_true(arguments:find("--write-out\n%{stderr}", 1, true) ~= nil)
			for index = 1, #body do state.stdout(body:sub(index, index)) end
			state.stderr("curl: (22) refused")
			state.stderr(marker:sub(1, split))
			state.stderr(marker:sub(split + 1))
			state.complete(22)
			helpers.assert_eq(result.ok, false, "split " .. tostring(split))
			helpers.assert_eq(result.status, 404)
			helpers.assert_eq(result.error_body, body)
			helpers.assert_eq(result.error, "HTTP 404")
			helpers.assert_eq(table.concat(chunks), body, "metadata must never enter NDJSON")
			helpers.assert_eq(terminals, 1)
			state.exit(22)
			helpers.assert_eq(terminals, 1, "the stale exit cannot publish twice")
		end
	end)
end)




helpers.describe("http_client: asynchronous curl ownership", function()
	helpers.it("preserves exact streaming HTTP status and ordinary failure classification", function()
		for _, status in ipairs({ 200, 299, 401, 404, 503 }) do
			local client, state = fresh_client()
			local result
			client.postStream("http://127.0.0.1:11434/api/chat", {}, "{}", {}, function() end,
				function(receipt) result = receipt end)
			state.stdout('{"error":"route not found"}')
			state.stderr("\nERGOPTI_HTTP_STATUS:" .. tostring(status) .. "\n")
			state.complete(status < 400 and 0 or 22)
			helpers.assert_eq(result.status, status)
			helpers.assert_eq(result.ok, status >= 200 and status < 300)
			if status >= 400 then
				helpers.assert_eq(result.error, "HTTP " .. tostring(status))
				helpers.assert_eq(result.error_body, '{"error":"route not found"}')
			else
				helpers.assert_eq(result.error_body, nil)
				helpers.assert_eq(result.error, nil, "a complete success has no refusal diagnostic")
			end
		end
	end)
end)




helpers.describe("http_client: asynchronous curl ownership", function()
	for _, method in ipairs({ "get", "post", "download", "postStream" }) do
		helpers.it("incomplete-error-body: " .. method .. " publishes only complete HTTP rejection bytes", function()
			local policy = require("llm.local_model_policy")
			local url = "http://127.0.0.1:11434/api/chat"
			local body = require("json").encode({ error = 'model "fixture:latest" not found' })
			for _, status in ipairs({ 401, 404, 503 }) do
				for _, exit in ipairs({ { code = 0 }, { code = 22 }, { code = 18 },
					{ code = 23 }, { code = 56 }, { code = 0, signal = 15 } }) do
					local client, state = fresh_client()
					local result, callbacks = nil, 0
					local function done(value) result, callbacks = value, callbacks + 1 end
					local marker = "\nERGOPTI_HTTP_STATUS:" .. status .. "\n"
					if method == "get" then client.get(url, {}, {}, done)
					elseif method == "post" then client.post(url, {}, "{}", done)
					elseif method == "download" then client.download(url, {}, "/tmp/owned-download", {}, done)
					else client.postStream(url, {}, "{}", {}, function() end, done) end
					if method == "postStream" then state.stdout(body); state.stderr(marker)
					else state.stdout(body .. marker) end
					state.stdout(nil); state.stderr(nil); state.exit(exit.code, exit.signal)
					local completed = not exit.signal and (exit.code == 0 or exit.code == 22)
					helpers.assert_eq(result.ok, false)
					helpers.assert_eq(result.status, status, "the HTTP status survives a transfer failure")
					helpers.assert_eq(result.error, "HTTP " .. status)
					helpers.assert_eq(result.body, "")
					helpers.assert_eq(result.error_body, completed and body or nil)
					local failure = policy.response_failure(result, "http://127.0.0.1:11434")
					helpers.assert_eq(policy.is_missing(failure), completed and status == 404 or false,
						"an incomplete transfer cannot authorize a missing-model offer")
					helpers.assert_eq(callbacks, 1)
					helpers.assert_true(not client.isActive())
					state.exit(exit.code, exit.signal)
					helpers.assert_eq(callbacks, 1, "late native exits cannot republish the refusal")
				end
			end
		end)
	end
end)




helpers.describe("http_client: asynchronous curl ownership", function()
	helpers.it("omits oversized error bodies and retains status after diagnostics exhaust their budget", function()
		local client, state = fresh_client()
		local result, bytes = nil, 0
		local body = string.rep("body", 20000)
		client.postStream("http://127.0.0.1:11434/api/chat", {}, "{}", {},
			function(chunk) bytes = bytes + #chunk end, function(receipt) result = receipt end)
		state.stdout(body:sub(1, 20000))
		state.stdout(body:sub(20001))
		state.stderr(string.rep("diagnostic", 10000))
		for char in ("\nERGOPTI_HTTP_STATUS:404\n"):gmatch(".") do state.stderr(char) end
		state.complete(22)
		helpers.assert_eq(bytes, #body, "the prefix budget must not truncate streamed data")
		helpers.assert_eq(result.status, 404, "receipt survives a full diagnostic buffer")
		helpers.assert_eq(result.error_body, nil, "a truncated prefix is never a complete HTTP error body")
		helpers.assert_eq(result.error, "HTTP 404")
	end)
end)




helpers.describe("http_client: asynchronous curl ownership", function()
	helpers.it("distinguishes complete error bodies from overflow at the exact capture boundary", function()
		local json = '{"error":"model \"fixture:latest\" not found"}'
		for _, length in ipairs({ 65535, 65536, 65537 }) do
			local client, state = fresh_client()
			local result, chunks = nil, {}
			local body = json .. string.rep(" ", length - #json)
			client.postStream("http://127.0.0.1:11434/api/chat", {}, "{}", {},
				function(chunk) chunks[#chunks + 1] = chunk end, function(receipt) result = receipt end)
			state.stdout(body:sub(1, 65535))
			state.stdout(body:sub(65536))
			state.stderr("\nERGOPTI_HTTP_STATUS:404\n")
			state.complete(22)
			helpers.assert_eq(result.status, 404)
			helpers.assert_eq(result.error, "HTTP 404")
			helpers.assert_eq(table.concat(chunks), body, "the capture budget cannot alter streaming data")
			helpers.assert_eq(result.error_body, length <= 65536 and body or nil,
				"only a complete body inside the budget can provide classification evidence")
		end
	end)
end)




helpers.describe("http_client: asynchronous curl ownership", function()
	helpers.it("keeps marker-like body text unchanged and never fabricates absent receipt status", function()
		local client, state = fresh_client()
		local result, chunks = nil, {}
		local body = "prefix\nERGOPTI_HTTP_STATUS:404\npayload"
		client.postStream("http://127.0.0.1:11434/api/chat", {}, "{}", {},
			function(chunk) chunks[#chunks + 1] = chunk end, function(receipt) result = receipt end)
		state.stdout(body)
		state.stderr("\nERGOPTI_HTTP_STATUS:299\n")
		state.complete(0)
		helpers.assert_true(result.ok)
		helpers.assert_eq(result.status, 299)
		helpers.assert_eq(table.concat(chunks), body)
		client, state = fresh_client()
		client.postStream("http://127.0.0.1:11434/api/chat", {}, "{}", {}, function() end,
			function(receipt) result = receipt end)
		state.complete(0)
		helpers.assert_eq(result.ok, false)
		helpers.assert_eq(result.status, 0)
		helpers.assert_eq(result.error, "missing HTTP status")
	end)
end)




helpers.describe("http_client: asynchronous curl ownership", function()
	helpers.it("refuses incomplete successful HTTP transfers and removes receipt from network diagnostics", function()
		for _, case in ipairs({ { status = 200, code = 18, error = "transfer incomplete" },
			{ status = 0, code = 7, error = "connection refused" } }) do
			local client, state = fresh_client()
			local result
			client.postStream("http://127.0.0.1:11434/api/chat", {}, "{}", {}, function() end,
				function(receipt) result = receipt end)
			state.stderr(case.error .. "\nERGOPTI_HTTP_STATUS:" .. string.format("%03d", case.status) .. "\n")
			state.complete(case.code)
			helpers.assert_eq(result.ok, false)
			helpers.assert_eq(result.status, case.status)
			helpers.assert_eq(result.error, case.error)
			helpers.assert_eq(result.error_body, nil, "transport refusal is not a model failure body")
		end
	end)
end)




helpers.describe("http_client: asynchronous curl ownership", function()
	helpers.it("retains the exact streaming owner on cancellation refusal and preserves independent owners", function()
		local client, state = fresh_client({ kill_failure = true })
		local terminals, rejection, independent = 0, nil, nil
		client.postStream("http://127.0.0.1:11434/api/chat", {}, "{}", {}, function() end,
			function() terminals = terminals + 1 end)
		client.get("http://127.0.0.1:11434/api/tags", {}, { owner = "vision" },
			function(receipt) independent = receipt end)
		helpers.assert_eq(client.cancel(), false)
		helpers.assert_true(client.isActive() and client.isActive("vision"))
		helpers.assert_eq(client.postStream("http://127.0.0.1:11434/api/chat", {}, "{}", {}, function() end,
			function(receipt) rejection = receipt end), false)
		helpers.assert_eq(rejection.error, "previous request cancellation failed")
		helpers.assert_eq(#state.requests, 2, "replacement cannot acquire over cancellation debt")
		helpers.assert_eq(terminals, 0)
		state.allow_kills = true
		helpers.assert_true(client.cancel())
		helpers.assert_true(not client.isActive() and client.isActive("vision"))
		state.complete_request(1, "late data", 22)
		helpers.assert_eq(terminals, 0)
		state.complete_request(2, "[]\nERGOPTI_HTTP_STATUS:200\n", 0)
		helpers.assert_true(independent.ok)
		helpers.assert_true(not client.isActive("vision"))
	end)
end)




helpers.describe("http_client: asynchronous curl ownership", function()
	helpers.it("waits for both streaming pipes after process exit before publishing the receipt", function()
		local client, state = fresh_client()
		local result, terminals = nil, 0
		client.postStream("http://127.0.0.1:11434/api/chat", {}, "{}", {}, function() end,
			function(receipt) result = receipt; terminals = terminals + 1 end)
		state.exit(22)
		helpers.assert_eq(result, nil, "process exit is not a completed HTTP receipt")
		helpers.assert_true(client.isActive())
		state.stdout('{"error":"route not found"}')
		state.stdout(nil)
		helpers.assert_eq(result, nil, "stderr receipt has not settled yet")
		state.stderr("\nERGOPTI_HTTP_STATUS:404\n")
		state.stderr(nil)
		helpers.assert_eq(result.status, 404)
		helpers.assert_eq(result.error_body, '{"error":"route not found"}')
		helpers.assert_eq(terminals, 1)
		helpers.assert_true(not client.isActive())
	end)
end)




helpers.describe("http_client: asynchronous curl ownership", function()
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
end)




helpers.describe("http_client: asynchronous curl ownership", function()
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
end)




helpers.describe("http_client: asynchronous curl ownership", function()
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

