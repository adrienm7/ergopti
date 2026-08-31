--- tests/unit/adapters/test_text_sender_callback_visibility.lua

--- Regression coverage for HS-203: TextSender completion callbacks are an
--- adapter boundary. A throwing caller must not escape into the injection path,
--- but its exception must remain visible through the central logger.

local helpers = require("tests.helpers")

helpers.describe("text_sender completion callback visibility", function()
	helpers.it("logs a throwing completion callback without changing injection success", function()
		helpers.with_fresh_modules({
			"adapters.text_sender",
			"adapters.clipboard",
			"adapters.synthetic_input",
			"adapters.timer_scheduler",
			"infra.logger",
		}, function()
			local errors = {}
			local logger = helpers.make_logger_stub()
			logger.error = function(_log, format, ...)
				errors[#errors + 1] = string.format(format, ...)
			end
			logger.callback = function(log, label, callback, ...)
				local ok, callback_error = xpcall(callback, debug.traceback, ...)
				if not ok then
					logger.error(log, "Callback '%s' raised: %s", label,
						tostring(callback_error))
				end
				return ok, callback_error
			end
			package.loaded["infra.logger"] = logger
			package.loaded["adapters.clipboard"] = {}
			package.loaded["adapters.timer_scheduler"] = {}
			package.loaded["adapters.synthetic_input"] = {
				emit_key_strokes = function(text) return text == "visible" end,
			}

			local sender = helpers.load_with_stubs("adapters.text_sender")
			local callback_count = 0
			local injected = sender.send("visible", { mode = "direct" }, function()
				callback_count = callback_count + 1
				error("injected completion failure")
			end)

			helpers.assert_true(injected,
				"a post-injection callback failure must not rewrite the injection result")
			helpers.assert_eq(callback_count, 1,
				"the completion callback must still run exactly once")
			helpers.assert_eq(#errors, 1,
				"the callback exception must emit one stable diagnostic")
			helpers.assert_contains(errors[1], "Text sender completion")
			helpers.assert_contains(errors[1], "injected completion failure")
		end)
	end)
end)
