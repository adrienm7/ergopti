--- tests/unit/lib/test_logger_session_diagnostics.lua

--- ==============================================================================
--- MODULE: Logger Session Diagnostic Ownership Tests
--- DESCRIPTION:
--- Exercises the public logger and real transport across callback-driven restart.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.log_transport_fixture")

--- Loads a private real logger core without opening a synchronous boot sink.
--- @param callback function Receives the real logger and transport fixture.
local function with_logger(callback)
	helpers.with_stub_scope({
		"infra.logger", "logger", "infra.launcher_environment", "_generated.logger_sub_files", "socket",
	}, function()
		Fixture.with_fixture(function()
			local context = Fixture.new_context()
			local Logger = require("infra.logger")
			helpers.assert_eq(Logger.start_async_sink(context.scheduler, context.options), true)
			callback(Logger, context)
		end)
	end)
end

helpers.describe("Logger session diagnostics", function()
	helpers.it("(logger-session-diagnostics) archives a pending failure on ordinary restart", function()
		with_logger(function(Logger, context)
			helpers.assert_eq(Logger.begin_async_sink_shutdown(function() error("unhandled drain marker") end), true)
			context.state.pump()
			helpers.assert_contains(Logger.async_sink_status().pending_failure, "unhandled drain marker")
			helpers.assert_eq(Logger.stop_async_sink(), true)
			helpers.assert_eq(Logger.start_async_sink(context.scheduler, context.options), true)
			local status = Logger.async_sink_status()
			helpers.assert_nil(status.last_error)
			helpers.assert_nil(status.pending_failure)
			helpers.assert_not_nil(status.retired_sink_failure)
			helpers.assert_contains(status.retired_sink_failure.pending_failure, "unhandled drain marker")
			helpers.assert_eq(Logger.stop_async_sink(), true)
		end)
	end)

	for _, boundary in ipairs({ "drain", "failure_handler" }) do
		helpers.it("(logger-session-diagnostics) retains the old " .. boundary .. " error after restart", function()
			with_logger(function(Logger, context)
				local original, successor = {}, {}
				local function restart()
					helpers.assert_eq(Logger.stop_async_sink(), true)
					helpers.assert_eq(Logger.start_async_sink(context.scheduler, context.options), true)
					helpers.assert_eq(Logger.set_async_sink_failure_handler(function(detail)
						successor[#successor + 1] = detail
					end), true)
				end
				helpers.assert_eq(Logger.set_async_sink_failure_handler(function(detail)
					original[#original + 1] = detail
					if boundary == "failure_handler" then
						restart()
						error("old Logger handler marker")
					end
				end), true)
				helpers.assert_eq(Logger.begin_async_sink_shutdown(function()
					if boundary == "drain" then restart() end
					error("old Logger drain marker")
				end), true)
				context.state.pump()
				context.state.pump()
				local status = Logger.async_sink_status()
				helpers.assert_nil(status.last_error, "the public Logger must not relabel an old failure as current")
				helpers.assert_nil(status.pending_failure)
				helpers.assert_nil(status.failure_handler_error)
				helpers.assert_eq(status.active, true)
				helpers.assert_eq(#successor, 0)
				helpers.assert_eq(#original, 1, "the original handler must retain the failure")
				helpers.assert_contains(original[1], "old Logger drain marker")
				helpers.assert_contains(status.retired_sink_failure.last_error, "old Logger drain marker")
				if boundary == "failure_handler" then
					helpers.assert_contains(status.retired_sink_failure.failure_handler_error, "old Logger handler marker")
				end
				status.retired_sink_failure.last_error = "caller mutation"
				helpers.assert_contains(Logger.async_sink_status().retired_sink_failure.last_error, "old Logger drain marker")
				helpers.assert_eq(Logger.stop_async_sink(), true)
			end)
		end)
	end

	helpers.it("(logger-session-diagnostics) keeps a late handler's result with its pending failure", function()
		with_logger(function(Logger, context)
			helpers.assert_eq(Logger.begin_async_sink_shutdown(function() error("pending drain marker") end), true)
			context.state.pump()
			helpers.assert_contains(Logger.async_sink_status().pending_failure, "pending drain marker")
			local original, successor = {}, {}
			local installed, detail = Logger.set_async_sink_failure_handler(function(failure)
				original[#original + 1] = failure
				helpers.assert_eq(Logger.stop_async_sink(), true)
				helpers.assert_eq(Logger.start_async_sink(context.scheduler, context.options), true)
				helpers.assert_eq(Logger.set_async_sink_failure_handler(function(next_failure)
					successor[#successor + 1] = next_failure
				end), true)
				error("late handler marker")
			end)
			helpers.assert_eq(installed, false)
			helpers.assert_contains(detail, "late handler marker")
			local status = Logger.async_sink_status()
			helpers.assert_nil(status.last_error)
			helpers.assert_nil(status.pending_failure)
			helpers.assert_nil(status.failure_handler_error)
			helpers.assert_eq(#original, 1)
			helpers.assert_eq(#successor, 0)
			helpers.assert_contains(status.retired_sink_failure.pending_failure, "pending drain marker")
			helpers.assert_contains(status.retired_sink_failure.failure_handler_error, "late handler marker")
			helpers.assert_eq(Logger.stop_async_sink(), true)
		end)
	end)
end)
