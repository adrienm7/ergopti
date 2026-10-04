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
	local state = { kills = {}, handles = {}, requests = {}, closes = {} }
	local fake = {}

	local function handle(kind)
		if options.allocation_failure_at == #state.handles + 1 then error("allocation refused") end
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
	function fake.write(pipe, data, callback)
		pipe.written = (pipe.written or "") .. data
		state.config = pipe.written
		if callback then callback(nil) end
		return true
	end
	function fake.read_stop(pipe) pipe.read_stopped = true; return true end
	function fake.is_closing(value) return value.closing end
	function fake.close(value, callback)
		if options.close_failure and not state.allow_closes then return nil, "close refused" end
		value.closing = true
		if callback then
			state.closes[#state.closes + 1] = { handle = value, callback = callback }
			if not options.defer_close then callback() end
		end
	end
	function state.ack_closes()
		for _, receipt in ipairs(state.closes) do
			if not receipt.acknowledged then
				receipt.acknowledged = true
				receipt.callback()
			end
		end
	end
	function fake.kill(pid, signal)
		state.kills[#state.kills + 1] = { pid = pid, signal = signal }
		if options.kill_missing then return nil, "ESRCH: no such process", "ESRCH" end
		if options.kill_failure and not state.allow_kills then return nil, "EPERM: operation not permitted", "EPERM" end
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
	for _, method in ipairs({ "get", "post", "postStream", "download" }) do
		for _, follow in ipairs({ false, true }) do
			helpers.it("linux-http-curlrc: " .. method .. " disables personal config first (follow=" .. tostring(follow) .. ")", function()
				local client, state = fresh_client()
				local result, options = nil, { follow_redirects = follow }
				local function complete(value) result = value end
				if method == "get" then helpers.assert_true(client.get("https://example.invalid", {}, options, complete))
				elseif method == "post" then helpers.assert_true(client.post("https://example.invalid", {}, "{}", complete, options))
				elseif method == "download" then helpers.assert_true(client.download("https://example.invalid", {}, "/tmp/unit-curlrc", options, complete))
				else helpers.assert_true(client.postStream("https://example.invalid", {}, "{}", options, function() end, complete)) end
				helpers.assert_eq(state.options.args[1], "--disable", "curl only skips its personal config when disable is the first argument")
				local joined = "\n" .. table.concat(state.options.args, "\n") .. "\n"
				-- Download follows public redirects by contract; get/post/stream
				-- preserve the caller's explicit choice.
				helpers.assert_eq(joined:find("\n--location\n", 1, true) ~= nil, method == "download" or follow)
				helpers.assert_true(joined:find("\n--config\n-\n", 1, true) ~= nil, "private stdin request config must remain enabled")
				if method == "postStream" then state.stdout("abc"); state.stderr("\nERGOPTI_HTTP_STATUS:200\n"); state.complete()
				else state.complete_request(1, "abc\nERGOPTI_HTTP_STATUS:200\n") end
				helpers.assert_true(result and result.ok and result.status == 200)
				helpers.assert_eq(client.isActive(), false)
			end)
		end
	end

	for _, method in ipairs({ "get", "post", "postStream", "download" }) do
		for _, target in ipairs({ "file:///owned/source", "FILE:///owned/source", "file:/owned/source",
			"ftp://127.0.0.1/native", "ftps://127.0.0.1/native", "gopher://127.0.0.1/native",
			"data:text/plain,synthetic", "telnet://127.0.0.1/native" }) do
			helpers.it("linux-http-transport-boundary: " .. method .. " refuses " .. target .. " before native effects", function()
				local client, state = fresh_client()
				local result, callbacks, chunks = nil, 0, 0
				local function complete(value) result = value; callbacks = callbacks + 1 end
				local dispatched
				if method == "get" then dispatched = client.get(target, {}, {}, complete)
				elseif method == "post" then dispatched = client.post(target, {}, "{}", complete)
				elseif method == "download" then dispatched = client.download(target, {}, "/tmp/unit-transport", {}, complete)
				else dispatched = client.postStream(target, {}, "{}", {}, function() chunks = chunks + 1 end, complete) end
				helpers.assert_eq(dispatched, false)
				helpers.assert_true(result and result.ok == false and result.status == 0 and type(result.error) == "string")
				helpers.assert_nil(result.error:find("owned/source", 1, true))
				helpers.assert_eq(callbacks, 1)
				helpers.assert_eq(chunks, 0)
				helpers.assert_eq(#state.handles, 0)
				helpers.assert_eq(#state.requests, 0)
				helpers.assert_eq(#state.kills, 0)
				helpers.assert_eq(client.isActive(), false)
			end)
		end
	end

	for _, method in ipairs({ "get", "post", "postStream", "download" }) do
		for _, case in ipairs({ { name = "HTTP", url = "http://example.invalid", fence = "=http,https" },
			{ name = "uppercase HTTPS", url = "HTTPS://example.invalid", fence = "=http,https" },
			{ name = "HTTPS-only", url = "https://example.invalid", fence = "=https", https_only = true } }) do
			helpers.it("linux-http-transport-options: " .. method .. " fences native " .. case.name .. " protocols", function()
				local client, state = fresh_client()
				local result, options = nil, { https_only = case.https_only }
				local function complete(value) result = value end
				if method == "get" then helpers.assert_true(client.get(case.url, {}, options, complete))
				elseif method == "post" then helpers.assert_true(client.post(case.url, {}, "{}", complete, options))
				elseif method == "download" then helpers.assert_true(client.download(case.url, {}, "/tmp/unit-http-transport", options, complete))
				else helpers.assert_true(client.postStream(case.url, {}, "{}", options, function() end, complete)) end
				local fences = 0
				for index, argument in ipairs(state.options.args) do
					if argument == "--proto" then fences = fences + 1; helpers.assert_eq(state.options.args[index + 1], case.fence) end
				end
				helpers.assert_eq(fences, 1, "one native fence must constrain initial requests and redirects")
				if method == "postStream" then state.stdout("abc"); state.stderr("\nERGOPTI_HTTP_STATUS:200\n"); state.complete()
				else state.complete_request(1, "abc\nERGOPTI_HTTP_STATUS:200\n") end
				helpers.assert_true(result and result.ok and result.status == 200)
			end)
		end
	end
	for index, policy in ipairs({ {}, { allowed_schemes = {} }, { allowed_schemes = "http,https" },
		{ allowed_schemes = { 42 } }, { allowed_schemes = { "HTTP" } },
		{ allowed_schemes = { "http", "http" } }, { allowed_schemes = { http = true } } }) do
		helpers.it("linux-http-transport-policy: refuses malformed shared inventory " .. index, function()
			local previous_json, previous_binding = package.loaded["json"], package.loaded["infra.http_transport_policy"]
			package.loaded["json"] = { decode = function() return policy end }
			package.loaded["infra.http_transport_policy"] = nil
			local ok, binding = pcall(require, "infra.http_transport_policy")
			package.loaded["json"], package.loaded["infra.http_transport_policy"] = previous_json, previous_binding
			helpers.assert_true(ok and type(binding) == "table" and type(binding.resolve) == "function", tostring(binding))
			local protocols, err = binding.resolve("https://example.invalid")
			helpers.assert_nil(protocols)
			helpers.assert_eq(err, "HTTP transport policy is invalid")
		end)
	end
	helpers.it("linux-http-transport-policy: unavailable shared policy refuses before allocation", function()
		local previous_paths, previous_binding = package.loaded["infra.paths"], package.loaded["infra.http_transport_policy"]
		package.loaded["infra.paths"] = { shared = function() return "/nonexistent-ergopti-transport-policy/policy.json" end }
		package.loaded["infra.http_transport_policy"] = nil
		local ok, binding = pcall(require, "infra.http_transport_policy")
		package.loaded["infra.paths"] = previous_paths
		helpers.assert_true(ok and type(binding) == "table" and type(binding.resolve) == "function", tostring(binding))
		local client, state = fresh_client()
		package.loaded["infra.http_transport_policy"] = previous_binding
		local result, callbacks = nil, 0
		helpers.assert_eq(client.get("https://example.invalid", {}, {}, function(value) result = value; callbacks = callbacks + 1 end), false)
		helpers.assert_true(result and result.ok == false and result.status == 0)
		helpers.assert_eq(result.error, "HTTP transport policy is unavailable")
		helpers.assert_eq(callbacks, 1)
		helpers.assert_eq(#state.handles, 0)
		helpers.assert_eq(#state.requests, 0)
		helpers.assert_eq(client.isActive(), false)
	end)

	for _, method in ipairs({ "post", "postStream" }) do
		for index, body in ipairs({ "@/owned/source", "@/owned/missing", "@-", "@", "@@literal", "@literal text" }) do
			helpers.it("linux-http-literal-body: " .. method .. " sends at-prefixed body " .. index .. " as raw caller bytes", function()
				local client, state = fresh_client()
				local result, callbacks, chunks = nil, 0, {}
				local function complete(value) result = value; callbacks = callbacks + 1 end
				if method == "post" then helpers.assert_true(client.post("https://example.invalid", {}, body, complete))
				else helpers.assert_true(client.postStream("https://example.invalid", {}, body, {}, function(bytes) chunks[#chunks + 1] = bytes end, complete)) end
				helpers.assert_true(state.config:find('data-raw = "' .. body .. '"\n', 1, true) ~= nil,
					"curl must not interpret caller bytes as a file or stdin reference")
				helpers.assert_nil(state.config:find("data-binary =", 1, true))
				for _, argument in ipairs(state.options.args) do helpers.assert_nil(argument:find(body, 1, true)) end
				if method == "post" then state.complete_request(1, "abc\nERGOPTI_HTTP_STATUS:200\n")
				else state.stdout("abc"); state.stderr("\nERGOPTI_HTTP_STATUS:200\n"); state.complete() end
				helpers.assert_true(result and result.ok and result.status == 200)
				helpers.assert_eq(callbacks, 1)
				if method == "postStream" then helpers.assert_eq(table.concat(chunks), "abc")
				else helpers.assert_eq(result.body, "abc") end
				helpers.assert_eq(client.isActive(), false)
			end)
		end
	end

	for _, method in ipairs({ "get", "post", "postStream", "download" }) do
		for index, byte in ipairs({ "\r", "\n", "\r\n", "\0" }) do
			for _, field in ipairs({ "name", "value" }) do
				helpers.it("linux-http-header-boundary: " .. method .. " refuses " .. field .. " control " .. index, function()
					local client, state = fresh_client()
					local headers = field == "name" and { ["X-Native" .. byte .. "X-Injected"] = "synthetic" }
						or { ["X-Native"] = "original" .. byte .. "X-Injected: synthetic" }
					local result, callbacks, chunks = nil, 0, 0
					local function complete(value) result = value; callbacks = callbacks + 1 end
					local dispatched
					if method == "get" then dispatched = client.get("https://example.invalid", headers, {}, complete)
					elseif method == "post" then dispatched = client.post("https://example.invalid", headers, "{}", complete)
					elseif method == "download" then dispatched = client.download("https://example.invalid", headers, "/tmp/unit-header", {}, complete)
					else dispatched = client.postStream("https://example.invalid", headers, "{}", {}, function() chunks = chunks + 1 end, complete) end
					helpers.assert_eq(dispatched, false)
					helpers.assert_true(result and result.ok == false and result.status == 0 and type(result.error) == "string")
					helpers.assert_nil(result.error:find("synthetic", 1, true))
					helpers.assert_eq(callbacks, 1)
					helpers.assert_eq(#state.handles, 0)
					helpers.assert_eq(#state.requests, 0)
					helpers.assert_eq(#state.kills, 0)
					helpers.assert_eq(chunks, 0)
					helpers.assert_eq(client.isActive(), false)
				end)
			end
		end
	end

	for index, policy in ipairs({ {}, { forbidden_bytes = {} }, { forbidden_bytes = "0,10,13" },
		{ forbidden_bytes = { 0, "10", 13 } }, { forbidden_bytes = { 0, 10, 10 } },
		{ forbidden_bytes = { 0, 256 } }, { forbidden_bytes = { [0] = 13, [1] = 0 } },
		{ forbidden_bytes = { 0, 10.5, 13 } } }) do
		helpers.it("linux-http-header-policy: rejects malformed inventory " .. index, function()
			local previous_json, previous_binding = package.loaded["json"], package.loaded["infra.http_header_policy"]
			package.loaded["json"] = { decode = function() return policy end }
			package.loaded["infra.http_header_policy"] = nil
			local ok, binding = pcall(require, "infra.http_header_policy")
			package.loaded["json"], package.loaded["infra.http_header_policy"] = previous_json, previous_binding
			helpers.assert_true(ok and type(binding) == "table" and type(binding.validate) == "function", tostring(binding))
			local allowed, err = binding.validate("X-Native", "literal")
			helpers.assert_nil(allowed)
			helpers.assert_eq(err, "HTTP header policy is invalid")
		end)
	end
	helpers.it("linux-http-header-policy: unavailable policy cannot retire a valid owner", function()
		local previous_paths, previous_binding = package.loaded["infra.paths"], package.loaded["infra.http_header_policy"]
		package.loaded["infra.paths"] = { shared = function() return "/nonexistent-ergopti-header-policy/policy.json" end }
		package.loaded["infra.http_header_policy"] = nil
		local ok, binding = pcall(require, "infra.http_header_policy")
		package.loaded["infra.paths"] = previous_paths
		helpers.assert_true(ok and type(binding) == "table" and type(binding.validate) == "function", tostring(binding))
		local client, state = fresh_client()
		package.loaded["infra.http_header_policy"] = previous_binding
		local good, bad = nil, nil
		helpers.assert_true(client.get("https://example.invalid/held", {}, { owner = "kept" }, function(value) good = value end))
		local handles = #state.handles
		helpers.assert_eq(client.get("https://example.invalid", { ["X-Native"] = "literal" }, { owner = "kept" }, function(value) bad = value end), false)
		helpers.assert_true(bad and bad.ok == false and bad.status == 0)
		helpers.assert_eq(#state.handles, handles)
		helpers.assert_eq(#state.requests, 1)
		helpers.assert_eq(#state.kills, 0)
		helpers.assert_true(client.isActive("kept"))
		state.complete_request(1, "abc\nERGOPTI_HTTP_STATUS:200\n")
		helpers.assert_true(good and good.ok and good.body == "abc")
	end)

	local invalid_preflight = {
		{ name = "NUL compare path", options = { etag_compare = "/owned/etag\0private-suffix" } },
		{ name = "NUL save path", options = { etag_save = "/owned/etag\0private-suffix" } },
		{ name = "NUL download path", download = "/owned/download\0private-suffix" },
		{ name = "numeric compare path", options = { etag_compare = 42 } },
		{ name = "numeric save path", options = { etag_save = 42 } },
		{ name = "mixed header names", headers = { [1] = "literal", ["X-Native"] = "literal" } },
		{ name = "numeric URL", url = 42 },
		{ name = "empty URL", url = "" },
		{ name = "raising header value", headers = { ["X-Native"] = setmetatable({}, {
			__tostring = function() error("Synthetic private header value") end,
		}) } },
	}
	for _, case in ipairs(invalid_preflight) do
		for _, existing in ipairs({ false, true }) do
			helpers.it("linux-http-preflight: " .. case.name .. " refuses before ownership/allocation (existing=" .. tostring(existing) .. ")", function()
				local client, state = fresh_client()
				local good, bad, good_callbacks, bad_callbacks = nil, nil, 0, 0
				if existing then
					helpers.assert_true(client.get("https://example.invalid/held", {}, { owner = "kept" }, function(value)
						good = value; good_callbacks = good_callbacks + 1
					end))
				end
				local handles, requests = #state.handles, #state.requests
				local options = { owner = "kept" }
				for key, value in pairs(case.options or {}) do options[key] = value end
				local function complete(value) bad = value; bad_callbacks = bad_callbacks + 1 end
				local protected, dispatched = pcall(function()
					if case.download then return client.download("https://example.invalid/direct", {}, case.download, options, complete) end
					return client.get(case.url or "https://example.invalid/direct", case.headers or {}, options, complete)
				end)
				helpers.assert_true(protected and dispatched == false, "invalid configuration must not escape or dispatch")
				helpers.assert_eq(bad_callbacks, 1)
				helpers.assert_true(bad and bad.ok == false and bad.status == 0 and type(bad.error) == "string")
				helpers.assert_nil(bad.error:find("private-suffix", 1, true))
				helpers.assert_nil(bad.error:find("Synthetic private header value", 1, true))
				helpers.assert_eq(#state.handles, handles, "preflight must precede timer/pipe allocation")
				helpers.assert_eq(#state.requests, requests)
				helpers.assert_eq(#state.kills, 0, "invalid replacement must not kill its predecessor")
				helpers.assert_eq(client.isActive("kept"), existing)
				if existing then
					state.complete_request(1, "abc\nERGOPTI_HTTP_STATUS:200\n")
					helpers.assert_true(good and good.ok and good.body == "abc")
					helpers.assert_eq(good_callbacks, 1)
				end
			end)
		end
	end

	for _, method in ipairs({ "get", "post", "postStream", "download" }) do
		for _, scheme in ipairs({ "https", "HTTPS" }) do
			helpers.it("linux-http-tls-redirect: " .. method .. " keeps " .. scheme .. " on every native hop", function()
				local client, state = fresh_client()
				local url = scheme .. "://example.invalid/api"
				local options = { follow_redirects = true, https_only = false }
				local result = nil
				local function complete(value) result = value end
				local dispatched
				if method == "get" then dispatched = client.get(url, {}, options, complete)
				elseif method == "post" then dispatched = client.post(url, {}, "{}", complete, options)
				elseif method == "download" then dispatched = client.download(url, {}, "/tmp/owned-tls-unit-download", options, complete)
				else dispatched = client.postStream(url, {}, "{}", options, function() end, complete) end
				helpers.assert_true(dispatched)
				helpers.assert_eq(options.https_only, false)
				local joined = "\n" .. table.concat(state.options.args, "\n") .. "\n"
				helpers.assert_true(joined:find("\n--location\n", 1, true) ~= nil)
				helpers.assert_true(joined:find("\n--proto-redir\n=https\n", 1, true) ~= nil,
					"secure redirect policy must not depend on the caller's https_only flag")
				if method == "postStream" then state.stderr("\nERGOPTI_HTTP_STATUS:307\n"); state.complete()
				else state.complete_request(1, "\nERGOPTI_HTTP_STATUS:307\n") end
				helpers.assert_true(result and result.ok == false and result.status == 307)
			end)
		end
	end

	helpers.it("linux-http-tls-redirect: public HTTP request can upgrade to TLS", function()
		local client, state = fresh_client()
		helpers.assert_true(client.get("http://example.invalid/api", {}, { follow_redirects = true }, function() end))
		local joined = "\n" .. table.concat(state.options.args, "\n") .. "\n"
		helpers.assert_true(joined:find("\n--location\n", 1, true) ~= nil)
		helpers.assert_true(joined:find("\n--proto-redir\n", 1, true) == nil)
		state.complete_request(1, "abc\nERGOPTI_HTTP_STATUS:200\n")
	end)

	helpers.it("linux-http-tls-redirect: explicit no-follow remains a single native request", function()
		local client, state = fresh_client()
		helpers.assert_true(client.get("https://example.invalid/api", {}, { follow_redirects = false }, function() end))
		local joined = "\n" .. table.concat(state.options.args, "\n") .. "\n"
		helpers.assert_true(joined:find("\n--location\n", 1, true) == nil)
		helpers.assert_true(joined:find("\n--proto-redir\n", 1, true) == nil)
		state.complete_request(1, "\nERGOPTI_HTTP_STATUS:307\n")
	end)

	local sensitive_headers = { "Api-Key", "Authorization", "Cookie", "Cookie2", "Proxy-Authorization", "X-Api-Key", "X-Goog-Api-Key" }
	for _, name in ipairs(sensitive_headers) do
		for _, method in ipairs({ "get", "post", "postStream", "download" }) do
			helpers.it("linux-http-redirect-credentials: " .. method .. " retains " .. name .. " only at its original hop", function()
				local client, state = fresh_client()
				local result, callbacks = nil, 0
				local headers, options = { [name] = "SyntheticUnitCredential" }, { follow_redirects = true }
				local function complete(value) result = value; callbacks = callbacks + 1 end
				local dispatched
				if method == "get" then dispatched = client.get("https://example.invalid/api", headers, options, complete)
				elseif method == "post" then dispatched = client.post("https://example.invalid/api", headers, "{}", complete, options)
				elseif method == "download" then dispatched = client.download("https://example.invalid/api", headers, "/tmp/owned-unit-download", options, complete)
				else dispatched = client.postStream("https://example.invalid/api", headers, "{}", options, function() end, complete) end
				helpers.assert_true(dispatched)
				helpers.assert_eq(options.follow_redirects, true, "caller options are immutable")
				local joined = "\n" .. table.concat(state.options.args, "\n") .. "\n"
				helpers.assert_true(joined:find("\n--location\n", 1, true) == nil, "native curl would forward a caller credential")
				helpers.assert_true(state.config:find(name .. ": SyntheticUnitCredential", 1, true) ~= nil)
				if method == "postStream" then state.stderr("\nERGOPTI_HTTP_STATUS:302\n"); state.complete()
				else state.complete_request(1, "\nERGOPTI_HTTP_STATUS:302\n") end
				helpers.assert_eq(callbacks, 1)
				helpers.assert_eq(result.ok, false)
				helpers.assert_eq(result.status, 302)
				helpers.assert_eq(result.error, "HTTP 302")
			end)
		end
		helpers.it("linux-http-redirect-credentials: recognizes uppercase " .. name, function()
			local client, state = fresh_client()
			helpers.assert_true(client.get("https://example.invalid/api", { [name:upper()] = "SyntheticUnitCredential" },
				{ follow_redirects = true }, function() end))
			local joined = "\n" .. table.concat(state.options.args, "\n") .. "\n"
			helpers.assert_true(joined:find("\n--location\n", 1, true) == nil)
			state.complete_request(1, "\nERGOPTI_HTTP_STATUS:302\n")
		end)
	end

	helpers.it("linux-http-redirect-credentials: missing policy refuses before replacing an existing request", function()
		local previous = package.loaded["infra.http_redirect_policy"]
		package.loaded["infra.http_redirect_policy"] = {
			allows_native_follow = function() return nil, "HTTP redirect policy is unavailable" end,
		}
		local ok, client, state = pcall(fresh_client)
		package.loaded["infra.http_redirect_policy"] = previous
		helpers.assert_true(ok)
		local good, bad = nil, nil
		helpers.assert_true(client.get("https://example.invalid/direct", {}, { owner = "kept" }, function(value) good = value end))
		helpers.assert_eq(client.get("https://example.invalid/redirect", {}, { owner = "kept", follow_redirects = true },
			function(value) bad = value end), false)
		helpers.assert_true(bad and bad.ok == false and bad.status == 0)
		helpers.assert_eq(bad.error, "HTTP redirect policy is unavailable")
		helpers.assert_eq(#state.requests, 1)
		helpers.assert_eq(#state.handles, 5)
		helpers.assert_eq(#state.kills, 0)
		helpers.assert_true(client.isActive("kept"))
		state.complete_request(1, "abc\nERGOPTI_HTTP_STATUS:200\n")
		helpers.assert_true(good.ok and good.body == "abc")
	end)

	for index, policy in ipairs({ {}, { sensitive_headers = {} }, { sensitive_headers = "authorization" },
		{ sensitive_headers = { 42 } }, { sensitive_headers = { "AUTHORIZATION" } },
		{ sensitive_headers = { "authorization", "authorization" } }, { sensitive_headers = { authorization = true } } }) do
		helpers.it("linux-http-redirect-policy: rejects malformed shared inventory " .. index, function()
			local previous_json = package.loaded["json"]
			local previous_policy = package.loaded["infra.http_redirect_policy"]
			package.loaded["json"] = { decode = function() return policy end }
			package.loaded["infra.http_redirect_policy"] = nil
			local ok, binding = pcall(require, "infra.http_redirect_policy")
			package.loaded["json"] = previous_json
			package.loaded["infra.http_redirect_policy"] = previous_policy
			helpers.assert_true(ok and type(binding) == "table" and type(binding.allows_native_follow) == "function", tostring(binding))
			local allowed, err = binding.allows_native_follow({ Accept = "application/json" })
			helpers.assert_eq(allowed, nil)
			helpers.assert_eq(err, "HTTP redirect policy is invalid")
		end)
	end
	for _, method in ipairs({ "get", "post", "download", "postStream" }) do
		for index, target in ipairs({ "https://example.invalid/api\0private-suffix", "https://example.invalid/api\0", "\0https://example.invalid/api" }) do
			helpers.it("linux-http-url-nul: refuses " .. method .. " URL byte position " .. index .. " before native allocation", function()
				local client, state = fresh_client()
				local callbacks, result, chunks = 0, nil, 0
				local function complete(value) result = value; callbacks = callbacks + 1 end
				local dispatched
				if method == "get" then dispatched = client.get(target, {}, {}, complete)
				elseif method == "post" then dispatched = client.post(target, {}, "{}", complete)
				elseif method == "download" then dispatched = client.download(target, {}, "/tmp/native-url.part", {}, complete)
				else dispatched = client.postStream(target, {}, "{}", {}, function() chunks = chunks + 1 end, complete) end
				helpers.assert_eq(dispatched, false)
				helpers.assert_eq(callbacks, 1)
				helpers.assert_eq(result.ok, false)
				helpers.assert_eq(result.status, 0)
				helpers.assert_true(type(result.error) == "string" and result.error ~= "")
				helpers.assert_true(result.error:find("private-suffix", 1, true) == nil, "never disclose URL bytes in refusal diagnostics")
				helpers.assert_eq(#state.handles, 0)
				helpers.assert_eq(#state.requests, 0)
				helpers.assert_eq(chunks, 0)
				helpers.assert_eq(client.isActive(), false)
			end)
		end
	end
	helpers.it("linux-http-url-nul: invalid metadata cannot cancel an existing owner", function()
		local client, state = fresh_client()
		local good, bad = nil, nil
		local options = { owner = "retained-native-url" }
		helpers.assert_true(client.get("https://example.invalid/good", {}, options, function(value) good = value end))
		local handles = #state.handles
		helpers.assert_eq(client.get("https://example.invalid/good\0ignored", {}, options, function(value) bad = value end), false)
		helpers.assert_eq(bad.ok, false)
		helpers.assert_true(client.isActive(options.owner))
		helpers.assert_eq(#state.handles, handles)
		helpers.assert_eq(#state.requests, 1)
		helpers.assert_eq(#state.kills, 0)
		state.complete_request(1, "Retained body\nERGOPTI_HTTP_STATUS:200\n", 0)
		helpers.assert_eq(good.ok, true)
		helpers.assert_eq(good.body, "Retained body")
		helpers.assert_eq(client.isActive(options.owner), false)
	end)
	for _, method in ipairs({ "get", "post", "download", "stream", "sha256" }) do
		for _, mode in ipairs({ "deadline", "cancel", "gone", "refusal" }) do
			helpers.it("linux-cli-orphan-receipts: " .. method .. " retains group ownership through " .. mode, function()
				local config = { kill_missing = mode == "gone", kill_failure = mode == "refusal" }
				local client, state
				if method == "sha256" then client, state = fresh_digest(config) else client, state = fresh_client(config) end
				local result, callbacks = nil, 0
				local function done(value) result, callbacks = value, callbacks + 1 end
				if method == "get" then client.get("http://127.0.0.1/receipt", {}, {}, done)
				elseif method == "post" then client.post("http://127.0.0.1/receipt", {}, "{}", done)
				elseif method == "download" then client.download("http://127.0.0.1/receipt", {}, "/tmp/receipt", {}, done)
				elseif method == "stream" then client.postStream("http://127.0.0.1/receipt", {}, "{}", {}, function() end, done)
				else client.sha256("/tmp/receipt", {}, function(value, failure)
					done({ digest = value, error = failure })
				end) end
				state.exit(0)
				helpers.assert_true(client.isActive(), "live inherited streams retain ownership after leader exit")
				if mode == "deadline" then
					state.timer.callback()
					helpers.assert_eq(callbacks, 1)
					helpers.assert_eq(result.error, "timeout")
				else
					local cancelled = client.cancel()
					if mode == "refusal" then
						helpers.assert_eq(cancelled, false, "refused native signal retains the request")
						helpers.assert_true(client.isActive())
						state.allow_kills = true
						helpers.assert_true(client.cancel())
					else helpers.assert_eq(cancelled, true) end
					helpers.assert_eq(callbacks, 0)
				end
				helpers.assert_true(#state.kills >= 1, "leader retirement cannot skip signalling the group")
				helpers.assert_eq(state.kills[1].pid, -4321)
				if mode == "deadline" or mode == "cancel" then
					helpers.assert_eq(state.kills[2].signal, "sigkill")
				end
				helpers.assert_true(not client.isActive())
				for _, handle in ipairs(state.handles) do helpers.assert_true(handle.closing) end
				local previous = callbacks
				state.stdout(nil)
				state.stderr(nil)
				state.exit(0)
				helpers.assert_eq(callbacks, previous, "late stream and exit receipts stay retired")
			end)
		end
	end
	for _, method in ipairs({ "get", "post", "download", "stream", "sha256" }) do
		for _, signal in ipairs({ 15, 9, 10, 12 }) do
			helpers.it("linux-cli-signal-receipts: " .. method .. " rejects signal " .. signal, function()
				local client, state
				if method == "sha256" then client, state = fresh_digest() else client, state = fresh_client() end
				local result, callbacks = nil, 0
				local function done(value) result, callbacks = value, callbacks + 1 end
				if method == "get" then client.get("http://127.0.0.1/receipt", {}, {}, done)
				elseif method == "post" then client.post("http://127.0.0.1/receipt", {}, "{}", done)
				elseif method == "download" then client.download("http://127.0.0.1/receipt", {}, "/tmp/receipt", {}, done)
				elseif method == "stream" then client.postStream("http://127.0.0.1/receipt", {}, "{}", {}, function() end, done)
				else client.sha256("/tmp/receipt", {}, function(value, failure)
					done({ ok = value ~= nil, digest = value, error = failure })
				end) end
				if method == "stream" then
					state.stdout("body")
					state.stderr("\nERGOPTI_HTTP_STATUS:200\n")
				elseif method == "sha256" then state.stdout(string.rep("a1", 32) .. " */tmp/receipt\0")
				else state.stdout("body\nERGOPTI_HTTP_STATUS:200\n") end
				state.stdout(nil)
				state.stderr(nil)
				state.exit(0, signal)
				helpers.assert_eq(callbacks, 1)
				helpers.assert_eq(result.ok, false)
				helpers.assert_true(result.error:find(tostring(128 + signal), 1, true) ~= nil)
				if method == "sha256" then helpers.assert_eq(result.digest, nil)
				else helpers.assert_eq(result.status, 200); helpers.assert_eq(result.body, "") end
				helpers.assert_true(not client.isActive())
				for _, handle in ipairs(state.handles) do helpers.assert_true(handle.closing) end
			end)
		end
	end
	for _, method in ipairs({ "get", "post", "download" }) do
		for _, completed in ipairs({ false, true }) do
			helpers.it("linux-buffered-http-receipt: " .. method .. " validates "
				.. (completed and "complete success" or "incomplete transfer"), function()
				local client, state = fresh_client()
				local result, terminals = nil, 0
				local function done(value) result = value; terminals = terminals + 1 end
				local options = { owner = "buffered-receipt" }
				if method == "get" then
					client.get("http://127.0.0.1/fixture", {}, options, done)
				elseif method == "post" then
					client.post("http://127.0.0.1/fixture", {}, "{}", done, options)
				else
					client.download("http://127.0.0.1/fixture", {}, "/tmp/owned-download", options, done)
				end
				state.stderr(completed and "" or "curl: (18) transfer closed with bytes remaining")
				state.complete_request(1, "partial\nERGOPTI_HTTP_STATUS:200\n", completed and 0 or 18)
				helpers.assert_eq(terminals, 1, "one native receipt yields one completion")
				helpers.assert_eq(result.status, 200, "retain the real HTTP status")
				helpers.assert_eq(result.ok, completed, "HTTP status alone cannot prove completed transport")
				if completed then
					helpers.assert_eq(result.error, nil, "successful requests do not carry an error")
					helpers.assert_eq(result.body, "partial")
				else
					helpers.assert_true(result.error:find("bytes remaining", 1, true) ~= nil)
					helpers.assert_eq(result.body, "", "partial bytes cannot become a successful body")
				end
				helpers.assert_true(not client.isActive(options.owner), "request ownership settles")
			end)
		end
	end

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
		helpers.assert_true(state.config:find('data-raw = "{\\"q\\":\\"Mon mot de passe \\\\\\"x\\\\\\"\\"}"', 1, true) ~= nil,
			"quotes and backslashes are escaped for curl's config parser: " .. tostring(state.config))
		helpers.assert_true(state.config:find('url = "https://api.cerebras.ai/v1/chat/completions"', 1, true) ~= nil)
	end)

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
		helpers.assert_true(state.config:find([[data-raw = "{'quoted':true}"]], 1, true) ~= nil,
			"the body must reach curl literally")
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
	local native_ok = pcall(require, "luv")
	local ffi_ok = pcall(require, "ffi")
	if native_ok and ffi_ok and package.config:sub(1, 1) == "/" then
		helpers.it("linux-digest-replacement: rejected paths preserve an actual native incumbent", function()
			local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
			local fixture = helpers.driver_root() .. "/tests/fixtures/native_file_digest_replacement.lua"
			local result = os.execute(quote(assert(arg[-1])) .. " " .. quote(fixture))
			helpers.assert_true(result == true or result == 0, "native digest replacement fixture must pass")
		end)
	end

	for _, length in ipairs({ 957, 958, 1106, 3500 }) do
		helpers.it("linux-digest-path-budget: hashes a " .. length .. "-byte path", function()
			local digest, state = fresh_digest()
			local path = "/" .. string.rep("p", length - 1)
			local value, err, callbacks = nil, nil, 0
			local expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
			helpers.assert_true(digest.sha256(path, {}, function(result, failure)
				value, err, callbacks = result, failure, callbacks + 1
			end))
			local receipt = expected .. " *" .. path .. "\0"
			-- Exercise accumulated chunks, not only a single oversized read.
			for index = 1, #receipt, 113 do state.stdout(receipt:sub(index, index + 112)) end
			state.complete_request(1, nil, 0)
			helpers.assert_eq(value, expected)
			helpers.assert_eq(err, nil)
			helpers.assert_eq(callbacks, 1)
			helpers.assert_true(not digest.isActive())
			for _, handle in ipairs(state.handles) do helpers.assert_true(handle.closing) end
		end)
	end

	for _, stream in ipairs({ "stdout", "stderr" }) do
		helpers.it("linux-digest-path-budget: bounds excess " .. stream .. " on long paths", function()
			local digest, state = fresh_digest()
			local path = "/" .. string.rep("p", 1105)
			local value, err, callbacks = nil, nil, 0
			helpers.assert_true(digest.sha256(path, {}, function(result, failure)
				value, err, callbacks = result, failure, callbacks + 1
			end))
			local limit = stream == "stdout" and 1024 + #path or 1024
			state[stream](string.rep("x", limit + 1))
			state.complete_request(1, nil, 0)
			helpers.assert_eq(value, nil)
			helpers.assert_eq(err, "sha256sum output exceeds limit")
			helpers.assert_eq(callbacks, 1, "late exit must not publish a second receipt")
			helpers.assert_true(not digest.isActive())
			helpers.assert_eq(state.kills[1].pid, -4321)
			for _, handle in ipairs(state.handles) do helpers.assert_true(handle.closing) end
		end)
	end

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

helpers.describe("http_client: cancellation receipt boundary", function()
	helpers.it("legacy HTTP cancellation is only signal acceptance before native exit and close ACKs", function()
		local client, state = fresh_client({ defer_close = true })
		client.get("http://127.0.0.1:9000/v1/models", {}, { owner = "local-api" }, function() end)
		local exited = false
		local original_exit = state.exit_callback
		state.exit_callback = function(...)
			exited = true
			original_exit(...)
		end
		helpers.assert_true(client.cancel("local-api"))
		helpers.assert_eq(client.isActive("local-api"), false)
		helpers.assert_eq(exited, false, "logical cancellation does not acknowledge native process exit")
		helpers.assert_eq(state.process.closing, false, "the native process handle remains owned until exit")
		state.exit(0)
		helpers.assert_true(exited)
		helpers.assert_true(state.process.closing)
	end)
end)

helpers.describe("http_client: retained GET settlement", function()
	helpers.it("owned GET waits for actual exit and every native close acknowledgment", function()
		local client, state = fresh_client({ defer_close = true })
		local terminals, settled, result = 0, 0, nil
		local operation = client.get_owned("http://127.0.0.1:9000/v1/models", {},
			{ owner = "local-api", timeout_ms = 1500 }, function(value)
				terminals = terminals + 1; result = value
			end)
		helpers.assert_true(operation.started)
		helpers.assert_eq(operation:is_settled(), false)
		helpers.assert_true(operation:on_settled(function() settled = settled + 1 end))
		state.stdout('{"data":[]}\nERGOPTI_HTTP_STATUS:200\n')
		state.stdout(nil); state.stderr(nil)
		state.ack_closes()
		helpers.assert_eq(terminals, 0, "EOF and pipe closure do not acknowledge process exit")
		helpers.assert_eq(operation:is_settled(), false)
		state.exit(0)
		helpers.assert_eq(terminals, 0, "process exit does not acknowledge pending close callbacks")
		state.ack_closes()
		helpers.assert_eq(operation:is_settled(), true)
		helpers.assert_eq(settled, 1)
		helpers.assert_eq(terminals, 1)
		helpers.assert_eq(result.status, 200)
		helpers.assert_eq(result.body, '{"data":[]}')
	end)

	helpers.it("owned GET cancellation retains debt and blocks both APIs until physical settlement", function()
		local client, state = fresh_client({ defer_close = true })
		local terminals, rejected = 0, nil
		local operation = client.get_owned("http://127.0.0.1:9000/v1/models", {},
			{ owner = "local-api" }, function() terminals = terminals + 1 end)
		helpers.assert_eq(operation:cancel(), false, "SIGTERM acceptance is not a physical exit receipt")
		helpers.assert_eq(client.isActive("local-api"), false, "the legacy logical activity ABI is unchanged")
		helpers.assert_eq(client.get("http://127.0.0.1:9000/v1/models", {}, { owner = "local-api" },
			function(value) rejected = value end), false)
		helpers.assert_eq(rejected.error, "previous request cleanup pending")
		local successor = client.get_owned("http://127.0.0.1:9000/v1/models", {},
			{ owner = "local-api" }, function() end)
		helpers.assert_eq(successor.started, false)
		helpers.assert_true(successor:is_settled(), "a refused successor acquires no native resource")
		helpers.assert_eq(#state.requests, 1)
		state.ack_closes()
		helpers.assert_eq(operation:is_settled(), false)
		state.exit(0)
		helpers.assert_eq(operation:is_settled(), false)
		state.ack_closes()
		helpers.assert_true(operation:cancel())
		helpers.assert_eq(terminals, 0, "late terminal events cannot publish after cancellation")
		local fresh = client.get_owned("http://127.0.0.1:9000/v1/models", {},
			{ owner = "local-api" }, function() end)
		helpers.assert_true(fresh.started)
		state.complete_request(2, '[]\nERGOPTI_HTTP_STATUS:200\n')
		state.ack_closes()
		helpers.assert_true(fresh:is_settled())
		state.exit(0)
		helpers.assert_eq(terminals, 0)
	end)

	helpers.it("owned GET fences callbacks on refused termination and keeps independent requests", function()
		local client, state = fresh_client({ kill_failure = true, defer_close = true })
		local terminals, independent = 0, nil
		local operation = client.get_owned("http://127.0.0.1:9000/v1/models", {},
			{ owner = "local-api" }, function() terminals = terminals + 1 end)
		client.get("http://127.0.0.1:9001/v1/models", {}, { owner = "prediction" },
			function(value) independent = value end)
		helpers.assert_eq(operation:cancel(), false)
		helpers.assert_true(client.isActive("local-api"))
		helpers.assert_true(client.isActive("prediction"))
		state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n')
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(terminals, 0, "cancel intent fences delivery even if the signal refuses")
		state.complete_request(2, '[]\nERGOPTI_HTTP_STATUS:200\n')
		helpers.assert_true(independent.ok)
	end)

	helpers.it("owned GET retries refused close and never reports it as settlement", function()
		local client, state = fresh_client({ close_failure = true, defer_close = true })
		local receipt
		local operation = client.get_owned("http://127.0.0.1:9000/v1/models", {},
			{ owner = "local-api" }, function(value) receipt = value end)
		state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n')
		helpers.assert_eq(receipt, nil)
		helpers.assert_eq(operation:is_settled(), false)
		state.allow_closes = true
		helpers.assert_eq(operation:cancel(), false)
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(receipt, nil, "cancelling a cleanup retry suppresses its pending success")
	end)

	helpers.it("owned GET failed spawn settles only after its allocated handles close", function()
		local client, state = fresh_client({ spawn_failure = true, defer_close = true })
		local failures = 0
		local operation = client.get_owned("http://127.0.0.1:9000/v1/models", {},
			{ owner = "local-api" }, function() failures = failures + 1 end)
		helpers.assert_eq(operation.started, false)
		helpers.assert_eq(operation:is_settled(), false)
		helpers.assert_eq(failures, 0)
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(failures, 1)
	end)
end)

helpers.describe("http_client: owned GET refusal boundaries", function()
	helpers.it("owned GET captures partial allocations before a later constructor throws", function()
		local client, state = fresh_client({ allocation_failure_at = 2, defer_close = true })
		local receipt
		local operation = client.get_owned("http://127.0.0.1:9000/v1/models", {},
			{ owner = "local-api" }, function(value) receipt = value end)
		helpers.assert_eq(operation.started, false)
		helpers.assert_eq(operation:is_settled(), false)
		helpers.assert_eq(#state.handles, 1)
		helpers.assert_eq(receipt, nil)
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(receipt.error, "libuv handle allocation failed")
	end)

	helpers.it("owned GET timeout retains refused termination debt and retries the exact process", function()
		local client, state = fresh_client({ kill_failure = true, defer_close = true })
		local terminals = 0
		local operation = client.get_owned("http://127.0.0.1:9000/v1/models", {},
			{ owner = "local-api" }, function() terminals = terminals + 1 end)
		state.timer.callback()
		state.ack_closes()
		helpers.assert_eq(client.isActive("local-api"), false)
		helpers.assert_eq(operation:is_settled(), false)
		helpers.assert_eq(terminals, 0)
		helpers.assert_eq(operation:cancel(), false)
		state.allow_kills = true
		helpers.assert_eq(operation:cancel(), false)
		helpers.assert_eq(state.kills[#state.kills].pid, -4321)
		state.exit(0)
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(terminals, 0, "cancel intent must suppress the pending timeout receipt")
	end)

	helpers.it("owned GET refuses an incomplete 200 and preserves genuine HTTP auth failure", function()
		for _, case in ipairs({
			{ status = 200, code = 18, error = "curl exited with code 18" },
			{ status = 401, code = 22, error = "HTTP 401" },
		}) do
			local client, state = fresh_client({ defer_close = true })
			local result
			local operation = client.get_owned("http://127.0.0.1:9000/v1/models", {},
				{ owner = "local-api" }, function(value) result = value end)
			state.complete_request(1, '{"data":[]}\nERGOPTI_HTTP_STATUS:' .. case.status .. '\n', case.code)
			state.ack_closes()
			helpers.assert_true(operation:is_settled())
			helpers.assert_eq(result.ok, false)
			helpers.assert_eq(result.status, case.status)
			helpers.assert_eq(result.error, case.error)
		end
	end)

	helpers.it("owned GET timer activation refusal waits for allocated native handle closure", function()
		local client, state = fresh_client({ timer_failure = true, defer_close = true })
		local receipt
		local operation = client.get_owned("http://127.0.0.1:9000/v1/models", {},
			{ owner = "local-api" }, function(value) receipt = value end)
		helpers.assert_eq(operation.started, false)
		helpers.assert_eq(operation:is_settled(), false)
		helpers.assert_eq(#state.requests, 0)
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(receipt.error, "timeout activation failed")
	end)
end)

helpers.describe("http_client: owned GET construction boundary", function()
	helpers.it("owned GET request construction refusal retains already allocated native handles", function()
		local client, state = fresh_client({ defer_close = true })
		local receipt
		local hostile_header = setmetatable({}, { __tostring = function() error("private header must not appear") end })
		local operation = client.get_owned("http://127.0.0.1:9000/v1/models", { Authorization = hostile_header },
			{ owner = "local-api" }, function(value) receipt = value end)
		helpers.assert_eq(operation.started, false)
		helpers.assert_eq(operation:is_settled(), false)
		helpers.assert_eq(#state.requests, 0)
		helpers.assert_eq(receipt, nil)
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(receipt.error, "curl request construction failed")
	end)
end)
