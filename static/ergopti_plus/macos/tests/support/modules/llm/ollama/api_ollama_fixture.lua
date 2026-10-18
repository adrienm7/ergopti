--- tests/support/modules/llm/ollama/api_ollama_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_api_ollama
--- DESCRIPTION:
--- Prelude shared by the test_api_ollama_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

local ApiOllama = helpers.load_with_stubs("modules.llm.api_ollama")

local function set_upvalue(fn, target, value)
	for index = 1, 64 do
		local name = debug.getupvalue(fn, index)
		if not name then break end
		if name == target then
			debug.setupvalue(fn, index, value)
			return true
		end
	end
	return false
end

local function get_upvalue(fn, target)
	for index = 1, 64 do
		local name, value = debug.getupvalue(fn, index)
		if not name then break end
		if name == target then return value end
	end
	return nil
end





local function warmup_upvalue(fn, target)
	for index = 1, 64 do
		local name, value = debug.getupvalue(fn, index)
		if name == target then return value end
		if not name then break end
	end
	error("Missing actual warmup upvalue: " .. target)
end

local function with_pending_warmup(callback)
	helpers.with_stub_scope({
		"modules.llm.api_ollama", "adapters.http_client", "adapters.timer_scheduler",
		"modules.llm", "modules.llm.warmup_controller",
		"modules.llm.ollama_endpoint", "infra.logger", "infra.notifications",
	}, function()
		local fixture = { requests = {}, timers = {}, origin = "http://localhost:16107" }
		local function post(url, body, _, done)
			helpers.assert_true(url:match("/api/chat$") ~= nil)
			helpers.assert_eq(type(body), "string")
			fixture.requests[#fixture.requests + 1] = { url = url, body = body, done = done }
			if fixture.synchronous then done(fixture.synchronous, "{}", {}) end
			-- The native API returns nil; the actual HTTP adapter retains activity.
			return nil
		end
		local api = helpers.load_with_stubs("modules.llm.api_ollama", {
			http = {
				asyncPost = post,
				doAsyncRequest = function(url, method, body, headers, done)
					helpers.assert_eq(method, "POST")
					return post(url, body, headers, done)
				end,
			},
			timer = { new = function(delay, done)
				local timer = { delay = delay, done = done, active = false, stops = 0 }
				function timer:start()
					self.active = true
					if fixture.on_start then fixture.on_start() end
					return self
				end
				function timer:stop() self.active = false; self.stops = self.stops + 1; return self end
				fixture.timers[#fixture.timers + 1] = timer
				return timer
			end },
		})
		api.get_base_url = function()
			if fixture.on_origin_read then fixture.on_origin_read() end
			return fixture.origin
		end
		local notifications = warmup_upvalue(api.warmup, "Notifications")
		local original_notify = notifications.notify
		notifications.notify = function(...)
			fixture.notification = { ... }
			if fixture.on_notify then fixture.on_notify() end
		end
		local client = warmup_upvalue(api.warmup, "_warmup_client")
		local ok, err = xpcall(function() callback(api, fixture, client) end, debug.traceback)
		if not ok then print("ORIGINAL_CALLBACK_FAILURE " .. tostring(err)) end
		local cleanup_errors = {}
		local function cleanup(action)
			local cleaned, cleanup_error = xpcall(action, debug.traceback)
			if not cleaned then cleanup_errors[#cleanup_errors + 1] = tostring(cleanup_error) end
		end
		cleanup(function() if fixture.finalize then fixture.finalize() end end)
		notifications.notify = original_notify
		cleanup(function()
			helpers.assert_true(client.cancel(), "the controlled original HTTP owner must retire normally")
		end)
		for _, timer in ipairs(fixture.timers) do
			cleanup(function()
				helpers.assert_eq(timer.active, false, "no controlled timeout may survive fixture cleanup")
			end)
		end
		if fixture.after_cleanup then fixture.after_cleanup(notifications.notify == original_notify) end
		if not ok then table.insert(cleanup_errors, 1, tostring(err)) end
		if #cleanup_errors > 0 then error(table.concat(cleanup_errors, "\n"), 0) end
	end)
end

return {
	ApiOllama = ApiOllama,
	get_upvalue = get_upvalue,
	set_upvalue = set_upvalue,
	warmup_upvalue = warmup_upvalue,
	with_pending_warmup = with_pending_warmup,
}
