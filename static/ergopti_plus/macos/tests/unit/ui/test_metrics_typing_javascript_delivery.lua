--- tests/unit/ui/test_metrics_typing_javascript_delivery.lua

--- ==============================================================================
--- MODULE: Typing Metrics JavaScript Delivery Tests
--- DESCRIPTION:
--- Exercises native admission and execution errors through the real request poller.
--- ==============================================================================

local helpers = require("tests.helpers")
local load_dashboard = require("tests.support.metrics_typing_fixture")

local Scope = require("tests.support.metrics_typing_scope")

helpers.describe("typing metrics JavaScript delivery", function()
	for _, mode in ipairs({ "nil", "throw", "execution_error", "self" }) do
		Scope.it("(typing-js-delivery) request poll " .. mode, function()
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
		Scope.it("(typing-js-delivery) callback " .. mode, function()
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


helpers.describe("typing metrics scalar native JSON boundary", function()
	local with_delivery = require("tests.support.typing_delivery_fixture")
	for _, request in ipairs({
		{ action = "clear_cache", reset_id = 1 },
		{ request_id = 17, start_date = "", end_date = "", apps = { 'éditeur 漢 😀\r\n\t"\\' } },
		{ request_id = 18, apps = { '");globalThis.__injected=true;//' } },
	}) do
		Scope.it("(hs-scalar-json-metrics) native table-only encoder accepts request " .. tostring(request.request_id or request.reset_id), function()
			with_delivery(function(_, context, timers, errors, _, evaluations)
				local Json = require("json")
				local req = Json.encode(request)
				local native = package.loaded["hs.json"]
				local encoded_tables = 0
				-- Explicit Hammerspoon 1.1.1 boundary double: libjson.m accepts LS_TTABLE.
				native.encode = function(value)
					helpers.assert_eq(type(value), "table", "native hs.json.encode never accepts scalar strings")
					encoded_tables = encoded_tables + 1
					return Json.encode(value)
				end
				native.decode = Json.decode
				context.poll()
				evaluations[1].done(req)
				helpers.assert_eq(#evaluations, 2, "a valid native request must reach compare-and-reset JavaScript")
				local quoted = assert(evaluations[2].code:match('window%._lua_request!==(.*)%){return false;}'))
				helpers.assert_eq(Json.decode(quoted), req, "all request bytes remain the original JavaScript string")
				helpers.assert_eq(encoded_tables, 0, "scalar delivery uses the canonical string encoder")
				helpers.assert_eq(#errors, 0)
				local queued = #timers
				evaluations[2].done(false)
				helpers.assert_eq(#timers, queued, "a replaced frontend mailbox is not consumed by old reset acknowledgement")
				helpers.assert_eq(#evaluations, 2)
			end)
		end)
	end
	for _, mode in ipairs({ "nil", "false", "throw" }) do
		Scope.it("(hs-scalar-json-metrics) canonical quotation refusal " .. mode .. " remains private", function()
			with_delivery(function(_, context, _, errors, _, evaluations)
				local Json = require("json")
				Json.quote = function()
					if mode == "throw" then error("PRIVATE_MAILBOX_BYTES") end
					if mode == "false" then return false end
				end
				context.poll(); evaluations[1].done('{"request_id":9}')
				context.poll(); evaluations[2].done('{"request_id":9}')
				helpers.assert_eq(#evaluations, 2, "refused encoding sends no reset script")
				helpers.assert_eq(#errors, 1, "duplicate encoding failure is bounded")
				helpers.assert_nil(errors[1]:find("PRIVATE_MAILBOX_BYTES", 1, true))
			end)
		end)
	end
	Scope.it("(hs-scalar-json-metrics) quotation reentry cannot reset a retired window", function()
		with_delivery(function(_, context, _, errors, _, evaluations)
			local Json = require("json")
			local original = Json.quote
			Json.quote = function(value)
				context.on_close()
				return original(value)
			end
			context.poll(); evaluations[1].done('{"request_id":9}')
			helpers.assert_eq(#evaluations, 1)
			helpers.assert_eq(#errors, 0, "retired recipients emit no fresh delivery errors")
		end)
	end)
end)

Scope.it("(hs-scalar-json-metrics) invalid UTF-8 mailbox bytes refuse without publishing JavaScript", function()
	require("tests.support.typing_delivery_fixture")(function(_, context, _, errors, _, evaluations)
		context.poll(); evaluations[1].done('{"request_id":9,"app":"' .. string.char(0xC0, 0xAF) .. '"}')
		helpers.assert_eq(#evaluations, 1)
		helpers.assert_eq(#errors, 1)
		helpers.assert_true(errors[1]:find("request reset; encoding", 1, true) ~= nil)
	end)
end)
