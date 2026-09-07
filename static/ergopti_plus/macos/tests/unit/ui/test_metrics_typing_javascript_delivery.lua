--- tests/unit/ui/test_metrics_typing_javascript_delivery.lua

--- ==============================================================================
--- MODULE: Typing Metrics JavaScript Delivery Tests
--- DESCRIPTION:
--- Exercises native admission and execution errors through the real request poller.
--- ==============================================================================

local helpers = require("tests.helpers")
local load_dashboard = require("tests.support.metrics_typing_fixture")

local function isolated_test(name, callback)
	helpers.it(name, function()
		local saved_hs = _G.hs
		local ok, err = xpcall(function()
			helpers.with_fresh_modules({ "adapters.file_system", "infra.logger", "adapters.timer_scheduler",
				"hs.fs", "hs.json", "ui.ui_builder", "modules.keylogger.log_manager",
				"ui.metrics_typing", "ui.metrics_typing.init" }, callback)
		end, debug.traceback)
		_G.hs = saved_hs
		if not ok then error(err, 0) end
	end)
end

helpers.describe("typing metrics JavaScript delivery", function()
	for _, mode in ipairs({ "nil", "throw", "execution_error", "self" }) do
		isolated_test("(typing-js-delivery) request poll " .. mode, function()
			local poll, completion
			local dashboard, context = load_dashboard({
				after = function() return { timer = {} }, true end,
				every = function(_, callback) poll = callback; return { timer = {} }, true end,
				cancel = function() return true end,
			})
			local errors, calls = {}, 0
			package.loaded["infra.logger"].error = function(_, template, ...)
				errors[#errors + 1] = string.format(template, ...)
			end
			context.webview.evaluateJavaScript = function(self, code, callback)
				calls = calls + 1
				helpers.assert_eq(code, "window._lua_request")
				completion = callback
				if mode == "nil" then return nil end
				if mode == "throw" then error("PRIVATE_NATIVE_DETAIL") end
				return self
			end
			helpers.assert_eq(dashboard.show(), true)
			poll()
			if mode == "execution_error" then completion(nil, { localizedDescription = "PRIVATE_NATIVE_DETAIL" }) end
			helpers.assert_eq(calls, 1)
			helpers.assert_eq(#errors, mode == "self" and 0 or 1)
			for _, message in ipairs(errors) do helpers.assert_nil(message:find("PRIVATE_NATIVE_DETAIL", 1, true)) end
		end)
	end
end)

helpers.describe("typing metrics callback ownership", function()
	for _, mode in ipairs({ "retired", "duplicate", "sync_refused", "repeated" }) do
		isolated_test("(typing-js-delivery) callback " .. mode, function()
			local poll, completion
			local dashboard, context = load_dashboard({
				after = function() return { timer = {} }, true end,
				every = function(_, callback) poll = callback; return { timer = {} }, true end,
				cancel = function() return true end,
			})
			local errors, calls = 0, 0
			package.loaded["infra.logger"].error = function() errors = errors + 1 end
			context.webview.evaluateJavaScript = function(self, _, callback)
				calls = calls + 1
				completion = callback
				if mode == "sync_refused" then callback(nil, {}); return nil end
				if mode == "repeated" then return nil end
				return self
			end
			helpers.assert_eq(dashboard.show(), true)
			poll()
			if mode == "retired" then
				context.on_close()
				completion(nil, {})
			elseif mode == "duplicate" then
				completion(nil, {})
				completion(nil, {})
			elseif mode == "repeated" then poll() end
			helpers.assert_eq(errors, mode == "retired" and 0 or 1)
			helpers.assert_eq(calls, mode == "repeated" and 2 or 1)
		end)
	end
end)
