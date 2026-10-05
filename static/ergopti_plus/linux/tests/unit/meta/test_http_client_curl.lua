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
	local state = { groups = {}, probes = {}, timer_starts = {}, kills = {}, handles = {}, requests = {}, closes = {}, refused_closes = {},
		descriptors = {}, descriptor_closes = {}, identities = {} }
	local fake = {}
	local function refused(receipt)
		if receipt == "throw" then error("SIMULATED close refusal") end
		if receipt == "false" then return false end
		return nil
	end

	local function handle(kind)
		if options.allocation_nil_at == #state.handles + 1 then return nil end
		if options.allocation_failure_at == #state.handles + 1 then error("allocation refused") end
		local value = { kind = kind, closing = false }
		state.handles[#state.handles + 1] = value
		return value
	end

	function fake.new_pipe() return handle("pipe") end
	function fake.update_time() end -- native void-style clock refresh
	function fake.pipe()
		if options.body_pipe_failure then return nil, "pipe refused" end
		local read, write = 100 + #state.descriptors, 101 + #state.descriptors
		state.descriptors[#state.descriptors + 1] = read
		state.descriptors[#state.descriptors + 1] = write
		state.identities[read] = { dev = 1, ino = read, type = "fifo" }
		state.identities[write] = { dev = 1, ino = read, type = "fifo" }
		return { read = read, write = write }
	end
	function fake.pipe_open(pipe, descriptor)
		state.first_body_handle = state.first_body_handle or pipe
		if options.body_attach_failure then return nil, "attachment refused" end
		pipe.descriptor = descriptor
		state.body_pipe = pipe
		return 0
	end
	function fake.fs_close(descriptor)
		state.descriptor_closes[#state.descriptor_closes + 1] = descriptor
		if options.raw_close_receipt and not state.allow_closes then
			if options.close_after_retirement then
				state.identities[descriptor] = options.reuse_descriptor and { dev = 9, ino = 99, type = "file" } or nil
			end
			return refused(options.raw_close_receipt)
		end
		state.identities[descriptor] = nil
		return true
	end
	function fake.fs_fstat(descriptor)
		if options.body_metadata_failure and not state.allow_metadata then return nil, "SIMULATED metadata failure", "EIO" end
		if state.identities[descriptor] then return state.identities[descriptor] end
		return nil, "descriptor absent", "EBADF"
	end
	function fake.new_timer()
		state.timer = handle("timer")
		return state.timer
	end
	function fake.timer_start(timer, timeout_ms, repeat_ms, callback)
		state.timer_starts[#state.timer_starts + 1] = { timer = timer, timeout = timeout_ms, repeat_ms = repeat_ms, callback = callback }
		if options.timer_failure or (repeat_ms > 0 and state.monitor_refused) then return nil, "timer refused" end
		timer.stopped = false
		timer.timeout_ms = timeout_ms
		timer.repeat_ms = repeat_ms
		timer.callback = callback
		return true
	end
	function fake.timer_stop(timer) timer.stopped = true; return true end
	function fake.read_start(pipe, callback) pipe.read_callback = callback; return true end
	function fake.write(pipe, data, callback)
		if pipe == state.body_pipe and options.body_write_failure then return nil, "write refused" end
		pipe.written = (pipe.written or "") .. data
		if pipe == state.body_pipe then state.body = pipe.written else state.config = pipe.written end
		if pipe == state.body_pipe and options.defer_body_write then state.body_written = callback; return true end
		if callback then callback(nil) end
		return true
	end
	function fake.read_stop(pipe) pipe.read_stopped = true; return true end
	function fake.is_closing(value) return value.closing end
	function fake.close(value, callback)
		if options.refused_close_callback and not state.allow_closes then
			state.refused_closes[#state.refused_closes + 1] = callback
			if options.refused_close_sync then callback() end
			if options.refused_close_callback == "throw" then error("close refused") end
			if options.refused_close_callback == "false" then return false end
			return nil, "close refused"
		end
		if value == state.first_body_handle and options.body_handle_close_receipt and not state.allow_closes then
			return refused(options.body_handle_close_receipt)
		end
		if options.close_failure and not state.allow_closes then return nil, "close refused" end
		if value.kind == "timer" and state.monitor_close_refused then return nil, "monitor close refused" end
		value.closing = true
		if value.descriptor then
			state.descriptor_closes[#state.descriptor_closes + 1] = value.descriptor
			state.identities[value.descriptor] = nil
			value.descriptor = nil
		end
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
		if signal == 0 then
			state.probes[#state.probes + 1] = { pid = pid, signal = signal }
			if state.probe_mode == "throw" then error("probe refused") end
			if state.probe_mode == "false" then return false end
			if state.probe_mode == "nil" then return nil end
			if state.probe_mode == "text-only" then return nil, "ESRCH: no such process" end
			if state.probe_mode == "unknown-code" then return nil, "probe refused", "EPERM" end
			if state.groups[-pid] == false then return nil, "ESRCH: no such process", "ESRCH" end
			return true
		end
		if options.kill_missing then return nil, "ESRCH: no such process", "ESRCH" end
		if options.kill_failure and not state.allow_kills then return nil, "EPERM: operation not permitted", "EPERM" end
		return true
	end
	function fake.spawn(command, options, callback)
		if config and config.spawn_failure then return nil, "EACCES", "permission denied" end
		local pid = 4320 + #state.requests + 1
		state.groups[pid] = true
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
	function state.exit(code, signal)
		if not options.descendants_alive then state.groups[state.requests[#state.requests].pid] = false end
		state.exit_callback(code or 0, signal or 0)
	end
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
		if not options.descendants_alive then state.groups[request.pid] = false end
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

helpers.describe("http_client: native POST redirect method selection", function()
	for _, method in ipairs({ "post", "postStream" }) do
		for _, body in ipairs({ { name = "nil" }, { name = "empty", value = "" }, { name = "literal", value = "{}" } }) do
			for _, follows in ipairs({ false, true }) do
				helpers.it("linux-http-redirect-method: " .. method .. " " .. body.name .. " body uses curl's native POST selection (follow=" .. tostring(follows) .. ")", function()
					local client, state = fresh_client()
					local result
					local options = { follow_redirects = follows }
					local function complete(value) result = value end
					if method == "post" then helpers.assert_true(client.post("http://127.0.0.1:9000/", {}, body.value, complete, options))
					else helpers.assert_true(client.postStream("http://127.0.0.1:9000/", {}, body.value, options, function() end, complete)) end
					for _, argument in ipairs(state.options.args) do
						helpers.assert_true(argument ~= "--request", "a custom POST word prevents native redirect method changes")
					end
					local joined = "\n" .. table.concat(state.options.args, "\n") .. "\n"
					helpers.assert_eq(joined:find("\n--location\n", 1, true) ~= nil, follows)
					helpers.assert_true(state.config:find("data-raw = ", 1, true) ~= nil or state.config:find("data-binary = ", 1, true) ~= nil,
						"the data option must still select POST for nil and empty bodies")
					if method == "postStream" then state.stdout("abc"); state.stderr("\nERGOPTI_HTTP_STATUS:200\n"); state.complete()
					else state.complete_request(1, "abc\nERGOPTI_HTTP_STATUS:200\n") end
					helpers.assert_true(result and result.ok and result.status == 200)
				end)
			end
		end
	end

	for _, method in ipairs({ "get", "get_owned", "download" }) do
		helpers.it("linux-http-redirect-method: " .. method .. " retains explicit GET", function()
			local client, state = fresh_client()
			local result
			local function complete(value) result = value end
			if method == "download" then helpers.assert_true(client.download("http://127.0.0.1:9000/", {}, "/tmp/unit-redirect-method", {}, complete))
			elseif method == "get_owned" then helpers.assert_true(client.get_owned("http://127.0.0.1:9000/", {}, {}, complete).started)
			else helpers.assert_true(client.get("http://127.0.0.1:9000/", {}, {}, complete)) end
			local count = 0
			for index, argument in ipairs(state.options.args) do
				if argument == "--request" then count = count + 1; helpers.assert_eq(state.options.args[index + 1], "GET") end
			end
			helpers.assert_eq(count, 1)
			state.complete_request(1, "abc\nERGOPTI_HTTP_STATUS:200\n")
			helpers.assert_true(result and result.ok)
		end)
	end

	for _, method in ipairs({ "post", "postStream" }) do
		helpers.it("linux-http-redirect-method: " .. method .. " keeps the synthetic credential redirect fence", function()
			local client, state = fresh_client()
			local options = { follow_redirects = true }
			local headers = { ["X-Api-Key"] = "SyntheticFixtureOnly" }
			if method == "post" then helpers.assert_true(client.post("http://127.0.0.1:9000/", headers, "{}", function() end, options))
			else helpers.assert_true(client.postStream("http://127.0.0.1:9000/", headers, "{}", options, function() end, function() end)) end
			local joined = "\n" .. table.concat(state.options.args, "\n") .. "\n"
			helpers.assert_nil(joined:find("\n--location\n", 1, true))
			helpers.assert_nil(joined:find("\n--request\n", 1, true))
			helpers.assert_eq(options.follow_redirects, true)
		end)
	end
end)

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
				helpers.assert_eq(state.body, body, "the dedicated channel carries exact caller bytes")
				helpers.assert_true(state.config:find('data-binary = "@/dev/fd/3"\n', 1, true) ~= nil,
					"only the adapter's fixed pipe reference can become a curl filename")
				helpers.assert_nil(state.config:find('data-binary = "' .. body .. '"\n', 1, true), "caller @ must not select a curl filename")
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

	for _, case in ipairs(invalid_preflight) do
		helpers.it("owned-http-preflight: " .. case.name .. " retains its regular predecessor", function()
			local client, state = fresh_client({ defer_close = true })
			local good, bad, good_callbacks, bad_callbacks = nil, nil, 0, 0
			helpers.assert_true(client.get("https://example.invalid/held", {}, { owner = "kept" }, function(value)
				good, good_callbacks = value, good_callbacks + 1
			end))
			local handles, requests = #state.handles, #state.requests
			local options = { owner = "kept" }
			for key, value in pairs(case.options or {}) do options[key] = value end
			if case.download then options.output_path = case.download end
			local operation = client.get_owned(case.url or "https://example.invalid/direct", case.headers or {}, options,
				function(value) bad, bad_callbacks = value, bad_callbacks + 1 end)
			helpers.assert_eq(operation.started, false)
			helpers.assert_true(operation:is_settled(), "invalid replacement has no native cleanup debt")
			helpers.assert_eq(bad_callbacks, 1)
			helpers.assert_true(bad and bad.ok == false and bad.status == 0 and type(bad.error) == "string")
			helpers.assert_nil(bad.error:find("private-suffix", 1, true))
			helpers.assert_nil(bad.error:find("Synthetic private header value", 1, true))
			helpers.assert_eq(#state.handles, handles, "owned replacement preflight precedes native allocation")
			helpers.assert_eq(#state.requests, requests)
			helpers.assert_eq(#state.kills, 0, "invalid owned replacement cannot terminate its predecessor")
			helpers.assert_true(client.isActive("kept"))
			state.complete_request(1, "abc\nERGOPTI_HTTP_STATUS:200\n")
			helpers.assert_true(good and good.ok and good.body == "abc")
			helpers.assert_eq(good_callbacks, 1)
		end)
	end

	helpers.it("owned-http-preflight: valid replacement composes once and retains physical cleanup ownership", function()
		local client, state = fresh_client({ defer_close = true })
		local previous, result, conversions = nil, nil, 0
		helpers.assert_true(client.get("https://example.invalid/held", {}, { owner = "kept" },
			function(value) previous = value end))
		local header = setmetatable({}, { __tostring = function()
			conversions = conversions + 1
			return "Synthetic native header"
		end })
		local operation = client.get_owned("https://example.invalid/direct", { ["X-Native"] = header }, { owner = "kept" },
			function(value) result = value end)
		helpers.assert_true(operation.started)
		helpers.assert_eq(conversions, 1, "validated metadata must not be constructed again after displacement")
		helpers.assert_eq(#state.requests, 2)
		helpers.assert_eq(#state.kills, 2)
		state.complete_request(2, "abc\nERGOPTI_HTTP_STATUS:200\n")
		helpers.assert_nil(result, "owned replacement waits for every native close acknowledgment")
		helpers.assert_true(not operation:is_settled())
		local blocked
		helpers.assert_eq(client.get("https://example.invalid/blocked", {}, { owner = "kept" },
			function(value) blocked = value end), false)
		helpers.assert_eq(blocked.error, "previous request cleanup pending")
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_true(result and result.ok and result.body == "abc")
		state.complete_request(1, "old\nERGOPTI_HTTP_STATUS:200\n")
		helpers.assert_nil(previous, "the displaced ordinary predecessor cannot publish a stale receipt")
	end)

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
		helpers.it("linux-digest-allocation: actual partial handles retire before refusal returns", function()
			local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
			local fixture = helpers.driver_root() .. "/tests/fixtures/native_file_digest_allocations.lua"
			local result = os.execute(quote(assert(arg[-1])) .. " " .. quote(fixture))
			helpers.assert_true(result == true or result == 0, "native digest allocation fixture must pass")
		end)
		helpers.it("linux-digest-replacement: rejected paths preserve an actual native incumbent", function()
			local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
			local fixture = helpers.driver_root() .. "/tests/fixtures/native_file_digest_replacement.lua"
			local result = os.execute(quote(assert(arg[-1])) .. " " .. quote(fixture))
			helpers.assert_true(result == true or result == 0, "native digest replacement fixture must pass")
		end)
		helpers.it("linux-digest-owner: actual updater cancellation preserves another native digest", function()
			local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
			local fixture = helpers.driver_root() .. "/tests/fixtures/native_file_digest_owners.lua"
			local result = os.execute(quote(assert(arg[-1])) .. " " .. quote(fixture))
			helpers.assert_true(result == true or result == 0, "native digest owner fixture must pass")
		end)
	end

	for _, mode in ipairs({ "raised", "nil" }) do
		for slot = 1, 3 do
			helpers.it("linux-digest-allocation: " .. mode .. " constructor at " .. slot .. " releases prior handles", function()
				local options = {}
				options[mode == "raised" and "allocation_failure_at" or "allocation_nil_at"] = slot
				local digest, state = fresh_digest(options)
				local value, failure, callbacks = nil, nil, 0
				helpers.assert_eq(digest.sha256("/tmp/allocation.part", { owner = "allocation-unit" }, function(hash, err)
					value, failure, callbacks = hash, err, callbacks + 1
				end), false)
				helpers.assert_nil(value)
				helpers.assert_eq(failure, "libuv handle allocation failed")
				helpers.assert_eq(callbacks, 1)
				helpers.assert_eq(#state.requests, 0)
				helpers.assert_nil(state.command)
				helpers.assert_true(not digest.isActive("allocation-unit"))
				helpers.assert_eq(#state.handles, slot - 1)
				for _, handle in ipairs(state.handles) do helpers.assert_true(handle.closing, "partial allocation must close") end
				helpers.assert_true(digest.cancel("allocation-unit"))
				helpers.assert_eq(callbacks, 1, "cancelling a refused owner cannot publish another callback")
			end)
		end
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
	for _, refusal in ipairs({ "false", "error", "throw" }) do
		for _, synchronous in ipairs({ false, true }) do
			helpers.it("owned-close-admission: refused " .. refusal .. " callback (sync=" .. tostring(synchronous) .. ")", function()
				local client, state = fresh_client({
					refused_close_callback = refusal, refused_close_sync = synchronous, defer_close = true,
				})
				local terminals, settlements = 0, 0
				local operation = client.get_owned("http://127.0.0.1:9000/v1/models", {},
					{ owner = "local-api" }, function() terminals = terminals + 1 end)
				operation:on_settled(function() settlements = settlements + 1 end)
				state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n')
				for _, callback in ipairs(state.refused_closes) do callback() end
				helpers.assert_eq(operation:is_settled(), false, "a refused close callback cannot release its handle")
				helpers.assert_eq(terminals, 0)
				helpers.assert_eq(settlements, 0)
				local successor = client.get_owned("http://127.0.0.1:9000/v1/models", {},
					{ owner = "local-api" }, function() end)
				helpers.assert_eq(successor.started, false, "the exact owner retains unacknowledged resources")
				state.allow_closes = true
				helpers.assert_eq(operation:cancel(), false)
				for _, callback in ipairs(state.refused_closes) do callback() end
				helpers.assert_eq(operation:is_settled(), false, "an old attempt cannot acknowledge its accepted successor")
				state.ack_closes()
				helpers.assert_true(operation:is_settled())
				helpers.assert_eq(settlements, 1)
				helpers.assert_eq(terminals, 0, "cancellation suppresses the retained success")
				state.ack_closes()
				helpers.assert_eq(settlements, 1)
			end)
		end
	end

	helpers.it("owned-close-admission: accepted synchronous callbacks settle exactly once", function()
		local client, state = fresh_client()
		local terminals, settlements = 0, 0
		local operation = client.get_owned("http://127.0.0.1:9000/v1/models", {},
			{ owner = "local-api" }, function() terminals = terminals + 1 end)
		operation:on_settled(function() settlements = settlements + 1 end)
		state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n')
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(terminals, 1)
		helpers.assert_eq(settlements, 1)
		state.ack_closes()
		helpers.assert_eq(terminals, 1)
		helpers.assert_eq(settlements, 1)
	end)

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

helpers.describe("http_client: request body pipe refusal boundaries", function()
	for _, case in ipairs({
		{ name = "handle allocation", options = { allocation_failure_at = 5 }, descriptors = 0 },
		{ name = "anonymous pipe allocation", options = { body_pipe_failure = true }, descriptors = 0 },
		{ name = "pipe attachment", options = { body_attach_failure = true }, descriptors = 2 },
		{ name = "spawn", options = { spawn_failure = true }, descriptors = 2 },
	}) do
		helpers.it("linux-http-body-pipe: simulated " .. case.name .. " refusal retires every admitted resource", function()
			local client, state = fresh_client(case.options)
			local result, callbacks = nil, 0
			helpers.assert_eq(client.post("http://127.0.0.1:9000/", {}, '{"text":"literal"}', function(value)
				result, callbacks = value, callbacks + 1
			end), false)
			helpers.assert_true(result and result.ok == false and result.status == 0)
			helpers.assert_eq(callbacks, 1)
			helpers.assert_eq(#state.requests, 0)
			helpers.assert_eq(#state.descriptor_closes, case.descriptors)
			for _, handle in ipairs(state.handles) do helpers.assert_true(handle.closing, "an admitted native handle was lost") end
		end)
	end

	for _, asynchronous in ipairs({ false, true }) do
		helpers.it("linux-http-body-pipe: simulated " .. (asynchronous and "asynchronous" or "immediate") .. " write refusal fences late receipts", function()
			local client, state = fresh_client({ body_write_failure = not asynchronous, defer_body_write = asynchronous })
			local result, callbacks = nil, 0
			local dispatched = client.post("http://127.0.0.1:9000/", {}, '{"text":"literal"}', function(value)
				result, callbacks = value, callbacks + 1
			end)
			helpers.assert_eq(dispatched, asynchronous)
			if asynchronous then state.body_written("EPIPE") end
			helpers.assert_true(result and result.ok == false and result.error == "curl body write failed")
			helpers.assert_eq(callbacks, 1)
			helpers.assert_eq(#state.kills, 2)
			helpers.assert_eq(#state.descriptor_closes, 2)
			state.complete_request(1, "abc\nERGOPTI_HTTP_STATUS:200\n")
			helpers.assert_eq(callbacks, 1)
			for _, handle in ipairs(state.handles) do helpers.assert_true(handle.closing) end
		end)
	end

	for _, cancelled in ipairs({ false, true }) do
		helpers.it("linux-http-body-pipe: " .. (cancelled and "cancellation" or "deadline") .. " closes a pending writer without affecting its successor", function()
			local client, state = fresh_client({ defer_body_write = true })
			local callbacks, result, successor = 0, nil, nil
			helpers.assert_true(client.post("http://127.0.0.1:9000/", {}, '{"text":"literal"}', function(value)
				result, callbacks = value, callbacks + 1
			end, { owner = "body-owner" }))
			local completed_write, writer = state.body_written, state.body_pipe
			helpers.assert_true(not writer.closing)
			if cancelled then helpers.assert_true(client.cancel("body-owner")) else state.timer.callback() end
			helpers.assert_true(writer.closing)
			helpers.assert_eq(callbacks, cancelled and 0 or 1)
			if not cancelled then helpers.assert_eq(result.error, "timeout") end
			helpers.assert_eq(#state.descriptor_closes, 2)
			helpers.assert_true(client.get("http://127.0.0.1:9000/fresh", {}, { owner = "body-owner" },
				function(value) successor = value end))
			completed_write("EPIPE")
			helpers.assert_true(client.isActive("body-owner"), "a stale body write retired its new owner")
			state.complete_request(1, "old\nERGOPTI_HTTP_STATUS:200\n")
			state.complete_request(2, "abc\nERGOPTI_HTTP_STATUS:200\n")
			helpers.assert_true(successor and successor.ok and successor.body == "abc")
			helpers.assert_eq(callbacks, cancelled and 0 or 1)
		end)
	end

	for _, method in ipairs({ "post", "postStream" }) do
		helpers.it("linux-http-body-pipe: " .. method .. " retains literal NUL refusal before replacing a valid owner", function()
			local client, state = fresh_client()
			local good, bad = nil, nil
			helpers.assert_true(client.get("http://127.0.0.1:9000/held", {}, { owner = "kept" }, function(value) good = value end))
			local handles = #state.handles
			local complete = function(value) bad = value end
			local dispatched
			if method == "post" then dispatched = client.post("http://127.0.0.1:9000/", {}, "before\0after", complete, { owner = "kept" })
			else dispatched = client.postStream("http://127.0.0.1:9000/", {}, "before\0after", { owner = "kept" }, function() end, complete) end
			helpers.assert_eq(dispatched, false)
			helpers.assert_true(bad and bad.ok == false and bad.status == 0)
			helpers.assert_eq(#state.handles, handles)
			helpers.assert_eq(#state.requests, 1)
			helpers.assert_eq(#state.kills, 0)
			helpers.assert_true(client.isActive("kept"))
			state.complete_request(1, "abc\nERGOPTI_HTTP_STATUS:200\n")
			helpers.assert_true(good and good.ok and good.body == "abc")
		end)
	end
end)

helpers.describe("http_client: exceptional body cleanup ownership", function()
	for _, receipt in ipairs({ "nil", "false", "throw" }) do
		for _, raw in ipairs({ false, true }) do
			helpers.it("linux-http-body-cleanup: simulated " .. receipt .. (raw and " raw rollback" or " reader handle") .. " refusal retains and retries its exact owner", function()
				local options = { defer_close = true }
				if raw then options.body_attach_failure = true; options.raw_close_receipt = receipt
				else options.body_handle_close_receipt = receipt end
				local client, state = fresh_client(options)
				local callbacks, blocked = 0, nil
				helpers.assert_eq(client.post("http://127.0.0.1:9000/", {}, "{}", function() callbacks = callbacks + 1 end, { owner = "body-debt" }), false)
				state.ack_closes()
				helpers.assert_eq(callbacks, 0)
				local candidate = client.get_owned("http://127.0.0.1:9000/", {}, { owner = "body-debt" }, function(value) blocked = value end)
				helpers.assert_eq(candidate.started, false)
				helpers.assert_eq(blocked.error, "previous request cleanup pending")
				helpers.assert_eq(client.cancel("body-debt"), false)
				state.allow_closes = true
				if not raw then state.exit(0) end
				client.cancel("body-debt")
				state.ack_closes()
				helpers.assert_true(client.cancel("body-debt"))
				helpers.assert_eq(callbacks, 0)
				for _, fd in ipairs(state.descriptors) do helpers.assert_nil(state.identities[fd]) end
				for _, handle in ipairs(state.handles) do helpers.assert_true(handle.closing) end
			end)
		end
		for _, reused in ipairs({ false, true }) do
			helpers.it("linux-http-body-cleanup: simulated " .. receipt .. " after retirement " .. (reused and "preserves reused descriptor" or "avoids EBADF retry"), function()
				local client, state = fresh_client({ body_attach_failure = true, raw_close_receipt = receipt,
					close_after_retirement = true, reuse_descriptor = reused })
				local callbacks = 0
				helpers.assert_eq(client.post("http://127.0.0.1:9000/", {}, "{}", function() callbacks = callbacks + 1 end, { owner = "retired-body" }), false)
				helpers.assert_eq(callbacks, 0)
				helpers.assert_true(client.cancel("retired-body"))
				helpers.assert_eq(#state.descriptor_closes, 2, "a retired or reused numeric descriptor must never be closed twice")
				for _, fd in ipairs(state.descriptors) do
					if reused then helpers.assert_eq(state.identities[fd].ino, 99) else helpers.assert_nil(state.identities[fd]) end
				end
				helpers.assert_eq(callbacks, 0)
			end)
		end
	end

	helpers.it("linux-http-body-cleanup: simulated body partial allocation with close refusal keeps captured handles fenced", function()
		local client, state = fresh_client({ allocation_failure_at = 2, close_failure = true, defer_close = true })
		local callbacks, blocked = 0, nil
		helpers.assert_eq(client.post("http://127.0.0.1:9000/", {}, "{}", function() callbacks = callbacks + 1 end, { owner = "body-allocation" }), false)
		helpers.assert_eq(#state.handles, 1)
		helpers.assert_eq(callbacks, 0)
		local candidate = client.get_owned("http://127.0.0.1:9000/", {}, { owner = "body-allocation" }, function(value) blocked = value end)
		helpers.assert_eq(candidate.started, false)
		helpers.assert_eq(blocked.error, "previous request cleanup pending")
		state.allow_closes = true
		helpers.assert_eq(client.cancel("body-allocation"), false)
		state.ack_closes()
		helpers.assert_true(client.cancel("body-allocation"))
		helpers.assert_eq(callbacks, 0)
	end)

	helpers.it("linux-http-body-cleanup: native exit event retries simulated reader close refusal before publishing", function()
		local client, state = fresh_client({ body_handle_close_receipt = "nil", defer_close = true })
		local callbacks, result = 0, nil
		helpers.assert_eq(client.post("http://127.0.0.1:9000/", {}, "{}", function(value) result, callbacks = value, callbacks + 1 end), false)
		state.ack_closes()
		helpers.assert_eq(callbacks, 0)
		state.allow_closes = true
		state.exit(0)
		helpers.assert_eq(callbacks, 0)
		state.ack_closes()
		helpers.assert_eq(callbacks, 1)
		helpers.assert_eq(result.error, "curl body pipe retirement failed")
		state.exit(0); state.ack_closes()
		helpers.assert_eq(callbacks, 1)
	end)
end)

helpers.describe("http_client: native body allocator compatibility", function()
	helpers.it("linux-http-body-cleanup: current luv allocator requests nonblocking native pipe ends", function()
		local allocator = dofile("infra/http_body_pipe.lua")
		local pair = allocator.allocate({ pipe = function(read_flags, write_flags)
			helpers.assert_true(read_flags.nonblock and write_flags.nonblock)
			return { read = 40, write = 41 }
		end })
		helpers.assert_eq(pair.read, 40)
		helpers.assert_eq(pair.write, 41)
	end)

	for _, refused in ipairs({ false, true }) do
		helpers.it("linux-http-body-cleanup: simulated Jammy binding uses pipe2 with atomic native flags " .. (refused and "refusal" or "success"), function()
			local previous = package.loaded["ffi"]
			local calls = 0
			package.loaded["ffi"] = { os = "Linux", cdef = function() end, new = function() return {} end,
				C = { pipe2 = function(descriptors, flags)
					calls = calls + 1
					helpers.assert_eq(flags, 2048 + 524288)
					if refused then return -1 end
					descriptors[0], descriptors[1] = 70, 71
					return 0
				end } }
			local ok, pair, detail = pcall(function() return dofile("infra/http_body_pipe.lua").allocate({}) end)
			package.loaded["ffi"] = previous
			helpers.assert_true(ok)
			helpers.assert_eq(calls, 1)
			if refused then helpers.assert_nil(pair); helpers.assert_eq(detail, "native body pipe allocation refused")
			else helpers.assert_eq(pair.read, 70); helpers.assert_eq(pair.write, 71) end
		end)
	end

	helpers.it("linux-http-body-cleanup: unavailable native allocation refuses without a synthetic pipe", function()
		local previous = package.loaded["ffi"]
		package.loaded["ffi"] = { os = "unavailable" }
		local ok, pair, detail = pcall(function() return dofile("infra/http_body_pipe.lua").allocate({}) end)
		package.loaded["ffi"] = previous
		helpers.assert_true(ok)
		helpers.assert_nil(pair)
		helpers.assert_eq(detail, "native body pipe unavailable")
	end)
end)

helpers.describe("http_client: unknown raw body identity", function()
	helpers.it("linux-http-body-cleanup: simulated missing initial identity never authorizes closing a later descriptor", function()
		local client, state = fresh_client({ body_metadata_failure = true })
		local callbacks, blocked = 0, nil
		helpers.assert_eq(client.post("http://127.0.0.1:9000/", {}, "{}", function() callbacks = callbacks + 1 end, { owner = "unknown-body" }), false)
		helpers.assert_eq(callbacks, 0)
		for _, fd in ipairs(state.descriptors) do state.identities[fd] = { dev = 9, ino = 99, type = "file" } end
		state.allow_metadata = true
		helpers.assert_eq(client.cancel("unknown-body"), false)
		helpers.assert_eq(#state.descriptor_closes, 0)
		for _, fd in ipairs(state.descriptors) do helpers.assert_eq(state.identities[fd].ino, 99) end
		local candidate = client.get_owned("http://127.0.0.1:9000/", {}, { owner = "unknown-body" }, function(value) blocked = value end)
		helpers.assert_eq(candidate.started, false)
		helpers.assert_eq(blocked.error, "previous request cleanup pending")
		for _, fd in ipairs(state.descriptors) do state.identities[fd] = nil end
		helpers.assert_true(client.cancel("unknown-body"), "EBADF still proves retirement without inventing descriptor ownership")
		helpers.assert_eq(callbacks, 0)
	end)
end)

--- Independent owned-group regressions: expected group absence is authored here,
--- never regenerated from the implementation. These are native-port doubles.

local function retired_leader_with_live_descendant(config)
	config = config or {}
	config.descendants_alive = true
	config.defer_close = true
	local client, state = fresh_client(config)
	local calls = 0
	local operation = client.get_owned("http://127.0.0.1:9000/models", {},
		{ owner = "group-receipt", timeout_ms = 1500 }, function() calls = calls + 1 end)
	return client, state, operation, function() return calls end
end

local function complete_owned_leader(state)
	state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n')
	state.ack_closes()
end

local function nonzero_signals(state)
	local count = 0
	for _, receipt in ipairs(state.kills) do if receipt.signal ~= 0 then count = count + 1 end end
	return count
end

local function assert_successor_blocked(client, state)
	local successor = client.get_owned("http://127.0.0.1:9000/models", {},
		{ owner = "group-receipt" }, function() end)
	helpers.assert_eq(successor.started, false)
	helpers.assert_true(successor:is_settled(), "refusal acquires no physical work")
	helpers.assert_eq(client.get("http://127.0.0.1:9000/models", {},
		{ owner = "group-receipt" }, function() end), false)
	helpers.assert_eq(#state.requests, 1, "both APIs must preserve the pending group owner")
end

helpers.describe("http_client: independent owned detached-group absence", function()
	helpers.it("owned-group: leader exit, both EOFs and stream/process ACKs leave a live descendant pending", function()
		local client, state, operation, calls = retired_leader_with_live_descendant()
		complete_owned_leader(state)
		helpers.assert_eq(operation:is_settled(), false, "leader exit is not detached-group absence")
		helpers.assert_eq(calls(), 0)
		for _, handle in ipairs(state.handles) do
			if handle.kind ~= "timer" then helpers.assert_true(handle.closing, "every other native close is admitted") end
		end
		assert_successor_blocked(client, state)
		helpers.assert_eq(state.timer.closing, false)
		helpers.assert_eq(state.timer.timeout_ms, 50)
		helpers.assert_eq(state.timer.repeat_ms, 50)
		helpers.assert_eq(#state.handles, 5, "cleanup reuses the acquired request timer")
		helpers.assert_true(nonzero_signals(state) >= 2)
	end)

	helpers.it("owned-group: accepted TERM and KILL retain debt until native ESRCH and monitor close ACK", function()
		local _, state, operation, calls = retired_leader_with_live_descendant()
		complete_owned_leader(state)
		state.timer.callback()
		helpers.assert_eq(operation:is_settled(), false, "signal acceptance cannot settle live descendants")
		helpers.assert_eq(calls(), 0)
		state.groups[4321] = false
		state.timer.callback()
		helpers.assert_eq(operation:is_settled(), false, "the cleanup monitor still owns its close callback")
		helpers.assert_true(state.timer.closing)
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(calls(), 1)
	end)

	for _, mode in ipairs({ "throw", "false", "nil", "text-only", "unknown-code" }) do
		helpers.it("owned-group: " .. mode .. " probe refusal is not a native absence receipt", function()
			local client, state, operation, calls = retired_leader_with_live_descendant()
			state.probe_mode = mode
			complete_owned_leader(state)
			helpers.assert_eq(operation:is_settled(), false)
			helpers.assert_eq(calls(), 0)
			helpers.assert_eq(nonzero_signals(state), 0, "an unadmitted group probe cannot authorize cleanup signals")
			assert_successor_blocked(client, state)
			state.probe_mode = nil
			state.groups[4321] = false
			state.timer.callback()
			state.ack_closes()
			helpers.assert_true(operation:is_settled())
		end)
	end

	helpers.it("owned-group: termination refusal and later signal acceptance both preserve descendant debt", function()
		local client, state, operation, calls = retired_leader_with_live_descendant({ kill_failure = true })
		complete_owned_leader(state)
		helpers.assert_eq(operation:is_settled(), false)
		state.timer.callback()
		assert_successor_blocked(client, state)
		state.allow_kills = true
		state.timer.callback()
		helpers.assert_eq(operation:is_settled(), false)
		helpers.assert_eq(calls(), 0)
		state.groups[4321] = false
		state.timer.callback()
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
	end)

	helpers.it("owned-group: a refused cleanup monitor stays owned and manual retry arms the same handle", function()
		local client, state, operation, calls = retired_leader_with_live_descendant()
		state.monitor_refused = true
		complete_owned_leader(state)
		helpers.assert_eq(operation:is_settled(), false)
		helpers.assert_eq(calls(), 0)
		assert_successor_blocked(client, state)
		state.monitor_refused = false
		helpers.assert_eq(operation:cancel(), false)
		helpers.assert_eq(#state.handles, 5)
		helpers.assert_eq(state.timer.repeat_ms, 50)
		state.groups[4321] = false
		state.timer.callback()
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(calls(), 0, "cancel intent suppresses the pending response")
	end)

	helpers.it("owned-group: refused monitor close rearms its referenced handle and waits for its own ACK", function()
		local client, state, operation, calls = retired_leader_with_live_descendant()
		complete_owned_leader(state)
		state.monitor_close_refused = true
		state.groups[4321] = false
		state.timer.callback()
		helpers.assert_eq(operation:is_settled(), false)
		helpers.assert_eq(calls(), 0)
		helpers.assert_eq(state.timer.stopped, false, "refused close must retain progress on the same timer")
		assert_successor_blocked(client, state)
		state.monitor_close_refused = false
		state.timer.callback()
		helpers.assert_eq(operation:is_settled(), false)
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(calls(), 1)
	end)

	helpers.it("owned-group: native group absence still waits for the exact leader exit receipt", function()
		local _, state, operation, calls = retired_leader_with_live_descendant()
		helpers.assert_eq(operation:cancel(), false)
		state.ack_closes()
		state.groups[4321] = false
		state.timer.callback()
		helpers.assert_eq(operation:is_settled(), false)
		local signals = #state.kills
		state.timer.callback()
		helpers.assert_eq(#state.kills, signals, "acknowledged absence forbids later signals on a reused PGID")
		state.exit()
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(calls(), 0)
	end)

	helpers.it("owned-group: stale old monitor and close callbacks cannot signal or settle a new owner", function()
		local client, state, operation, calls = retired_leader_with_live_descendant()
		complete_owned_leader(state)
		local old_monitor = state.timer.callback
		state.groups[4321] = false
		old_monitor()
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		local old_closes = {}
		for _, receipt in ipairs(state.closes) do old_closes[#old_closes + 1] = receipt.callback end
		local successor = client.get_owned("http://127.0.0.1:9000/models", {},
			{ owner = "group-receipt" }, function() end)
		helpers.assert_true(successor.started)
		local signals = #state.kills
		old_monitor()
		for _, callback in ipairs(old_closes) do callback() end
		helpers.assert_eq(#state.kills, signals)
		helpers.assert_eq(successor:is_settled(), false)
		helpers.assert_true(client.isActive("group-receipt"))
		helpers.assert_eq(calls(), 1)
		state.groups[4322] = false
		state.complete_request(2, '[]\nERGOPTI_HTTP_STATUS:200\n')
		state.ack_closes()
		helpers.assert_true(successor:is_settled())
	end)

	helpers.it("owned-group: already absent completed groups need no retirement signals", function()
		local client, state = fresh_client({ defer_close = true })
		local operation = client.get_owned("http://127.0.0.1:9000/models", {}, {}, function() end)
		state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n')
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(nonzero_signals(state), 0)
		helpers.assert_true(#state.probes > 0)
	end)

	helpers.it("owned-group: exceptional legacy body cleanup retains its existing boolean ABI and no group monitor", function()
		local config = { descendants_alive = true, defer_close = true }
		local client, state = fresh_client(config)
		local result
		helpers.assert_true(client.post("http://127.0.0.1:9000/models", {}, "{}", function(value) result = value end))
		config.close_failure = true -- Refuse terminal cleanup only after successful admission.
		state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n')
		helpers.assert_eq(result, nil)
		state.allow_closes = true
		helpers.assert_eq(client.cancel(), false)
		state.ack_closes()
		helpers.assert_true(client.cancel())
		helpers.assert_eq(#state.probes, 0, "_body_cleanup is the retained historical internal operation")
		for _, receipt in ipairs(state.timer_starts) do helpers.assert_eq(receipt.repeat_ms, 0) end
	end)
end)

--- Independent source-capability cases. Expected admission/delivery decisions
--- are authored here, never generated from the adapter. All native ports below
--- are controlled doubles; these cases are not native installation evidence.

local function authorizer_client(config, hook)
	local fake, state = fake_luv(config)
	if hook then hook(fake, state) end
	local previous_luv, previous_client = package.loaded["luv"], package.loaded["adapters.http_client"]
	package.loaded["luv"], package.loaded["adapters.http_client"] = fake, nil
	local client = require("adapters.http_client")
	package.loaded["luv"], package.loaded["adapters.http_client"] = previous_luv, previous_client
	return client, state
end

helpers.describe("http_client: captured owned source capability", function()
	for _, invalid in ipairs({ false, true, "callable", {} }) do
		helpers.it("owned-authorizer: wrong capability type " .. type(invalid) .. " refuses without allocation or response", function()
			local client, state = fresh_client()
			local responses = 0
			local operation = client.get_owned("http://127.0.0.1:9000/models", {},
				{ authorized = invalid }, function() responses = responses + 1 end)
			helpers.assert_eq(operation.started, false)
			helpers.assert_true(operation:is_settled(), "a wrong typed capability acquires no physical work")
			helpers.assert_eq(#state.handles, 0)
			helpers.assert_eq(#state.requests, 0)
			helpers.assert_eq(responses, 0)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "number", "string", "throw" }) do
		helpers.it("owned-authorizer: initial " .. mode .. " is a settled noncallback refusal", function()
			local client, state = fresh_client()
			local responses, calls = 0, 0
			local operation = client.get_owned("http://127.0.0.1:9000/models", {}, { owner = "source", authorized = function()
				calls = calls + 1
				if mode == "throw" then error("synthetic authorizer exception") end
				if mode == "false" then return false elseif mode == "number" then return 1 elseif mode == "string" then return "true" end
			end }, function() responses = responses + 1 end)
			helpers.assert_eq(operation.started, false)
			helpers.assert_true(operation:is_settled())
			helpers.assert_eq(#state.requests, 0)
			helpers.assert_eq(#state.handles, 0)
			helpers.assert_eq(responses, 0)
			helpers.assert_eq(calls, 1)
			local successor = client.get_owned("http://127.0.0.1:9000/models", {}, { owner = "source" }, function() end)
			helpers.assert_true(successor.started, "no nonexistent cleanup debt can retain the source owner")
			state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n')
		end)
	end

	helpers.it("owned-authorizer: reserves before initial capability reentry and never calls a blocked successor capability", function()
		local client, state = fresh_client()
		local nested, nested_calls, nested_responses, entered = nil, 0, 0, false
		local operation = client.get_owned("http://127.0.0.1:9000/models", {}, { owner = "source", authorized = function()
			if not entered then
				entered = true
				nested = client.get_owned("http://127.0.0.1:9000/models", {}, { owner = "source", authorized = function()
					nested_calls = nested_calls + 1; return true
				end }, function() nested_responses = nested_responses + 1 end)
			end
			return true
		end }, function() end)
		helpers.assert_true(operation.started)
		helpers.assert_eq(nested.started, false)
		helpers.assert_true(nested:is_settled())
		helpers.assert_eq(nested_calls, 0)
		helpers.assert_eq(nested_responses, 0, "a blocked authorized successor cannot publish a rejection receipt")
		helpers.assert_eq(#state.requests, 1)
		state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n')
	end)

	helpers.it("owned-authorizer: captures the originating function once despite caller option replacement", function()
		local client, state = fresh_client()
		local calls, replacement_calls, responses = 0, 0, 0
		local options = { owner = "source" }
		options.authorized = function()
			calls = calls + 1
			options.authorized = function() replacement_calls = replacement_calls + 1; return false end
			return true
		end
		local operation = client.get_owned("http://127.0.0.1:9000/models", {}, options, function() responses = responses + 1 end)
		helpers.assert_true(operation.started)
		state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n')
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(calls, 3, "initial, last dispatch and physically settled delivery use the original capability")
		helpers.assert_eq(replacement_calls, 0)
		helpers.assert_eq(responses, 1)
	end)

	helpers.it("owned-authorizer: credential construction withdrawal refuses before spawn and waits for allocated ACKs", function()
		local client, state = fresh_client({ defer_close = true })
		local current, responses, constructions = true, 0, 0
		local header = setmetatable({}, { __tostring = function()
			constructions = constructions + 1; current = false; return "SyntheticCredential"
		end })
		local operation = client.get_owned("http://127.0.0.1:9000/models", { Authorization = header },
			{ owner = "source", authorized = function() return current end }, function() responses = responses + 1 end)
		helpers.assert_eq(#state.requests, 0, "the last credential callback can withdraw physical dispatch")
		helpers.assert_eq(constructions, 1)
		helpers.assert_eq(operation.started, false)
		helpers.assert_eq(operation:is_settled(), false)
		local successor = client.get_owned("http://127.0.0.1:9000/models", {}, { owner = "source" }, function() end)
		helpers.assert_eq(successor.started, false)
		helpers.assert_eq(#state.handles, 4)
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(responses, 0)
	end)

	helpers.it("owned-authorizer: native setup withdrawal is checked after timer admission before spawn", function()
		local current = true
		local client, state = authorizer_client({ defer_close = true }, function(fake)
			local start = fake.timer_start
			fake.timer_start = function(...)
				local accepted = start(...); current = false; return accepted
			end
		end)
		local responses = 0
		local operation = client.get_owned("http://127.0.0.1:9000/models", {},
			{ owner = "source", authorized = function() return current end }, function() responses = responses + 1 end)
		helpers.assert_eq(#state.requests, 0)
		helpers.assert_eq(operation.started, false)
		helpers.assert_eq(operation:is_settled(), false)
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(responses, 0)
	end)

	for _, mode in ipairs({ "false", "throw" }) do
		helpers.it("owned-authorizer: last dispatch " .. mode .. " suppresses callback without discarding refused-close debt", function()
			local client, state = fresh_client({ defer_close = true, close_failure = true })
			local calls, responses = 0, 0
			local operation = client.get_owned("http://127.0.0.1:9000/models", {}, { owner = "source", authorized = function()
				calls = calls + 1
				if calls == 1 then return true end
				if mode == "throw" then error("last admission revoked") end
				return false
			end }, function() responses = responses + 1 end)
			helpers.assert_eq(#state.requests, 0)
			helpers.assert_eq(operation.started, false)
			helpers.assert_eq(operation:is_settled(), false)
			state.allow_closes = true
			operation:cancel()
			state.ack_closes()
			helpers.assert_true(operation:is_settled())
			helpers.assert_eq(responses, 0)
		end)
	end

	helpers.it("owned-authorizer: late source withdrawal suppresses response after exact native close acknowledgments", function()
		local client, state = fresh_client({ defer_close = true })
		local current, responses, settled = true, 0, 0
		local operation = client.get_owned("http://127.0.0.1:9000/models", {},
			{ owner = "source", authorized = function() return current end }, function() responses = responses + 1 end)
		operation:on_settled(function() settled = settled + 1 end)
		state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n')
		helpers.assert_eq(operation:is_settled(), false)
		current = false
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(responses, 0)
		helpers.assert_eq(settled, 1)
		current = true
		state.ack_closes(); state.exit(0)
		helpers.assert_eq(responses, 0, "a restored predicate cannot resurrect an already withdrawn delivery")
	end)

	helpers.it("owned-authorizer: descendant and refused close debts remain independent of revoked source", function()
		local client, state = fresh_client({ defer_close = true, descendants_alive = true })
		local current, responses = true, 0
		local operation = client.get_owned("http://127.0.0.1:9000/models", {},
			{ owner = "source", authorized = function() return current end }, function() responses = responses + 1 end)
		state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n'); state.ack_closes()
		current = false
		helpers.assert_eq(operation:is_settled(), false)
		local successor = client.get_owned("http://127.0.0.1:9000/models", {}, { owner = "source" }, function() end)
		helpers.assert_eq(successor.started, false)
		state.groups[4321] = false
		state.timer.callback()
		helpers.assert_eq(operation:is_settled(), false, "native absence does not acknowledge the referenced monitor close")
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(responses, 0)
	end)

	helpers.it("owned-authorizer: delivery reentry cannot start a successor before the predicate returns", function()
		local client, state = fresh_client({ defer_close = true })
		local calls, nested, responses = 0, nil, 0
		local operation = client.get_owned("http://127.0.0.1:9000/models", {}, { owner = "source", authorized = function()
			calls = calls + 1
			if calls == 3 then nested = client.get_owned("http://127.0.0.1:9000/models", {}, { owner = "source" }, function() end) end
			return true
		end }, function() responses = responses + 1 end)
		state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n'); state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(nested.started, false)
		helpers.assert_true(nested:is_settled())
		helpers.assert_eq(#state.requests, 1)
		helpers.assert_eq(responses, 1)
	end)

	helpers.it("owned-authorizer: cancelling inside final capability cannot recurse or publish after cancel intent", function()
		local client, state = fresh_client({ defer_close = true })
		local calls, responses, operation, nested_cancel = 0, 0, nil, nil
		operation = client.get_owned("http://127.0.0.1:9000/models", {}, { owner = "source", authorized = function()
			calls = calls + 1
			if calls == 3 then nested_cancel = operation:cancel() end
			return true
		end }, function() responses = responses + 1 end)
		state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n'); state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(calls, 3)
		helpers.assert_eq(nested_cancel, false, "foreign authorization remains in flight until it returns")
		helpers.assert_eq(responses, 0)
	end)

	helpers.it("owned-authorizer: cancelled requests never invoke a final capability or deliver a late result", function()
		local client, state = fresh_client({ defer_close = true })
		local calls, responses = 0, 0
		local operation = client.get_owned("http://127.0.0.1:9000/models", {}, { owner = "source", authorized = function()
			calls = calls + 1; return true
		end }, function() responses = responses + 1 end)
		operation:cancel()
		state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n'); state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(calls, 2)
		helpers.assert_eq(responses, 0)
	end)

	helpers.it("owned-authorizer: metadata exception after reservation releases only its own source owner", function()
		local client, state = fresh_client()
		local responses, response = 0, nil
		local policy = require("infra.http_redirect_policy")
		local original_policy = policy.allows_native_follow
		policy.allows_native_follow = function() error("synthetic metadata policy exception") end
		local called, operation = pcall(client.get_owned, "http://127.0.0.1:9000/models", {},
			{ owner = "source", follow_redirects = true, authorized = function() return true end }, function(value)
				responses = responses + 1; response = value
			end)
		policy.allows_native_follow = original_policy
		helpers.assert_true(called, "metadata exceptions must retire the exact reserved operation rather than escape")
		helpers.assert_eq(operation.started, false)
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(#state.requests, 0)
		helpers.assert_eq(responses, 1)
		helpers.assert_type(response, "table")
		helpers.assert_eq(response.ok, false)
	end)

	helpers.it("owned-authorizer: throwing final capability settles physical debt without publishing", function()
		local client, state = fresh_client({ defer_close = true })
		local calls, responses = 0, 0
		local operation = client.get_owned("http://127.0.0.1:9000/models", {}, { owner = "source", authorized = function()
			calls = calls + 1
			if calls == 3 then error("source capability withdrawn at final acknowledgment") end
			return true
		end }, function() responses = responses + 1 end)
		state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n'); state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(calls, 3)
		helpers.assert_eq(responses, 0)
	end)

	helpers.it("owned-authorizer: late old callbacks cannot consult old source or affect an admitted successor", function()
		local client, state = fresh_client({ defer_close = true })
		local current, old_calls, old_responses, new_responses = true, 0, 0, 0
		local old = client.get_owned("http://127.0.0.1:9000/models", {}, { owner = "source", authorized = function()
			old_calls = old_calls + 1; return current
		end }, function() old_responses = old_responses + 1 end)
		state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n'); current = false; state.ack_closes()
		helpers.assert_true(old:is_settled())
		helpers.assert_eq(old_responses, 0)
		local calls, kills = old_calls, #state.kills
		local successor = client.get_owned("http://127.0.0.1:9000/models", {},
			{ owner = "source", authorized = function() return true end }, function() new_responses = new_responses + 1 end)
		helpers.assert_true(successor.started)
		state.complete_request(1, 'stale\nERGOPTI_HTTP_STATUS:200\n'); state.ack_closes()
		helpers.assert_eq(old_calls, calls)
		helpers.assert_eq(#state.kills, kills)
		helpers.assert_eq(successor:is_settled(), false)
		helpers.assert_eq(new_responses, 0)
		state.complete_request(2, '[]\nERGOPTI_HTTP_STATUS:200\n'); state.ack_closes()
		helpers.assert_true(successor:is_settled())
		helpers.assert_eq(new_responses, 1)
	end)

	helpers.it("owned-authorizer: legacy boolean GET ignores the optional owned-only capability", function()
		local client, state = fresh_client()
		local calls, responses = 0, 0
		helpers.assert_true(client.get("http://127.0.0.1:9000/models", {}, { authorized = function()
			calls = calls + 1; return false
		end }, function() responses = responses + 1 end))
		state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n')
		helpers.assert_eq(calls, 0)
		helpers.assert_eq(responses, 1)
	end)
end)
