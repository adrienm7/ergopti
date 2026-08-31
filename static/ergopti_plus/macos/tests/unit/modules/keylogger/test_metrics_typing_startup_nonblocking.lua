--- tests/unit/modules/keylogger/test_metrics_typing_startup_nonblocking.lua

--- ============================================================================
--- MODULE: Regression — typing dashboard vendors are local and non-blocking
--- DESCRIPTION:
--- WebKit blocks HTML parsing on ordinary scripts. Chart vendors are committed
--- locally so a CDN can neither stall nor inject into the privileged page, and
--- remain deferred while the local data pipeline continues loading.
--- ============================================================================

local helpers = require("tests.helpers")

helpers.describe("metrics_typing: vendor scripts do not block first paint", function()
	helpers.it("defers every pinned local chart dependency before the data pipeline", function()
		local fh = assert(io.open(helpers.shared("ui/metrics_typing/index.html"), "r"))
		local html = fh:read("*a")
		fh:close()
		for _, file in ipairs({
			"chart.umd.js", "chartjs-adapter-date-fns.bundle.min.js",
			"hammer.min.js", "chartjs-plugin-zoom.min.js",
		}) do
			helpers.assert_true(html:find('<script defer src="../vendor/' .. file, 1, true) ~= nil,
				"local dependency must be deferred: " .. file)
		end
		helpers.assert_true(html:find("cdn.jsdelivr.net", 1, true) == nil,
			"the privileged page must not execute remote dependencies")
		helpers.assert_true(html:find('<script src="main.js"></script>', 1, true) ~= nil,
			"the local main.js export remains available to the macOS injector")

		package.loaded["ui.ui_builder"] = nil
		local builder = require("ui.ui_builder")
		local built = builder.build_injected_html(helpers.shared("ui/metrics_typing/"))
		helpers.assert_true(built:find("Chart.js v4.4.9", 1, true) ~= nil,
			"the macOS inline builder must embed attribute-bearing vendor scripts")
		helpers.assert_true(built:find('src="../vendor/', 1, true) == nil,
			"no relative vendor reference may survive in an inline WKWebView document")
	end)
end)
