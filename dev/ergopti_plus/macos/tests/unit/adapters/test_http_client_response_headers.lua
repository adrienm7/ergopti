--- tests/unit/adapters/test_http_client_response_headers.lua

--- ==============================================================================
--- MODULE: HttpClient Hands The Response Headers To Its Caller
--- DESCRIPTION:
--- hs.http delivers (status, body, headers), and the adapter dropped the headers:
--- a caller could not read an ETag, so a conditional request (If-None-Match,
--- answered by a 304 that GitHub does not count against its rate limit) was
--- impossible on macOS. The result table now carries them, on the native path
--- and on the credential-safe redirect path.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads a fresh adapter whose native requests answer synchronously.
local function load_client(response_headers)
	package.loaded["adapters.http_client"] = nil
	package.loaded["adapters.timer_scheduler"] = nil
	return helpers.load_with_stubs("adapters.http_client", {
		http = {
			asyncGet = function(_url, _headers, callback)
				callback(200, "[]", response_headers)
				return { cancel = function() return true end }
			end,
			doAsyncRequest = function(_url, _method, _body, _headers, callback)
				callback(200, "[]", response_headers)
				return { cancel = function() return true end }
			end,
		},
	})
end

helpers.describe("http_client: response headers reach the caller", function()
	helpers.it("a plain GET delivers the headers", function()
		local HttpClient = load_client({ ETag = 'W/"abc"', ["Content-Type"] = "application/json" })
		local result = nil
		HttpClient.new().get("https://api.github.com/repos/o/r/releases", { Accept = "application/json" },
			function(r) result = r end)
		helpers.assert_not_nil(result, "the synchronous stub must complete the request")
		helpers.assert_eq(result.status, 200)
		helpers.assert_eq(type(result.headers), "table", "the result carries the response headers")
		helpers.assert_eq(result.headers.ETag, 'W/"abc"')
	end)

	helpers.it("a credentialed GET on the redirect-safe path delivers the headers", function()
		local HttpClient = load_client({ etag = 'W/"def"' })
		local result = nil
		HttpClient.new().get("https://api.example.com/v1", { Authorization = "Bearer x" },
			function(r) result = r end)
		helpers.assert_not_nil(result, "the synchronous stub must complete the request")
		helpers.assert_eq(result.headers.etag, 'W/"def"')
	end)

	helpers.it("a response without headers yields an empty table", function()
		local HttpClient = load_client(nil)
		local result = nil
		HttpClient.new().get("https://api.github.com/x", {}, function(r) result = r end)
		helpers.assert_not_nil(result, "the synchronous stub must complete the request")
		helpers.assert_eq(result.headers, {}, "callers read headers without a nil check")
	end)
end)

--- The adapter over a native double that answers through the returned hooks.
--- @return table client, table callbacks
local function load_fixture()
	local callbacks = {}
	local http = {}
	function http.doAsyncRequest(_url, _method, _body, _headers, callback)
		callbacks[#callbacks + 1] = callback
		return nil
	end
	function http.asyncGet(_url, _headers, callback)
		callbacks[#callbacks + 1] = callback
		return nil
	end
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
	local HttpClient = helpers.load_with_stubs("adapters.http_client", { http = http, timer = timer })
	return HttpClient.new(), callbacks
end

helpers.describe("HttpClient response headers", function()
	helpers.it("hands the response headers to the caller, a 304 included (layout-catalogue)", function()
		local client, callbacks = load_fixture()
		local terminal
		client.get("https://raw.example.test/index.json", { ["If-None-Match"] = '"e1"' },
			function(result) terminal = result end)
		helpers.assert_eq(#callbacks, 1)
		callbacks[1](304, "", { ETag = '"e1"' })
		helpers.assert_eq(terminal.status, 304)
		helpers.assert_eq(terminal.headers.ETag, '"e1"')

		client.get("https://raw.example.test/index.json", {}, function(result) terminal = result end)
		callbacks[2](200, "{}", { Etag = '"e2"' })
		helpers.assert_eq(terminal.ok, true)
		helpers.assert_eq(terminal.headers.Etag, '"e2"')
	end)

	helpers.it("carries no header on a network failure (layout-catalogue)", function()
		local client, callbacks = load_fixture()
		local terminal
		client.get("https://raw.example.test/index.json", {}, function(result) terminal = result end)
		callbacks[1](-1, nil, { ETag = '"stale"' })
		helpers.assert_eq(terminal.status, 0)
		helpers.assert_nil(terminal.headers.ETag)
	end)
end)
