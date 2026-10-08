--- tests/unit/meta/test_curl_engine_scan.lua

--- ==============================================================================
--- MODULE: Extracted Curl Engine Blocking Transport Guard
--- DESCRIPTION:
--- Inspects the actual production-owned dispatch implementation rather than
--- only its public wrapper. The existing two-file transport scan remains
--- unchanged in the historical suite; this is additional coverage.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("curl_http_client: extracted production engine", function()
	helpers.it("keeps synchronous process execution out of the actual owned dispatch source", function()
		local engine = require("adapters.curl_http_client")
		local source_path = debug.getinfo(engine.dispatch_owned, "S").source:gsub("^@", "")
		helpers.assert_true(source_path:match("/adapters/curl_http_client%.lua$") ~= nil,
			"the scan must inspect the actual production dispatch source")
		local file = assert(io.open(source_path, "rb"))
		local source = file:read("*a"); file:close()
		for _, forbidden in ipairs({ "io%s*%.%s*popen%s*%(", "os%s*%.%s*execute%s*%(" }) do
			helpers.assert_true(source:find(forbidden) == nil,
				"owned curl dispatch cannot block the keyboard event loop with synchronous process execution")
		end
	end)
end)
