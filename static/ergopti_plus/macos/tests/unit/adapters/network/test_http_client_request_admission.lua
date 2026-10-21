--- tests/unit/adapters/network/test_http_client_request_admission.lua

--- ==============================================================================
--- MODULE: HttpClient request admission and HTTPS redirect regression tests
--- DESCRIPTION:
--- Drives the real adapter over a native double that follows redirects exactly
--- as hs.http documents (enableRedirect defaults to true) and records every
--- hop it fetches.
--- 1. An initial URL with a control byte or a non-HTTP scheme reached the native
---    request; it is now refused before any ownership change
---    (http-initial-url-2026-10-21).
--- 2. An invalid replacement request used to cancel the valid request in flight
---    before its own native refusal; validation now precedes cancellation
---    (http-validate-before-cancel-2026-10-21).
--- 3. A public HTTPS request used native auto-follow, so an HTTPS-to-HTTP
---    redirect was fetched in clear; HTTPS requests now follow through the
---    adapter's own hop policy, which refuses the downgrade
---    (https-public-downgrade-2026-10-21).
--- ==============================================================================

local helpers = require("tests.helpers")

--- Builds a native hs.http double with documented redirect semantics.
--- @param redirects table Map of URL to Location for 302 responses.
--- @return table http, table state
local function native_http(redirects)
	local state = { fetched = {}, pending = {} }
	local function fetch(url, enable_redirect, callback, hold)
		state.fetched[#state.fetched + 1] = url
		local location = redirects[url]
		if location and enable_redirect then
			return fetch(location, enable_redirect, callback, hold)
		end
		local status, headers = 200, {}
		if location then status, headers = 302, { Location = location } end
		if hold then
			state.pending[#state.pending + 1] = function() callback(status, "body of " .. url, headers) end
		else
			callback(status, "body of " .. url, headers)
		end
	end
	local http = {}
	function http.doAsyncRequest(url, _method, _body, _headers, callback, cache_or_redirect, explicit)
		if type(url) ~= "string" then error("bad argument #1 to 'doAsyncRequest' (string expected)") end
		local enable = true
		if type(cache_or_redirect) == "boolean" then enable = cache_or_redirect end
		if type(explicit) == "boolean" then enable = explicit end
		fetch(url, enable, callback, state.hold)
	end
	function http.asyncGet(url, headers, callback)
		return http.doAsyncRequest(url, "GET", nil, headers, callback)
	end
	function http.asyncPost(url, body, headers, callback)
		return http.doAsyncRequest(url, "POST", body, headers, callback)
	end
	return http, state
end

--- Loads one fresh client over the native double.
--- @param redirects table|nil
--- @return table client, table state, table logs
local function load_client(redirects)
	local http, state = native_http(redirects or {})
	local timer = { secondsSinceEpoch = function() return 0 end }
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
	package.loaded["infra.logger"] = nil
	local HttpClient = helpers.load_with_stubs("adapters.http_client", { http = http, timer = timer })
	local logs = {}
	local logger = helpers.make_logger_stub()
	logger.error = function(_, template, ...) logs[#logs + 1] = string.format(template, ...) end
	package.loaded["infra.logger"] = logger
	package.loaded["adapters.http_client"] = nil
	HttpClient = require("adapters.http_client")
	return HttpClient.new(), state, logs
end


helpers.describe("HttpClient: initial URL admission (http-initial-url-2026-10-21)", function()
	for _, case in ipairs({
		{ "an embedded NUL", "http://127.0.0.1:11434/api\0/../other" },
		{ "a line break", "https://api.example.test/v1\r\nX-Injected: 1" },
		{ "a file URL", "file:///etc/passwd" },
		{ "a relative reference", "/api/version" },
		{ "a non-string URL", 42 },
	}) do
		helpers.it("refuses " .. case[1] .. " before any native request", function()
			local client, state, logs = load_client()
			local terminal
			helpers.assert_eq(client.get(case[2], {}, function(result) terminal = result end), false)
			helpers.assert_eq(#state.fetched, 0, "the native request must never see this URL")
			helpers.assert_eq(terminal and terminal.ok, false, "the caller must receive one failure")
			helpers.assert_eq(client.isActive(), false)
			for _, line in ipairs(logs) do
				helpers.assert_true(line:find("passwd", 1, true) == nil and line:find("api", 1, true) == nil,
					"the refusal must not log the URL: " .. line)
			end
		end)
	end

	helpers.it("admits uppercase HTTP schemes", function()
		local client, state = load_client()
		local terminal
		helpers.assert_eq(client.get("HTTP://127.0.0.1:11434/api/version", {}, function(result) terminal = result end), true)
		helpers.assert_eq(#state.fetched, 1)
		helpers.assert_eq(terminal.ok, true)
	end)
end)


helpers.describe("HttpClient: an invalid replacement keeps the request in flight (http-validate-before-cancel-2026-10-21)", function()
	for _, invalid in ipairs({ { "nil URL", nil }, { "NUL URL", "http://h/\0" }, { "file URL", "file:///tmp/x" } }) do
		helpers.it("delivers the first response after a refused " .. invalid[1], function()
			local client, state = load_client()
			state.hold = true
			local first, second
			helpers.assert_eq(client.get("http://127.0.0.1:11434/api/version", {}, function(result) first = result end), true)
			helpers.assert_eq(client.get(invalid[2], {}, function(result) second = result end), false)
			helpers.assert_eq(second and second.ok, false, "the refused request reports its own failure")
			helpers.assert_eq(client.isActive(), true, "the valid request must still be owned")
			state.pending[1]()
			helpers.assert_eq(first and first.ok, true, "the valid request must not be cancelled by a refusal")
		end)
	end
end)


helpers.describe("HttpClient: public HTTPS never follows a downgrade (https-public-downgrade-2026-10-21)", function()
	helpers.it("refuses an HTTPS-to-HTTP redirect without fetching the HTTP hop", function()
		local client, state = load_client({ ["https://releases.example.test/latest"] = "http://releases.example.test/latest" })
		local terminal
		client.get("https://releases.example.test/latest", {}, function(result) terminal = result end)
		for _, url in ipairs(state.fetched) do
			helpers.assert_true(url:sub(1, 8) == "https://", "a clear-text hop was fetched: " .. url)
		end
		helpers.assert_eq(terminal.ok, false)
		helpers.assert_eq(terminal.status, 302)
	end)

	helpers.it("still follows a public cross-origin HTTPS redirect", function()
		local client, state = load_client({ ["https://github.example.test/asset"] = "https://objects.example.test/blob" })
		local terminal
		client.get("https://github.example.test/asset", {}, function(result) terminal = result end)
		helpers.assert_eq(state.fetched, { "https://github.example.test/asset", "https://objects.example.test/blob" })
		helpers.assert_eq(terminal.ok, true)
		helpers.assert_eq(terminal.body, "body of https://objects.example.test/blob")
	end)

	helpers.it("still follows an HTTP-to-HTTPS upgrade", function()
		local client, state = load_client({ ["http://example.test/a"] = "https://example.test/a" })
		local terminal
		client.get("http://example.test/a", {}, function(result) terminal = result end)
		helpers.assert_eq(state.fetched[#state.fetched], "https://example.test/a")
		helpers.assert_eq(terminal.ok, true)
	end)
end)
