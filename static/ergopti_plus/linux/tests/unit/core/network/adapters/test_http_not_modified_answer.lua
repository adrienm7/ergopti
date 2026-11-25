--- static/ergopti_plus/linux/tests/unit/core/network/adapters/test_http_not_modified_answer.lua

--- A 304 is the answer a conditional request asks for. The field report of
--- 2026-11-25 showed « HTTP request failed: HTTP 304. » in the error window each
--- time the layout manager refreshed its catalogue with a cached ETag, although
--- the catalogue then used its cached copy as designed.

local helpers = require("tests.helpers")

helpers.describe("curl HTTP client: 304 Not Modified (http-not-modified)", function()
	helpers.it("treats the 304 of a conditional request as its answer, not a failure (http-not-modified)", function()
		local Client = helpers.load_module("core.network.adapters.curl_http_client")
		helpers.assert_true(Client.is_not_modified_answer({ ok = false, status = 304, error = "HTTP 304" }, true))
	end)

	helpers.it("keeps a 304 nobody asked for, and every other status, a failure (http-not-modified)", function()
		local Client = helpers.load_module("core.network.adapters.curl_http_client")
		helpers.assert_true(not Client.is_not_modified_answer({ ok = false, status = 304 }, false),
			"a 304 without a validator is unexpected")
		helpers.assert_true(not Client.is_not_modified_answer({ ok = false, status = 404 }, true))
		helpers.assert_true(not Client.is_not_modified_answer({ ok = false, status = 0 }, true))
	end)

	helpers.it("logs the not-modified branch before the failure branch (http-not-modified)", function()
		-- The terminal log of finish(): the 304 branch must come before the
		-- ERROR branch, or the user sees the error window again.
		local source = assert(helpers.read_module_source("core.network.adapters.curl_http_client"))
		local answer = source:find("elseif M.is_not_modified_answer(result,", 1, true)
		local failure = source:find('Logger.error(LOG, "HTTP request failed: %s."', 1, true)
		helpers.assert_true(answer ~= nil and failure ~= nil and answer < failure,
			"finish() checks the 304 answer before logging a failure")
	end)
end)
