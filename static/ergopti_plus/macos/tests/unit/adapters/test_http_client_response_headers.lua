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
