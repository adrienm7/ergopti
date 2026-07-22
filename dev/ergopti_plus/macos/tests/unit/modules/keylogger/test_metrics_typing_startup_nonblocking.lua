--- tests/unit/modules/keylogger/test_metrics_typing_startup_nonblocking.lua

--- ============================================================================
--- MODULE: Regression — typing dashboard vendor scripts are non-blocking
--- DESCRIPTION:
--- WebKit blocks HTML parsing on ordinary remote scripts. When a CDN stalls,
--- main.js never exports process_manifest before the Lua injector times out and
--- the metrics view remains blank. Chart vendors are optional, so they must be
--- deferred while the local data pipeline continues loading.
--- ============================================================================

local helpers = require("tests.helpers")

helpers.describe("metrics_typing: vendor scripts do not block first paint", function()
	helpers.it("defers every remote chart dependency before the local data pipeline", function()
		local fh = assert(io.open(helpers.shared("ui/metrics_typing/index.html"), "r"))
		local html = fh:read("*a")
		fh:close()
		for _, url in ipairs({
			"chart.js", "date-fns", "chartjs-adapter-date-fns", "hammerjs@2.0.8", "chartjs-plugin-zoom",
		}) do
			helpers.assert_true(html:find('<script defer src="https://cdn.jsdelivr.net/npm/' .. url, 1, true) ~= nil,
				"remote dependency must be deferred: " .. url)
		end
		helpers.assert_true(html:find('<script src="main.js"></script>', 1, true) ~= nil,
			"the local main.js export remains available to the macOS injector")
	end)
end)
