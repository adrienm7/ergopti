--- tests/unit/adapters/test_http_client_redirect_policy.lua

--- ==============================================================================
--- MODULE: HttpClient Redirect Policy Regression Tests
--- DESCRIPTION:
--- Exercises the real adapter against a redirect-aware native double. Requests
--- carrying caller credentials must disable Hammerspoon's opaque auto-follow,
--- preserve those credentials only on the same origin, and strip them before a
--- cross-origin hop. Native negative statuses must also honour the port's
--- network-error status contract.
--- ==============================================================================

local helpers = require("tests.helpers")

local function copy_headers(headers)
	local copy = {}
	for key, value in pairs(headers or {}) do copy[key] = value end
	return copy
end

local function load_fixture()
	local state = {
		requests = {},
		callbacks = {},
		unsafe_calls = 0,
	}
	local http = {}
	function http.doAsyncRequest(url, method, body, headers, callback, enable_redirect)
		state.requests[#state.requests + 1] = {
			url = url,
			method = method,
			body = body,
			headers = copy_headers(headers),
			enable_redirect = enable_redirect,
		}
		state.callbacks[#state.callbacks + 1] = callback
		return nil
	end
	function http.asyncGet(url, headers, callback)
		state.unsafe_calls = state.unsafe_calls + 1
		state.requests[#state.requests + 1] = {
			url = url,
			method = "GET",
			headers = copy_headers(headers),
			enable_redirect = true,
		}
		callback(200, "opaque auto-follow", {})
		return nil
	end
	function http.asyncPost(url, body, headers, callback)
		state.unsafe_calls = state.unsafe_calls + 1
		state.requests[#state.requests + 1] = {
			url = url,
			method = "POST",
			body = body,
			headers = copy_headers(headers),
			enable_redirect = true,
		}
		callback(200, "opaque auto-follow", {})
		return nil
	end

	local timer = {
		secondsSinceEpoch = function() return 0 end,
	}
	function timer.new(_, callback)
		local running = false
		return {
			start = function(self) running = true; return self end,
			stop = function(self) running = false; return self end,
			running = function() return running end,
			callback = callback,
		}
	end

	package.loaded["adapters.http_client"] = nil
	package.loaded["adapters.timer_scheduler"] = nil
	local HttpClient = helpers.load_with_stubs("adapters.http_client", {
		http = http,
		timer = timer,
	})
	return HttpClient.new(), state
end

helpers.describe("HttpClient redirect ownership", function()
	helpers.it("pins redirect confidentiality in the shared port contract", function()
		local file = assert(io.open("../_shared/core/ports/HttpClient.spec.js", "rb"))
		local contract = file:read("*a")
		file:close()
		helpers.assert_contains(contract, "Redirect confidentiality")
		helpers.assert_contains(contract, "MUST NOT cross an origin boundary")
		helpers.assert_contains(contract, "MUST NOT be redirected to HTTP")
	end)

	helpers.it("strips caller credentials before a cross-origin redirect", function()
		local client, state = load_fixture()
		local terminal
		helpers.assert_eq(client.get("https://api.example.test/v1/models", {
			Authorization = "Bearer private-token",
			["x-api-key"] = "private-anthropic-token",
			Cookie = "session=private-cookie",
			["X-Request-ID"] = "trace-123",
		}, function(result) terminal = result end), true)

		helpers.assert_eq(state.unsafe_calls, 0,
			"credentialed requests must not use the opaque auto-follow wrappers")
		helpers.assert_eq(#state.requests, 1)
		helpers.assert_eq(state.requests[1].enable_redirect, false)
		state.callbacks[1](302, "", {
			Location = "https://login.portal.test/continue",
		})

		helpers.assert_eq(#state.requests, 2)
		local redirected = state.requests[2]
		helpers.assert_eq(redirected.url, "https://login.portal.test/continue")
		helpers.assert_eq(redirected.enable_redirect, false)
		helpers.assert_eq(redirected.headers.Authorization, nil)
		helpers.assert_eq(redirected.headers["x-api-key"], nil)
		helpers.assert_eq(redirected.headers.Cookie, nil)
		helpers.assert_eq(redirected.headers["X-Request-ID"], "trace-123",
			"non-sensitive correlation headers must survive the redirect")
		helpers.assert_eq(terminal, nil,
			"an intermediate redirect must not publish a terminal result")

		state.callbacks[2](200, "safe final response", {})
		helpers.assert_eq(terminal.ok, true)
		helpers.assert_eq(terminal.status, 200)
		helpers.assert_eq(terminal.body, "safe final response")
	end)

	helpers.it("preserves caller credentials across a same-origin redirect", function()
		local client, state = load_fixture()
		client.get("https://api.example.test/v1/models", {
			Authorization = "Bearer same-origin-token",
		}, function() end)
		state.callbacks[1](307, "", { location = "/v2/models" })

		helpers.assert_eq(#state.requests, 2)
		helpers.assert_eq(state.requests[2].url, "https://api.example.test/v2/models")
		helpers.assert_eq(state.requests[2].headers.Authorization,
			"Bearer same-origin-token")
	end)

	helpers.it("refuses an HTTPS downgrade before dispatching another hop", function()
		local client, state = load_fixture()
		local terminal
		client.get("https://api.example.test/v1/models", {
			Authorization = "Bearer downgrade-token",
		}, function(result) terminal = result end)
		state.callbacks[1](302, "", {
			Location = "http://api.example.test/insecure",
		})

		helpers.assert_eq(#state.requests, 1,
			"a secure request must never dispatch its downgraded hop")
		helpers.assert_eq(terminal.ok, false)
		helpers.assert_eq(terminal.status, 302)
	end)

	helpers.it("converts a 303 POST to a bodyless GET without entity headers", function()
		local client, state = load_fixture()
		client.post("https://api.example.test/v1/submit", {
			Authorization = "Bearer same-origin-token",
			["Content-Type"] = "application/json",
			["Content-Length"] = "2",
		}, "{}", function() end)
		state.callbacks[1](303, "", { Location = "/v1/result" })

		local redirected = state.requests[2]
		helpers.assert_eq(redirected.method, "GET")
		helpers.assert_eq(redirected.body, nil)
		helpers.assert_eq(redirected.headers.Authorization, "Bearer same-origin-token")
		helpers.assert_eq(redirected.headers["Content-Type"], nil)
		helpers.assert_eq(redirected.headers["Content-Length"], nil)
	end)

	helpers.it("bounds a redirect loop inside the original request", function()
		local client, state = load_fixture()
		local terminal
		client.get("https://api.example.test/start", {
			Authorization = "Bearer loop-token",
		}, function(result) terminal = result end)
		for index = 1, 6 do
			state.callbacks[index](302, "", { Location = "/loop-" .. tostring(index) })
		end

		helpers.assert_eq(#state.requests, 6,
			"five followed redirects plus the initial request must be the hard limit")
		helpers.assert_eq(terminal.ok, false)
		helpers.assert_eq(terminal.status, 302)
	end)

	helpers.it("normalizes native network failures to the port status contract", function()
		local client, state = load_fixture()
		local terminal
		client.get("https://api.example.test/v1/models", {
			Authorization = "Bearer network-test-token",
		}, function(result)
			terminal = result
		end)

		state.callbacks[1](-1, "Connection failed: certificate rejected", nil)
		helpers.assert_eq(terminal.status, 0)
		helpers.assert_eq(terminal.ok, false)
		helpers.assert_true(type(terminal.error) == "string" and terminal.error ~= "")
	end)
end)
