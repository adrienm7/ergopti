--- tests/unit/modules/keylogger/test_metrics_collector_privacy.lua

--- ============================================================================
--- MODULE: Metrics Collector Logging Privacy Regression
--- DESCRIPTION:
--- Ensures that the high-frequency metrics collector never sends captured text
--- to a logger transport. The logger ring and every configured sink receive the
--- exact formatted message, so a DEBUG-only character leak bypasses at-rest
--- encryption completely.
--- ============================================================================

local helpers = require("tests.helpers")

local function with_spy_logger(body)
	local logger_name = "logger.shim"
	local collector_name = "modules.keylogger.metrics_collector"
	local previous_logger = package.loaded[logger_name]
	local previous_collector = package.loaded[collector_name]
	local lines = {}

	local function record(_, format, ...)
		lines[#lines + 1] = select("#", ...) > 0 and string.format(format, ...) or tostring(format)
	end

	package.loaded[logger_name] = {
		debug = record,
		trace = record,
		done = record,
		info = record,
		start = record,
		success = record,
		warn = record,
		error = record,
	}
	package.loaded[collector_name] = nil

	local ok, err = pcall(function()
		body(require(collector_name), lines)
	end)

	package.loaded[logger_name] = previous_logger
	package.loaded[collector_name] = previous_collector
	helpers.assert_true(ok, "privacy probe must not throw: " .. tostring(err))
end

helpers.describe("metrics collector logging privacy", function()
	helpers.it("never logs a captured character (lnx-060)", function()
		with_spy_logger(function(collector, lines)
			local sentinel = "☠"
			collector.init({})
			collector.on_keydown(sentinel, 1000)

			for _, line in ipairs(lines) do
				helpers.assert_true(not line:find(sentinel, 1, true),
					"a captured character sequence must never reach a logger transport")
			end
			helpers.assert_eq(collector.get_session_stats().keystrokes, 1,
				"removing sensitive diagnostics must not drop the collected keystroke")
		end)
	end)
end)
