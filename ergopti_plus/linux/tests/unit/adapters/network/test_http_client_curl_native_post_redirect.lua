--- tests/unit/adapters/network/test_http_client_curl_native_post_redirect.lua

--- ==============================================================================
--- MODULE: Asynchronous HTTP Process Ownership
--- DESCRIPTION:
--- Drives the Linux HttpClient through a controllable libuv double. The tests
--- prove dispatch returns before output, timeout and cancel kill the detached
--- process group, and exactly one terminal callback survives late events.
--- ==============================================================================

package.loaded["tests.support.adapters.network.http_client_curl_fixture"] = nil
local Fixture = require("tests.support.adapters.network.http_client_curl_fixture")
local helpers, fresh_client, fresh_digest, invalid_preflight, sensitive_headers =
	Fixture.helpers, Fixture.fresh_client, Fixture.fresh_digest, Fixture.invalid_preflight, Fixture.sensitive_headers




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

	-- Ollama removes a model only on DELETE /api/delete: without the method word
	-- curl's data option would send the body as a POST, which Ollama answers 405.
	helpers.it("linux-http-delete-method: an owned DELETE names its method and keeps its body", function()
		local client, state = fresh_client()
		local result
		local body = '{"name":"qwen:2b"}'
		local operation = client.dispatch_owned("http://127.0.0.1:11434/api/delete", { ["Content-Type"] = "application/json" }, body,
			{ method = "DELETE", buffered = true, owner = "ollama_model_delete", authorized = function() return true end },
			nil, function(value) result = value end)
		helpers.assert_true(operation.started)
		local count = 0
		for index, argument in ipairs(state.options.args) do
			if argument == "--request" then count = count + 1; helpers.assert_eq(state.options.args[index + 1], "DELETE") end
		end
		helpers.assert_eq(count, 1)
		helpers.assert_true(state.config:find('data-binary = "@/dev/fd/3"', 1, true) ~= nil, "the model name travels in the body")
		helpers.assert_eq(state.body, body)
		state.complete_request(1, "\nERGOPTI_HTTP_STATUS:200\n")
		helpers.assert_true(result and result.ok and result.status == 200)
	end)

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
end)




helpers.describe("http_client: asynchronous curl ownership", function()
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
end)




helpers.describe("http_client: asynchronous curl ownership", function()
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
end)




helpers.describe("http_client: asynchronous curl ownership", function()
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
end)




helpers.describe("http_client: asynchronous curl ownership", function()
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
end)




helpers.describe("http_client: asynchronous curl ownership", function()
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
end)




helpers.describe("http_client: asynchronous curl ownership", function()
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
end)




helpers.describe("http_client: asynchronous curl ownership", function()
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
end)




helpers.describe("http_client: asynchronous curl ownership", function()
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
end)




helpers.describe("http_client: asynchronous curl ownership", function()
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
end)




helpers.describe("http_client: asynchronous curl ownership", function()
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
end)




helpers.describe("http_client: asynchronous curl ownership", function()
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
end)




helpers.describe("http_client: asynchronous curl ownership", function()
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
end)




helpers.describe("http_client: asynchronous curl ownership", function()
	helpers.it("linux-http-tls-redirect: public HTTP request can upgrade to TLS", function()
		local client, state = fresh_client()
		helpers.assert_true(client.get("http://example.invalid/api", {}, { follow_redirects = true }, function() end))
		local joined = "\n" .. table.concat(state.options.args, "\n") .. "\n"
		helpers.assert_true(joined:find("\n--location\n", 1, true) ~= nil)
		helpers.assert_true(joined:find("\n--proto-redir\n", 1, true) == nil)
		state.complete_request(1, "abc\nERGOPTI_HTTP_STATUS:200\n")
	end)
end)




helpers.describe("http_client: asynchronous curl ownership", function()
	helpers.it("linux-http-tls-redirect: explicit no-follow remains a single native request", function()
		local client, state = fresh_client()
		helpers.assert_true(client.get("https://example.invalid/api", {}, { follow_redirects = false }, function() end))
		local joined = "\n" .. table.concat(state.options.args, "\n") .. "\n"
		helpers.assert_true(joined:find("\n--location\n", 1, true) == nil)
		helpers.assert_true(joined:find("\n--proto-redir\n", 1, true) == nil)
		state.complete_request(1, "\nERGOPTI_HTTP_STATUS:307\n")
	end)
end)




helpers.describe("http_client: asynchronous curl ownership", function()
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
end)




helpers.describe("http_client: asynchronous curl ownership", function()
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
end)




helpers.describe("http_client: asynchronous curl ownership", function()
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
end)




helpers.describe("http_client: asynchronous curl ownership", function()
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
end)




helpers.describe("http_client: asynchronous curl ownership", function()
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
end)




helpers.describe("http_client: asynchronous curl ownership", function()
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
end)




helpers.describe("http_client: asynchronous curl ownership", function()
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
end)




helpers.describe("http_client: asynchronous curl ownership", function()
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
end)

