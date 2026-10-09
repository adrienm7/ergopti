--- tests/unit/ui/menu/menu_llm/test_ollama_enable_probe.lua

--- ==============================================================================
--- MODULE: Ollama Enable HTTP Ownership
--- DESCRIPTION:
--- Runs the actual HttpClient and probe owner over observable native capabilities.
--- ==============================================================================

local helpers = require("tests.helpers")
local OWNED = { "infra.logger", "adapters.http_client", "adapters.timer_scheduler",
	"ui.menu.menu_llm.ollama_enable_probe", "llm.enable_admission" }

-- ===================================
-- ===================================
-- ======= 1/ Native Port Fixtures ====
-- ===================================
-- ===================================

--- Runs exact HTTP and timer ports without starting external services.
--- @param options table Native refusal injections.
--- @param callback function Receives probe owner and observed ports.
local function with_probe(options, callback)
	helpers.with_stub_scope(OWNED, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		local ports = { requests = {}, timers = {}, delivered = {} }
		local scheduler = {}
		function scheduler.after(_, action)
			local handle = { timer = {}, action = action, observers = {} }
			ports.timers[#ports.timers + 1] = handle
			return handle, true
		end
		function scheduler.cancel(handle)
			if options.timer_refused then return false end
			handle.timer = nil
			local observers = handle.observers
			handle.observers = {}
			for _, observer in ipairs(observers) do observer() end
			return true
		end
		function scheduler.onSettled(handle, observer)
			if handle.timer == nil then observer() else handle.observers[#handle.observers + 1] = observer end
			return true
		end
		package.loaded["adapters.timer_scheduler"] = scheduler
		local Probe = helpers.load_with_stubs("ui.menu.menu_llm.ollama_enable_probe", {
			http = { doAsyncRequest = function(url, method, body, headers, done, cache_policy, follow_redirects)
				local request = { url = url, done = done, cancels = 0, method = method,
					body = body, headers = headers, cache_policy = cache_policy, follow_redirects = follow_redirects }
				function request:cancel()
					self.cancels = self.cancels + 1
					if options.cancel_mode == "throw" then error("native HTTP cancellation refusal") end
					if options.cancel_mode == "nil" then return nil end
					return options.cancel_mode ~= "false"
				end
				ports.requests[#ports.requests + 1] = request
				if options.sync_then_throw then done(200, '{"version":"native-fixture"}', {}) error("native acquisition failed") end
				return request
			end },
		})
		ports.scheduler = scheduler
		ports.observe = function(receipt) ports.delivered[#ports.delivered + 1] = receipt end
		callback(Probe.new(), ports)
	end)
end

-- ===================================
-- ===================================
-- ======= 2/ Exact Settlement =========
-- ===================================
-- ===================================

helpers.describe("Ollama version owner joins actual HTTP capabilities", function()
	helpers.it("delivers the unmodified complete receipt after timeout retirement", function()
		with_probe({}, function(owner, ports)
			helpers.assert_eq(owner.request("http://127.0.0.1:11435", ports.observe), true)
			helpers.assert_eq(owner.scope_idle(), false)
			helpers.assert_eq(ports.requests[1].url, "http://127.0.0.1:11435/api/version")
			helpers.assert_eq(ports.requests[1].method, "GET")
			helpers.assert_eq(ports.requests[1].body, nil)
			helpers.assert_eq(ports.requests[1].headers, {})
			helpers.assert_eq(ports.requests[1].cache_policy, "ignoreLocalCache", "native argument 6 must force a fresh network receipt")
			helpers.assert_eq(ports.requests[1].follow_redirects, false, "the actual native call must refuse opaque redirect following")
			ports.requests[1].done(200, '{"version":"native-fixture"}', {})
			helpers.assert_eq(#ports.delivered, 1)
			helpers.assert_eq(ports.delivered[1].body, '{"version":"native-fixture"}')
			helpers.assert_eq(ports.timers[1].timer, nil)
			helpers.assert_eq(owner.scope_idle(), true)
		end)
	end)

	helpers.it("discards synchronous success from a native acquisition that raises", function()
		with_probe({ sync_then_throw = true }, function(owner, ports)
			helpers.assert_eq(owner.request("http://127.0.0.1:11435", ports.observe), false)
			helpers.assert_eq(#ports.delivered, 0)
			helpers.assert_eq(owner.scope_idle(), true)
		end)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains exact HTTP cleanup after native cancel " .. mode, function()
			with_probe({ cancel_mode = mode }, function(owner, ports)
				helpers.assert_eq(owner.request("http://127.0.0.1:11435", ports.observe), true)
				helpers.assert_eq(owner.cancel(), false)
				helpers.assert_eq(owner.scope_idle(), false)
				helpers.assert_eq(owner.request("http://127.0.0.1:11435", ports.observe), false)
				helpers.assert_eq(#ports.requests, 1)
				ports.requests[1].done(200, '{"version":"late-native"}', {})
				helpers.assert_eq(#ports.delivered, 0)
				helpers.assert_eq(owner.scope_idle(), true)
				helpers.assert_eq(owner.request("http://127.0.0.1:11435", ports.observe), true)
				helpers.assert_eq(#ports.requests, 2)
			end)
		end)
	end

	helpers.it("does not deliver a good response while timeout cleanup is refused", function()
		local options = { timer_refused = true }
		with_probe(options, function(owner, ports)
			helpers.assert_eq(owner.request("http://127.0.0.1:11435", ports.observe), true)
			ports.requests[1].done(200, '{"version":"native-fixture"}', {})
			helpers.assert_eq(#ports.delivered, 0)
			helpers.assert_eq(owner.scope_idle(), false)
			helpers.assert_eq(owner.request("http://127.0.0.1:11435", ports.observe), false)
			options.timer_refused = false
			helpers.assert_eq(ports.scheduler.cancel(ports.timers[1]), true)
			helpers.assert_eq(#ports.delivered, 1)
			helpers.assert_eq(owner.scope_idle(), true)
		end)
	end)
end)

return true
