--- tests/unit/adapters/network/test_http_header_capture_contract.lua

--- Admitted headers are detached before timers can reenter the caller.
local helpers = require("tests.helpers")

local function with_client(scenario)
	helpers.with_fresh_modules({ "adapters.http_client", "core.events.timer_scheduler", "infra.logger",
		"infra.http_header_policy" }, function()
		local world = { calls = {}, timers = 0, logs = {}, mutate = function() end }
		local http = {}
		function http.doAsyncRequest(url, method, body, headers, callback)
			world.calls[#world.calls + 1] = { method = method, body = body, headers = headers, callback = callback }
		end
		function http.asyncGet(url, headers, callback)
			world.calls[#world.calls + 1] = { method = "GET", headers = headers, callback = callback }
		end
		function http.asyncPost(url, body, headers, callback)
			world.calls[#world.calls + 1] = { method = "POST", body = body, headers = headers, callback = callback }
		end
		local timer = { secondsSinceEpoch = function() return 0 end }
		function timer.new()
			world.timers = world.timers + 1
			local active = false
			return {
				start = function(self) active = true; world.mutate(); return self end,
				stop = function(self) active = false; return self end,
				running = function() return active end,
			}
		end
		local logger = helpers.make_logger_stub()
		logger.error = function(_, template, ...) world.logs[#world.logs + 1] = string.format(template, ...) end
		package.loaded["infra.logger"] = logger
		local client = helpers.load_with_stubs("adapters.http_client", { http = http, timer = timer }).new()
		scenario(client, world)
	end)
end

helpers.describe("HTTP immutable admission", function()
	for _, method in ipairs({ "get", "post" }) do
		helpers.it("detaches " .. method .. " headers before native timer reentry", function()
			with_client(function(client, world)
				local headers = { ["X-Token"] = "Bearer FIRST", ["X-Mode"] = "original" }
				world.mutate = function() headers["X-Token"] = "Bearer REPLACED"; headers["X-Mode"] = "changed" end
				local accepted
				if method == "get" then accepted = client.get("http://localhost/test", headers, function() end)
				else accepted = client.post("http://localhost/test", headers, "body", function() end) end
				helpers.assert_eq(accepted, true)
				helpers.assert_eq(#world.calls, 1)
				helpers.assert_eq(world.calls[1].headers["X-Token"], "Bearer FIRST")
				helpers.assert_eq(world.calls[1].headers["X-Mode"], "original")
				headers["X-Token"] = "Bearer AFTER"
				helpers.assert_eq(world.calls[1].headers["X-Token"], "Bearer FIRST")
			end)
		end)
	end

	for _, method in ipairs({ "get", "post" }) do
		helpers.it("detaches " .. method .. " credentials on the guarded redirect path", function()
			with_client(function(client, world)
				local headers = { Authorization = "Bearer ORIGINAL" }
				world.mutate = function() headers.Authorization = "Bearer NEW" end
				local accepted
				if method == "get" then accepted = client.get("http://localhost/test", headers, function() end)
				else accepted = client.post("http://localhost/test", headers, "body", function() end) end
				helpers.assert_eq(accepted, true)
				helpers.assert_eq(#world.calls, 1)
				helpers.assert_eq(world.calls[1].headers.Authorization, "Bearer ORIGINAL")
			end)
		end)
	end

	helpers.it("refuses a malformed replacement without native work or leaking its token", function()
		with_client(function(client, world)
			local first, refused
			helpers.assert_true(client.get("http://localhost/first", {}, function(value) first = value end))
			local before_calls, before_timers = #world.calls, world.timers
			local secret = "PRIVATE_TOKEN_123"
			helpers.assert_eq(client.post("http://localhost/next", { Authorization = secret .. "\r\nX: injected" }, "body",
				function(value) refused = value end), false)
			helpers.assert_eq(#world.calls, before_calls)
			helpers.assert_eq(world.timers, before_timers)
			helpers.assert_eq(refused and refused.error_kind, "invalid_request")
			helpers.assert_nil(tostring(refused.error):find(secret, 1, true))
			helpers.assert_true(#world.logs > 0, "the refusal must be reported without its value")
			for _, line in ipairs(world.logs) do helpers.assert_nil(line:find(secret, 1, true)) end
			world.calls[1].callback(200, "ok", {})
			helpers.assert_true(first and first.ok, "the earlier request must still complete")
		end)
	end)
end)
